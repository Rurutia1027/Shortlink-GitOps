# Setting Up ArgoCD on Kind-Based K8s Cluster 

This guide explains, step by step, how to: 
- Install ArgoCD into a **kind** (Kubernetes-in-Docker) cluster 
- Expose the ArgoCD UI/API for local development 
- Connect ArgoCD to your **GitOps repo** （e.g., ·shortlink-gitops`)
- Understand where ArgoCD usually lives in **production** clusters. 


---


### 1. Prerequisites 
You should have: 
- A running **kind** cluster: 

```bash 
kind create --name shortlink-dev 
# or already created and `kubectl config current-context` points to it
```

- `kubectl` installed and configured 

```bash 
kubectl get nodes 
```

- (Optional but recommended) `kubens` / `kubectx` for namespace/context switching. 

---

### 2. Where do we install ArgoCD ? 

In almost all setups (dev and prod), ArgoCD is installed into its **own namespace**, usually called: 

- `argocd`

On a **kind** dev cluster: 
- Namespace: `argocd`
- ArgoCD components (API server, repo-server, application-controller, dex, redis, etc.) run as Deployments/StatefulSets in that namespace. 
- ArgoCD then deployes **our apps** into other namespace (e.g., `shortlink`).

In **production**, the pattern is the same: 
- A dedicated `argocd` (or `gitops-system`) namespace
- Restricted RBAC and network policies
- ArgoCD has permissions to manage only the allowd namespace/clsuter 

We'll follow this pattern in the examples below. 

--- 

### 3. Installing ArgoCD on kind 
#### 3.1 Create the `argocd` namespace 

```bash 
kubectl creaet namespace argocd 
```

#### 3.2 Install ArgoCD (core components)
For a simple dev setup, use the official **core** install (no ingress, minimal extras): 

```bash 
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

This will creaet: 

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
- **Password**: value form the command above 

> For dev, we can change this password in the UI or disable the admin user once we create another account. 
> For prod, we'd typically integrate with SSO (OIDC/Dex). 

---

### 5. Connecting ArgoCD to our GitOps repo 

We will use the `shortlink-gitops` as the source of truth. 

#### 5.1 Add the Git repo (via UI)
In the ArgoCD UI: 
- 1. Go to **Settings -> Repositories**
- 2. Click **CONNECT REPO**
3. Enter:
   - **Type**: Git
   - **Repository URL**: e.g. `https://github.com/${ORG}/shortlink-gitops.git` (replace with real URL)
   - **Username/Password** or **SSH** if private (for dev, https with PAT is fine).
4. Click **Connect**.


Alternatively, via CLI: 

```bash 
argocd repo add https://github.com/${ORG}/shortlink-gitops.git \
  --username <GITHUB_USER> \
  --password <GITHUB_TOKEN> 
```

> The `argocd` CLI can port-forward automatically if we set `ARGOCD_SERVER=localhost:8080`

---

### 5.5 Core Mechanism: How ArgoCD Connects to GitOps and Deploys Apps 
This is the **most critical** part to understand: how a ready ArgoCD instance actually connects to our GitOps repository and deploys our applications. 


#### 5.5.1 The Bridge: Application CRD 
ArgoCD "deploys our apps"  through **Application Custom Resource Definitions (CRDs)**. When we create an `Application` resource in the `argocd` namespace, we're telling ArgoCD: 
- TODO 

