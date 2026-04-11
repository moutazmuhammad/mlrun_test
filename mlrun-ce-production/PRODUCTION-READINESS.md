# MLRun CE - Production Readiness Report

## Cloud Portability

This chart is **cloud-agnostic** and runs on:

| Cloud | Status | Notes |
|-------|--------|-------|
| GCP (GKE) | Supported | Uses Workload Identity for registry auth |
| AWS (EKS) | Supported | Uses IRSA for registry auth |
| Azure (AKS) | Supported | Uses AD Workload Identity for registry auth |
| Red Hat OpenShift | Supported | Requires `nonroot-v2` SCC binding (chart uses hardcoded UIDs that conflict with default `restricted-v2` SCC) |
| On-prem / generic K8s | Supported | Uses pull secret for registry auth |

See `INSTALL.md` step 3 for cloud-specific setup.

---

## Fixed via values.yaml (chart supports these)

These issues were resolved in `values.yaml` using configuration options that the chart subcharts already support. No chart template modifications were needed.

| Fix | Component | What was added |
|-----|-----------|----------------|
| Security context | MLRun API | `runAsNonRoot: true`, `drop: ALL`, `allowPrivilegeEscalation: false` |
| Security context | MLRun UI | `runAsNonRoot: true`, `drop: ALL`, `allowPrivilegeEscalation: false` |
| Pod security context | MLRun API, MLRun UI | `runAsNonRoot: true` at pod level |
| Liveness probe | MLRun API | `httpGet /api/healthz:8080` (initialDelay: 30s, period: 15s) |
| Readiness probe | MLRun API | `httpGet /api/healthz:8080` (initialDelay: 10s, period: 10s) |
| Liveness probe | MLRun DB (MySQL) | `mysqladmin ping` (initialDelay: 30s, period: 10s) |
| Readiness probe | MLRun DB (MySQL) | `mysqladmin ping` (initialDelay: 10s, period: 5s) |
| Resource limits | MLRun API | requests: 250m / 512Mi, limits: 2 CPU / 2Gi |
| Resource limits | MLRun UI | requests: 100m / 128Mi, limits: 500m / 256Mi |
| Resource limits | MLRun DB | requests: 250m / 512Mi, limits: 1 CPU / 1Gi |
| Resource limits | Nuclio Controller | requests: 100m / 128Mi, limits: 500m / 256Mi |
| Resource limits | Nuclio Dashboard | requests: 100m / 128Mi, limits: 500m / 512Mi |
| Resource limits | MPI Operator | requests: 100m / 128Mi, limits: 500m / 256Mi |
| Resource limits | Spark Controller | requests: 100m / 128Mi, limits: 500m / 300Mi |
| Resource limits | Spark Webhook | requests: 100m / 128Mi, limits: 500m / 300Mi |
| PDB | Spark Controller | `minAvailable: 1` |
| PDB | Spark Webhook | `minAvailable: 1` |
| Log levels | Nuclio system + functions | Changed from `debug` to `info` for production |
| Secrets | All MinIO credentials | Moved from hardcoded values to external Kubernetes Secrets |
| Registry auth | GCP Artifact Registry | Workload Identity (no stored credentials) |
| Service types | All services | ClusterIP only (no NodePort, no LoadBalancer) |

---

## Cannot fix via values (chart does not provide the mechanism)

These issues are hardcoded in the chart templates. They require either modifying the upstream chart templates or applying post-install workarounds.

### No Resource Limits on Pipeline Components

The following deployments have `resources: {}` or only partial requests hardcoded in their templates, with no values override available:

| Deployment | Current State | Template File |
|-----------|---------------|---------------|
| ml-pipeline | requests only (250m / 500Mi), no limits | `templates/pipelines/deployments/ml-pipeline.yaml` |
| ml-pipeline-ui | no resources | `templates/pipelines/deployments/ml-pipeline-ui.yaml` |
| ml-pipeline-scheduledworkflow | no resources | `templates/pipelines/deployments/ml-pipeline-scheduledworkflow.yaml` |
| ml-pipeline-viewer-crd | no resources | `templates/pipelines/deployments/ml-pipeline-viewer-crd.yaml` |
| ml-pipeline-visualizationserver | no resources | `templates/pipelines/deployments/ml-pipeline-visualizationserver.yaml` |
| metadata-grpc-deployment | no resources | `templates/pipelines/deployments/metadata-grpc-deployment.yaml` |
| metadata-envoy-deployment | no resources | `templates/pipelines/deployments/metadata-envoy-deployment.yaml` |
| metadata-writer | no resources | `templates/pipelines/deployments/metadata-writer.yaml` |
| Pipelines MySQL | requests only (100m / 500Mi), no limits | `templates/pipelines/deployments/mysql.yaml` |
| workflow-controller | requests only (100m / 500Mi), no limits | `templates/pipelines/deployments/workflow-controller.yaml` |

