#!/usr/bin/env bash
# Register the prod Application with ArgoCD (AppProject + Application).
# Requires GIT_REPO_URL to be set to your Git repo (e.g. https://github.com/you/Shortlink-GitOps.git).
# ArgoCD will then sync k8s/overlays/prod from that repo; do NOT run kubectl apply -k for prod when using ArgoCD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

if [[ -z "${GIT_REPO_URL:-}" ]]; then
  echo "Error: GIT_REPO_URL is not set."
  echo "Example: export GIT_REPO_URL=https://github.com/your-org/Shortlink-GitOps.git"
  echo "Then run: $0"
  exit 1
fi

echo "==> Registering ArgoCD prod app (repo: ${GIT_REPO_URL})"
cd "${REPO_ROOT}"

# Apply AppProject (inline to avoid typos: use "destinations" and "clusterResourceWhitelist")
kubectl apply -n "${ARGOCD_NS}" -f - <<'PROJECT'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: shortlink
  namespace: argocd
spec:
  description: ShortLink platform (middleware + apps) GitOps project
  destinations:
    - namespace: shortlink
      server: https://kubernetes.default.svc
    - namespace: istio-system
      server: https://kubernetes.default.svc
  sourceRepos:
    - '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
PROJECT

# Apply Application with repo URL
kubectl apply -n "${ARGOCD_NS}" -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shortlink-prod
  namespace: ${ARGOCD_NS}
spec:
  project: shortlink
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: HEAD
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: shortlink
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo "==> Done. Open ArgoCD UI and check application shortlink-prod."
