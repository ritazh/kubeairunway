package v1alpha1

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	airunwayv1alpha1 "github.com/kaito-project/airunway/controller/api/v1alpha1"
)

func podJSON(t *testing.T, pod *corev1.Pod) []byte {
	t.Helper()
	raw, err := json.Marshal(pod)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestWebhookInjectsCPUPreferredAffinity(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pod",
			Namespace: "default",
			Labels:    map[string]string{airunwayv1alpha1.LabelCPUPreferred: "true"},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{{Name: "model", Image: "test:latest"}},
			Affinity: &corev1.Affinity{
				NodeAffinity: &corev1.NodeAffinity{
					RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
						NodeSelectorTerms: []corev1.NodeSelectorTerm{{
							MatchExpressions: []corev1.NodeSelectorRequirement{{
								Key:      "kubernetes.io/os",
								Operator: corev1.NodeSelectorOpIn,
								Values:   []string{"linux"},
							}},
						}},
					},
				},
			},
		},
	}

	h := &cpuPreferredHandler{}
	resp := h.Handle(context.Background(), admission.Request{
		AdmissionRequest: admissionv1.AdmissionRequest{
			Object: runtime.RawExtension{Raw: podJSON(t, pod)},
		},
	})

	if resp.Result != nil && resp.Result.Code == http.StatusBadRequest {
		t.Fatalf("webhook returned error: %s", resp.Result.Message)
	}
	if !resp.Allowed {
		t.Fatal("expected admission to be allowed")
	}
	if len(resp.Patches) == 0 {
		t.Fatal("expected patches to be returned")
	}

	patched := pod.DeepCopy()
	injectCPUPreferredAffinity(patched)

	prefs := patched.Spec.Affinity.NodeAffinity.PreferredDuringSchedulingIgnoredDuringExecution
	if len(prefs) != 1 {
		t.Fatalf("expected 1 preferred term, got %d", len(prefs))
	}
	if prefs[0].Weight != 100 {
		t.Errorf("expected weight 100, got %d", prefs[0].Weight)
	}
	expr := prefs[0].Preference.MatchExpressions[0]
	if expr.Key != "nvidia.com/gpu.present" || expr.Operator != corev1.NodeSelectorOpDoesNotExist {
		t.Errorf("unexpected expression: %+v", expr)
	}

	required := patched.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution
	if required == nil || len(required.NodeSelectorTerms) == 0 {
		t.Error("required affinity was removed")
	}
}

func TestWebhookSkipsNonLabelledPod(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "gpu-pod", Namespace: "default"},
		Spec:       corev1.PodSpec{Containers: []corev1.Container{{Name: "model", Image: "test:latest"}}},
	}

	h := &cpuPreferredHandler{}
	resp := h.Handle(context.Background(), admission.Request{
		AdmissionRequest: admissionv1.AdmissionRequest{
			Object: runtime.RawExtension{Raw: podJSON(t, pod)},
		},
	})

	if !resp.Allowed {
		t.Fatal("expected admission to be allowed")
	}
	if len(resp.Patches) != 0 {
		t.Error("expected no patches for non-labelled pod")
	}
}

func TestInjectCPUPreferredAffinityPreservesExisting(t *testing.T) {
	pod := &corev1.Pod{
		Spec: corev1.PodSpec{
			Affinity: &corev1.Affinity{
				NodeAffinity: &corev1.NodeAffinity{
					PreferredDuringSchedulingIgnoredDuringExecution: []corev1.PreferredSchedulingTerm{
						{
							Weight: 50,
							Preference: corev1.NodeSelectorTerm{
								MatchExpressions: []corev1.NodeSelectorRequirement{{
									Key:      "zone",
									Operator: corev1.NodeSelectorOpIn,
									Values:   []string{"us-west"},
								}},
							},
						},
					},
				},
			},
		},
	}

	injectCPUPreferredAffinity(pod)

	prefs := pod.Spec.Affinity.NodeAffinity.PreferredDuringSchedulingIgnoredDuringExecution
	if len(prefs) != 2 {
		t.Fatalf("expected 2 preferred terms, got %d", len(prefs))
	}
	if prefs[0].Weight != 50 {
		t.Error("existing preferred term was modified")
	}
	if prefs[1].Weight != 100 {
		t.Error("new term not appended correctly")
	}
}
