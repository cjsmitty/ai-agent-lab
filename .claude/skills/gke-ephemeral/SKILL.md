---
name: gke-ephemeral
description: The cheap, throwaway GKE-via-Terraform pattern — zonal Standard cluster on spot/preemptible e2-small nodes, API enablement, Workload Identity, clean destroy, and cost guards. Use when writing or reviewing Terraform for short-lived demo clusters.
---

# Ephemeral GKE via Terraform (cheap, clean up/down)

One command up, one command down, no lingering spend. For demo clusters that live hours, not weeks.

## Cost-minimal shape
- **Zonal Standard cluster** (not regional, not Autopilot): one zone = one control plane, no multi-zone node replication. Autopilot is simpler but slower to start and less tunable; Standard e2-small spot is the cheapest throwaway.
- Node pool: 1–2 × `e2-small`, `spot = true` (spot supersedes `preemptible`). Fine for a demo; pods can be evicted — don't use for anything real.
- `deletion_protection = false` on the cluster — otherwise `terraform destroy` fails and the demo cluster lingers, billing.
- Remove the default node pool (`remove_default_node_pool = true`, `initial_node_count = 1`) and manage a `google_container_node_pool` explicitly.

## Required project services
```hcl
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "aiplatform.googleapis.com",   # Vertex AI for the agent's Gemini calls
  ])
  service            = each.key
  disable_on_destroy = false   # never disable shared APIs on teardown — breaks other uses of the project
}
```
Add `depends_on` from the cluster to the API resources — first apply in a fresh project fails otherwise.

## Workload Identity (the no-API-key story)
- Cluster: `workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }`
- Node pool: `workload_metadata_config { mode = "GKE_METADATA" }`
- App SA: `google_service_account` + project-level `roles/aiplatform.user`
- Binding: `google_service_account_iam_member` with role `roles/iam.workloadIdentityUser`, member `serviceAccount:${var.project_id}.svc.id.goog[<namespace>/<ksa-name>]` — namespace/KSA must exactly match the k8s manifests; the KSA carries the `iam.gke.io/gcp-service-account: <gcp-sa-email>` annotation.

## Lifecycle & guards
```
terraform init
terraform apply -var-file=terraform.tfvars    # ~5–10 min
# demo...
terraform destroy -var-file=terraform.tfvars  # ALWAYS after each session
```
- Output a paste-ready `gcloud container clusters get-credentials <name> --zone <zone> --project <project>`.
- Destroy leftovers to check for: LoadBalancer Services created by kubectl/Harness (delete the k8s Service first or the forwarding rule/firewall may orphan), and Artifact Registry images (storage billing).
- `terraform.tfvars` is gitignored; ship `terraform.tfvars.example`. Pin `google` provider versions. Local state is fine for a throwaway lab.
- Timing gotcha: GKE create ≈ 5–10 min, destroy ≈ 5 min — stand up the cluster BEFORE the demo slot, never during.
