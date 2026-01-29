#!/usr/bin/env bash
# Port-forward ArgoCD UI to localhost (default 8088 to avoid conflict with app on 8080).
# Run in foreground; Ctrl+C to stop.
set -euo pipefail

ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_UI_PORT="${ARGOCD_UI_PORT:-8088}"

echo "==> ArgoCD UI: http://localhost:${ARGOCD_UI_PORT} (user: admin)"
echo "    Stop with Ctrl+C"
kubectl port-forward -n "${ARGOCD_NS}" svc/argocd-server "${ARGOCD_UI_PORT}:80"
