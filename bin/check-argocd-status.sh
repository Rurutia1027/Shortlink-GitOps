#!/bin/bash
# Quick ArgoCD status checker
# Usage: ./check-argocd-status.sh [app-name]

set -e

APP_NAME="${1:-shortlink-prod}"
NAMESPACE="argocd"

echo "=========================================="
echo "ArgoCD Status Check: $APP_NAME"
echo "=========================================="
echo ""

# Check if ArgoCD port-forward is needed
if ! curl -s http://localhost:8088/healthz > /dev/null 2>&1; then
    echo "⚠️  ArgoCD server not reachable on localhost:8088"
    echo "   Run: ./bin/argocd-port-forward.sh"
    echo ""
    echo "Trying kubectl method instead..."
    echo ""
fi

# Method 1: Try ArgoCD CLI (if available and server reachable)
if command -v argocd &> /dev/null && curl -s http://localhost:8088/healthz > /dev/null 2>&1; then
    echo "=== ArgoCD CLI Status ==="
    argocd app get "$APP_NAME" 2>&1 || echo "Failed to get app via CLI"
    echo ""
fi

# Method 2: kubectl (always works)
echo "=== Kubernetes Application Resource ==="
kubectl get application -n "$NAMESPACE" "$APP_NAME" -o custom-columns=\
NAME:.metadata.name,\
SYNC:.status.sync.status,\
HEALTH:.status.health.status,\
REVISION:.status.sync.revision 2>&1 || {
    echo "❌ Application not found: $APP_NAME"
    echo "   Available applications:"
    kubectl get application -n "$NAMESPACE" 2>&1 || echo "   No applications found"
    exit 1
}

echo ""
echo "=== Detailed Status ==="
kubectl get application -n "$NAMESPACE" "$APP_NAME" -o jsonpath='{.status}' | \
    python3 -m json.tool 2>/dev/null || \
    kubectl get application -n "$NAMESPACE" "$APP_NAME" -o yaml | grep -A 30 "status:"

echo ""
echo "=== Sync Operation State ==="
OP_STATE=$(kubectl get application -n "$NAMESPACE" "$APP_NAME" -o jsonpath='{.status.operationState}' 2>/dev/null)
if [ -n "$OP_STATE" ] && [ "$OP_STATE" != "null" ]; then
    echo "$OP_STATE" | python3 -m json.tool 2>/dev/null || echo "$OP_STATE"
else
    echo "No active operation"
fi

echo ""
echo "=== Recent Sync History ==="
if command -v argocd &> /dev/null && curl -s http://localhost:8088/healthz > /dev/null 2>&1; then
    argocd app history "$APP_NAME" --limit 5 2>&1 || echo "Cannot get history via CLI"
else
    echo "ArgoCD CLI not available or server not reachable"
    echo "Install: brew install argocd"
    echo "Port-forward: ./bin/argocd-port-forward.sh"
fi

echo ""
echo "=== Target Resources Status ==="
TARGET_NS=$(kubectl get application -n "$NAMESPACE" "$APP_NAME" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)
if [ -n "$TARGET_NS" ]; then
    echo "Namespace: $TARGET_NS"
    kubectl get all -n "$TARGET_NS" 2>&1 | head -20
else
    echo "Cannot determine target namespace"
fi

echo ""
echo "=== Recent Events (target namespace) ==="
if [ -n "$TARGET_NS" ]; then
    kubectl get events -n "$TARGET_NS" --sort-by='.lastTimestamp' 2>&1 | tail -10
fi

echo ""
echo "=========================================="
echo "Quick Actions:"
echo "  Refresh:  argocd app get $APP_NAME --refresh"
echo "  Sync:     argocd app sync $APP_NAME"
echo "  Watch:    argocd app sync $APP_NAME --watch"
echo "=========================================="
