## Setting Up ArgoCD on a kind-based Kubernetes Cluster

This guide explains, step by step, how to:

- Install ArgoCD into a **kind** (Kubernetes-in-Docker) cluster
- Expose the ArgoCD UI/API for local development
- Connect ArgoCD to your **GitOps repo** (e.g. `shortlink-gitops`)
- Understand where ArgoCD usually lives in **production** clusters

> We’ll assume you already have a running kind cluster and `kubectl` configured to talk to it.

---

### 1. Prerequisites

You should have:

- A running **kind** cluster:

```bash
kind create cluster --name shortlink-dev
# or already created and `kubectl config current-context` points to it
```

- `kubectl` installed and configured:

```bash
kubectl get nodes
```

- (Optional but recommended) `kubens` / `kubectx` for namespace/context switching.

---

### 2. Where do we install ArgoCD?

In almost all setups (dev and prod), ArgoCD is installed into its **own namespace**, usually called:

- `argocd`

On a **kind** dev cluster:

- Namespace: `argocd`
- ArgoCD components (API server, repo-server, application-controller, dex, redis, etc.) run as Deployments/StatefulSets in that namespace.
- ArgoCD then deploys **your apps** into other namespaces (e.g. `shortlink`).

In **production**, the pattern is the same:

- A dedicated `argocd` (or `gitops-system`) namespace
- Restricted RBAC and network policies
- ArgoCD has permissions to manage only the allowed namespaces/clusters

We’ll follow this pattern in the examples below.

---

### 3. Installing ArgoCD on kind

#### 3.1 Create the `argocd` namespace

```bash
kubectl create namespace argocd
```

#### 3.2 Install ArgoCD (core components)

For a simple dev setup, use the official **core** install (no ingress, minimal extras):

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

This will create:

- `argocd-server` (API server + UI)
- `argocd-repo-server` (Git + Helm + Kustomize rendering)
- `argocd-application-controller` (reconciliation engine)
- `argocd-dex-server` (optional SSO)
- `argocd-redis` (caching)

Wait for pods to come up:

```bash
kubectl get pods -n argocd
```

All should eventually be **Running**.

---

### 4. Accessing the ArgoCD UI on kind

For local development, the simplest is to **port-forward** the ArgoCD API server.

#### 4.1 Port-forward

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Now open:

```bash
http://localhost:8080
```

#### 4.2 Get the initial admin password

By default, ArgoCD creates an `admin` user whose password is stored in a Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

Login via UI:

- **Username**: `admin`
- **Password**: value from the command above

> For dev, you can change this password in the UI or disable the admin user once you create another account. For prod, you’d typically integrate with SSO (OIDC / Dex).

---

### 5. Connecting ArgoCD to your GitOps repo

We will use the `shortlink-gitops` repo as the **source of truth**.

#### 5.1 Add the Git repo (via UI)

In the ArgoCD UI:

1. Go to **Settings → Repositories**.
2. Click **CONNECT REPO**.
3. Enter:
   - **Type**: Git
   - **Repository URL**: e.g. `https://github.com/your-org/shortlink-gitops.git` (replace with real URL)
   - **Username/Password** or **SSH** if private (for dev, https with PAT is fine).
4. Click **Connect**.

Alternatively, via CLI:

```bash
argocd repo add https://github.com/your-org/shortlink-gitops.git \
  --username <GITHUB_USER> \
  --password <GITHUB_TOKEN>
```

> The `argocd` CLI can port-forward automatically if you set `ARGOCD_SERVER=localhost:8080`.

---

### 5.5 Core Mechanism: How ArgoCD Connects to GitOps and Deploys Apps

This is the **most critical** part to understand: how a ready ArgoCD instance actually connects to your GitOps repository and deploys your applications.

#### 5.5.1 The Bridge: Application CRD

ArgoCD "deploys your apps" through **Application Custom Resource Definitions (CRDs)**. When you create an `Application` resource in the `argocd` namespace, you're telling ArgoCD:

- **Where** your GitOps repo is (`spec.source.repoURL`)
- **What path** to render (`spec.source.path`)
- **Which revision** to use (`spec.source.targetRevision`)
- **Where** to deploy (`spec.destination.server` and `spec.destination.namespace`)

Here's what an `Application` CR looks like:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shortlink-dev
  namespace: argocd
spec:
  project: shortlink
  source:
    repoURL: https://github.com/your-org/shortlink-gitops.git
    targetRevision: HEAD
    path: k8s/overlays/dev  # 👈 This is the key: ArgoCD renders THIS path
  destination:
    server: https://kubernetes.default.svc
    namespace: shortlink
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### 5.5.2 GitOps Repository Requirements: The Three Conditions

