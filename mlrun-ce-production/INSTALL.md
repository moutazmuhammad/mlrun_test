# MLRun CE - Production Installation Guide

This guide walks through the complete installation of the MLRun CE platform from scratch, including the data layer (MinIO, Kafka) in `aib-data` and the ML platform in `aib-system`.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Create Namespaces](#2-create-namespaces)
3. [Configure Container Registry](#3-configure-container-registry)
4. [Install MinIO in aib-data](#4-install-minio-in-aib-data)
5. [Install Kafka in aib-data](#5-install-kafka-in-aib-data)
6. [Update values.yaml with Your Configuration](#6-update-valuesyaml-with-your-configuration)
7. [Install MLRun CE in aib-system](#7-install-mlrun-ce-in-aib-system)
8. [Verify the Installation](#8-verify-the-installation)
9. [Access the Services](#9-access-the-services)
10. [Run a Smoke Test](#10-run-a-smoke-test)
11. [Upgrade and Uninstall](#11-upgrade-and-uninstall)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prerequisites

### Tools

| Tool | Minimum Version | Check Command |
|------|-----------------|---------------|
| kubectl | 1.24+ | `kubectl version --client` |
| Helm | 3.10+ | `helm version` |
| A running Kubernetes cluster | 1.24+ | `kubectl cluster-info` |

### Cluster Resources

Minimum recommended resources for a production deployment:

| Component | CPU (requests) | Memory (requests) | Storage |
|-----------|---------------|-------------------|---------|
| MLRun API | 250m | 512Mi | 8Gi PVC |
| MLRun DB (MySQL) | 250m | 512Mi | 8Gi PVC |
| MLRun UI | 100m | 128Mi | - |
| Jupyter | 500m | 1Gi | 8Gi PVC |
| Nuclio Controller | 100m | 128Mi | - |
| Nuclio Dashboard | 100m | 128Mi | - |
| KFP (all components) | ~800m | ~2Gi | 20Gi PVC |
| Spark Operator | 100m | 128Mi | - |
| MPI Operator | 100m | 128Mi | - |
| MinIO (aib-data) | 500m | 512Mi | configurable |
| Kafka (aib-data) | 500m | 1Gi | configurable |
| **Total (approx.)** | **~3.3 CPU** | **~6.2Gi** | **~44Gi+** |

### Storage

A StorageClass must be available for dynamic PVC provisioning. Check available classes:

```bash
kubectl get storageclass
```

Note the name of your default or preferred StorageClass - you will need it in step 6.

---

## 2. Create Namespaces

Create all three namespaces used by the platform:

```bash
# Data layer: MinIO and Kafka
kubectl create namespace aib-data

# ML platform: MLRun, Nuclio, Jupyter, Pipelines, Spark, MPI
kubectl create namespace aib-system

# Nuclio serverless functions runtime
kubectl create namespace aib-serving
```

Verify:

```bash
kubectl get namespaces | grep aib
```

Expected output:

```
aib-data      Active   ...
aib-serving   Active   ...
aib-system    Active   ...
```

---

## 3. Configure Container Registry (GCP Artifact Registry)

Nuclio needs a container registry to build and push function images. This guide uses **GCP Artifact Registry**.

### 3.1 Create a Docker Repository in Artifact Registry

If you haven't already, create a Docker repository in GCP:

```bash
# Set your variables
GCP_PROJECT="your-gcp-project-id"
GCP_REGION="us-central1"           # choose your region
REPO_NAME="mlrun-functions"

gcloud artifacts repositories create ${REPO_NAME} \
  --repository-format=docker \
  --location=${GCP_REGION} \
  --description="MLRun/Nuclio function images"
```

Your registry URL will be: `${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO_NAME}`

### 3.2 Set Up Workload Identity

Workload Identity lets Kubernetes service accounts authenticate to GCP services (like Artifact Registry) via IAM - no JSON keys, no stored credentials.

**Step 1** - Ensure Workload Identity is enabled on your GKE cluster:

```bash
# Check if already enabled
gcloud container clusters describe <CLUSTER_NAME> \
  --zone <ZONE> \
  --format="value(workloadIdentityConfig.workloadPool)"

# If empty, enable it (requires cluster update)
gcloud container clusters update <CLUSTER_NAME> \
  --zone <ZONE> \
  --workload-pool="${GCP_PROJECT}.svc.id.goog"
```

**Step 2** - Create a GCP service account:

```bash
GCP_SA_NAME="mlrun-registry"

gcloud iam service-accounts create ${GCP_SA_NAME} \
  --display-name="MLRun Artifact Registry access"
```

**Step 3** - Grant it Artifact Registry Writer role (push + pull):

```bash
gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
  --member="serviceAccount:${GCP_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"
```

**Step 4** - Bind the GCP SA to the Kubernetes service accounts that need registry access:

```bash
# Nuclio dashboard (builds and pushes images) - in aib-system
gcloud iam service-accounts add-iam-policy-binding \
  ${GCP_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[aib-system/nuclio]"

# Default SA in aib-serving (function pods pull images)
gcloud iam service-accounts add-iam-policy-binding \
  ${GCP_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[aib-serving/default]"
```

**Step 5** - Annotate the Kubernetes service accounts (after Helm install in step 7, or pre-create them):

```bash
# Nuclio SA in aib-system
kubectl annotate serviceaccount nuclio \
  --namespace aib-system \
  iam.gke.io/gcp-service-account=${GCP_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com

# Default SA in aib-serving
kubectl annotate serviceaccount default \
  --namespace aib-serving \
  iam.gke.io/gcp-service-account=${GCP_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com
```

> **Note:** The `nuclio` service account is created by the Helm chart. If annotating before install, pre-create it:
> ```bash
> kubectl create serviceaccount nuclio --namespace aib-system
> ```

**Step 6** - In `values.yaml`, the registry secret is already set to empty (Workload Identity needs no secret):

```yaml
global:
  registry:
    url: "us-central1-docker.pkg.dev/your-gcp-project/mlrun-functions"
    secretName: ""     # no secret needed with Workload Identity
```

### 3.3 Verify Workload Identity and Registry Access

```bash
# Verify Workload Identity is configured on the cluster
gcloud container clusters describe <CLUSTER_NAME> \
  --zone <ZONE> \
  --format="value(workloadIdentityConfig.workloadPool)"
# Expected: <project-id>.svc.id.goog

# Verify IAM binding exists
gcloud iam service-accounts get-iam-policy \
  ${GCP_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com \
  --format="table(bindings.role,bindings.members)"

# After Helm install, verify the SA annotation
kubectl get serviceaccount nuclio -n aib-system -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
# Expected: mlrun-registry@<project-id>.iam.gserviceaccount.com

# Test push from your machine (for validation)
gcloud auth configure-docker ${GCP_REGION}-docker.pkg.dev
docker pull busybox:latest
docker tag busybox:latest ${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO_NAME}/test:latest
docker push ${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO_NAME}/test:latest

# Clean up test image
gcloud artifacts docker images delete \
  ${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REPO_NAME}/test:latest --quiet
```

---

## 4. Install MinIO in aib-data

MinIO provides S3-compatible object storage for all ML artifacts.

### 4.1 Create MinIO Values File

Create a file called `minio-values.yaml`:

```yaml
# minio-values.yaml
fullnameOverride: minio

# Standalone mode for single-node production. Use "distributed" for HA.
mode: standalone
replicas: 1

# Root credentials - CHANGE THESE for production
# These must match the values in mlrun-ce-production/values.yaml
rootUser: minio
rootPassword: minio123

# Storage
persistence:
  enabled: true
  # storageClass: ""       # Set your StorageClass here
  size: 50Gi               # Adjust based on expected artifact volume

# Resource allocation
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi

# Services - ClusterIP only
service:
  type: ClusterIP
  port: 9000

consoleService:
  type: ClusterIP
  port: 9001

# Create the "mlrun" bucket automatically on startup
buckets:
  - name: mlrun
    policy: none
    purge: false
```

### 4.2 Install MinIO

```bash
helm install minio ./mlrun-ce/charts/minio \
  --namespace aib-data \
  -f minio-values.yaml
```

### 4.3 Verify MinIO

```bash
# Check pod is running
kubectl get pods -n aib-data -l app=minio

# Check service is reachable
kubectl get svc -n aib-data minio
```

Expected:

```
NAME    TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
minio   ClusterIP   10.x.x.x      <none>        9000/TCP   ...
```

### 4.4 Verify the Bucket Was Created

```bash
# Port-forward to MinIO
kubectl port-forward svc/minio 9000:9000 -n aib-data &

# Test with curl (should return XML with bucket listing)
curl -s http://localhost:9000/minio/health/live
# Expected: empty 200 OK response

# Stop port-forward
kill %1
```

### 4.5 Verify Cross-Namespace DNS

From any pod in `aib-system`, MinIO must be reachable at `minio.aib-data.svc.cluster.local:9000`. Test this:

```bash
kubectl run dns-test --rm -it --restart=Never \
  --namespace aib-system \
  --image=busybox:1.37 -- \
  nslookup minio.aib-data.svc.cluster.local
```

Expected: a DNS response with the MinIO ClusterIP.

---

## 5. Install Kafka in aib-data

Kafka provides event streaming for MLRun model monitoring.

### 5.1 Create Kafka Values File

Create a file called `kafka-values.yaml`:

```yaml
# kafka-values.yaml
global:
  security:
    allowInsecureImages: true

fullnameOverride: kafka-stream

image:
  repository: 'bitnamilegacy/kafka'

# Single-node for production start. Scale controller.replicaCount for HA.
controller:
  replicaCount: 1
  resourcesPreset: "medium"

# Replication settings - set to 1 for single-node, increase for HA
extraConfigYaml:
  default.replication.factor: "1"
  offsets.topic.replication.factor: "1"
  transaction.state.log.replication.factor: "1"
  transaction.state.log.min.isr: "1"

listeners:
  client:
    name: CLIENT
    containerPort: 9092
    protocol: PLAINTEXT
  controller:
    name: CONTROLLER
    containerPort: 9093
    protocol: PLAINTEXT
  interbroker:
    name: INTERNAL
    containerPort: 9094
    protocol: PLAINTEXT

advertisedListeners: >-
  CLIENT://kafka-stream.aib-data.svc.cluster.local:9092,
  CONTROLLER://kafka-stream-controller-headless.aib-data.svc.cluster.local:9093,
  INTERNAL://kafka-stream-controller-headless.aib-data.svc.cluster.local:9094,
```

### 5.2 Install Kafka

```bash
helm install kafka ./mlrun-ce/charts/kafka \
  --namespace aib-data \
  -f kafka-values.yaml
```

### 5.3 Verify Kafka

```bash
# Check pods
kubectl get pods -n aib-data -l app.kubernetes.io/name=kafka

# Check service
kubectl get svc -n aib-data | grep kafka
```

Wait until all Kafka pods are `Running` and `Ready`:

```bash
kubectl wait --for=condition=Ready pods \
  -l app.kubernetes.io/name=kafka \
  -n aib-data \
  --timeout=300s
```

---

## 6. Create Secrets and Update Configuration

No credentials are stored in `values.yaml`. All sensitive values are managed as Kubernetes Secrets created before the Helm install.

### 6.1 Create MinIO Credentials Secret

This secret provides S3 credentials to MLRun API, Jupyter, and job pods. The values must match your MinIO deployment from step 4.

```bash
# Replace with your actual MinIO credentials from step 4
kubectl create secret generic minio-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=minio \
  --from-literal=AWS_SECRET_ACCESS_KEY=minio123 \
  --namespace aib-system
```

### 6.2 Create Pipelines MinIO Artifact Secret

This secret provides MinIO credentials to Kubeflow Pipelines components (API server, UI, Argo). The key names are different from the MLRun secret because the Pipelines templates expect `accesskey`/`secretkey`.

```bash
# Same credentials, different key names
kubectl create secret generic mlpipeline-minio-artifact \
  --from-literal=accesskey=minio \
  --from-literal=secretkey=minio123 \
  --namespace aib-system
```

### 6.3 Verify Secrets

```bash
kubectl get secrets -n aib-system | grep -E "minio|mlpipeline"
```

Expected:

```
minio-credentials              Opaque   2   ...
mlpipeline-minio-artifact      Opaque   2   ...
```

### 6.4 Update Storage Class

Find all storage class fields and set them:

```bash
grep -n "storageClass:" mlrun-ce-production/values.yaml
```

Replace with your StorageClass, for example:

```yaml
storageClass: "gp3"            # AWS EBS
storageClass: "premium-rwo"    # GKE
storageClass: "managed-csi"    # AKS
storageClass: "local-path"     # k3s/Rancher
```

### 6.5 Update Registry URL

```bash
grep -n "TODO" mlrun-ce-production/values.yaml
```

| Value | What to Set |
|-------|-------------|
| `global.registry.url` | Your GCP Artifact Registry URL (e.g. `us-central1-docker.pkg.dev/my-project/mlrun-functions`) |
| `global.registry.secretName` | `"gcr-registry-credentials"` (JSON key) or `""` (Workload Identity) - see step 3 |
| All `storageClass` fields | Your cluster's StorageClass name |

---

## 7. Install MLRun CE in aib-system

### 7.1 Install the Chart

```bash
helm install mlrun-ce ./mlrun-ce \
  --namespace aib-system \
  -f mlrun-ce-production/values.yaml
```

### 7.2 Watch the Rollout

```bash
# Watch all pods come up
kubectl get pods -n aib-system -w
```

Wait for all pods to reach `Running` status. This typically takes 3-5 minutes. The expected pods are:

```
NAME                                             READY   STATUS
mlrun-api-chief-...                              2/2     Running
mlrun-api-worker-...                             2/2     Running
mlrun-db-...                                     1/1     Running
mlrun-ui-...                                     1/1     Running
mlrun-jupyter-...                                1/1     Running
nuclio-controller-...                            1/1     Running
nuclio-dashboard-...                             1/1     Running
spark-operator-controller-...                    1/1     Running
mpi-operator-...                                 1/1     Running
ml-pipeline-...                                  1/1     Running
ml-pipeline-ui-...                               1/1     Running
ml-pipeline-persistenceagent-...                 1/1     Running
ml-pipeline-scheduledworkflow-...                1/1     Running
ml-pipeline-viewer-crd-...                       1/1     Running
ml-pipeline-visualizationserver-...              1/1     Running
metadata-grpc-deployment-...                     1/1     Running
metadata-envoy-deployment-...                    1/1     Running
metadata-writer-...                              1/1     Running
mysql-...                                        1/1     Running
workflow-controller-...                          1/1     Running
```

### 7.3 Wait for All Deployments

```bash
kubectl wait --for=condition=Available deployments --all \
  -n aib-system \
  --timeout=600s
```

---

## 8. Verify the Installation

Run these checks to confirm everything is connected properly.

### 8.1 Check All Pods Are Running

```bash
echo "=== aib-data ==="
kubectl get pods -n aib-data

echo ""
echo "=== aib-system ==="
kubectl get pods -n aib-system

echo ""
echo "=== aib-serving ==="
kubectl get pods -n aib-serving
```

`aib-serving` will be empty until you deploy your first Nuclio function.

### 8.2 Check All Services Are ClusterIP

```bash
kubectl get svc -n aib-system -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,PORTS:.spec.ports[*].port
```

All services should show `TYPE: ClusterIP`. No NodePort or LoadBalancer should appear.

### 8.3 Verify MLRun API Can Reach MinIO

```bash
kubectl exec -n aib-system deploy/mlrun-api-chief -c mlrun-api -- \
  env | grep -E "AWS_|S3_|MLRUN_STORAGE"
```

Expected output should include:

```
AWS_ACCESS_KEY_ID=minio
AWS_SECRET_ACCESS_KEY=minio123
AWS_ENDPOINT_URL_S3=http://minio.aib-data.svc.cluster.local:9000
```

### 8.4 Verify MLRun API Can Reach Kubeflow Pipelines

```bash
kubectl exec -n aib-system deploy/mlrun-api-chief -c mlrun-api -- \
  env | grep KFP
```

Expected:

```
MLRUN_KFP_URL=http://ml-pipeline.aib-system.svc.cluster.local:8888
```

### 8.5 Verify MLRun API Health

```bash
kubectl exec -n aib-system deploy/mlrun-api-chief -c mlrun-api -- \
  wget -qO- http://localhost:8080/api/healthz
```

### 8.6 Verify Pipelines API Health

```bash
kubectl exec -n aib-system deploy/ml-pipeline -- \
  wget -qO- http://localhost:8888/apis/v1beta1/healthz
```

### 8.7 Verify Nuclio Dashboard Health

```bash
kubectl exec -n aib-system deploy/nuclio-dashboard -- \
  wget -qO- http://localhost:8070/api/healthz 2>/dev/null || echo "check manually"
```

---

## 9. Access the Services

All services use ClusterIP. Use `kubectl port-forward` for local access, or configure an Ingress controller for production access.

### 9.1 Port-Forward (Development / Quick Access)

Open each in a separate terminal:

```bash
# Jupyter Notebook - http://localhost:8888
kubectl port-forward svc/mlrun-jupyter 8888:8888 -n aib-system

# MLRun UI - http://localhost:8060
kubectl port-forward svc/mlrun-ui 8060:80 -n aib-system

# MLRun API - http://localhost:8080
kubectl port-forward svc/mlrun-api 8080:8080 -n aib-system

# Kubeflow Pipelines UI - http://localhost:8081
kubectl port-forward svc/ml-pipeline-ui 8081:80 -n aib-system

# Nuclio Dashboard - http://localhost:8070
kubectl port-forward svc/nuclio 8070:8070 -n aib-system

# MinIO Console (in aib-data) - http://localhost:9001
kubectl port-forward svc/minio-console 9001:9001 -n aib-data
```

### 9.2 Ingress (Production Access)

For production, deploy an ingress controller (e.g. nginx-ingress) and create Ingress resources. Example for nginx:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mlrun-ingress
  namespace: aib-system
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: jupyter.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mlrun-jupyter
                port:
                  number: 8888
    - host: mlrun.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mlrun-ui
                port:
                  number: 80
    - host: mlrun-api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mlrun-api
                port:
                  number: 8080
    - host: pipelines.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ml-pipeline-ui
                port:
                  number: 80
```

---

## 10. Run a Smoke Test

### 10.1 Open Jupyter

Port-forward Jupyter (step 9.1), then open http://localhost:8888 in your browser.

### 10.2 Create a Test Project

In a Jupyter notebook cell, run:

```python
import mlrun

# Create a new project
project = mlrun.get_or_create_project(
    name="smoke-test",
    context="./smoke-test"
)

print(f"Project: {project.name}")
print(f"Artifact path: {project.artifact_path}")
```

This verifies:
- Jupyter can reach the MLRun API
- MLRun API can reach the MySQL database
- The project is created successfully

### 10.3 Test Artifact Storage (MinIO)

```python
import mlrun

project = mlrun.get_or_create_project("smoke-test")

# Log a test artifact - this writes to MinIO
project.log_artifact(
    "test-artifact",
    body="hello from mlrun",
    local_path="test.txt"
)

print("Artifact stored successfully in MinIO")
```

This verifies:
- MLRun can write to MinIO in `aib-data` across namespaces

### 10.4 Test Kubeflow Pipelines

```python
import mlrun

project = mlrun.get_or_create_project("smoke-test")

# Define a simple function
@mlrun.handler()
def hello(context):
    context.logger.info("Hello from KFP pipeline!")
    return "success"

# Create a function from the handler
fn = project.set_function(
    func="./smoke_test_fn.py",
    name="hello-fn",
    kind="job",
    image="mlrun/mlrun"
)

# Run it
run = fn.run(name="smoke-test-run", local=False)
print(f"Run state: {run.status.state}")
```

This verifies:
- MLRun can submit jobs to Kubernetes
- Jobs can access MinIO for artifact storage

### 10.5 Test Nuclio Function Deployment

```python
import mlrun

project = mlrun.get_or_create_project("smoke-test")

# Create a simple serving function
serving_fn = mlrun.new_function(
    "test-serving",
    kind="serving",
    image="mlrun/mlrun"
)

# Check the function can be built (requires registry)
# serving_fn.deploy()
print("Nuclio function created successfully")
```

---

## 11. Upgrade and Uninstall

### Upgrade

After modifying `values.yaml`:

```bash
helm upgrade mlrun-ce ./mlrun-ce \
  --namespace aib-system \
  -f mlrun-ce-production/values.yaml
```

### Uninstall

Uninstall in reverse order:

```bash
# 1. Remove MLRun CE
helm uninstall mlrun-ce --namespace aib-system

# 2. Remove Kafka
helm uninstall kafka --namespace aib-data

# 3. Remove MinIO
helm uninstall minio --namespace aib-data
```

PVCs with `helm.sh/resource-policy: keep` will NOT be deleted automatically. To fully clean up:

```bash
# WARNING: This deletes all persistent data permanently
kubectl delete pvc --all -n aib-system
kubectl delete pvc --all -n aib-data

# Delete namespaces
kubectl delete namespace aib-system aib-data aib-serving
```

---

## 12. Troubleshooting

### Pod stuck in Pending

```bash
kubectl describe pod <pod-name> -n aib-system
```

Common causes:
- **Insufficient resources**: check node capacity with `kubectl top nodes`
- **No StorageClass**: ensure `storageClass` is set correctly in `values.yaml`
- **PVC not bound**: check `kubectl get pvc -n aib-system`

### MLRun API CrashLoopBackOff

```bash
kubectl logs deploy/mlrun-api-chief -c mlrun-api -n aib-system --tail=50
```

Common causes:
- **Cannot reach MySQL**: check `mlrun-db` pod is running
- **Cannot reach MinIO**: test cross-namespace DNS (step 4.5)

### Pipelines pods failing

```bash
kubectl logs deploy/ml-pipeline -n aib-system --tail=50
```

Common causes:
- **Pipeline MySQL not ready**: check `kubectl get pods -n aib-system | grep mysql`
- **MinIO unreachable**: check `pipeline-install-config` configmap has correct `minioServiceHost`

```bash
kubectl get configmap pipeline-install-config -n aib-system -o yaml | grep minio
```

Expected: `minioServiceHost: minio.aib-data.svc.cluster.local`

### Nuclio functions not deploying in aib-serving

```bash
kubectl logs deploy/nuclio-controller -n aib-system --tail=50
```

Common causes:
- **RBAC**: Nuclio needs permissions in `aib-serving`. Check if ClusterRole bindings exist:
  ```bash
  kubectl get clusterrolebinding | grep nuclio
  ```
- **Namespace doesn't exist**: ensure `aib-serving` was created (step 2)
- **Registry not configured**: check `global.registry.url` is set and the secret exists in `aib-serving`

### Cross-namespace connectivity issues

Test DNS resolution and network connectivity:

```bash
# Test MinIO DNS from aib-system
kubectl run test-dns --rm -it --restart=Never \
  --namespace aib-system \
  --image=busybox:1.37 -- \
  wget -qO- http://minio.aib-data.svc.cluster.local:9000/minio/health/live

# Test Kafka DNS from aib-system
kubectl run test-kafka --rm -it --restart=Never \
  --namespace aib-system \
  --image=busybox:1.37 -- \
  nslookup kafka-stream.aib-data.svc.cluster.local
```

If DNS fails, check:
- CoreDNS is running: `kubectl get pods -n kube-system -l k8s-app=kube-dns`
- No NetworkPolicies blocking cross-namespace traffic: `kubectl get networkpolicy -A`

### Check all configmaps have correct values

```bash
# MLRun env
kubectl get configmap mlrun-common-env -n aib-system -o yaml

# Jupyter env
kubectl get configmap jupyter-common-env -n aib-system -o yaml

# Pipeline config
kubectl get configmap pipeline-install-config -n aib-system -o yaml

# Workflow controller (Argo artifact repo config)
kubectl get configmap workflow-controller-configmap -n aib-system -o yaml
```

All MinIO references should point to `minio.aib-data.svc.cluster.local`.
