# GitOps Workflow & Troubleshooting Guide

This guide explains the proper order for GitOps deployments with ArgoCD and how to troubleshoot sync issues.

---

## 📋 Proper GitOps Workflow

### Step-by-Step Process

```
1. Edit YAML files locally
   ↓
2. Commit & Push to GitHub (feature branch or main)
   ↓
3. Merge to main branch (if using feature branch)
   ↓
4. ArgoCD detects Git changes (polls every 3 minutes by default)
   ↓
5. ArgoCD renders Kustomize (compiles YAML)
   ↓
6. ArgoCD compares desired state (Git) vs current state (K8s)
   ↓
7. ArgoCD syncs changes to Kubernetes cluster
   ↓
8. Resources are created/updated in cluster
```

### Detailed Workflow

#### 1. **Make Changes Locally**

```bash
cd /Users/emma/architecture/GitOps/Shortlink-GitOps

# Edit YAML files
vim k8s/base/clickhouse/clickhouse.yaml
# ... make your changes ...
```

#### 2. **Commit & Push to GitHub**

```bash
# Check what changed
git status
git diff

# Commit changes
git add k8s/base/clickhouse/clickhouse.yaml
git commit -m "fix: remove duplicate default-password.xml to resolve auth conflict"

# Push to GitHub
git push origin main
# OR if using feature branch:
# git push origin feature/fix-clickhouse-auth
```

#### 3. **Merge to Main (if using feature branch)**

```bash
# On GitHub: Create Pull Request → Merge to main
# OR locally:
git checkout main
git merge feature/fix-clickhouse-auth
git push origin main
```

#### 4. **ArgoCD Auto-Detection**

ArgoCD polls the Git repository every **3 minutes** by default. After you push to `main`:

- ArgoCD detects the commit hash changed
- ArgoCD fetches the new YAML files
- ArgoCD renders Kustomize (compiles base + overlays)
- ArgoCD compares desired state vs current state
- If differences found → **Sync** (if auto-sync enabled) or **OutOfSync** status

#### 5. **Monitor Sync Status**

```bash
# Check ArgoCD application status
argocd app get shortlink-prod

# Or via kubectl
kubectl get application -n argocd shortlink-prod -o yaml

# Watch sync in real-time
argocd app get shortlink-prod --refresh
```

---

## 🔍 Checking Sync Status

### Via ArgoCD CLI

```bash
# 1. Ensure ArgoCD port-forward is running
./bin/argocd-port-forward.sh

# 2. Login (if not already logged in)
argocd login localhost:8088 --username admin --password <PASSWORD>

# 3. Check application status
argocd app get shortlink-prod

# 4. List all applications
argocd app list

# 5. Watch sync progress
argocd app sync shortlink-prod --watch
```

### Via kubectl

```bash
# Check application status
kubectl get application -n argocd shortlink-prod

# Detailed status
kubectl get application -n argocd shortlink-prod -o yaml | grep -A 20 "status:"

# Check sync operation history
kubectl get application -n argocd shortlink-prod -o jsonpath='{.status.operationState}'
```

### Via ArgoCD UI

```bash
# Start port-forward
./bin/argocd-port-forward.sh

# Open browser
open http://localhost:8088
# Login: admin / <password>
# Navigate to: Applications → shortlink-prod
```

---

## ⚙️ Sync Policy Configuration

### Current Configuration

Your `application-shortlink-prod.yaml` has:

```yaml
syncPolicy:
  automated:
    prune: true      # Delete resources removed from Git
    selfHeal: true   # Auto-sync if cluster drifts from Git
  syncOptions:
    - CreateNamespace=true
```

**This means:**
- ✅ **Auto-sync enabled**: ArgoCD automatically syncs when Git changes
- ✅ **Prune enabled**: Resources deleted from Git are removed from cluster
- ✅ **Self-heal enabled**: If someone manually changes cluster, ArgoCD reverts it

### Manual Sync (if auto-sync disabled)

If auto-sync is disabled, you need to manually trigger sync:

```bash
# Manual sync
argocd app sync shortlink-prod

# Sync with specific options
argocd app sync shortlink-prod --prune --force

# Sync and watch progress
argocd app sync shortlink-prod --watch
```

---

## 🐛 Troubleshooting Sync Errors

### 1. Check Application Status

```bash
argocd app get shortlink-prod
```

Look for:
- **Sync Status**: `Synced` ✅ or `OutOfSync` ⚠️ or `Unknown` ❌
- **Health Status**: `Healthy` ✅ or `Degraded` ⚠️ or `Missing` ❌
- **Message**: Error details

### 2. Check Sync Operation History

```bash
# View recent sync operations
argocd app history shortlink-prod

# View specific operation details
argocd app get shortlink-prod --refresh
```

### 3. Common Error Types

#### A. **Render Error** (Kustomize compilation failed)

**Symptoms:**
```
Status: Unknown
Message: Error: failed to build: ...
```

**Debug:**
```bash
# Check Kustomize build locally
cd /Users/emma/architecture/GitOps/Shortlink-GitOps
kubectl kustomize k8s/overlays/prod

# Check ArgoCD repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

**Common causes:**
- YAML syntax errors
- Missing resources referenced in kustomization.yaml
- Invalid Kustomize patches

#### B. **Sync Error** (Failed to apply to cluster)

**Symptoms:**
```
Status: OutOfSync
Health: Degraded
Message: Error: ... failed to apply
```

**Debug:**
```bash
# Check sync operation details
argocd app get shortlink-prod --refresh

