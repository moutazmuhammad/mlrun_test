# MLRun CE - Production Deployment

## Overview

MLRun CE (Community Edition) is an umbrella Helm chart that deploys a complete MLOps platform on Kubernetes. This production configuration splits the deployment across multiple namespaces:

| Namespace | Components |
|-----------|------------|
| `aib-system` | MLRun, Nuclio, Jupyter, Kubeflow Pipelines, Spark Operator, MPI Operator |
| `aib-data` | MinIO, Kafka (installed from separate charts) |
| `aib-serving` | Nuclio serverless functions (runtime only) |

All services use **ClusterIP** (no NodePort, no LoadBalancer). Access is expected through an ingress controller or port-forwarding.

---

## Components

### MLRun (namespace: aib-system)

The core ML orchestration engine. Manages the full ML lifecycle: data ingestion, model training, serving, and monitoring.

| Sub-component | Purpose | Internal Endpoint |
|---------------|---------|-------------------|
| **MLRun API** (`mlrun-api`) | REST API server. Central control plane that manages projects, runs, artifacts, and schedules. | `mlrun-api:8080` |
| **MLRun API Chief** (`mlrun-api-chief`) | Leader instance for distributed API operations (migrations, scheduling). | `mlrun-api-chief:8080` |
| **MLRun UI** (`mlrun-ui`) | Web dashboard for managing projects, viewing runs, browsing artifacts, and monitoring models. | `mlrun-ui:80` |
| **MLRun DB** (`mlrun-db`) | MySQL database storing project metadata, run history, artifact records, and model monitoring data. | `mlrun-db:3306` |

**Key connections:**
- MLRun API reads/writes metadata to MLRun DB via `mysql+pymysql://root@mlrun-db:3306/mlrun`
- MLRun API stores artifacts in MinIO (aib-data) at `s3://mlrun/`
- MLRun API registers Nuclio as a follower for project synchronization
- MLRun UI talks to MLRun API for all data
- MLRun API submits pipelines to Kubeflow Pipelines API at `http://ml-pipeline:8888`

---

### Nuclio (namespace: aib-system, functions in aib-serving)

Serverless function framework for deploying real-time ML serving functions, data processing, and event-driven workloads.

| Sub-component | Purpose | Internal Endpoint |
|---------------|---------|-------------------|
| **Controller** | Watches Nuclio Function CRDs and manages function lifecycle (deploy, scale, delete). | - |
| **Dashboard** | API and UI for managing serverless functions. Used by MLRun to deploy serving functions. | `nuclio:8070` |

**Key connections:**
- Nuclio Dashboard is configured as a follower of MLRun for project sync (`projectsLeader.kind: mlrun`)
- Nuclio Controller syncs with MLRun API at `http://mlrun-api-chief:8080/api`
- Functions are deployed into the `aib-serving` namespace (`functionNamespace: aib-serving`)
- Uses Kaniko for in-cluster container image builds
- RBAC is set to `namespaced` mode (does not watch all namespaces)

---

### Jupyter Notebook (namespace: aib-system)

Interactive development environment pre-configured with the MLRun SDK, providing a ready-to-use workspace for building and testing ML pipelines.

| Sub-component | Purpose | Internal Endpoint |
|---------------|---------|-------------------|
| **Jupyter** (`mlrun-jupyter`) | JupyterLab server with MLRun SDK pre-installed. | `mlrun-jupyter:8888` |

**Key connections:**
- Connects to MLRun API at `http://mlrun-api:8080` (via `MLRUN_DBPATH` env var)
- Links to MLRun UI at `http://mlrun-ui:80/mlrun` (via `MLRUN_UI_URL`)
- Reads/writes data to MinIO (aib-data) using S3-compatible credentials from `jupyter-common-env` configmap
- Has its own PVC (`8Gi`) mounted at `/home/jovyan/` for notebook persistence

---

### Kubeflow Pipelines (namespace: aib-system)

Workflow orchestration engine for defining, scheduling, and running multi-step ML pipelines using Argo Workflows.

