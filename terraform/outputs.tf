output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.lab.name
}

output "cluster_endpoint" {
  description = "GKE control plane endpoint."
  value       = google_container_cluster.lab.endpoint
}

output "cluster_zone" {
  description = "Zone the cluster runs in."
  value       = google_container_cluster.lab.location
}

output "gcp_sa_email" {
  description = "GCP service account email — paste into the KSA annotation iam.gke.io/gcp-service-account in k8s/."
  value       = google_service_account.app.email
}

output "get_credentials_command" {
  description = "Paste-ready command to point kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.lab.name} --zone ${google_container_cluster.lab.location} --project ${var.project_id}"
}

output "artifact_registry_repo" {
  description = "Optional Artifact Registry Docker repo (null unless enable_artifact_registry = true)."
  value       = var.enable_artifact_registry ? "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker[0].repository_id}" : null
}
