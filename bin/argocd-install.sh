#!/usr/bin/env bash 
# Install ArgoCD in the cluster (prod GitOps controller only)
# Does NOT run kustomize apply: ArgoCD will sync from Git; use kubectl apply -k only for dev/prod 

set -euo pipefail 

ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_MANIFEST="${ARGOCD_MANIFEST:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"
ARGOCD_UI_PORT="${ARGOCD_UI_PORT:-8088}"

echo "==> Creating namespace ${ARGOCD_NS}"
kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing ArgoCD (prod GitOps controller)"
kubectl apply -n "${ARGOCD_NS}" -f "${ARGOCD_MANIFEST}"

echo "==> Waiting for ArgoCD pods to be ready (timeout 120s)"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n "${ARGOCD_NS}" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n "${ARGOCD_NS}" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n "${ARGOCD_NS}" --timeout=120s 2>/dev/null || true

echo ""
echo "==> ArgoCD installed. Next steps:"
echo "  1. Start UI port-forward (use port ${ARGOCD_UI_PORT} to avoid conflict with app on 8080):"
echo "     ./bin/argocd-port-forward.sh"
echo "  2. Open http://localhost:${ARGOCD_UI_PORT} and log in (user: admin)."
echo "  3. Get admin password:"
echo "     kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
echo "  4. Register prod app from this repo: ./bin/argocd-register-prod.sh (after setting GIT_REPO_URL)"
echo ""

# Show password if secret exists
if kubectl get secret -n "${ARGOCD_NS}" argocd-initial-admin-secret &>/dev/null; then
  echo "==> Initial admin password (save it):"
  kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  echo ""
fi