#!/usr/bin/env bash
# scripts/up.sh — stand up the ephemeral AI Agent Lab: terraform apply the GKE
# cluster, point kubectl at it, patch the k8s placeholder values into a TEMP
# copy of k8s/ (the checked-in manifests are never modified), deploy, and
# print the demo URL.
#
# Runs on YOUR machine. Prereqs: terraform, gcloud, kubectl on PATH; GCP
# Application Default Credentials; terraform/terraform.tfvars filled in
# (copy terraform/terraform.tfvars.example).
#
# Usage:
#   scripts/up.sh [-i|--image FULL_IMAGE_REF]
#
# Env vars:
#   DOCKERHUB_USER=me      -> deploy image me/ai-agent-lab:latest
#                             (ignored if -i/--image is given)
#   TF_AUTO_APPROVE=1      -> pass -auto-approve to terraform apply
#
# If neither -i/--image nor DOCKERHUB_USER is set, the DOCKERHUB_USER
# placeholder is left in the Deployment: the pod will sit in
# ImagePullBackOff until Harness (or you) deploys a real image. That is an
# acceptable state for wiring up the pipeline — the script warns instead of
# failing.
#
# COST: the cluster and the LoadBalancer bill by the hour. Run
# scripts/down.sh after EVERY demo session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
K8S_DIR="${REPO_ROOT}/k8s"
NAMESPACE="ai-agent"