**Workaround:** Apply a `LimitRange` to the `aib-system` namespace after install:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: aib-system
spec:
  limits:
    - default:
        cpu: "1"
        memory: 1Gi
      defaultRequest:
        cpu: 100m
        memory: 256Mi
      type: Container
```

```bash
kubectl apply -f limitrange.yaml
```

---

### No Security Context on Pipeline and Jupyter Pods

The following deployments have `securityContext: {}` hardcoded in their templates, with no values override available:

| Deployment | Template File |
|-----------|---------------|
| ml-pipeline | `templates/pipelines/deployments/ml-pipeline.yaml` |
| ml-pipeline-ui | `templates/pipelines/deployments/ml-pipeline-ui.yaml` |
| ml-pipeline-persistenceagent | `templates/pipelines/deployments/ml-pipeline-persistenceagent.yaml` |
| ml-pipeline-scheduledworkflow | `templates/pipelines/deployments/ml-pipeline-scheduledworkflow.yaml` |
| ml-pipeline-viewer-crd | `templates/pipelines/deployments/ml-pipeline-viewer-crd.yaml` |
| ml-pipeline-visualizationserver | `templates/pipelines/deployments/ml-pipeline-visualizationserver.yaml` |
| metadata-grpc-deployment | `templates/pipelines/deployments/metadata-grpc-deployment.yaml` |
| metadata-envoy-deployment | `templates/pipelines/deployments/metadata-envoy-deployment.yaml` |
| metadata-writer | `templates/pipelines/deployments/metadata-writer.yaml` |
| Jupyter Notebook | `templates/jupyter-notebook/deployment.yaml` (runs as UID 1000 but missing explicit `runAsNonRoot: true`) |

> **Note:** `workflow-controller` is the one pipeline deployment that already has proper security context (`runAsNonRoot: true`, `drop: ALL`, `readOnlyRootFilesystem: true`). Pipelines MySQL has a configurable `securityContext` via `pipelines.db.securityContext` values but does not set `runAsNonRoot` by default.

**Impact:** If the cluster enforces Pod Security Admission at `restricted` level, these pods will be rejected.

**Workaround:** Set namespace PSA to `baseline` level:

```bash
kubectl label namespace aib-system pod-security.kubernetes.io/enforce=baseline
```

---

### No Liveness/Readiness Probes

The following deployments have no health probes and the templates do not support adding them via values:

| Deployment | Template File |
|-----------|---------------|
| Pipelines MySQL | `templates/pipelines/deployments/mysql.yaml` |
| ml-pipeline-persistenceagent | `templates/pipelines/deployments/ml-pipeline-persistenceagent.yaml` |
| ml-pipeline-scheduledworkflow | `templates/pipelines/deployments/ml-pipeline-scheduledworkflow.yaml` |
| ml-pipeline-viewer-crd | `templates/pipelines/deployments/ml-pipeline-viewer-crd.yaml` |
| metadata-writer | `templates/pipelines/deployments/metadata-writer.yaml` |
| workflow-controller | Has liveness only, no readiness probe |
| Nuclio Controller | `charts/nuclio/templates/deployment/controller.yaml` |
| Jupyter Notebook | `templates/jupyter-notebook/deployment.yaml` |

> **Note:** The following pipeline deployments already have probes: ml-pipeline (liveness + readiness), ml-pipeline-ui (liveness + readiness), ml-pipeline-visualizationserver (liveness + readiness), metadata-grpc (liveness + readiness via tcpSocket), metadata-envoy (no probes but stateless proxy). Nuclio Dashboard already has liveness, readiness, and startup probes.

**Impact:** Kubernetes won't detect if a process hangs. The pod stays `Running` but non-functional until manually restarted.

---

### All Replicas Hardcoded to 1

Every pipeline deployment has `replicas: 1` hardcoded in the template, not configurable via values:

| Deployment | Template File |
|-----------|---------------|
| ml-pipeline | `templates/pipelines/deployments/ml-pipeline.yaml` |
| ml-pipeline-ui | `templates/pipelines/deployments/ml-pipeline-ui.yaml` |
| ml-pipeline-persistenceagent | `templates/pipelines/deployments/ml-pipeline-persistenceagent.yaml` |
| ml-pipeline-scheduledworkflow | `templates/pipelines/deployments/ml-pipeline-scheduledworkflow.yaml` |
| ml-pipeline-viewer-crd | `templates/pipelines/deployments/ml-pipeline-viewer-crd.yaml` |
| ml-pipeline-visualizationserver | `templates/pipelines/deployments/ml-pipeline-visualizationserver.yaml` |
| metadata-grpc-deployment | `templates/pipelines/deployments/metadata-grpc-deployment.yaml` |
| metadata-envoy-deployment | `templates/pipelines/deployments/metadata-envoy-deployment.yaml` |
| metadata-writer | `templates/pipelines/deployments/metadata-writer.yaml` |
| Pipelines MySQL | `templates/pipelines/deployments/mysql.yaml` |
| workflow-controller | `templates/pipelines/deployments/workflow-controller.yaml` |
| Nuclio Controller | `charts/nuclio/templates/deployment/controller.yaml` |
| Jupyter Notebook | `templates/jupyter-notebook/deployment.yaml` |

**Impact:** Single point of failure for every component. Kubernetes auto-restarts pods, but expect 30s-2min downtime per component failure.

**Workaround:** For critical databases (MLRun DB, Pipelines MySQL), consider replacing with an external managed MySQL (e.g. Cloud SQL) that provides built-in HA.

---

### No PodDisruptionBudgets

Only the Spark Operator supports PDB via values. All other components have no PDB support in their templates:

| Component | PDB Available |
|-----------|--------------|
| Spark Controller | Yes (enabled via values) |
| Spark Webhook | Yes (enabled via values) |
| All other components | No |

**Impact:** During node maintenance or upgrades, pods can be evicted without availability guarantees. With `replicas: 1`, this means guaranteed downtime during eviction.

---

### No NetworkPolicies

The chart contains zero `NetworkPolicy` templates. All pods in all namespaces can communicate freely with each other.

**Impact:** A compromised pod can reach any service (MySQL databases, MinIO, internal APIs).

**Workaround:** Create NetworkPolicies as separate manifests after install:

```yaml
# Restrict MinIO access to aib-system only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-minio-from-aib-system
  namespace: aib-data
