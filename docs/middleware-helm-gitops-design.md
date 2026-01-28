## Middleware with Helm + Apps with Kustomize + GitOps (Design & Conversion Guide)

This document describes how to evolve the current **Kustomize-only middleware** (Postgres / Redis / Kafka) into a **Helm-managed middleware layer**, while keeping:

- **Microservices** (`shortlink`, `admin`) on **Kustomize**
- **GitOps** (ArgoCD) as the deployment engine
- Clear separation between infra and app layers

The focus here is on design and trade-offs; we are **not** auto-generating Helm values or charts in this doc, but outlining how to convert and integrate.

---

## 1. Current State (Baseline)

### 1.1 Middleware via Kustomize (shortlink-platform repo)

Under `shortlink-platform/k8s/base/`:

- `postgres/postgres-all.yaml` – StatefulSet + Service + init ConfigMap
- `redis/redis.yaml` – StatefulSet + Service
- `kafka/kafka.yaml` – Zookeeper + Kafka StatefulSets + Services

`base/kustomization.yaml`:

```yaml
resources:
  - postgres/
  - redis/
  - kafka/
```

Overlays:

- `k8s/overlays/dev`: namespace + base middleware only
- `k8s/overlays/prod`: namespace + base middleware + apps (`shortlink`, `admin`) + Istio

### 1.2 GitOps (isolated repo)

In `/Users/emma/Irish-Project/worspace/shortlink-gitops/` we now have:

- `k8s/` – copied structure from `shortlink-platform/k8s`
- `argocd/` – `AppProject` + `Application` manifests for `dev` and `prod`

Currently, both **middleware and apps** are deployed via **Kustomize** from this GitOps repo.

---

## 2. Target State Overview

### 2.1 Desired Target Architecture

- **Middleware (Kafka, Redis, Postgres, future ClickHouse etc.)**
  - Deployed via **Helm charts** (Bitnami/Confluent/Strimzi/etc.)
  - Managed as **separate ArgoCD Applications**
  - One or more **values.yaml** per environment (dev/prod)

- **Microservices (`shortlink`, `admin`)**
  - Continue to use **Kustomize overlays** (`k8s/overlays/prod/shortlink`, `.../admin`)
  - Reference middleware via **stable DNS** and **Secrets**

- **GitOps**
  - `shortlink-gitops` becomes the GitOps repo
  - ArgoCD Applications:
    - `shortlink-middleware-dev` (Helm)
    - `shortlink-apps-dev` (Kustomize)
    - `shortlink-middleware-prod` (Helm)
    - `shortlink-apps-prod` (Kustomize)

### 2.2 Why This Hybrid is Reasonable

- Leverages **Helm** where it shines (complex, stateful infra)
- Keeps **Kustomize** where it’s simple and explicit (your Spring Boot apps)
- GitOps (ArgoCD) orchestrates both:
  - Helm source for middleware
  - Kustomize source for apps

---

## 3. Helm vs Kustomize for Middleware – Conversion Trade-offs

### 3.1 Helm Benefits for Middleware

- **Operational Best Practices** baked into charts:
  - StatefulSets, PDBs, liveness/readiness probes
  - TLS/SASL, metrics exporters, security contexts
  - Configuration of replication, persistence, and resource limits
- **Versioned upgrades**:
  - Chart versions track app versions (e.g., Kafka/Zookeeper/Postgres)
  - Upgrade notes and tested migrations
- **Enterprise expectations**:
  - Many orgs already approve specific charts (Bitnami, Confluent, Strimzi)
  - Security scans and signing more common on charts

### 3.2 Kustomize Drawbacks for Middleware

- You own:
  - HA patterns
  - Upgrade strategies
  - Security hardening
  - Complex config matrices (e.g., Kafka listeners, Postgres replication)
- Harder to keep in sync with upstream improvements.

### 3.3 “Double Conversion” Concern (values → templates → YAML)

**Concern**: Helm introduces:

1. `values.yaml` (your config)
2. Chart templates
3. Rendered YAML (at ArgoCD sync time)

**Why it’s acceptable in GitOps**:

- Deterministic rendering if you **pin chart versions and images**
- ArgoCD still shows diffs on **rendered manifests**
- Changes are driven by **values.yaml** changes, which are still plain YAML and Git-tracked

**When “native YAML only” is better**:

- You have simple infra and don’t want template indirection
- You want maximum explicitness and are willing to own all ops concerns

---

## 4. Concrete Conversion Plan (Design Only)

### 4.1 General Pattern

For each middleware component (Postgres, Redis, Kafka):

1. **Pick a chart**
   - Postgres: `bitnami/postgresql` or `bitnami/postgresql-ha`
   - Redis: `bitnami/redis` or `bitnami/redis-cluster`
   - Kafka: `bitnami/kafka` or `bitnami/kafka`+ZK, or `strimzi` for advanced setups

2. **Create values files in GitOps repo**
   - `shortlink-gitops/helm-values/postgres/dev-values.yaml`
   - `shortlink-gitops/helm-values/postgres/prod-values.yaml`
   - Similarly for `redis` and `kafka`

3. **Add ArgoCD Helm Applications** for middleware
   - `argocd/application-mw-dev-postgres.yaml`
   - `argocd/application-mw-prod-postgres.yaml`
   - Same pattern for redis/kafka

4. **Remove or deprecate** raw Kustomize middleware YAMLs over time
   - `k8s/base/postgres/` → eventually not used
   - `k8s/base/redis/`, `k8s/base/kafka/` → same

