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

### 3. Container Registry Authentication (Cloud-Agnostic)

| | |
|---|---|
| **Namespace** | Depends on chosen approach (see below) |
| **Purpose** | Authenticates to the container registry for pushing function images (Nuclio Dashboard) and pulling them (function pods) |

The chart supports multiple authentication methods across clouds. Choose one:

#### Option A: Cloud-Native Identity (recommended - no secret required)

For managed Kubernetes services, use the native workload identity feature. **No `Secret` resource is created.** Authentication is handled via service account annotations and IAM.

| Cloud | Mechanism | SA Annotation |
|-------|-----------|---------------|
| **GCP / GKE** | Workload Identity | `iam.gke.io/gcp-service-account=<sa>@<project>.iam.gserviceaccount.com` |
| **AWS / EKS** | IRSA | `eks.amazonaws.com/role-arn=arn:aws:iam::<account>:role/<role>` |
| **Azure / AKS** | Azure AD Workload Identity | `azure.workload.identity/client-id=<client-id>` + label `azure.workload.identity/use=true` |
| **OpenShift** | Built-in SA tokens | None (automatic) |

The SAs that need the annotation:
- `nuclio` in `aib-system` (needs push)
- `default` in `aib-serving` (needs pull)

See `INSTALL.md` step 3 for the full cloud-specific configuration (3.A GCP, 3.B AWS, 3.C Azure, 3.D OpenShift).

**values.yaml configuration:**

```yaml
global:
  registry:
    url: "<cloud-specific-registry-url>"
    secretName: ""     # empty = use native identity
```

#### Option B: Pull Secret (fallback for any registry)

For clusters without workload identity (on-prem, generic Kubernetes) or when using external registries like Docker Hub, GHCR, or Harbor.

| | |
|---|---|
| **Namespace** | `aib-system` **AND** `aib-serving` (both required) |
| **Type** | `kubernetes.io/dockerconfigjson` |
| **Required keys** | `.dockerconfigjson` (auto-created by `kubectl create secret docker-registry`) |

**Create:**

```bash
for NS in aib-system aib-serving; do
  kubectl create secret docker-registry registry-credentials \
    --docker-server=<registry-url> \
    --docker-username=<user> \
    --docker-password=<password> \
    --namespace "${NS}"
done
```

**values.yaml configuration:**

```yaml
global:
  registry:
    url: "<registry-url>/mlrun-functions"
    secretName: "registry-credentials"
```

**Components that use the registry credentials:**

| Component | Namespace | What it does with it |
|-----------|-----------|---------------------|
| Nuclio Dashboard | `aib-system` | Pushes built function container images to the registry |
| MLRun API | `aib-system` | Configures Nuclio builds with the registry URL when deploying serving functions |
| Nuclio Function Pods | `aib-serving` | Pulls function container images from the registry at runtime |

**Verify the setup:**

```bash
# Check the K8s SA has the expected annotation or imagePullSecret
kubectl get serviceaccount nuclio -n aib-system -o yaml

# After Helm install, check that a test push works by watching Nuclio build logs
kubectl logs -n aib-system deploy/nuclio-dashboard -f
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
| Registry credentials | `aib-system` + `aib-serving` | **Depends** - Yes (pull secret) or No (cloud-native identity: GKE WI / IRSA / Azure WI / OpenShift) | `.dockerconfigjson` (if pull secret) | Nuclio Dashboard, MLRun API, Function Pods |
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

To rotate registry credentials:

**Cloud-native identity (GCP/AWS/Azure/OpenShift):** No secret to rotate. Rotate at the cloud IAM level (rotate the underlying service account/IAM role key, update federated credentials, etc.), then restart Nuclio:

```bash
kubectl rollout restart deployment/nuclio-dashboard -n aib-system
```

**Pull secret (fallback):**

```bash
# 1. Update the secret in both namespaces
for NS in aib-system aib-serving; do
  kubectl create secret docker-registry registry-credentials \
    --docker-server=<registry-url> \
    --docker-username=<user> \
    --docker-password=<new-password> \
    --namespace "${NS}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# 2. Restart Nuclio to pick up new credentials
kubectl rollout restart deployment/nuclio-dashboard -n aib-system
```
