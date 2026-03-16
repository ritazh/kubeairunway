#!/usr/bin/env bash
# =============================================================================
# KubeAIRunway - DGX Spark Kubernetes Cluster Bootstrap
# =============================================================================
#
# Sets up two NVIDIA DGX Spark nodes as a Kubernetes cluster using kubeadm,
# installs the NVIDIA GPU Operator, and validates GPU access.
#
# This script runs LOCALLY and SSHes into the remote nodes. Key-based SSH is
# recommended. If a password is required, pass --ssh-password (needs sshpass
# installed locally) or omit it to be prompted interactively.
#
# After setup, the kubeconfig is copied locally to ~/.kube/config-dgx and
# all subsequent operations (GPU Operator, validation) are run locally.
#
# Usage:
#   ./scripts/setup-cluster.sh \
#     --control-plane <node1-ip> \
#     --worker <node2-ip> \
#     [--ssh-user <user>]       # default: current $USER
#     [--ssh-password <pass>]   # use password auth via sshpass (prompted if omitted)
#     [--k8s-version <version>] # default: 1.32 (current stable)
#     [--skip-prereqs]          # skip OS prerequisite install (re-run faster)
#     [--skip-init]             # skip kubeadm init + CNI (resume after control plane is up)
#     [--skip-gpu-operator]     # skip GPU Operator install
#     [--validate-only]         # only run GPU validation pod
#
# Prerequisites (local machine):
#   - ssh, scp
#   - kubectl
#   - helm
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
CONTROL_PLANE_IP=""
WORKER_IP=""
SSH_USER="${USER}"
SSH_PASSWORD=""
K8S_VERSION="1.32"
SKIP_PREREQS=0
SKIP_INIT=0
SKIP_GPU_OPERATOR=0
VALIDATE_ONLY=0
KUBECONFIG_PATH="${HOME}/.kube/config-dgx"
export KUBECONFIG="${KUBECONFIG_PATH}"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()     { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }
error()  { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }
die()    { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-plane)   CONTROL_PLANE_IP="$2"; shift 2 ;;
    --worker)          WORKER_IP="$2"; shift 2 ;;
    --ssh-user)        SSH_USER="$2"; shift 2 ;;
    --ssh-password)    SSH_PASSWORD="$2"; shift 2 ;;
    --k8s-version)     K8S_VERSION="$2"; shift 2 ;;
    --skip-prereqs)    SKIP_PREREQS=1; shift ;;
    --skip-init)       SKIP_INIT=1; SKIP_PREREQS=1; shift ;;
    --skip-gpu-operator) SKIP_GPU_OPERATOR=1; shift ;;
    --validate-only)   VALIDATE_ONLY=1; shift ;;
    -h|--help)
      sed -n '14,40p' "$0"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
[[ -n "${CONTROL_PLANE_IP}" ]] || die "--control-plane <ip> is required"
[[ -n "${WORKER_IP}" ]] || die "--worker <ip> is required"

for cmd in ssh scp kubectl helm; do
  command -v "${cmd}" &>/dev/null || die "Required command not found: ${cmd}"
done

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Resolve SSH/SCP prefix: use sshpass if a password was provided or prompt,
# otherwise fall back to key-based auth silently.
if [[ -n "${SSH_PASSWORD}" ]]; then
  command -v sshpass &>/dev/null \
    || die "--ssh-password requires sshpass. Install it with: brew install sshpass (macOS) or apt-get install sshpass (Linux)"
  SSH_PREFIX="sshpass -p ${SSH_PASSWORD}"
  SCP_PREFIX="sshpass -p ${SSH_PASSWORD}"
  # Disable host-key checking (sshpass can't handle interactive prompts)
  SSH_OPTS="${SSH_OPTS} -o PasswordAuthentication=yes -o PubkeyAuthentication=no"
elif ! ssh-add -l &>/dev/null && ! ls "${HOME}/.ssh/id_"* &>/dev/null 2>&1; then
  # No key agent and no key files — prompt for password interactively
  warn "No SSH key found. You will be prompted for the SSH password on each connection."
  warn "Tip: pass --ssh-password <pass> to avoid repeated prompts, or set up key-based auth."
  SSH_PREFIX=""
  SCP_PREFIX=""
else
  SSH_PREFIX=""
  SCP_PREFIX=""
fi

# Helper: run a command on a remote node
remote() {
  local host="$1"; shift
  # shellcheck disable=SC2029,SC2086
  ${SSH_PREFIX} ssh ${SSH_OPTS} "${SSH_USER}@${host}" "$@"
}