| Sub-component | Purpose | Internal Endpoint |
|---------------|---------|-------------------|
| **API Server** (`ml-pipeline`) | REST/gRPC API for creating, listing, and managing pipeline runs. | `ml-pipeline:8888` (HTTP), `ml-pipeline:8887` (gRPC) |
| **UI** (`ml-pipeline-ui`) | Web interface for visualizing pipelines, viewing run graphs, comparing experiments, and browsing artifacts. | `ml-pipeline-ui:80` |
| **Workflow Controller** | Argo Workflows controller that executes pipeline DAGs as Kubernetes pods. | - |
| **Scheduled Workflow** | Manages cron-based recurring pipeline runs. | - |
| **Persistence Agent** | Syncs workflow status from Argo back to the Pipelines API for tracking. | - |
| **Metadata gRPC Server** | ML Metadata (MLMD) store for tracking pipeline lineage (inputs, outputs, executions). | `metadata-grpc-service:8080` |
| **Metadata Envoy** | gRPC proxy in front of the Metadata server. | `metadata-envoy-service:9090` |
| **Metadata Writer** | Watches completed workflows and writes lineage information to the MLMD store. | - |
| **Viewer CRD Controller** | Manages TensorBoard and other viewer CRDs for pipeline output visualization. | - |
| **Visualization Server** | Renders pipeline output visualizations (HTML, ROC curves, confusion matrices). | `ml-pipeline-visualizationserver:8888` |
| **Pipeline MySQL** (`mysql`) | Dedicated MySQL instance for pipelines metadata, MLMD, and cache databases. | `mysql:3306` |

**Key connections:**
- API Server stores pipeline definitions and artifacts in MinIO (aib-data) via `pipeline-install-config` configmap
- API Server reads/writes to its own MySQL instance (separate from MLRun DB)
- Workflow Controller stores Argo workflow logs/artifacts in MinIO using S3 protocol
- MLRun API submits pipelines to `ml-pipeline:8888` (configured via `mlrun-pipelines-config` configmap)
- UI fetches artifacts directly from MinIO for display

---

### Spark Operator (namespace: aib-system)

Manages Apache Spark applications on Kubernetes. Used by MLRun for distributed data processing and training jobs.

| Sub-component | Purpose |
|---------------|---------|
| **Controller** | Watches SparkApplication CRDs and manages Spark driver/executor pod lifecycle. |
| **Webhook** | Admission webhook for mutating Spark pods (e.g., injecting volumes, tolerations). |

**Key connections:**
- Spark jobs run in the `aib-system` namespace (`jobNamespaces: [aib-system]`)
- MLRun submits SparkApplication CRDs when users request Spark runtime jobs
- Uses the `sparkapp` service account for Spark pods

---

### MPI Operator (namespace: aib-system)

Manages distributed training jobs using the MPI (Message Passing Interface) protocol. Used for multi-node training with frameworks like Horovod.

| Sub-component | Purpose |
|---------------|---------|
| **Controller** | Watches MPIJob CRDs and orchestrates launcher/worker pods for distributed training. |

**Key connections:**
- MLRun submits MPIJob CRDs for distributed training workloads
- Creates launcher and worker pods within the namespace

---

### MinIO (namespace: aib-data - installed separately)

S3-compatible object storage. Central data store for all binary artifacts across the platform.

**What depends on MinIO:**
- **MLRun API** - stores run artifacts, feature store data, model files, and model monitoring data
- **Jupyter** - reads/writes data files and notebooks output
- **Kubeflow Pipelines API** - stores pipeline definitions and run artifacts
- **Argo Workflow Controller** - archives workflow logs
- **Pipelines UI** - fetches artifacts for display

**Cross-namespace access:**
The `_helpers.tpl` template uses `minio.externalHost` to resolve the MinIO endpoint dynamically. When set to `minio.aib-data.svc.cluster.local`, all components reach MinIO across namespaces without needing an ExternalName Service.