ArgoCD doesn't care about your **directory structure style**. It only cares that your GitOps repo satisfies **three conditions**:

1. ✅ **It's a Git repository** (accessible via HTTPS/SSH)
2. ✅ **The specified path can be rendered into valid Kubernetes YAML**
   - For Kustomize: `kustomize build <path>` must succeed
   - For Helm: `helm template <path>` must succeed
   - For plain YAML: the path must contain valid `.yaml`/`.yml` files
3. ✅ **The rendered YAML can be applied** to the target cluster/namespace

**Directory style is completely free**:
- ✅ Kustomize-organized (base + overlays)
- ✅ Helm charts (`charts/` with `values.yaml`)
- ✅ Plain native YAML files
- ✅ Mixed (some apps use Kustomize, others use Helm)

ArgoCD will render each `Application`'s `path` according to what it detects (Kustomize `kustomization.yaml`, Helm `Chart.yaml`, or plain YAML).

#### 5.5.3 How ArgoCD Renders: The Rendering Engine

When ArgoCD processes an `Application`, here's what happens:

1. **`argocd-repo-server`** (a Deployment in `argocd` namespace):
   - Clones/fetches the Git repo at `targetRevision`
   - Detects the rendering method for `path`:
     - **Kustomize**: If `path` contains `kustomization.yaml`, runs `kustomize build <path>`
     - **Helm**: If `path` contains `Chart.yaml`, runs `helm template <path> --values <values.yaml>`
     - **Plain YAML**: If neither, treats files as raw Kubernetes manifests
   - Outputs rendered Kubernetes YAML

2. **`argocd-application-controller`** (another Deployment):
   - Receives the rendered YAML from `repo-server`
   - Compares it with the current cluster state
   - Applies differences to `spec.destination.namespace` on `spec.destination.server`
   - Monitors health and sync status

#### 5.5.4 Examples: Different GitOps Styles

**Example 1: Kustomize-organized (our current setup)**

```
shortlink-gitops/
├── k8s/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   └── ...
│   └── overlays/
│       ├── dev/
│       │   └── kustomization.yaml  # 👈 ArgoCD renders this
│       └── prod/
│           └── kustomization.yaml  # 👈 Or this
```

Application CR:
```yaml
spec:
  source:
    path: k8s/overlays/dev  # ArgoCD runs: kustomize build k8s/overlays/dev
```

**Example 2: Helm-oriented**

```
shortlink-gitops/
├── charts/
│   └── shortlink/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           └── deployment.yaml
└── values/
    ├── dev-values.yaml
    └── prod-values.yaml
```

Application CR:
```yaml
spec:
  source:
    path: charts/shortlink  # ArgoCD runs: helm template charts/shortlink -f values/dev-values.yaml
    helm:
      valueFiles:
        - ../../values/dev-values.yaml
```

**Example 3: Plain native YAML**

```
shortlink-gitops/
├── dev/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
└── prod/
    ├── deployment.yaml
    └── service.yaml
```

Application CR:
```yaml
spec:
  source:
    path: dev  # ArgoCD treats all .yaml files as raw Kubernetes manifests
```

#### 5.5.5 The Complete Flow: From Git Commit to Deployed Pods

Here's the **real mechanism** step-by-step:

1. **You push a commit** to `shortlink-gitops`:
   ```bash
   git commit -m "Update shortlink deployment replicas"
   git push origin main
   ```

2. **ArgoCD detects the change** (via polling or webhook):
   - `argocd-application-controller` polls the Git repo (default: every 3 minutes)
   - Or a Git webhook triggers an immediate sync

3. **`argocd-repo-server` renders**:
   ```bash
   # Internally, ArgoCD does:
   cd /tmp/git-repo-clone
   kustomize build k8s/overlays/dev  # or helm template, or cat *.yaml
   # Output: rendered Kubernetes YAML
   ```

4. **`argocd-application-controller` applies**:
   - Compares rendered YAML with current cluster state
   - Generates a diff
   - Applies changes: `kubectl apply -f <rendered-yaml> -n shortlink`

5. **ArgoCD monitors**:
   - Watches Deployment/StatefulSet status
   - Reports health (Healthy/Degraded/Progressing)
   - Shows sync status (Synced/OutOfSync)

#### 5.5.6 Key Takeaway

> **ArgoCD "deploys your apps" by:**
> 
> 1. Reading `Application` CRDs that specify `repoURL` + `path`
> 2. Using `argocd-repo-server` to render the `path` (via Kustomize/Helm/plain YAML)
> 3. Using `argocd-application-controller` to apply the rendered YAML to the target namespace
> 
> **Your GitOps repo just needs to:**
> - Be a Git repository
> - Have a `path` that renders to valid Kubernetes YAML
> - Be accessible to ArgoCD (via credentials you configured in step 5.1)