# Helper: run a script on a remote node as root (via sudo)
# Uploads the script as a temp file first so sudo's stdin is free for
# password prompting — avoids the conflict of feeding the script via stdin.
remote_script() {
  local host="$1"
  local script="$2"
  local tmp="/tmp/kubeairunway-setup-$$.sh"

  # Step 1: upload script to a temp file (no sudo required)
  # shellcheck disable=SC2086
  printf '%s' "${script}" \
    | ${SSH_PREFIX} ssh ${SSH_OPTS} "${SSH_USER}@${host}" "cat > ${tmp} && chmod 600 ${tmp}"

  # Step 2: execute with sudo
  local exit_code=0
  if [[ -n "${SSH_PASSWORD}" ]]; then
    # Feed password to sudo via stdin (-S); script runs from the file
    # shellcheck disable=SC2086
    ${SSH_PREFIX} ssh ${SSH_OPTS} "${SSH_USER}@${host}" \
      "echo '${SSH_PASSWORD}' | sudo -S bash ${tmp}" || exit_code=$?
  else
    # Allocate a pseudo-TTY so sudo can prompt for a password interactively
    # shellcheck disable=SC2086
    ${SSH_PREFIX} ssh -t ${SSH_OPTS} "${SSH_USER}@${host}" \
      "sudo bash ${tmp}" || exit_code=$?
  fi

  # Step 3: clean up regardless of outcome
  # shellcheck disable=SC2086
  ${SSH_PREFIX} ssh ${SSH_OPTS} "${SSH_USER}@${host}" "rm -f ${tmp}" 2>/dev/null || true

  return "${exit_code}"
}

# Helper: scp with password support
secure_copy() {
  # shellcheck disable=SC2086
  ${SCP_PREFIX} scp ${SSH_OPTS} "$@"
}

# -----------------------------------------------------------------------------
# Phase 0: Validate SSH connectivity
# -----------------------------------------------------------------------------
log "Checking SSH connectivity..."
remote "${CONTROL_PLANE_IP}" "echo ok" &>/dev/null \
  || die "Cannot SSH to control plane ${CONTROL_PLANE_IP} as ${SSH_USER}"
remote "${WORKER_IP}" "echo ok" &>/dev/null \
  || die "Cannot SSH to worker ${WORKER_IP} as ${SSH_USER}"
ok "SSH connectivity verified"

if [[ "${VALIDATE_ONLY}" -eq 1 ]]; then
  log "Skipping cluster setup (--validate-only)"
else

# -----------------------------------------------------------------------------
# Phase 1: Install prerequisites on both nodes
# -----------------------------------------------------------------------------
if [[ "${SKIP_PREREQS}" -eq 0 ]]; then
  PREREQ_SCRIPT=$(cat <<'SCRIPT'
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.32}"

echo "==> Disabling swap"
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

echo "==> Loading kernel modules"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> Setting sysctl params"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "==> Installing containerd"
apt-get update -qq
apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg

# Configure containerd with systemd cgroup driver
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "==> Installing kubeadm, kubelet, kubectl (${K8S_VERSION})"
KUBE_MINOR=$(echo "${K8S_VERSION}" | cut -d. -f1-2)
KUBE_MAJOR=$(echo "${K8S_VERSION}" | cut -d. -f1)
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq "kubelet" "kubeadm" "kubectl"
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet
echo "==> Prerequisites installed"
SCRIPT
)

  log "Installing prerequisites on control plane (${CONTROL_PLANE_IP})..."
  remote_script "${CONTROL_PLANE_IP}" "K8S_VERSION=${K8S_VERSION} $(echo "${PREREQ_SCRIPT}")"
  ok "Prerequisites installed on control plane"

  log "Installing prerequisites on worker (${WORKER_IP})..."
  remote_script "${WORKER_IP}" "K8S_VERSION=${K8S_VERSION} $(echo "${PREREQ_SCRIPT}")"
  ok "Prerequisites installed on worker"
else
  warn "Skipping prerequisite install (--skip-prereqs)"
fi

# -----------------------------------------------------------------------------
# Phase 2: Initialize control plane
# -----------------------------------------------------------------------------
if [[ "${SKIP_INIT}" -eq 1 ]]; then
  warn "Skipping control plane init (--skip-init)"
else
log "Initializing Kubernetes control plane on ${CONTROL_PLANE_IP}..."

INIT_SCRIPT=$(cat <<SCRIPT
set -euo pipefail

# If a previous init left state behind, reset first
if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "==> Detected previous kubeadm init — resetting first"
  kubeadm reset -f
fi

echo "==> Running kubeadm init"
if ! kubeadm init \
  --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
  --pod-network-cidr=10.244.0.0/16 \
  2>&1 | tee /tmp/kubeadm-init.log; then
  echo "ERROR: kubeadm init failed. Full log:"
  cat /tmp/kubeadm-init.log
  exit 1
fi

# Stage kubeconfig in /tmp so scp can read it without root
cp /etc/kubernetes/admin.conf /tmp/kubeadm-admin.conf
chmod 644 /tmp/kubeadm-admin.conf
echo "==> kubeconfig staged at /tmp/kubeadm-admin.conf"

# Extract the join command from init output into a readable file
grep -E "(kubeadm join|--token|--discovery)" /tmp/kubeadm-init.log \
  | tr -d '\t\\' | tr '\n' ' ' | sed 's/  */ /g' > /tmp/kubeadm-join.txt
chmod 644 /tmp/kubeadm-join.txt
echo "==> join command staged at /tmp/kubeadm-join.txt"
SCRIPT
)