5. **Keep apps on Kustomize** and adjust env vars to match Helm-generated service names:
   - DB URLs, Redis host/port, Kafka bootstrap servers remain **stable DNS**.

### 4.2 Example: Postgres Conversion (Design)

**Current** (simplified):

- StatefulSet `postgres` in `shortlink` namespace
- Service `postgres.shortlink.svc.cluster.local:5432`
- Init ConfigMap creates `admin` and `shortlink` DBs

**Target with Helm**:

- Chart: `bitnami/postgresql`
- Values (dev):

```yaml
# shortlink-gitops/helm-values/postgres/dev-values.yaml
global:
  postgresql:
    auth:
      username: admin
      password: admin
      database: admin

primary:
  persistence:
    enabled: true
    size: 10Gi

readReplicas:
  enabled: false

fullnameOverride: postgres
```

**DNS contract**:
- Service remains (or is aliased to) `postgres.shortlink.svc.cluster.local` so apps don’t change.

**ArgoCD Application (design)**:

```yaml
spec:
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: 12.10.0       # example
    helm:
      valueFiles:
        - helm-values/postgres/dev-values.yaml
  destination:
    namespace: shortlink
```

### 4.3 Example: Redis Conversion (Design)

**Current**:
- StatefulSet `redis`, Service `redis.shortlink.svc.cluster.local:6379`

**Target with Helm (Bitnami)**:

```yaml
# shortlink-gitops/helm-values/redis/dev-values.yaml
auth:
  enabled: true
  password: StrongRedisPass123!

master:
  persistence:
    enabled: true
    size: 5Gi

replica:
  replicaCount: 0  # dev: single node

fullnameOverride: redis
```

Apps keep using:
- `REDIS_HOST=redis.shortlink.svc.cluster.local`
- `REDIS_PORT=6379`

### 4.4 Example: Kafka Conversion (Design)

Kafka is more complex; a chart gives:

- Zookeeper + Kafka pods
- Listeners, advertised listeners, metrics, and optional TLS/SASL

**Target with Helm (Bitnami)**:

```yaml
# shortlink-gitops/helm-values/kafka/dev-values.yaml
zookeeper:
  enabled: true

listeners:
  client:
    name: CLIENT
    port: 9092

externalAccess:
  enabled: false  # in-cluster only for now

fullnameOverride: kafka
```

Apps keep using:
- `KAFKA_BOOTSTRAP_SERVERS=kafka.shortlink.svc.cluster.local:9092`

---

## 5. Integration with Existing Kustomize & GitOps

### 5.1 ArgoCD Application Layout (Design)

In `shortlink-gitops/argocd/`, you can evolve to:

- `appproject-shortlink.yaml` – already present
- Middleware apps (Helm):
  - `application-mw-dev-postgres.yaml`
  - `application-mw-dev-redis.yaml`
  - `application-mw-dev-kafka.yaml`
  - `application-mw-prod-postgres.yaml`
  - `application-mw-prod-redis.yaml`
  - `application-mw-prod-kafka.yaml`
- App layer (Kustomize):
  - `application-shortlink-dev.yaml` → points to `k8s/overlays/dev` (middleware may be **removed** from this overlay once Helm is used)
  - `application-shortlink-prod.yaml` → points to `k8s/overlays/prod` (minus middleware)

### 5.2 Stepwise Migration Strategy

1. **Phase 0 – Keep Kustomize as source of truth**
   - No change; document current state (done).

2. **Phase 1 – Introduce Helm for one component (e.g., Redis)**
   - Create Redis Helm Application (dev only).
   - Remove `../../base/redis/` from `k8s/overlays/dev/kustomization.yaml` in GitOps repo.
   - Verify:
     - Redis DNS unchanged (`redis.shortlink.svc.cluster.local`)
     - Apps still connect correctly.

3. **Phase 2 – Migrate Postgres**
   - Repeat pattern for Postgres.
   - Ensure DB initialization (Flyway jobs) still work with new service.

4. **Phase 3 – Migrate Kafka**
   - Migrate last; most sensitive for statistics pipeline.
   - Validate performance and client configuration thoroughly.

5. **Phase 4 – Clean-up**
   - Remove unused Kustomize middleware manifests from both app repo and GitOps repo.
   - Update docs to point only to Helm for middleware.

---

## 6. Trade-off Summary for Enterprise Use

### Helm-managed Middleware
- **Pros**:
  - Faster adoption of best practices and upgrades.
  - Stronger alignment with how enterprises typically manage infra.
  - Easier to standardize across teams.
- **Cons**:
  - Requires Helm knowledge + chart governance.
  - More implicit behavior (templates) vs pure YAML.

### Kustomize-managed Middleware
- **Pros**:
  - Maximum explicitness and control.
  - Single tool (Kustomize) for everything.
- **Cons**:
  - Higher long-term ops/maintenance cost.
  - Harder to keep infra aligned with upstream/best practices.

### Recommendation for Your Context

Given your goals:
- **Statistics subsystem + Kafka + Postgres + Redis** need to be robust and scalable.
- You already have **GitOps** and a clear separation of middleware vs apps.

**Recommended**:
- Move **middleware** to Helm (with pinned charts and well-structured values).
- Keep **apps** on Kustomize.
- Let ArgoCD orchestrate both, with clearly separated Applications.

This gives you:
- Enterprise-grade middleware management.
- Clean, native Kustomize for microservices.
- A GitOps story that remains readable and auditable.