The directory structure is **your choice**—ArgoCD adapts to Kustomize, Helm, or plain YAML based on what it finds at the specified `path`.

---

### 6. Creating Applications for dev/prod (kind)

We already created ArgoCD manifests in `shortlink-gitops/argocd/`:

- `appproject-shortlink.yaml`
- `application-shortlink-dev.yaml`
- `application-shortlink-prod.yaml`

You can apply them directly from your local clone of `shortlink-gitops`:

```bash
cd /Users/emma/Irish-Project/worspace/shortlink-gitops

kubectl apply -n argocd -f argocd/appproject-shortlink.yaml
kubectl apply -n argocd -f argocd/application-shortlink-dev.yaml
kubectl apply -n argocd -f argocd/application-shortlink-prod.yaml
```

Make sure to update the `repoURL` fields to point to your real Git repo, for example:

```yaml
spec:
  source:
    repoURL: https://github.com/your-org/shortlink-gitops.git
    targetRevision: main
    path: k8s/overlays/dev   # or prod
```

Once applied:

- ArgoCD will show two Applications: `shortlink-dev` and `shortlink-prod`.
- You can click **SYNC** in the UI (or rely on `syncPolicy.automated`) to deploy to the `shortlink` namespace in your kind cluster.

---

### 7. How ArgoCD & kind work together (high-level flow)

Now that you understand the core mechanism (section 5.5), here's the complete flow:

1. **You change YAML** in `shortlink-gitops` (Kustomize bases/overlays, annotations, etc.).
2. You **push** to Git (GitHub/GitLab/…).
3. **ArgoCD detects the change** (via `Application` CR watching `repoURL` + `path`):
   - `argocd-application-controller` polls Git or receives webhook
4. **`argocd-repo-server` renders**:
   - Clones repo at `targetRevision` (e.g. `HEAD`)
   - Runs `kustomize build k8s/overlays/dev` (or `helm template`, or reads plain YAML)
   - Outputs rendered Kubernetes YAML
5. **`argocd-application-controller` applies**:
   - Compares rendered YAML with current cluster state
   - Applies diff to `spec.destination.namespace` (`shortlink`) on `spec.destination.server` (kind cluster)
6. **ArgoCD monitors**:
   - Watches Deployment/StatefulSet health
   - Reports sync status in UI/CLI

Your **kind cluster** is just a regular Kubernetes cluster from ArgoCD’s perspective; no special handling is required beyond kubeconfig context.

---

### 8. What changes in production?

In production, the high-level pattern is the same, but with **more discipline**:

#### 8.1 Where do we usually run ArgoCD in prod?

- Dedicated namespace, often called:
  - `argocd`, `gitops-system`, or similar.
- Sometimes in a **management/platform cluster** separate from app clusters.

ArgoCD then:

- Connects to multiple clusters (via `argocd cluster add ...`).
- Uses `spec.destination.server` to pick the target cluster API server per Application.

#### 8.2 Namespaces and isolation

Typical namespace layout:

- `argocd` – ArgoCD itself
- `shortlink` – your app workloads (what we use now)
- `istio-system` – service mesh
- `monitoring` – Prometheus/Grafana, etc.

RBAC and NetworkPolicies:

- Limit what ArgoCD can manage (only certain namespaces).
- Protect ArgoCD API from public exposure (Ingress with auth, or cluster-internal only).

#### 8.3 Git & credentials in prod

- Use:
  - SSH keys stored as Kubernetes Secrets, or
  - HTTPS with Personal Access Tokens (PATs) stored as Secrets.
- Lock down `AppProject`:
  - Restrict `sourceRepos` to specific Git URLs.
  - Restrict `destinations` to allowed namespaces/clusters.

---

### 9. Summary

- On **kind**:
  - Install ArgoCD into the `argocd` namespace.
  - Port-forward `argocd-server` for UI/CLI access.
  - Register `shortlink-gitops` as a repository.
  - Apply `AppProject` and `Application` manifests from `shortlink-gitops/argocd/`.
  - ArgoCD will then:
    - Watch your Git repo.
    - Render Kustomize overlays.
    - Apply them to the `shortlink` namespace in the kind cluster.

- For **production**:
  - Use the same model: dedicated `argocd` namespace, Applications pointing at GitOps repo.
  - Add stricter RBAC, network policies, SSO, and possibly multi-cluster support.

This article gives you both the **“how”** (commands and manifests) and the **“where”** (namespace and repo wiring) for running ArgoCD on kind now, and a clear path to lifting the same model into a real production environment later.


