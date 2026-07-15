# Ephemeral, cheap GKE cluster for the Harness AI Agent Lab.
#
# Lifecycle (stand up BEFORE the demo slot — create takes ~5-10 min):
#   terraform init
#   terraform apply -var-file=terraform.tfvars     # ~5-10 min
#   ... demo ...
#   terraform destroy -var-file=terraform.tfvars   # ALWAYS after each session (~5 min)
#
# Before destroy: delete any LoadBalancer Services created via kubectl/Harness
# first, or their forwarding rules/firewalls may orphan and keep billing.
#
# Cost guards baked in below: zonal (not regional/Autopilot), 1-3 e2-standard-2
# SPOT nodes, small standard disks, deletion_protection = false so destroy
# never leaves a billing cluster behind.
# (e2-standard-2, not e2-small/e2-medium: the Harness delegate requests 1000m
# CPU / 2Gi and will not schedule on shared-core nodes — e2-small and e2-medium
# both expose only ~940m allocatable CPU, below the delegate's 1000m request.
# e2-standard-2 (2 vCPU / 8GB) gives ~1930m/~6.5Gi allocatable per node.)

# ---------------------------------------------------------------------------
# Project APIs — enabled by apply, NEVER disabled by destroy
# (disable_on_destroy = false: disabling shared APIs would break other uses
# of the project and slow down the next lab apply).
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",        # GKE
    "compute.googleapis.com",          # nodes, disks, networking
    "artifactregistry.googleapis.com", # optional Docker repo
    "aiplatform.googleapis.com",       # Vertex AI (Gemini calls from the agent)
    "iam.googleapis.com",              # service accounts
    "iamcredentials.googleapis.com",   # Workload Identity token exchange
  ])

  service            = each.key
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# GKE — zonal Standard cluster, default node pool removed, explicit spot pool
# ---------------------------------------------------------------------------
resource "google_container_cluster" "lab" {
  name     = var.cluster_name
  location = var.zone # zonal: single control plane, no multi-zone node replication

  # Cost/teardown guard: without this, `terraform destroy` fails and the
  # demo cluster lingers, billing.
  deletion_protection = false

  # Manage the node pool explicitly; the default pool is created then removed.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity — the no-API-key path to Vertex AI.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # First apply in a fresh project fails without the APIs enabled first.
  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "spot" {
  name     = "spot-pool"
  cluster  = google_container_cluster.lab.name
  location = var.zone

  node_count = var.node_count # 1-3 enforced by variable validation (3 fits the CI build pod)

  node_config {
    machine_type = var.node_machine_type # e2-standard-2
    spot         = true                  # cheapest; pods can be evicted — demo only
    disk_size_gb = 30
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Required on the node pool for Workload Identity to serve pod tokens.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ---------------------------------------------------------------------------
# Vertex AI auth via Workload Identity — no API keys anywhere.
# ONE SHARED GCP SA (ai-agent-app, roles/aiplatform.user) is impersonated by the
# KSA <namespace>/<ksa_name> (see k8s/ and CLAUDE.md conventions) in EACH app
# namespace; every KSA carries the annotation
#   iam.gke.io/gcp-service-account: <gcp_sa_email output>
#
# Multi-env: the app deploys to dev/uat/prd namespaces on the same cluster, each
# with its own KSA (same name, ai-agent-sa) but all sharing this single GCP SA.
# A workloadIdentityUser binding is required per (namespace/KSA) principal —
# without it, pods in that namespace get NO Vertex auth. The bindings live on
# the GCP SA side, so the namespaces need not exist yet (no ordering dependency
# on Harness deploying first).
# ---------------------------------------------------------------------------
resource "google_service_account" "app" {
  account_id   = var.gcp_sa_name
  display_name = "AI Agent Lab app (Vertex AI via Workload Identity)"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "app_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.app.email}"
}

# Legacy single-namespace binding (ai-agent/ai-agent-sa). Kept for backward
# compat with the originally-running deploy so it does not lose Vertex auth; the
# multi-env dev/uat/prd bindings are added additively below.
resource "google_service_account_iam_member" "app_workload_identity" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.ksa_name}]"

  # The Workload Identity pool PROJECT.svc.id.goog is created lazily when the
  # first WI-enabled cluster comes up. Without this dependency, Terraform
  # applies the binding in parallel with cluster creation and it fails with
  # "Error 400: Identity Pool does not exist (PROJECT.svc.id.goog)" (observed
  # on a fresh project). The cluster (not the node pool) is the right
  # dependency: the pool exists as soon as the cluster with
  # workload_identity_config is up.
  #
  # Note: on brand-new projects a short IAM propagation window can still
  # surface the same 400 even after the cluster exists — simply re-run
  # `terraform apply`; it resolves cleanly and is idempotent.
  depends_on = [google_container_cluster.lab]
}

# Multi-env bindings: one workloadIdentityUser member per app namespace
# (dev/uat/prd), all pointing at the SAME shared GCP SA and the same KSA name.
# Members created:
#   serviceAccount:PROJECT.svc.id.goog[ai-agent-dev/ai-agent-sa]
#   serviceAccount:PROJECT.svc.id.goog[ai-agent-uat/ai-agent-sa]
#   serviceAccount:PROJECT.svc.id.goog[ai-agent-prd/ai-agent-sa]
resource "google_service_account_iam_member" "app_workload_identity_envs" {
  for_each = toset(var.app_namespaces)

  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value}/${var.ksa_name}]"

  # Same lazy Identity Pool dependency as the legacy binding above; see its note.
  depends_on = [google_container_cluster.lab]
}

# ---------------------------------------------------------------------------
# Optional Artifact Registry Docker repo (default OFF — DockerHub is primary).
# Cost guard: stored images bill even after the cluster is destroyed; if you
# enable this, destroy removes the repo and its images with it.
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "docker" {
  count = var.enable_artifact_registry ? 1 : 0

  repository_id = var.artifact_repo_name
  location      = var.region
  format        = "DOCKER"
  description   = "Optional Docker repo for the AI Agent Lab (DockerHub is primary)."

  depends_on = [google_project_service.apis]
}