remote_script "${CONTROL_PLANE_IP}" "${INIT_SCRIPT}"
ok "Control plane initialized"

# -----------------------------------------------------------------------------
# Phase 2b: Fetch kubeconfig locally
# -----------------------------------------------------------------------------
log "Copying kubeconfig to ${KUBECONFIG_PATH}..."
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
secure_copy "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/kubeadm-admin.conf" "${KUBECONFIG_PATH}"
# Fix the server address (kubeadm may write 0.0.0.0 or localhost in some configs)
sed -i.bak "s|https://.*:6443|https://${CONTROL_PLANE_IP}:6443|g" "${KUBECONFIG_PATH}"
ok "Kubeconfig saved to ${KUBECONFIG_PATH}"

# Wait for API server to be reachable
log "Waiting for API server..."
for i in $(seq 1 30); do
  kubectl get nodes &>/dev/null && break
  sleep 5
done
kubectl get nodes

# -----------------------------------------------------------------------------
# Phase 2c: Install CNI (Flannel) — run locally
# -----------------------------------------------------------------------------
log "Installing Flannel CNI..."
kubectl apply \
  -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
ok "Flannel CNI installed"

# -----------------------------------------------------------------------------
# Phase 2d: Remove control-plane NoSchedule taint
# -----------------------------------------------------------------------------
log "Removing NoSchedule taint from control plane node..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
ok "Control plane taint removed (workloads can now schedule on control plane)"
fi  # end skip-init

# -----------------------------------------------------------------------------
# Phase 2d: Retrieve join command (extracted from init log, no sudo needed)
# -----------------------------------------------------------------------------
log "Retrieving join command..."
JOIN_CMD=$(remote "${CONTROL_PLANE_IP}" "cat /tmp/kubeadm-join.txt" \
  | tr -s ' ' | sed 's/^ //;s/ $//')
[[ -n "${JOIN_CMD}" ]] || die "Could not retrieve join command from /tmp/kubeadm-join.txt on control plane"
ok "Join command: ${JOIN_CMD}"

# -----------------------------------------------------------------------------
# Phase 3: Join worker node
# -----------------------------------------------------------------------------
log "Joining worker node (${WORKER_IP}) to the cluster..."
remote_script "${WORKER_IP}" "${JOIN_CMD}"
ok "Worker joined"

# Wait for both nodes to be Ready
log "Waiting for both nodes to be Ready..."
kubectl wait node \
  --all --for=condition=Ready --timeout=300s
ok "All nodes are Ready"
kubectl get nodes -o wide

fi  # end VALIDATE_ONLY skip

# -----------------------------------------------------------------------------
# Phase 4: NVIDIA GPU Operator
# -----------------------------------------------------------------------------
if [[ "${VALIDATE_ONLY}" -eq 0 && "${SKIP_GPU_OPERATOR}" -eq 0 ]]; then
  log "Installing NVIDIA GPU Operator..."

  # Add NVIDIA Helm repo
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
  helm repo update

  # DGX Spark ships with NVIDIA drivers pre-installed — skip driver installation
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --set driver.enabled=false \
    --wait \
    --timeout=10m

  ok "NVIDIA GPU Operator installed"
elif [[ "${SKIP_GPU_OPERATOR}" -eq 1 ]]; then
  warn "Skipping GPU Operator install (--skip-gpu-operator)"
fi

# -----------------------------------------------------------------------------
# Phase 5: GPU Validation
# -----------------------------------------------------------------------------
log "Running GPU validation pod..."

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-validation
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: cuda-test
    image: nvidia/cuda:12.4.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

log "Waiting for cuda-validation pod to complete..."
# Wait for terminal state (pod goes directly to Succeeded/Failed, never Ready)
for i in $(seq 1 60); do
  PHASE=$(kubectl get pod cuda-validation \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]] && break
  sleep 5
done

echo ""
echo "=== nvidia-smi output ==="
kubectl logs cuda-validation
echo "========================="

FINAL_PHASE=$(kubectl get pod cuda-validation \
  -o jsonpath='{.status.phase}')

log "Cleaning up validation pod..."
kubectl delete pod cuda-validation --ignore-not-found

echo ""
log "GPU resource capacity per node:"
kubectl get nodes \
  -o custom-columns="NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu"

if [[ "${FINAL_PHASE}" == "Succeeded" ]]; then
  ok "GPU validation PASSED"
else
  die "GPU validation FAILED (pod phase: ${FINAL_PHASE})"
fi

echo ""
ok "Cluster setup complete!"
echo ""
echo "  Kubeconfig: ${KUBECONFIG_PATH}"
echo ""
echo "  To use this cluster:"
echo "    export KUBECONFIG=${KUBECONFIG_PATH}"
echo "    kubectl get nodes"
echo ""
echo "  To deploy KubeAIRunway:"
echo "    make controller-install controller-deploy"