ok()   { echo "✓ $*"; }
warn() { echo "! $*" >&2; }
fail() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Args -------------------------------------------------------------------
IMAGE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      [[ $# -ge 2 ]] || fail "$1 requires a value (full image ref, e.g. myuser/ai-agent-lab:latest)"
      IMAGE_REF="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (see --help)"
      ;;
  esac
done
if [[ -z "${IMAGE_REF}" && -n "${DOCKERHUB_USER:-}" ]]; then
  IMAGE_REF="${DOCKERHUB_USER}/ai-agent-lab:latest"
fi

# --- Preflight ---------------------------------------------------------------
step "Preflight checks"
for tool in terraform gcloud kubectl; do
  command -v "${tool}" >/dev/null 2>&1 \
    || fail "'${tool}' not found on PATH — install it first (see README 'Infrastructure' section)."
done
ok "terraform, gcloud, kubectl found"

[[ -f "${TF_DIR}/terraform.tfvars" ]] || fail "missing ${TF_DIR}/terraform.tfvars —
  cp ${TF_DIR}/terraform.tfvars.example ${TF_DIR}/terraform.tfvars
  then edit project_id (tfvars is gitignored, never commit it)."
ok "terraform.tfvars present"

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  fail "no GCP Application Default Credentials — run:
  gcloud auth application-default login
(and 'gcloud auth login' if gcloud itself isn't authenticated yet)."
fi
ok "GCP Application Default Credentials working"

# --- Terraform apply ---------------------------------------------------------
step "terraform init"
terraform -chdir="${TF_DIR}" init -input=false
ok "init complete"

step "terraform apply (cluster create takes ~5-10 min)"
APPLY_ARGS=(-var-file=terraform.tfvars)
if [[ "${TF_AUTO_APPROVE:-0}" == "1" ]]; then
  APPLY_ARGS+=(-auto-approve)
  warn "TF_AUTO_APPROVE=1 — applying without confirmation"
fi
terraform -chdir="${TF_DIR}" apply "${APPLY_ARGS[@]}"
ok "terraform apply complete"

# --- Read outputs ------------------------------------------------------------
step "Reading terraform outputs"
CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
CLUSTER_ZONE="$(terraform -chdir="${TF_DIR}" output -raw cluster_zone)"
GCP_SA_EMAIL="$(terraform -chdir="${TF_DIR}" output -raw gcp_sa_email)"
GET_CREDS_CMD="$(terraform -chdir="${TF_DIR}" output -raw get_credentials_command)"
# get_credentials_command ends with "--project <PROJECT_ID>"
PROJECT_ID="${GET_CREDS_CMD##*--project }"
[[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != *" "* ]] \
  || fail "could not parse project id from get_credentials_command output: ${GET_CREDS_CMD}"
ok "cluster=${CLUSTER_NAME} zone=${CLUSTER_ZONE} project=${PROJECT_ID}"
ok "app GCP SA: ${GCP_SA_EMAIL}"

# --- kubectl credentials -----------------------------------------------------
step "Fetching cluster credentials for kubectl"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone "${CLUSTER_ZONE}" --project "${PROJECT_ID}"
ok "kubectl context set"

# --- Patch placeholders into a TEMP copy of k8s/ ------------------------------
# Never touches the checked-in k8s/ files (Harness consumes those as-is).
step "Rendering k8s manifests (temp copy — checked-in k8s/ untouched)"
TMP_K8S="$(mktemp -d)"
trap 'rm -rf "${TMP_K8S}"' EXIT

cp "${K8S_DIR}/namespace.yaml" "${K8S_DIR}/service.yaml" "${TMP_K8S}/"
# PROJECT_ID placeholder -> real project (KSA annotation + GOOGLE_CLOUD_PROJECT)
sed "s/PROJECT_ID/${PROJECT_ID}/g" "${K8S_DIR}/serviceaccount.yaml" > "${TMP_K8S}/serviceaccount.yaml"
sed "s/PROJECT_ID/${PROJECT_ID}/g" "${K8S_DIR}/configmap.yaml"      > "${TMP_K8S}/configmap.yaml"
ok "PROJECT_ID -> ${PROJECT_ID} in serviceaccount.yaml + configmap.yaml"

if [[ -n "${IMAGE_REF}" ]]; then
  sed "s|DOCKERHUB_USER/ai-agent-lab:latest|${IMAGE_REF}|g" \
    "${K8S_DIR}/deployment.yaml" > "${TMP_K8S}/deployment.yaml"
  ok "deployment image -> ${IMAGE_REF}"
else
  cp "${K8S_DIR}/deployment.yaml" "${TMP_K8S}/deployment.yaml"
  warn "no -i/--image and no DOCKERHUB_USER set — leaving the DOCKERHUB_USER
  image placeholder. The pod will ImagePullBackOff until Harness deploys a
  real image (fine for pipeline wiring). Re-run with:
    DOCKERHUB_USER=<you> scripts/up.sh    or    scripts/up.sh -i <full-image-ref>"
fi

# --- Deploy -------------------------------------------------------------------
step "kubectl apply (namespace first, then the rest)"
kubectl apply -f "${TMP_K8S}/namespace.yaml"
kubectl apply -f "${TMP_K8S}"
ok "manifests applied"

step "Waiting for deployment rollout (120s timeout)"
if kubectl -n "${NAMESPACE}" rollout status deploy/ai-agent --timeout=120s; then
  ok "deployment ai-agent is ready"
else
  warn "rollout not ready within 120s — expected if the image is still the
  placeholder (ImagePullBackOff). Check: kubectl -n ${NAMESPACE} get pods"
fi

step "Waiting for LoadBalancer external IP (up to 180s)"
EXTERNAL_IP=""
DEADLINE=$((SECONDS + 180))
while (( SECONDS < DEADLINE )); do
  EXTERNAL_IP="$(kubectl -n "${NAMESPACE}" get svc ai-agent \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${EXTERNAL_IP}" ]] && break
  sleep 5
done
if [[ -n "${EXTERNAL_IP}" ]]; then
  ok "external IP: ${EXTERNAL_IP}"
else
  warn "no external IP after 180s — check later with:
  kubectl -n ${NAMESPACE} get svc ai-agent"
fi

# --- Summary -------------------------------------------------------------------
echo
echo "=============================================================="
echo " AI Agent Lab is UP"
echo "=============================================================="
echo " Cluster   : ${CLUSTER_NAME} (zone ${CLUSTER_ZONE}, project ${PROJECT_ID})"
echo " GCP SA    : ${GCP_SA_EMAIL}"
if [[ -n "${EXTERNAL_IP}" ]]; then
  echo " Demo URL  : http://${EXTERNAL_IP}/"
else
  echo " Demo URL  : pending — kubectl -n ${NAMESPACE} get svc ai-agent"
fi
echo " kubectl   : ${GET_CREDS_CMD}"
echo
echo " Failure toggle: FAILURE_MODE in k8s/configmap.yaml (none |"
echo " healthz_500 | crash_on_start | latency | bad_agent) — or override"
echo " it as a Harness service variable and redeploy the SAME image."
echo
echo " !!! COST REMINDER: this cluster + LoadBalancer bill by the hour."
echo " !!! Run scripts/down.sh after the demo. Every time. No exceptions."
echo "=============================================================="
