# MLRun CE - Required Secrets Reference

All secrets must be created **before** running `helm install`. No credentials are stored in `values.yaml`.

---

## Quick Setup

Run all commands below to create every required secret in one go:

```bash
# Variables - set these once
MINIO_USER="minio"
MINIO_PASSWORD="minio123"

# 1. MinIO credentials for MLRun and Jupyter (aib-system)
kubectl create secret generic minio-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="${MINIO_USER}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_PASSWORD}" \
  --namespace aib-system

# 2. MinIO credentials for Kubeflow Pipelines (aib-system)
kubectl create secret generic mlpipeline-minio-artifact \
  --from-literal=accesskey="${MINIO_USER}" \
  --from-literal=secretkey="${MINIO_PASSWORD}" \
  --namespace aib-system
```

> **Note:** Container registry authentication uses GKE Workload Identity (no secret needed).
> See `INSTALL.md` step 3 for Workload Identity setup.

---

## Secret Details

### 1. `minio-credentials`

| | |
|---|---|
| **Namespace** | `aib-system` |
| **Type** | `Opaque` |
| **Purpose** | Provides S3-compatible credentials (MinIO) to MLRun API, Jupyter, and all MLRun job pods for reading/writing artifacts, feature store data, and model files. |
| **Required keys** | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| **Values must match** | The `rootUser` and `rootPassword` of the MinIO deployment in `aib-data` |

**Consumed by:**

| Component | How | What it does with it |
|-----------|-----|---------------------|
| MLRun API (`mlrun-api-chief`, `mlrun-api-worker`) | `envFrom.secretRef` in deployment | Authenticates to MinIO for storing/retrieving run artifacts, feature store data, model monitoring data |
| Jupyter Notebook (`mlrun-jupyter`) | `envFrom.secretRef` in deployment | Authenticates to MinIO for reading/writing data files and notebook outputs |
| MLRun Job Pods (training, serving) | Inherited via `MLRUN_STORAGE__AUTO_MOUNT_PARAMS` env | Runtime pods authenticate to MinIO when storing artifacts from training runs |

**Create:**

```bash
kubectl create secret generic minio-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=<your-minio-user> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-minio-password> \
  --namespace aib-system
```

**Verify:**

```bash
kubectl get secret minio-credentials -n aib-system -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
```

---

### 2. `mlpipeline-minio-artifact`

| | |
|---|---|
| **Namespace** | `aib-system` |
| **Type** | `Opaque` |
| **Purpose** | Provides S3-compatible credentials (MinIO) to all Kubeflow Pipelines components for storing pipeline artifacts, workflow logs, and ML metadata. |
| **Required keys** | `accesskey`, `secretkey` |
| **Values must match** | The `rootUser` and `rootPassword` of the MinIO deployment in `aib-data` |

> **Note:** This secret uses different key names (`accesskey`/`secretkey`) than `minio-credentials` (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) because the Kubeflow Pipelines templates hardcode these key names in their `secretKeyRef` references.

**Consumed by:**

