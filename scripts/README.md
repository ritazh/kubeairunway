# KubeAIRunway Cluster Setup Scripts

## setup-cluster.sh

Bootstraps two bare-metal nodes into a Kubernetes cluster using kubeadm, installs the NVIDIA GPU Operator, and validates GPU access with a CUDA test pod.

The script runs **locally** and SSHes into the remote nodes — you do not need to copy anything to the nodes manually.

### Prerequisites

**Local machine:**
- `ssh` / `scp` with access to both nodes (key-based recommended; password auth supported via `--ssh-password`, requires `sshpass`)
- `kubectl`
- `helm`

**Remote nodes (DGX Spark):**
- Ubuntu 24.04.4 LTS
- NVIDIA drivers pre-installed (standard on DGX OS)
- Internet access for package downloads

### Usage

```bash
./scripts/setup-cluster.sh \
  --control-plane <node1-ip> \
  --worker <node2-ip>
```

If the SSH user on the remote nodes differs from your local username:

```bash
./scripts/setup-cluster.sh \
  --control-plane <node1-ip> \
  --worker <node2-ip> \
  --ssh-user <remote-user> \
  --ssh-password <remote-user-password>
```

### What it does

| Step | Where it runs | What happens |
|------|--------------|--------------|
| Prerequisites | SSH → both nodes | Disables swap, loads kernel modules, installs containerd + kubeadm/kubelet/kubectl |
| Control plane init | SSH → node 1 | Runs `kubeadm init`, sets up kubeconfig |
| Fetch kubeconfig | Local | Copies kubeconfig to `~/.kube/config-dgx`, fixes server URL |
| CNI install | Local | Applies Flannel manifests via kubectl |
| Worker join | SSH → node 2 | Runs `kubeadm join` with a generated token |
| GPU Operator | Local | Installs `nvidia/gpu-operator` via Helm with drivers disabled (DGX OS ships with drivers) |
| GPU validation | Local | Runs `nvidia-smi` in a CUDA pod, prints output, cleans up |

After the script completes, your kubeconfig is at `~/.kube/config-dgx`:

```bash
export KUBECONFIG=~/.kube/config-dgx
kubectl get nodes
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--control-plane <ip>` | *(required)* | IP of the control plane node |
| `--worker <ip>` | *(required)* | IP of the worker node |
| `--ssh-user <user>` | `$USER` | SSH username for remote nodes |
| `--ssh-password <pass>` | *(none)* | SSH password (uses `sshpass`; omit to use key auth or be prompted) |
| `--k8s-version <ver>` | `1.32` | Kubernetes minor version to install |
| `--skip-prereqs` | off | Skip OS package installation (useful for re-runs) |
| `--skip-init` | off | Skip kubeadm init + CNI install; implies `--skip-prereqs` (use when control plane is already up) |
| `--skip-gpu-operator` | off | Skip NVIDIA GPU Operator installation |
| `--validate-only` | off | Only run the GPU validation pod against an existing cluster |

### Re-running after a failure

If the script fails partway through, use `--skip-prereqs` to avoid reinstalling packages that already succeeded:

```bash
./scripts/setup-cluster.sh \
  --control-plane <node1-ip> \
  --worker <node2-ip> \
  --skip-prereqs
```

To re-validate GPUs on an already-running cluster:

```bash
KUBECONFIG=~/.kube/config-dgx \
./scripts/setup-cluster.sh \
  --control-plane <node1-ip> \
  --worker <node2-ip> \
  --validate-only
```

### Deploying KubeAIRunway

Once the cluster is up and GPUs are validated:

```bash
export KUBECONFIG=~/.kube/config-dgx

# Install CRDs and deploy the controller
make controller-install controller-deploy
```
