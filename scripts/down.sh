#!/usr/bin/env bash
# scripts/down.sh — tear down the ephemeral AI Agent Lab.
#
# Order matters: the LoadBalancer Service was created by kubectl/Harness, NOT
# by Terraform, so its GCP forwarding rule can orphan (and keep billing) if
# the cluster is destroyed underneath it. This script deletes the Service
# first, then runs terraform destroy.
#
# Runs on YOUR machine. Tolerates a cluster that is already gone or an
# unreachable kubectl context — it skips the Service delete with a note and
# proceeds to terraform destroy.
#
# Usage:
#   scripts/down.sh
#
# Env vars:
#   TF_AUTO_APPROVE=1   -> pass -auto-approve to terraform destroy

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

# --- Preflight ---------------------------------------------------------------
step "Preflight checks"
for tool in terraform gcloud kubectl; do
  command -v "${tool}" >/dev/null 2>&1 \
    || fail "'${tool}' not found on PATH — install it first (see README 'Teardown + costs')."
done
ok "terraform, gcloud, kubectl found"

[[ -f "${TF_DIR}/terraform.tfvars" ]] || fail "missing ${TF_DIR}/terraform.tfvars — destroy needs the same
  var file that apply used (cp ${TF_DIR}/terraform.tfvars.example and edit)."
ok "terraform.tfvars present"

# Best-effort project id for the leftover-check hints at the end.
PROJECT_ID="$(sed -n 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "${TF_DIR}/terraform.tfvars" | head -n 1 || true)"
PROJECT_ID="${PROJECT_ID:-<PROJECT_ID>}"

# --- 1. Release the LoadBalancer first ----------------------------------------
# The Service's forwarding rule/firewall live outside Terraform state; delete
# it before the cluster goes away or it can keep billing (~$0.025/hr).
step "Deleting the LoadBalancer Service first (orphaned forwarding-rule guard)"
if kubectl --request-timeout=10s cluster-info >/dev/null 2>&1; then
  if kubectl --request-timeout=30s delete -f "${K8S_DIR}/service.yaml" \
       --ignore-not-found --timeout=90s; then
    ok "Service deleted (or already absent)"
    echo "  waiting 20s for GCP to release the forwarding rule..."
    sleep 20
    ok "LoadBalancer release grace period done"
  else
    warn "Service delete did not complete cleanly — continuing to terraform
  destroy anyway; check the leftover hints printed at the end."
  fi
else
  warn "kubectl context unreachable (cluster may already be destroyed) —
  skipping the Service delete. If the cluster WAS up under a different
  context, check the leftover hints printed at the end."
fi

# --- 2. terraform destroy ------------------------------------------------------
step "terraform destroy (~5 min)"
terraform -chdir="${TF_DIR}" init -input=false >/dev/null
DESTROY_ARGS=(-var-file=terraform.tfvars)
if [[ "${TF_AUTO_APPROVE:-0}" == "1" ]]; then
  DESTROY_ARGS+=(-auto-approve)
  warn "TF_AUTO_APPROVE=1 — destroying without confirmation"
fi
terraform -chdir="${TF_DIR}" destroy "${DESTROY_ARGS[@]}"
ok "terraform destroy complete"

# --- 3. Leftover checks ----------------------------------------------------------
echo
echo "=============================================================="
echo " AI Agent Lab is DOWN"
echo "=============================================================="
echo " Verify nothing lingers (all should come back empty):"
echo
echo "   gcloud container clusters list --project ${PROJECT_ID}"
echo "   gcloud compute forwarding-rules list --project ${PROJECT_ID}"
echo "   gcloud compute disks list --project ${PROJECT_ID}"
echo
echo " Forwarding rules and disks are the two things that keep billing"
echo " if a LoadBalancer or node disk orphaned. Project APIs stay enabled"
echo " on destroy by design (harmless, no idle cost, faster next apply)."
echo "=============================================================="