**Credentials:**
MinIO credentials (`rootUser`/`rootPassword`) must match between this chart's values and the actual MinIO deployment in `aib-data`. They are propagated to:
- `mlrun-common-env` configmap (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- `jupyter-common-env` configmap
- `mlpipeline-minio-artifact` secret
- `workflow-controller-configmap` (Argo artifact repository)

---

### Kafka (namespace: aib-data - installed separately)

Event streaming platform. Used by MLRun for real-time model monitoring and stream processing.

**What depends on Kafka:**
- **MLRun model monitoring** - streams prediction data and drift metrics

---

## Architecture Diagram

```
aib-system namespace
+-----------------------------------------------------------------------+
|                                                                       |
|  +-------------+    submits     +-------------------+                 |
|  | Jupyter     |--------------->| MLRun API         |                 |
|  | (Lab + SDK) |    REST API    | (mlrun-api:8080)  |                 |
|  +-------------+                +--------+----------+                 |
|        |                           |     |     |                      |
|        |                     +-----+   +-+   +-+------+               |
|        |                     |         |             |                |
|        |              +------v--+  +---v-------+  +--v-----------+    |
|        |              | MLRun DB|  | Nuclio    |  | KFP API      |    |
|        |              | (MySQL) |  | Dashboard |  | (ml-pipeline)|    |
|        |              +---------+  +-----+-----+  +------+-------+    |
|        |                                |                |            |
|        |              deploys functions |                |            |
|        |              to aib-serving    |    +-----------v---------+  |
|        |                                |    | Argo Workflow        | |
|        |                                |    | Controller           | |
|        |                                |    +-----+---------------+  |
|        |                                |          |                  |
|  +-----v-------+   +--------+  +------v-----+      |                  |
|  | MLRun UI    |   | Spark  |  | MPI        |      |                  |
|  | Dashboard   |   | Operator| | Operator   |      |                  |
|  +-------------+   +--------+  +------------+      |                  |
|                                                    |                  |
|  +------------------------------------------------v-+                 |
|  | Kubeflow Pipelines UI (ml-pipeline-ui:80)        |                 |
|  +--------------------------------------------------+                 |
|                                                                       |
+-----------------------------------------------------------------------+

aib-data namespace                     aib-serving namespace
+----------------------------+         +---------------------------+
|                            |         |                           |
|  +---------+  +---------+  |         |  +---------------------+  |
|  | MinIO   |  | Kafka   |  |  <---   |  | Nuclio Functions    |  |
|  | (:9000) |  | (:9092) |  |  S3/    |  | (serving, ETL, etc) |  |
|  +---------+  +---------+  |  events |  +---------------------+  |
|                            |         |                           |
+----------------------------+         +---------------------------+
        ^
        | S3 protocol
        |
   All components in aib-system
   (MLRun, Jupyter, Pipelines, Argo)
```

---

## Installation

### Prerequisites

1. Kubernetes cluster (any provider)
2. Helm 3.x
3. Namespaces created:
   ```bash
   kubectl create namespace aib-system
   kubectl create namespace aib-data
   kubectl create namespace aib-serving
   ```
4. MinIO and Kafka already deployed in `aib-data`

### Deploy MLRun CE

```bash
helm install mlrun-ce ./mlrun-ce \
  --namespace aib-system \
  -f mlrun-ce-production/values.yaml
```

### Verify

```bash
# Check all pods are running
kubectl get pods -n aib-system

# Check services are ClusterIP
kubectl get svc -n aib-system
```

### Access Services (via port-forward)

Since all services are ClusterIP, use `kubectl port-forward` for local access:

```bash
# Jupyter Notebook
kubectl port-forward svc/mlrun-jupyter 8888:8888 -n aib-system

# MLRun UI
kubectl port-forward svc/mlrun-ui 8060:80 -n aib-system

# MLRun API
kubectl port-forward svc/mlrun-api 8080:8080 -n aib-system

# Kubeflow Pipelines UI
kubectl port-forward svc/ml-pipeline-ui 8081:80 -n aib-system

# Nuclio Dashboard
kubectl port-forward svc/nuclio 8070:8070 -n aib-system
```

For production access, configure an Ingress controller (nginx, traefik, etc.) with appropriate rules for each service.

---

## Configuration

### Required TODOs

Before deploying, update these values in `values.yaml`:

| Value | Description |
|-------|-------------|
| `global.registry.url` | Container registry URL for function images |
| `minio.rootUser` / `minio.rootPassword` | Must match the MinIO deployment in aib-data |
| `pipelines.minio.accessKey` / `secretKey` | Must match the MinIO deployment in aib-data |
| `*.persistence.storageClass` | Set to your cluster's storage class |

### Cross-Namespace MinIO

The chart uses a dynamic MinIO host resolution via `minio.externalHost` in `_helpers.tpl`:

```yaml
minio:
  enabled: false
  externalHost: minio.aib-data.svc.cluster.local  # cross-namespace DNS
```

When `externalHost` is set, all components (MLRun, Jupyter, Pipelines, Argo) use this host. When unset, it falls back to `minio.<release-namespace>.svc.cluster.local`.

### Nuclio Cross-Namespace Functions

Nuclio controller runs in `aib-system` but deploys functions to `aib-serving`:

```yaml
nuclio:
  functionNamespace: aib-serving
```

Ensure the Nuclio service account has RBAC permissions to manage pods in `aib-serving`.

---

## Data Flow Summary

1. **User develops** in Jupyter, writes ML code using the MLRun SDK
2. **MLRun API** receives job submissions, stores metadata in MLRun DB (MySQL)
3. **Training jobs** run as Kubernetes pods (plain, Spark via Spark Operator, or distributed via MPI Operator)
4. **Artifacts** (models, datasets, logs) are stored in MinIO (aib-data) under `s3://mlrun/`
5. **Pipelines** are submitted to Kubeflow Pipelines, which runs them as Argo Workflows
6. **Serving functions** are deployed via Nuclio into `aib-serving` namespace
7. **Kafka** (aib-data) streams real-time prediction data for model monitoring
