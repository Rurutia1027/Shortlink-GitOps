#!/bin/bash
# View ClickHouse logs easily
# Usage: ./view-clickhouse-logs.sh [err|log|both]

set -e

NAMESPACE="shortlink"
POD_NAME="clickhouse-0"
LOG_TYPE="${1:-both}"

echo "=== ClickHouse Log Viewer ==="
echo "Pod: $POD_NAME"
echo "Namespace: $NAMESPACE"
echo ""

# Check if pod exists
if ! kubectl get pod -n "$NAMESPACE" "$POD_NAME" &>/dev/null; then
    echo "Error: Pod $POD_NAME not found in namespace $NAMESPACE"
    exit 1
fi

# Get pod status
STATUS=$(kubectl get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.status.phase}')
echo "Pod Status: $STATUS"
echo ""

if [ "$STATUS" != "Running" ]; then
    echo "⚠️  Pod is not Running. Showing previous container logs..."
    echo ""
    kubectl logs -n "$NAMESPACE" "$POD_NAME" --previous --tail=100
    echo ""
    echo "---"
    echo "To see error log file, try:"
    echo "  kubectl exec -n $NAMESPACE $POD_NAME -- cat /var/log/clickhouse-server/clickhouse-server.err.log"
    exit 0
fi

case "$LOG_TYPE" in
    err)
        echo "=== Error Log (last 100 lines) ==="
        kubectl exec -n "$NAMESPACE" "$POD_NAME" -- tail -100 /var/log/clickhouse-server/clickhouse-server.err.log 2>&1 || \
        kubectl logs -n "$NAMESPACE" "$POD_NAME" --previous --tail=100
        ;;
    log)
        echo "=== Info Log (last 100 lines) ==="
        kubectl exec -n "$NAMESPACE" "$POD_NAME" -- tail -100 /var/log/clickhouse-server/clickhouse-server.log 2>&1 || \
        kubectl logs -n "$NAMESPACE" "$POD_NAME" --previous --tail=100
        ;;
    both|*)
        echo "=== Error Log (last 50 lines) ==="
        kubectl exec -n "$NAMESPACE" "$POD_NAME" -- tail -50 /var/log/clickhouse-server/clickhouse-server.err.log 2>&1 || \
        echo "Cannot access error log (pod may be crashing)"
        echo ""
        echo "=== Container Logs (last 50 lines) ==="
        kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=50 --previous 2>&1 || \
        kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=50 2>&1
        ;;
esac

echo ""
echo "---"
echo "To follow logs in real-time:"
echo "  kubectl logs -n $NAMESPACE $POD_NAME -f"
echo ""
echo "To exec into pod:"
echo "  kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"
