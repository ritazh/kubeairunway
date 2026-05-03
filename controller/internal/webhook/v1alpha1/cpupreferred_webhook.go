/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1alpha1

import (
	"context"
	"encoding/json"
	"net/http"

	corev1 "k8s.io/api/core/v1"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	airunwayv1alpha1 "github.com/kaito-project/airunway/controller/api/v1alpha1"
)

const cpuPreferredWebhookPath = "/mutate-v1-pod"

var cpuPreferredLog = logf.Log.WithName("cpu-preferred-webhook")

// +kubebuilder:webhook:path=/mutate-v1-pod,mutating=true,failurePolicy=ignore,sideEffects=None,groups="",resources=pods,verbs=create,versions=v1,name=cpu-preferred.airunway.ai,admissionReviewVersions=v1

// SetupCPUPreferredWebhookWithManager registers the pod-mutating webhook
// that injects soft node anti-affinity for GPU nodes on pods labelled
// with airunway.ai/cpu-preferred=true.
func SetupCPUPreferredWebhookWithManager(mgr ctrl.Manager) {
	mgr.GetWebhookServer().Register(cpuPreferredWebhookPath, &webhook.Admission{
		Handler: &cpuPreferredHandler{},
	})
}

type cpuPreferredHandler struct{}

func (h *cpuPreferredHandler) Handle(_ context.Context, req admission.Request) admission.Response {
	pod := &corev1.Pod{}
	if err := json.Unmarshal(req.Object.Raw, pod); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	if pod.Labels[airunwayv1alpha1.LabelCPUPreferred] != "true" {
		return admission.Allowed("not a cpu-preferred pod")
	}

	cpuPreferredLog.Info("injecting cpu-preferred affinity", "pod", pod.Name, "namespace", pod.Namespace)
	injectCPUPreferredAffinity(pod)

	marshaled, err := json.Marshal(pod)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}
	return admission.PatchResponseFromRaw(req.Object.Raw, marshaled)
}

// injectCPUPreferredAffinity adds a preferredDuringSchedulingIgnoredDuringExecution
// term that favours nodes without nvidia.com/gpu.present. This is additive —
// it does not overwrite any existing affinity rules.
func injectCPUPreferredAffinity(pod *corev1.Pod) {
	term := corev1.PreferredSchedulingTerm{
		Weight: 100,
		Preference: corev1.NodeSelectorTerm{
			MatchExpressions: []corev1.NodeSelectorRequirement{
				{
					Key:      "nvidia.com/gpu.present",
					Operator: corev1.NodeSelectorOpDoesNotExist,
				},
			},
		},
	}

	if pod.Spec.Affinity == nil {
		pod.Spec.Affinity = &corev1.Affinity{}
	}
	if pod.Spec.Affinity.NodeAffinity == nil {
		pod.Spec.Affinity.NodeAffinity = &corev1.NodeAffinity{}
	}
	pod.Spec.Affinity.NodeAffinity.PreferredDuringSchedulingIgnoredDuringExecution = append(
		pod.Spec.Affinity.NodeAffinity.PreferredDuringSchedulingIgnoredDuringExecution,
		term,
	)
}