spec:
  podSelector:
    matchLabels:
      app: minio
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: aib-system
      ports:
        - port: 9000
---
# Restrict Pipelines MySQL to pipeline components only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-pipelines-mysql
  namespace: aib-system
spec:
  podSelector:
    matchLabels:
      app: mysql
      application-crd-id: kubeflow-pipelines
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              application-crd-id: kubeflow-pipelines
      ports:
        - port: 3306
---
# Restrict MLRun DB to MLRun components only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-mlrun-db
  namespace: aib-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mlrun-ce
      ports:
        - port: 3306
```

---

### Broad RBAC ClusterRoles

Several ClusterRoles use wildcard verbs (`*`) on resources. These are required for the platform to function:

| ClusterRole | Broad Permissions | Why Needed |
|------------|-------------------|------------|
| `pipeline-runner` | `*` verbs on pods, deployments, PVs, secrets | Argo workflows need to create/manage step pods |
| `nuclio function-deployer` | `*` verbs on services, configmaps, pods, deployments, ingresses, HPA | Nuclio needs to deploy function resources |
| `mlrun api-role` | `*` verbs on pods, services, secrets, configmaps | MLRun API manages jobs, functions, and CRDs |
| `argo-role` | pods, pods/exec, secrets, services, events (all verbs) | Argo controller orchestrates workflows |

**Impact:** Compromise of these service accounts grants broad namespace access.

**Mitigation:** Already mitigated by namespace isolation (aib-system, aib-serving, aib-data). Strengthen with NetworkPolicies above.

---

### Pipeline MySQL Empty Password

The Pipelines MySQL deployment template hardcodes `MYSQL_ALLOW_EMPTY_PASSWORD: true` with no values override.

**Impact:** The database has no password protection. It's only accessible within the cluster (ClusterIP service), so the risk is limited to in-cluster access.

**Workaround:** Apply the NetworkPolicy for Pipelines MySQL shown above to restrict access to pipeline components only.

---

## Summary

| Category | Status | Notes |
|----------|--------|-------|
| Secrets management | **Fixed** | External K8s Secrets, no hardcoded values |
| Network exposure | **Fixed** | All ClusterIP, no external access |
| Persistence | **Fixed** | All PVCs enabled with keep policy |
| Resource limits (MLRun, Nuclio, Spark, MPI) | **Fixed** | Requests and limits set via values |
| Resource limits (Pipeline components) | **Not fixable** | Hardcoded in templates; use LimitRange workaround |
| Security contexts (MLRun API, UI) | **Fixed** | runAsNonRoot, drop ALL via values |
| Security contexts (Pipeline, Jupyter) | **Not fixable** | Hardcoded empty in templates; use PSA baseline |
| Health probes (MLRun API, DB) | **Fixed** | Liveness + readiness via values |
| Health probes (Pipeline components, Jupyter) | **Not fixable** | Templates don't support values-based probes |
| High availability | **Not fixable** | All replicas hardcoded to 1 |
| PDB | **Partial** | Spark only; others not supported |
| NetworkPolicies | **Not fixable** | No template support; apply post-install |
| Log levels | **Fixed** | Set to `info` for production |
| Registry auth | **Fixed** | Workload Identity, no stored credentials |
