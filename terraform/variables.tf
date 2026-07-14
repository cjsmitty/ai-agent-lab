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
  description = "Number of spot e2-small nodes (1-2 is plenty for the demo; keep it small, it's a cost guard)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = "node_count must be 1 or 2 — this is a cheap throwaway demo cluster."
  }
}

variable "node_machine_type" {
  description = "Machine type for the node pool."
  type        = string
  default     = "e2-small"
}

# --- Shared naming conventions (must stay in sync with k8s/, see CLAUDE.md) ---

variable "k8s_namespace" {
  description = "Kubernetes namespace of the app — must match k8s/ manifests (Workload Identity binding)."
  type        = string
  default     = "ai-agent"
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