| Component | How | What it does with it |
|-----------|-----|---------------------|
| Pipelines API Server (`ml-pipeline`) | `secretKeyRef` in deployment env vars (`OBJECTSTORECONFIG_ACCESSKEY`, `OBJECTSTORECONFIG_SECRETACCESSKEY`) | Authenticates to MinIO for storing/retrieving pipeline definitions and run artifacts |
| Pipelines UI (`ml-pipeline-ui`) | `secretKeyRef` in deployment env vars (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`) | Authenticates to MinIO for fetching artifacts to display in the web UI |
| Argo Workflow Controller | `accessKeySecret`/`secretKeySecret` in `workflow-controller-configmap` artifact repository config | Authenticates to MinIO for archiving workflow logs and step artifacts |
| Viewer CRD Controller | `secretKeyRef` in `ml-pipeline-ui-configmap` viewer pod template | Injects MinIO credentials into TensorBoard/viewer pods for accessing artifacts |

**Create:**

```bash
kubectl create secret generic mlpipeline-minio-artifact \
  --from-literal=accesskey=<your-minio-user> \
  --from-literal=secretkey=<your-minio-password> \
  --namespace aib-system
```

**Verify:**

```bash
kubectl get secret mlpipeline-minio-artifact -n aib-system -o jsonpath='{.data.accesskey}' | base64 -d
```

---

### 3. GCP Artifact Registry Authentication (Workload Identity - no secret)

| | |
|---|---|
| **Namespace** | N/A (no Kubernetes Secret required) |
| **Type** | GKE Workload Identity |
| **Purpose** | Authenticates to GCP Artifact Registry for pushing function images (during build) and pulling them (during function deployment). |

This deployment uses **GKE Workload Identity** instead of stored credentials. No `docker-registry` secret is needed. Authentication is handled by binding a GCP service account (with `roles/artifactregistry.writer`) to the Kubernetes service accounts via IAM.

**Affected components:**

| Component | Namespace | What it does |
|-----------|-----------|-------------|
| Nuclio Dashboard | `aib-system` | Pushes built function container images to GCP Artifact Registry |
| MLRun API | `aib-system` | Configures Nuclio builds with registry URL when deploying serving functions |
| Nuclio Function Pods | `aib-serving` | Pulls function container images from GCP Artifact Registry at runtime |

**Setup:**

See `INSTALL.md` step 3 for the full Workload Identity configuration (GCP SA creation, IAM bindings, K8s SA annotations).

**values.yaml configuration:**

```yaml
global:
  registry:
    url: "us-central1-docker.pkg.dev/your-gcp-project/mlrun-functions"
    secretName: ""     # empty = Workload Identity, no secret
```

**Verify:**

```bash
# Check Workload Identity annotation on Nuclio SA
kubectl get serviceaccount nuclio -n aib-system \
  -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
# Expected: mlrun-registry@<project-id>.iam.gserviceaccount.com

# Check default SA in aib-serving
kubectl get serviceaccount default -n aib-serving \
  -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
# Expected: mlrun-registry@<project-id>.iam.gserviceaccount.com
```

---

### 4. `mysql-secret` (auto-generated by chart)

| | |
|---|---|
| **Namespace** | `aib-system` |
| **Type** | `Opaque` |
| **Purpose** | Credentials for the Kubeflow Pipelines MySQL database (internal to the chart). |
| **Required keys** | `username`, `password` |
| **Created by** | The Helm chart automatically (from `pipelines.db.username` value) |

> **You do NOT create this secret manually.** It is listed here for completeness. The chart template `pipelines/secrets/mysql-secret.yaml` creates it automatically with the username from `pipelines.db.username` and an empty password.

**Consumed by:**

| Component | How | What it does with it |
|-----------|-----|---------------------|
| Pipelines API Server (`ml-pipeline`) | `secretKeyRef` in deployment env vars (`DBCONFIG_MYSQLCONFIG_USER`, `DBCONFIG_MYSQLCONFIG_PASSWORD`) | Connects to the Pipelines MySQL database |
| Metadata gRPC Server (`metadata-grpc-deployment`) | `secretKeyRef` in deployment env vars (`DBCONFIG_USER`, `DBCONFIG_PASSWORD`) | Connects to the MLMD MySQL database |

---

### 5. `mlrun-db` (auto-generated by mlrun subchart)

| | |
|---|---|
| **Namespace** | `aib-system` |
| **Type** | `Opaque` |
| **Purpose** | MySQL connection DSN for the MLRun metadata database. |
| **Required keys** | `dsn`, `oldDsn` |
| **Created by** | The mlrun subchart automatically (from `mlrun.httpDB.dsn` and `mlrun.httpDB.oldDsn` values) |

> **You do NOT create this secret manually.** The mlrun subchart creates it from the DSN values in `values.yaml`.

**Consumed by:**

| Component | How | What it does with it |
|-----------|-----|---------------------|
| MLRun API Chief (`mlrun-api-chief`) | `secretKeyRef` in deployment env vars (`MLRUN_HTTPDB__DSN`, `MLRUN_HTTPDB__OLD_DSN`) | Connects to the MLRun MySQL database for storing project metadata, run history, artifacts |
| MLRun API Worker (`mlrun-api-worker`) | Same as above | Same as above |

---

## Summary Table

| Secret Name | Namespace | Create Manually? | Keys | Used By |
|-------------|-----------|-----------------|------|---------|
| `minio-credentials` | `aib-system` | **Yes** | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | MLRun API, Jupyter, Job Pods |
| `mlpipeline-minio-artifact` | `aib-system` | **Yes** | `accesskey`, `secretkey` | Pipelines API, Pipelines UI, Argo, Viewer Pods |
| GCP Artifact Registry | N/A | No (Workload Identity) | N/A | Nuclio Dashboard, MLRun API, Function Pods |
| `mysql-secret` | `aib-system` | No (auto) | `username`, `password` | Pipelines API, Metadata gRPC |
| `mlrun-db` | `aib-system` | No (auto) | `dsn`, `oldDsn` | MLRun API |

---

## Rotating Secrets

To rotate MinIO credentials:

```bash
# 1. Update MinIO deployment in aib-data with new credentials

# 2. Update the secrets in aib-system
kubectl create secret generic minio-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=<new-user> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<new-password> \
  --namespace aib-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic mlpipeline-minio-artifact \
  --from-literal=accesskey=<new-user> \
  --from-literal=secretkey=<new-password> \
  --namespace aib-system \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart all affected deployments to pick up new credentials
kubectl rollout restart deployment/mlrun-api-chief -n aib-system
kubectl rollout restart deployment/mlrun-api-worker -n aib-system
kubectl rollout restart deployment/mlrun-jupyter -n aib-system
kubectl rollout restart deployment/ml-pipeline -n aib-system
kubectl rollout restart deployment/ml-pipeline-ui -n aib-system
kubectl rollout restart deployment/workflow-controller -n aib-system
```

To rotate GCP Artifact Registry access (Workload Identity):

```bash
# No secret rotation needed. To change the GCP service account:

# 1. Create a new GCP SA and grant it artifactregistry.writer
# 2. Update the Workload Identity bindings
# 3. Re-annotate the Kubernetes service accounts
kubectl annotate serviceaccount nuclio \
  --namespace aib-system --overwrite \
  iam.gke.io/gcp-service-account=<new-sa>@<project>.iam.gserviceaccount.com

kubectl annotate serviceaccount default \
  --namespace aib-serving --overwrite \
  iam.gke.io/gcp-service-account=<new-sa>@<project>.iam.gserviceaccount.com

# 4. Restart Nuclio to pick up the new identity
kubectl rollout restart deployment/nuclio-dashboard -n aib-system
```
