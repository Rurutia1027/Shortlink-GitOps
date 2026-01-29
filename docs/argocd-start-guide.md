# How to Start ArgoCD (Prod-only)

ArgoCD is **prod-only** in this repo: it watches Git and syncs `k8s/overlays/prod` into your cluster.

**Do not confuse ArgoCD with Kustomize**:

- **Kustomize local apply**: you run `kubectl apply -k ...` from your Mac.
- **ArgoCD**: ArgoCD pulls from Git and applies manifests in-cluster (ArgoCD runs Kustomize rendering inside the repo-server).

| Method | When to use | Who applies to the cluster |
|--------|-------------|----------------------------|
| `kubectl apply -k k8s/overlays/dev` | Local dev | You (your Mac) |
| `kubectl apply -k k8s/overlays/prod` | Only if ArgoCD is NOT used | You (your Mac) |
| ArgoCD sync | **Prod-only** | ArgoCD (in-cluster, from Git) |

---

## Prerequisites

- A working Kubernetes cluster
- `kubectl get nodes` works
- Local port **8088** is available (ArgoCD UI will use 8088 to avoid conflict with your app on 8080)

---

## Start with scripts (recommended)

Run from the **Shortlink-GitOps repo root** (adjust the path to your local repo, e.g. `/Users/emma/architecture/GitOps/Shortlink-GitOps`):

```bash
cd /path/to/Shortlink-GitOps

# 1) Install ArgoCD (install only; does NOT run kustomize apply)
chmod +x bin/argocd-install.sh bin/argocd-port-forward.sh bin/argocd-register-prod.sh
./bin/argocd-install.sh

# 2) Start UI port-forward (8088, no conflict with 8080)
./bin/argocd-port-forward.sh
# Open http://localhost:8088 (user: admin). Password is printed by the install script.

# 3) Register prod app (make ArgoCD watch your Git repo)
export GIT_REPO_URL=https://github.com/Rurutia1027/Shortlink-GitOps.git
./bin/argocd-register-prod.sh
```

After this, prod changes are done by pushing to Git and letting ArgoCD sync. **Do not** run `kubectl apply -k k8s/overlays/prod` for prod anymore.

---

## Do I need `brew install argocd` on macOS?

Only if you want to use the **ArgoCD CLI** (`argocd ...`) from your Mac.

- If you only use the ArgoCD **UI**, you do **not** need the CLI.
- If you want CLI commands (recommended), install it:

```bash
brew install argocd
```

---

## Common ArgoCD CLI commands (macOS) — 3 to 5 essentials

> The `argocd` CLI talks to the **ArgoCD Server** running in Kubernetes. You must be able to reach it (usually via port-forward) before running these commands.

1) Port-forward ArgoCD UI/API to your Mac:

```bash
./bin/argocd-port-forward.sh
```

2) Login (connect your local CLI to the in-cluster ArgoCD Server):

```bash
argocd login localhost:8088 --username admin --password <PASSWORD>
```

3) List applications:

```bash
argocd app list
```

4) Inspect one application (sync status / health / resources):

```bash
argocd app get shortlink-prod
```

5) Trigger a sync (manual sync, even if automated sync is enabled):

```bash
argocd app sync shortlink-prod
```

---

## `kubectl` vs `argocd` CLI vs ArgoCD Server (what connects to what)

| Tool | Connects to | What it manages |
|------|-------------|-----------------|
| **kubectl** | **Kubernetes API** (the cluster) | Cluster resources (pods/services/apply YAML, etc.) |
| **argocd CLI** | **ArgoCD Server** (a service running in K8s) | ArgoCD resources (apps/sync/repos/projects, etc.) |

Think of it as:

```
Your Mac                          Inside the K8s cluster
─────────                         ──────────────────────
kubectl   ──────► Kubernetes API   (direct cluster access)
argocd CLI ────► ArgoCD Server ───► uses Kubernetes API to apply/sync
                  ↑
           must be reachable first
```

So yes: **local macOS `argocd` CLI → (port-forward or Ingress/LB) → in-cluster ArgoCD Server → cluster changes**.

