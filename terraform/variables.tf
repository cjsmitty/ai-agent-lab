variable "project_id" {
  description = "GCP project ID that hosts the ephemeral lab cluster."
  type        = string
}

variable "region" {
  description = "GCP region (used by the provider; the cluster itself is zonal)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the zonal GKE cluster (one zone = one control plane = cheapest)."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the ephemeral GKE cluster."
  type        = string
  default     = "ai-agent-lab"
}

variable "node_count" {
  description = "Number of spot e2-standard-2 nodes. 2 runs the app + Harness delegate (1000m CPU); 3 adds a node so the Harness CI build pod (~930m CPU) can also schedule. Keep it small — it's a cost guard."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count must be 1, 2, or 3 — this is a cheap throwaway demo cluster."
  }
}

variable "node_machine_type" {
  description = "Machine type for the node pool. e2-standard-2 (2 vCPU / 8GB) is required so the Harness delegate (1000m CPU / 2Gi memory request) fits alongside app pods. Shared-core types are too small: e2-small (~940m/1.33Gi) and e2-medium (1 vCPU, ~940m allocatable CPU) both fall short of the delegate's 1000m CPU request. e2-standard-2 gives ~1930m allocatable CPU and ~6.5Gi allocatable memory."
  type        = string
  default     = "e2-standard-2"
}

# --- Shared naming conventions (must stay in sync with k8s/, see CLAUDE.md) ---

variable "k8s_namespace" {
  description = "Legacy single-namespace of the app (backward compat with the originally-running deploy). Kept bound for Workload Identity; the multi-env demo uses app_namespaces below."
  type        = string
  default     = "ai-agent"
}

variable "app_namespaces" {
  description = "Multi-env namespaces the app deploys into (Harness dev/uat/prd on the same cluster). Each gets a Workload Identity binding for the SHARED gcp_sa_name SA, using the same ksa_name. Must match k8s/ manifests (CLAUDE.md conventions)."
  type        = list(string)
  default     = ["ai-agent-dev", "ai-agent-uat", "ai-agent-prd"]
}

variable "ksa_name" {
  description = "Kubernetes ServiceAccount name of the app — must match k8s/ manifests (Workload Identity binding)."
  type        = string
  default     = "ai-agent-sa"
}

variable "gcp_sa_name" {
  description = "Account ID of the GCP service account the app impersonates via Workload Identity."
  type        = string
  default     = "ai-agent-app"
}

# --- Optional extras ---

variable "enable_artifact_registry" {
  description = "Create an Artifact Registry Docker repo. Default false — DockerHub is the primary registry for the lab, and stored images bill even when the cluster is destroyed."
  type        = bool
  default     = false
}

variable "artifact_repo_name" {
  description = "Name of the optional Artifact Registry Docker repository."
  type        = string
  default     = "ai-agent-lab"
}
