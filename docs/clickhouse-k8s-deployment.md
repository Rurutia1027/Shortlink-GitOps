# ClickHouse Kubernetes Deployment Guide

This document explains how to deploy ClickHouse on a Kubernetes cluster using Kustomize, following enterprise-level standards and best practices.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Design](#architecture-design)
3. [Deployment Structure](#deployment-structure)
4. [Deployment Steps](#deployment-steps)
5. [Configuration Details](#configuration-details)
6. [Verification](#verification)
7. [Production Considerations](#production-considerations)
8. [Troubleshooting](#troubleshooting)

---

## Overview

### Introduction to ClickHouse

ClickHouse is a column-oriented database management system (DBMS) for online analytical processing (OLAP), particularly suitable for:

- **Real-time Analytics**: Low-latency queries on large datasets
- **Data Warehousing**: Store and query historical data
- **Event Stream Analysis**: Process event data from message queues like Kafka
- **Time-Series Data**: Store and query time-series data

### Deployment Goals

- ✅ Use **Kustomize** to manage Kubernetes configurations
- ✅ Follow enterprise-level standards (resource limits, health checks, persistent storage)
- ✅ Support **StatefulSet** deployment (ensuring data persistence)
- ✅ Integrate into existing GitOps workflow (ArgoCD)

---

## Architecture Design

### Component Overview

```
┌─────────────────────────────────────────┐
│         Kubernetes Cluster              │
│                                         │
│  ┌──────────────────────────────────┐  │
│  │      ClickHouse StatefulSet      │  │
│  │  ┌────────────────────────────┐  │  │
│  │  │  clickhouse-server:23.12   │  │  │
│  │  │  - HTTP: 8123              │  │  │
│  │  │  - Native: 9000            │  │  │
│  │  │  - Inter-server: 9009      │  │  │
│  │  └────────────────────────────┘  │  │
│  └──────────────────────────────────┘  │
│           │                             │
│           ▼                             │
│  ┌──────────────────────────────────┐  │
│  │    PersistentVolume (100Gi)      │  │
│  │    - Data: /var/lib/clickhouse   │  │
│  │    - Logs: /var/log/clickhouse   │  │
│  └──────────────────────────────────┘  │
│                                         │
│  ┌──────────────────────────────────┐  │
│  │         ConfigMap                 │  │
│  │    - config.xml                   │  │
│  │    - users.xml                   │  │
│  └──────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

### Port Configuration

| Port | Protocol | Purpose | Description |
|------|----------|---------|-------------|
| 8123 | HTTP | HTTP Interface | RESTful API for queries and management |
| 9000 | TCP | Native Protocol | High-performance binary protocol for client connections |
| 9009 | HTTP | Inter-server | Inter-node communication (for distributed tables) |

---

## Deployment Structure

### Kustomize Directory Structure

```
k8s/
├── base/
│   ├── clickhouse/
│   │   ├── clickhouse.yaml          # StatefulSet, Service, ConfigMap
│   │   └── kustomization.yaml       # Kustomize resource references
│   └── kustomization.yaml           # Includes clickhouse/
└── overlays/
    ├── dev/
    │   ├── clickhouse/
    │   │   ├── kustomization.yaml   # Dev overlay configuration
    │   │   └── clickhouse-dev-patch.yaml  # Dev resource overrides (smaller resources)
    │   └── kustomization.yaml       # Includes clickhouse/
    └── prod/
        ├── clickhouse/
        │   ├── kustomization.yaml   # Prod overlay configuration
        │   └── clickhouse-prod-patch.yaml  # Prod resource overrides (larger resources + security)
        └── kustomization.yaml       # Includes clickhouse/
```

### Resource List

The deployment includes the following Kubernetes resources:

1. **ConfigMap** (`clickhouse-config`)
   - `config.xml`: ClickHouse server configuration
   - `users.xml`: User and permission configuration

2. **StatefulSet** (`clickhouse`)
   - 1 replica (single-node deployment)
   - Persistent storage: 100Gi (data) + 20Gi (logs)
   - Resource limits: 4-8Gi memory, 2-4 CPU

3. **Service** (`clickhouse`)
   - Headless Service (`clusterIP: None`)
   - Exposes 8123 (HTTP), 9000 (Native), 9009 (Inter-server)

---

## Deployment Steps

### Prerequisites

- ✅ Kubernetes cluster is ready (kind/minikube/GKE/EKS, etc.)
- ✅ `kubectl` is configured and can access the cluster
- ✅ Kustomize is installed (or use `kubectl apply -k`)

### Step 1: Check Namespace

Ensure the `shortlink` namespace exists:

```bash
kubectl get namespace shortlink
# If it doesn't exist, create it:
kubectl create namespace shortlink
```

### Step 2: Deploy ClickHouse (using Kustomize)

#### Option A: Deploy base directly (not recommended, for testing only)

```bash
cd /Users/emma/Irish-Project/worspace/shortlink-gitops
kubectl apply -k k8s/base/clickhouse/
```

#### Option B: Deploy via overlay (recommended)

**Development Environment** (smaller resources, suitable for local testing):

```bash
kubectl apply -k k8s/overlays/dev/
```

**Production Environment** (larger resources, includes security configuration):

```bash
# Step 1: Create Secret first (required, otherwise StatefulSet will fail)
kubectl create secret generic clickhouse-secret \
  --from-literal=password='your-secure-password' \
  -n shortlink

# Step 2: Deploy ClickHouse
kubectl apply -k k8s/overlays/prod/
```

**Note**: Production environments should use password management tools (such as Vault, Sealed Secrets) instead of directly using `kubectl create secret`. See the "Production Considerations" section below for details.

#### Dev vs Prod Configuration Differences

| Configuration Item | Dev | Prod |
|-------------------|-----|------|
| **CPU Request** | 1000m (1 core) | 4000m (4 cores) |
| **CPU Limit** | 2000m (2 cores) | 8000m (8 cores) |
| **Memory Request** | 2Gi | 8Gi |
| **Memory Limit** | 4Gi | 16Gi |
| **Data Storage** | 50Gi | 200Gi |
| **Log Storage** | 10Gi | 50Gi |
| **Replicas** | 1 | 1 (scalable) |
| **Network Policy** | None | Yes |
| **Password Management** | No password | Secret |

### Step 3: Verify Deployment Status

```bash
# Check StatefulSet
kubectl get statefulset -n shortlink clickhouse

# Check Pods
kubectl get pods -n shortlink -l app=clickhouse

# Check Service
kubectl get svc -n shortlink clickhouse

# View Pod logs
kubectl logs -n shortlink clickhouse-0 -f
```

Expected output:

```
NAME         READY   STATUS    RESTARTS   AGE
clickhouse-0 1/1     Running   0          2m
```

### Step 4: Wait for Pod Ready

```bash
kubectl wait --for=condition=ready pod -n shortlink -l app=clickhouse --timeout=300s
```

---

## Configuration Details

### ConfigMap Configuration

#### `config.xml` Key Configuration Items

| Configuration Item | Value | Description |
|-------------------|-------|-------------|
| `http_port` | 8123 | HTTP interface port |
| `tcp_port` | 9000 | Native protocol port |
| `interserver_http_port` | 9009 | Inter-node communication port |
| `max_connections` | 4096 | Maximum concurrent connections |
| `max_concurrent_queries` | 100 | Maximum concurrent queries |
| `uncompressed_cache_size` | 8GB | Uncompressed data cache size |
| `mark_cache_size` | 5GB | Mark cache size |

#### `users.xml` User Configuration

- **default user**: Default user, no password (for development environment only)
- **clickhouse_user**: Example user (production should use Secret for password management)

### Resource Limits

| Resource Type | Request | Limit | Description |
|--------------|---------|-------|-------------|
| CPU | 2000m | 4000m | 2-4 cores |
| Memory | 4Gi | 8Gi | 4-8 GB |

### Storage Configuration

| Storage Type | Size | Mount Path | Purpose |
|-------------|------|------------|---------|
| `clickhouse-data` | 100Gi | `/var/lib/clickhouse` | Data files |
| `clickhouse-logs` | 20Gi | `/var/log/clickhouse-server` | Log files |

### Health Checks

- **Liveness Probe**: HTTP GET `/ping`, starts after 30 seconds, checks every 10 seconds
- **Readiness Probe**: HTTP GET `/ping`, starts after 10 seconds, checks every 5 seconds

---

## Verification

### 1. Connection Test (HTTP)

```bash
# Port-forward
kubectl port-forward -n shortlink svc/clickhouse 8123:8123

# Test in another terminal
curl http://localhost:8123/ping
# Expected output: Ok.
```

### 2. Query Test

```bash
# Create test table
curl -X POST 'http://localhost:8123/' \
  --data 'CREATE TABLE test_table (id UInt32, name String) ENGINE = MergeTree() ORDER BY id'

# Insert data
curl -X POST 'http://localhost:8123/' \
  --data "INSERT INTO test_table VALUES (1, 'test')"

# Query data
curl -X POST 'http://localhost:8123/' \
  --data 'SELECT * FROM test_table'
```

### 3. Using ClickHouse Client (Native Protocol)

```bash
# Install clickhouse-client (if not installed)
# macOS: brew install clickhouse
# Linux: Download and install clickhouse-client

# Port-forward Native port
kubectl port-forward -n shortlink svc/clickhouse 9000:9000

# Connect
clickhouse-client --host localhost --port 9000

# Execute in client
SHOW DATABASES;
SELECT version();
```

### 4. Check Data Persistence

```bash
# Enter Pod
kubectl exec -it -n shortlink clickhouse-0 -- bash

# Check data directory
ls -lh /var/lib/clickhouse/

# Check logs
tail -f /var/log/clickhouse-server/clickhouse-server.log
```

---

## Production Considerations

### 1. Security Configuration

#### Using Secret for Password Management (Production)

**Note**: Prod overlay already includes Secret reference, but you need to create the actual Secret first.

**Option A: Manually Create Secret**

```bash
kubectl create secret generic clickhouse-secret \
  --from-literal=password='your-secure-password' \
  -n shortlink
```

**Option B: Use Sealed Secrets or Vault (Recommended)**

```bash
# Using Sealed Secrets
kubectl create secret generic clickhouse-secret \
  --from-literal=password='your-secure-password' \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > clickhouse-sealed-secret.yaml

kubectl apply -f clickhouse-sealed-secret.yaml -n shortlink
```

**Option C: Update Secret in prod patch**

Edit `k8s/overlays/prod/clickhouse/clickhouse-prod-patch.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: clickhouse-secret
  namespace: shortlink
type: Opaque
stringData:
  password: "YOUR_ACTUAL_SECURE_PASSWORD"  # Replace with actual password
```

**Note**: Production environments should use password management tools (such as Vault, Sealed Secrets) instead of hardcoding passwords directly in YAML.

#### Network Policy

Restrict network access to ClickHouse:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: clickhouse-netpol
  namespace: shortlink
spec:
  podSelector:
    matchLabels:
      app: clickhouse
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: shortlink
      ports:
        - protocol: TCP
          port: 8123
        - protocol: TCP
          port: 9000
```

### 2. High Availability Deployment

#### Multi-Replica StatefulSet

Modify `clickhouse.yaml`:

```yaml
spec:
  replicas: 3  # 3 replicas
```

#### Using ClickHouse Keeper (ZooKeeper Alternative)

Deploy ClickHouse Keeper for ReplicatedMergeTree:

```yaml
# clickhouse-keeper.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: clickhouse-keeper
spec:
  replicas: 3
  # ... ClickHouse Keeper configuration
```

### 3. Monitoring and Alerting

#### Prometheus Metrics

ClickHouse exposes Prometheus metrics at the `/metrics` endpoint:

```yaml
# ServiceMonitor (if using Prometheus Operator)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: clickhouse
spec:
  selector:
    matchLabels:
      app: clickhouse
  endpoints:
    - port: http
      path: /metrics
```

#### Key Metrics

- `ClickHouseMetrics_Query`: Number of queries
- `ClickHouseMetrics_Read`: Read operations
- `ClickHouseMetrics_Write`: Write operations
- `ClickHouseAsyncMetrics_MemoryTracking`: Memory usage

### 4. Backup Strategy

#### Using `clickhouse-backup`

```yaml
# CronJob example
apiVersion: batch/v1
kind: CronJob
metadata:
  name: clickhouse-backup
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: altinity/clickhouse-backup:latest
              command:
                - clickhouse-backup
                - create
                - --config=/etc/clickhouse-backup/config.yml
```

### 5. Performance Tuning

#### Adjust Resources Based on Workload

```yaml
resources:
  requests:
    memory: "8Gi"    # Increase memory
    cpu: "4000m"     # Increase CPU
  limits:
    memory: "16Gi"
    cpu: "8000m"
```

#### Adjust ClickHouse Configuration

In `config.xml`:

```xml
<max_memory_usage>20000000000</max_memory_usage>  <!-- 20GB -->
<max_concurrent_queries>200</max_concurrent_queries>
```

---

## Troubleshooting

### Common Issues

#### 1. Pod Cannot Start

```bash
# Check Pod status
kubectl describe pod -n shortlink clickhouse-0

# View logs
kubectl logs -n shortlink clickhouse-0

# Check events
kubectl get events -n shortlink --sort-by='.lastTimestamp'
```

**Possible Causes**:
- StorageClass does not exist
- Insufficient resource configuration
- Configuration file syntax error

#### 2. Connection Refused

```bash
# Check Service
kubectl get svc -n shortlink clickhouse

# Check Endpoints
kubectl get endpoints -n shortlink clickhouse

# Test connection
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://clickhouse.shortlink.svc.cluster.local:8123/ping
```

#### 3. Insufficient Disk Space

```bash
# Check PVC
kubectl get pvc -n shortlink

# Check Pod disk usage
kubectl exec -n shortlink clickhouse-0 -- df -h /var/lib/clickhouse
```

**Solutions**:
- Increase PVC size
- Clean up old data (TTL policy)
- Use data compression

#### 4. Query Performance Issues

```sql
-- View slow queries
SELECT * FROM system.query_log 
WHERE type = 'QueryFinish' 
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- View table sizes
SELECT 
    database,
    table,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
GROUP BY database, table
ORDER BY sum(bytes) DESC;
```

---

## GitOps Integration

### ArgoCD Deployment

ClickHouse is already included in `k8s/base/kustomization.yaml`, ArgoCD will automatically sync:

```yaml
# argocd/application-shortlink-dev.yaml
spec:
  source:
    path: k8s/overlays/dev
    # ClickHouse will be automatically included in the deployment
```

### Deployment Order

In ArgoCD sync waves, ClickHouse should be deployed after Kafka:

```yaml
# clickhouse.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Same stage as Kafka
```

---

## Summary

- ✅ ClickHouse deployed to Kubernetes via Kustomize
- ✅ Configured with enterprise-level standards (resource limits, health checks, persistence)
- ✅ Supports HTTP and Native protocol access
- ✅ Integrated into GitOps workflow (ArgoCD)
- ✅ Provides production environment best practices guide

Next Steps: Refer to [ClickHouse Best Practices document](./clickhouse-best-practices.md) to learn about core components and use cases.
