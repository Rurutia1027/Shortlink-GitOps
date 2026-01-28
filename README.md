# Shortlink GitOps 
This is intended to become the **separate GitOps / ArgoCD repository** for the Shortlink platform. 

## Environments
- **dev**: middleware only (namespace + postgres + redis + kafka)
- **prod**: runs locally as well, but includes middleware + application deployments (admin + shortlink + istio)

## Layout
- `k8s/`: copied from application repo (`shortlink-backend/k8s/*`) so GitOps can be isolated 
- `argocd/`: ArgoCD `AppProject` + `Application` manifests (dev/prod)

## How ArgoCD should sync 
- Dev app points to `k8s/overlays/dev`
- Prod app points to `k8s/overlays/prod` 
