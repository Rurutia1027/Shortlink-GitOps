# Argo CD PostSync Hooks

This repo uses **Argo CD sync hooks** so that one-off Jobs (migrations, topic creation) run in a strict order **after** the main Sync, and any hook failure fails the whole sync.

## Hook order

Argo CD runs in three phases:

```
PreSync  →  Sync  →  PostSync
```

- **PreSync**: Hooks that must run before any Sync resources (e.g. pre-install checks).
- **Sync**: Normal resources (Deployments, StatefulSets, Services, ConfigMaps, etc.). Our base (Postgres, Redis, Kafka, ClickHouse) and overlays (shortlink, admin) deploy here. Sync-wave patches order within Sync (e.g. shortlink wave 2, admin wave 3).
- **PostSync**: Hooks that run **only after** Sync has completed successfully. Used for migrations and post-deploy Jobs.

Argo CD enforces:

- **Previous phase must succeed** before the next starts.
- **If a hook fails**, the sync is marked failed; later phases do not run.

So: infra and apps are applied in Sync; only when that is healthy do we run PostSync Jobs (Flyway, Kafka topic). If a migration or topic Job fails, the sync fails and you fix before continuing.

## Benefits of PostSync

1. **Ordering**: Migrations and topic creation run only after Postgres/Kafka (and optionally app Deployments) are up. No “Job runs before DB is ready”.
2. **Fail-fast**: A failed migration or topic Job fails the sync, so you don’t leave the app in a half-migrated state.
3. **No manual steps**: You don’t “apply base, wait, then manually run jobs”. One sync does: Sync (infra + app) → PostSync (Jobs). Git remains the single source of truth.
4. **Cleanup**: With `hook-delete-policy: HookSucceeded`, successful Jobs are deleted by Argo CD; only failed runs stay for debugging.

## Jobs we use as PostSync hooks

| Job | Purpose | Order in PostSync |
|-----|---------|-------------------|
| `flyway-admin` | Admin DB migrations | sync-wave `"0"` (first) |
| `flyway-shortlink` | Shortlink DB migrations | sync-wave `"1"` (after admin) |
| `kafka-create-stats-topic` | Create `shortlink-stats-events` topic | (no wave; runs with other PostSync) |

Annotations used:

```yaml
annotations:
  argocd.argoproj.io/hook: PostSync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded
  argocd.argoproj.io/sync-wave: "0"   # optional; order among PostSync hooks
```

## Prod overlay and re-deployment

Our Argo CD **Application** points at:

- **Path**: `k8s/overlays/prod`
- **Sync policy**: `automated` with `prune: true`, `selfHeal: true`

So:

- **Any change under `k8s/overlays/prod`** (including the Job manifests referenced there) is part of the desired state Argo CD syncs.
- **Including the Flyway and Kafka topic Jobs** in the prod overlay (via `../../base/flyway-admin-job.yaml`, `../../base/flyway-shortlink-job.yaml`, and `../../base/kafka/` which contains `kafka-create-topic-job.yaml`) means:
  - **Job YAML changes trigger a re-sync**: When you push edits to those Job files (image, env, command, annotations, etc.), Argo CD sees a diff and runs a sync.
  - **PostSync runs again**: On sync, Argo CD runs PreSync → Sync → PostSync. The hook Jobs are part of PostSync; Argo CD will create/update them and run them according to hook semantics (e.g. new Job run for that sync).

So: **yes, modifying these Jobs in the repo that backs `k8s/overlays/prod` will trigger re-deployment** in the sense that the next sync will apply the new Job specs and run the PostSync phase (and thus run the Jobs again as per Argo CD’s hook behavior).

## Summary

- Use **PostSync** for migrations and Kafka topic creation so they run after Sync and any failure fails the sync.
- **Flyway** and **Kafka create-topic** Jobs are refactored to PostSync and are included in the prod overlay so that changes to those Job manifests are synced by Argo CD and re-running sync will re-run the PostSync phase (and the Jobs).
