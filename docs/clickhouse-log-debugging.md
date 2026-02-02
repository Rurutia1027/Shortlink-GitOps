# ClickHouse Log Debugging Guide

This guide shows multiple ways to access ClickHouse logs for debugging.

---

## Method 1: Quick Log View Script (Recommended)

Use the provided script to view logs:

```bash
cd /Users/emma/architecture/GitOps/Shortlink-GitOps
chmod +x bin/view-clickhouse-logs.sh
./bin/view-clickhouse-logs.sh
```

Options:
- `./bin/view-clickhouse-logs.sh err` - Show error log only
- `./bin/view-clickhouse-logs.sh log` - Show info log only  
- `./bin/view-clickhouse-logs.sh both` - Show both (default)

---

## Method 2: Direct kubectl Commands

### View Container Logs (when pod is running)
```bash
# Last 100 lines
kubectl logs -n shortlink clickhouse-0 --tail=100

# Follow logs in real-time
kubectl logs -n shortlink clickhouse-0 -f

# Previous container (if pod crashed)
kubectl logs -n shortlink clickhouse-0 --previous --tail=100
```

### View Log Files Inside Container (when pod is running)
```bash
# Error log
kubectl exec -n shortlink clickhouse-0 -- cat /var/log/clickhouse-server/clickhouse-server.err.log

# Info log
kubectl exec -n shortlink clickhouse-0 -- cat /var/log/clickhouse-server/clickhouse-server.log

# Tail error log
kubectl exec -n shortlink clickhouse-0 -- tail -f /var/log/clickhouse-server/clickhouse-server.err.log
```

---

## Method 3: Debug Pod (Access Logs via PVC)

If the ClickHouse pod is crashing, create a debug pod that mounts the same log volume:

```bash
# Apply the log viewer pod
kubectl apply -f k8s/base/clickhouse/clickhouse-log-viewer.yaml

# Wait for it to start
kubectl wait --for=condition=Ready pod/clickhouse-log-viewer -n shortlink --timeout=60s

# View error log
kubectl exec -it clickhouse-log-viewer -n shortlink -- cat /logs/clickhouse-server.err.log

# Tail error log
kubectl exec -it clickhouse-log-viewer -n shortlink -- tail -f /logs/clickhouse-server.err.log

# Interactive shell
kubectl exec -it clickhouse-log-viewer -n shortlink -- sh
# Inside pod:
#   tail -f /logs/clickhouse-server.err.log
#   ls -lh /logs/
```

**Note:** For prod overlay (emptyDir), the log viewer won't work because logs are ephemeral. Use Method 1 or 2 instead.

---

## Method 4: Local ClickHouse Setup (For Development)

If you want to run ClickHouse locally for easier debugging:

### Option A: Docker Compose

Create `docker-compose-clickhouse.yml`:

```yaml
version: '3.8'
services:
  clickhouse:
    image: clickhouse/clickhouse-server:23.12-alpine
    ports:
      - "8123:8123"
      - "9000:9000"
    environment:
      - CLICKHOUSE_DB=default
      - CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1
    volumes:
      - clickhouse-data:/var/lib/clickhouse
      - ./clickhouse-config/users.xml:/etc/clickhouse-server/users.d/users.xml:ro
      - ./clickhouse-config/default-password.xml:/etc/clickhouse-server/users.d/default-password.xml:ro
    command: >
      /bin/sh -c "
      echo '<clickhouse><users><default><no_password /><networks><ip>::/0</ip></networks></default></users></clickhouse>' > /etc/clickhouse-server/users.d/users.xml &&
      echo '<clickhouse><users><default><no_password /></default></users></clickhouse>' > /etc/clickhouse-server/users.d/default-password.xml &&
      /entrypoint.sh
      "

volumes:
  clickhouse-data:
```

Run:
```bash
docker-compose -f docker-compose-clickhouse.yml up -d
docker-compose -f docker-compose-clickhouse.yml logs -f clickhouse
```

### Option B: Kind/Local K8s with Log Access

If using Kind or local K8s, you can mount logs to host:

```yaml
# In clickhouse.yaml, add hostPath volume (for local dev only)
volumes:
  - name: clickhouse-logs-host
    hostPath:
      path: /tmp/clickhouse-logs
      type: DirectoryOrCreate
```

Then logs will be at `/tmp/clickhouse-logs` on your host machine.

---

## Common Error Patterns

### Authentication Failed
```
DB::Exception: default: Authentication failed: password is incorrect
```
**Solution:** Check `users.d/default-password.xml` has `<no_password />`

### Config Merge Error
```
DB::Exception: Error loading configuration
```
**Solution:** Check XML syntax in ConfigMap files

### Port Already in Use
```
Address already in use: 8123
```
**Solution:** Check if another ClickHouse instance is running

---

## Quick Troubleshooting Commands

```bash
# Check pod status
kubectl get pods -n shortlink -l app=clickhouse

# Describe pod (see events and errors)
kubectl describe pod -n shortlink clickhouse-0

# Check ConfigMap
kubectl get configmap -n shortlink clickhouse-config -o yaml

# Verify volume mounts
kubectl describe pod -n shortlink clickhouse-0 | grep -A 10 "Mounts:"

# Test ClickHouse HTTP endpoint (when running)
curl http://localhost:8123/ping
# Should return: Ok.
```

---

## Export Logs to Local File

```bash
# Export error log
kubectl logs -n shortlink clickhouse-0 --previous > clickhouse-error.log 2>&1

# Export both logs
kubectl logs -n shortlink clickhouse-0 --previous > clickhouse.log 2>&1
kubectl exec -n shortlink clickhouse-0 -- cat /var/log/clickhouse-server/clickhouse-server.err.log >> clickhouse-error-detail.log 2>&1 || echo "Cannot access log file"
```