# Check specific resource errors
kubectl get events -n shortlink --sort-by='.lastTimestamp' | tail -20

# Check pod status
kubectl get pods -n shortlink

# Check resource that failed
kubectl describe <resource-type> <resource-name> -n shortlink
```

**Common causes:**
- Resource validation errors (e.g., invalid YAML)
- Resource conflicts (e.g., port already in use)
- Missing dependencies (e.g., ConfigMap not created yet)
- RBAC/permission issues

#### C. **Health Check Failed** (Resource exists but unhealthy)

**Symptoms:**
```
Status: Synced
Health: Degraded
```

**Debug:**
```bash
# Check resource health
kubectl get pods -n shortlink
kubectl describe pod <pod-name> -n shortlink
kubectl logs <pod-name> -n shortlink

# Check resource events
kubectl get events -n shortlink --field-selector involvedObject.name=<resource-name>
```

### 4. Check ArgoCD Component Logs

```bash
# ArgoCD Application Controller (manages sync)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100

# ArgoCD Repo Server (renders Kustomize)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100

# ArgoCD Server (API/UI)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100
```

### 5. Force Refresh & Retry

```bash
# Refresh application (re-fetch from Git)
argocd app get shortlink-prod --refresh

# Hard refresh (clear cache)
argocd app get shortlink-prod --hard-refresh

# Retry failed sync
argocd app sync shortlink-prod --force
```

---

## ⏱️ Why Sync Takes Long Time

### Normal Sync Duration

- **Small changes** (1-5 resources): 10-30 seconds
- **Medium changes** (10-20 resources): 30-60 seconds
- **Large changes** (50+ resources): 1-3 minutes

### Factors Affecting Sync Time

1. **Number of resources**: More resources = longer sync
2. **Resource dependencies**: Resources with dependencies wait for prerequisites
3. **Health checks**: ArgoCD waits for resources to become healthy
4. **Network latency**: Git fetch, K8s API calls
5. **Cluster load**: High cluster load slows down operations

### If Sync Seems Stuck

```bash
# Check if sync is actually running
argocd app get shortlink-prod

# Check operation state
kubectl get application -n argocd shortlink-prod -o jsonpath='{.status.operationState}' | jq

# Check if resources are being created
kubectl get pods -n shortlink -w

# Check ArgoCD controller logs for errors
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50 -f
```

---

## 🔧 Quick Troubleshooting Commands

### Check Everything at Once

```bash
#!/bin/bash
# Quick status check script

echo "=== ArgoCD Application Status ==="
argocd app get shortlink-prod

echo ""
echo "=== Kubernetes Resources ==="
kubectl get all -n shortlink

echo ""
echo "=== Recent Events ==="
kubectl get events -n shortlink --sort-by='.lastTimestamp' | tail -10

echo ""
echo "=== Pod Status ==="
kubectl get pods -n shortlink

echo ""
echo "=== ArgoCD Controller Logs (last 20 lines) ==="
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=20
```

### Common Fixes

#### Fix 1: Force Sync After Failed Operation

```bash
argocd app sync shortlink-prod --force --prune
```

#### Fix 2: Delete and Recreate Application

```bash
# Delete application (does NOT delete cluster resources)
argocd app delete shortlink-prod

# Re-register
./bin/argocd-register-prod.sh
```

#### Fix 3: Fix YAML and Re-sync

```bash
# 1. Fix YAML locally
vim k8s/base/clickhouse/clickhouse.yaml

# 2. Commit & push
git add k8s/base/clickhouse/clickhouse.yaml
git commit -m "fix: correct YAML syntax"
git push origin main

# 3. Wait for auto-sync or manually trigger
argocd app sync shortlink-prod --refresh
```

---

## 📊 Understanding Sync States

| Status | Meaning | Action Needed |
|--------|---------|---------------|
| **Synced** | Git state matches cluster state | ✅ None |
| **OutOfSync** | Git has changes not in cluster | ⚠️ Sync (auto or manual) |
| **Unknown** | ArgoCD can't determine state | ❌ Check logs, refresh |
| **Syncing** | Sync operation in progress | ⏳ Wait |

| Health | Meaning | Action Needed |
|--------|---------|---------------|
| **Healthy** | All resources healthy | ✅ None |
| **Degraded** | Some resources unhealthy | ⚠️ Check resource logs |
| **Missing** | Resources not found | ❌ Check if deleted or not created |
| **Progressing** | Resources being created/updated | ⏳ Wait |

---

## 🎯 Best Practices

1. **Always test locally first**:
   ```bash
   kubectl kustomize k8s/overlays/prod
   ```

2. **Commit small, incremental changes** (easier to debug)

3. **Check sync status after push**:
   ```bash
   argocd app get shortlink-prod --refresh
   ```

4. **Monitor during sync**:
   ```bash
   argocd app sync shortlink-prod --watch
   ```

5. **Check logs if sync fails**:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
   ```

---

## 📝 Summary: Proper Workflow

```bash
# 1. Make changes
vim k8s/base/clickhouse/clickhouse.yaml

# 2. Test locally
kubectl kustomize k8s/overlays/prod > /tmp/rendered.yaml
# Review /tmp/rendered.yaml

# 3. Commit & push
git add k8s/base/clickhouse/clickhouse.yaml
git commit -m "fix: remove duplicate auth config"
git push origin main

# 4. Wait for ArgoCD to detect (or manually trigger)
argocd app sync shortlink-prod --watch

# 5. Verify
argocd app get shortlink-prod
kubectl get pods -n shortlink
```
