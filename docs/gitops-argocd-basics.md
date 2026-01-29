## GitOps & ArgoCD Basics (ShortLink GitIOps Repo)

### What is GitOps?
**GitOps** is an operating model where 
- **Git** is the *single source of truth* for our system's desired state (Kubernetes manifests, Kustomize overlays, Helm values, etc.).
- A **controller** running in the cluster (here: ArgoCD) continuously: 
> Reads desired state from Git
> Compares it to the actual state in the cluster 
> Reconciles differences automatically 

Key properties: 
- **Declarative**: we describe what we want (YAML), not how to do it
- **Versioned**: every change is a commit / PR; full audit trail.
- **Automated reconcile**: no `kubectl apply` from laptops; the controller applies and heals drift. 

In this repo: 
- `/k8s` holds the desired state (Kustomize bases + overlays)
- `/argocd` defines how ArgoCD should apply that state to the cluster


---

### 2. What is ArgoCD ? 
**ArgoCD** is a Kubernetes controller that implements GitOps: 
- Watches Git repositories for changes. 
- For each **`Application`** CR:
> Fetches manifests from Git(`repoURL`, `path`, `targetRevision`)
> Renders them (plain YAML, Kustomize, or Helm)
> Applies them to the cluster until real state matches desired state. 

Core **CRDs** we use: 

#### **AppProject**: 
- Groups Applications 
- Defines allowed repos, destinations (namespaces/clusters), and resource kinds. 

#### **Application**: 
- Defines *what* to deploy (source in Git)
- Defines *where* to deploy (cluster + namespace)
- Optional `syncPolicy.automated` to auto-apply changes. 


Example (conceptual) `Application`:

```yaml 
spec: 
  project: shortlink 
  source:
    repoURL: https://github.com/Rururtia1027/shortlink-gitops.git 
    targetRevision: main 
    path: k8s/overlays/prod 
  destination: 
    server: https://kubernetes.default.svc 
    namespace: shortlink 
  syncPoilcy:
    automated:
      prune: true 
      selfHeal: true 
```

--- 

### 3. How Kustomize fits in 
Kustomize letes you build: 
- **Base** manifests (e.g., `k8s/base/postgres`, `k8s/base/redis`, `k8s/base/kafka`)
- **Overlays** for environments (e.g., `k8s/overlays/dev`, `k8s/overlays/prod`) that 
> Add namespaces 
> Patch replicas, images, env vars, etc. 

ArgoCD treats a Kustomize path as: 
- 1. Run `kustomize build` on the folder 
- 2. Take the rendered YAML.
- 3. Apply it to the cluster. 

For example, in `application-shortlink-prod.yaml` we point ArgoCD to:

```yaml 
spec: 
  source: 
    path: k8s/overlays/prod 
```

ArgoCD builds and applies everything in that overlay. 

---

### 4. Sync Waves - what is `argocd.argoproj.io/sync-wave` ? 

By default, ArgoCD applies all resources in an `Application` in one go (subject to Kubernetes dependencies). **Sync waves** let you control **order** explicitly. 

- Annotation: `argocd.argoproj.io/sync-wave: "<integer>"`
- Default waves is `"0"` if not specified 
- ArgoCD applies resources in increasing wave order:
> Wave 0 -> wait for health 
> Wave 1 -> wait for health 
> Wave 2 -> ... 


In our setup we encode the deployment stages like this: 
- **Wave 0** (default, no annotaiton)
> Middleware: Postgres, Redis, Kafka (StatefulSets + Services)

-  **Wave 1** 
> Flyway Jobs: `flyway-admin`, `flyway-shortlink`

- **Wave 2**
> `shortlink` Deployment 

- **Wave 3**
> `admin` Deployment 


This matches the desired stages: 
1. Deploy middleware 
2. Validate middleware health 
3. Run DB migrations
4. Deploy `shortlink`
5. Deploy `admin` 

ArgoCD automatically waits for lower-wave resources to become **Health** before moving on to higher waves. 

---

### 5. Hooks - what are `argocd.argoproj.io/hook` and `...hook-delete-policy`?
**Hook** are special resources that ArgoCD runs at specific points in the sync lifecycle: `PreSync`, `Sync`, `PostSync`, etc. 

We use **Sync hooks** for Flyway Jobs: 

```yaml 
metadata:
  annotations: 
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/hook: Sync 
    argocd.argoproj.io/hook-delete-policy: HookSucceed 
```

Meaning: 
- Resource is created during the Sync phase (after wave 0)
- ArgoCD **waits** for the Job to complete 
- When it succeeds, ArgoCD deletes the Job (per `HookSucceeded` policy)
- If the job fails, sync fails and higher waves are not applied 

This is how we implement: 
- Stage 3: "trigger two jobs if flyway db migations, and validate both of them are complete successfully".

---

### 6. Health Status (Healthy / Degraded / Progressing)

ArgoCD computes a health status for each resource:

- **Deployments**: Healthy when desired replicas are available and probes pass.
- **StatefulSets**: Healthy when all replicas are ready.
- **Jobs**: Healthy when they succeed.

For an `Application`:

- **Healthy**: all managed resources are Healthy.
- **Progressing**: some resources are still being created/updated.
- **Degraded**: some resources are failing (e.g., CrashLoopBackOff, Job failed).

How this matches your stages:

- If middleware (wave 0) is not Ready → Application is Progressing/Degraded, waves 1+ won’t continue.
- If Flyway Jobs (wave 1) fail → Application is Degraded, waves 2+ won’t run.
- If `shortlink` or `admin` Deployments fail health checks → Application is Degraded.

---

### 7. Summary: How ArgoCD orchestrates your 5 stages

With the annotations we added under `shortlink-gitops/k8s`:

1. **Stage 1 – Deploy middleware**
   - Postgres/Redis/Kafka (StatefulSets + Services) are applied at **wave 0** (default).
2. **Stage 2 – Validate middleware health**
   - ArgoCD waits until those StatefulSets are **Healthy**.
3. **Stage 3 – Run Flyway Jobs**
   - Flyway Jobs (`flyway-admin`, `flyway-shortlink`) are **Sync hooks** at **wave 1**.
   - ArgoCD waits for them to **Complete**; fails if they do not.
4. **Stage 4 – Deploy `shortlink`**
   - `shortlink` Deployment has **wave 2**; it’s only applied after waves 0–1 succeeded.
5. **Stage 5 – Deploy `admin`**
   - `admin` Deployment has **wave 3**; it’s only applied after waves 0–2 succeeded.

All this orchestration is driven by:

- Kustomize structure (`k8s/base`, `k8s/overlays/dev`, `k8s/overlays/prod`)
- ArgoCD `Application` definitions in `argocd/`
- A small set of **annotations** on Jobs and Deployments

No extra scripting or Helm is required at this stage; ArgoCD + Kustomize + annotations give you a declarative, GitOps-friendly deployment pipeline.

