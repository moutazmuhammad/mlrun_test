# AIB Platform — Istio Mesh Configuration

Umbrella Helm chart that manages all Istio mesh configuration for the AIB cloud platform. It provides a single, centralized place to control how services communicate (security), how traffic enters the cluster (networking), and how services reach external APIs (egress).

---

## Table of Contents

- [Network Topology](#network-topology)
- [Chart Structure](#chart-structure)
- [How It Works](#how-it-works)
- [1. mesh-security](#1-mesh-security)
  - [1.1 PeerAuthentication (mTLS)](#11-peerauthentication-mtls)
  - [1.2 AuthorizationPolicy](#12-authorizationpolicy)
  - [1.3 RequestAuthentication (JWT)](#13-requestauthentication-jwt)
- [2. mesh-networking](#2-mesh-networking)
  - [2.1 Domain](#21-domain)
  - [2.2 Gateway](#22-gateway)
  - [2.3 Services (VirtualService)](#23-services-virtualservice)
  - [2.4 DestinationRule (Traffic Policy)](#24-destinationrule-traffic-policy)
- [3. mesh-egress](#3-mesh-egress)
  - [3.1 ServiceEntry](#31-serviceentry)
  - [3.2 Egress Gateway Routing](#32-egress-gateway-routing)
- [Installation](#installation)
- [Environment Overrides](#environment-overrides)
- [Full Values Reference](#full-values-reference)

---

# Network Topology

```
Customer-managed ELB (external)
        │
        ▼
┌──────────────────┐
│  Istio Ingress   │  ClusterIP — no cloud LB provisioned by the platform
│  Gateway (pod)   │
└────────┬─────────┘
         │  mesh-networking: Gateway + VirtualService
         ▼
┌──────────────────┐
│  Platform        │  argocd, mlrun, mlflow, kubeflow, minio, etc.
│  Services        │
└────────┬─────────┘
         │  mesh-egress: ServiceEntry + optional egress gateway
         ▼
┌──────────────────┐
│  External APIs   │  api.openai.com, huggingface.co, etc.
└──────────────────┘
```

### Detailed Explanation

This topology shows how external user traffic travels through the platform:

1. **External Load Balancer**
   - Managed by the customer (AWS ELB/NLB, GCP LB, Azure LB, F5, etc.).
   - Routes external internet traffic into the Kubernetes cluster.

2. **Istio Ingress Gateway**
   - Acts as the entry point into the service mesh.
   - Implemented as an Envoy proxy pod managed by Istio.
   - Receives traffic from the external load balancer.

3. **Platform Services**
   - Internal services running in Kubernetes namespaces.
   - Examples include ArgoCD, MLRun, MLflow, Kubeflow, and MinIO.

4. **External APIs**
   - External services accessed by platform workloads.
   - Examples include OpenAI APIs or HuggingFace model endpoints.

Traffic entering the cluster is controlled by **mesh-networking**, while outbound traffic to external APIs is controlled by **mesh-egress**.

---

# Chart Structure

```
aib-platform/
├── Chart.yaml
├── values.yaml
├── mesh-security/
├── mesh-networking/
└── mesh-egress/
```

### Detailed Explanation

The chart follows the **Helm Umbrella Chart pattern**.

An umbrella chart is a parent chart that installs multiple subcharts together.

This structure allows the platform to separate responsibilities into three logical areas:

| Subchart | Responsibility |
|--------|--------|
| mesh-security | Service-to-service security inside the mesh |
| mesh-networking | Ingress traffic routing |
| mesh-egress | External service access |

Each subchart has its own:

- `values.yaml`
- `templates/`
- Helm resources

The umbrella chart coordinates configuration across all of them.

---

# How It Works

### Detailed Explanation

The Helm chart relies heavily on **values-driven configuration**.

Key ideas:

**1. Templates are static**

Developers should **never modify the templates**.  
Templates use Helm loops (`range`) and conditionals to generate resources dynamically.

**2. Values drive everything**

All configuration happens through `values.yaml`.

Example:

```yaml
mesh-security:
  meshSecurity:
    mtls:
      mode: STRICT
```

This automatically generates the required Istio resources.

**3. Environment-specific configuration**

Each environment (dev, staging, prod) has its own values file.

Example:

```
values/dev/aib-platform-values.yaml
values/prod/aib-platform-values.yaml
```

This allows the same chart to be deployed to multiple environments.

---

# 1. mesh-security

**What it does:** Controls how services authenticate and authorize each other inside the mesh.

### Detailed Explanation

In Kubernetes without a service mesh, services communicate freely using plaintext HTTP/TCP.

This means:

- Any pod can call any other pod
- Traffic may not be encrypted
- No built-in identity verification

The `mesh-security` chart introduces security controls using **Istio security policies**.

It provides three main capabilities:

| Capability | Resource |
|---|---|
| Encrypted service communication | PeerAuthentication |
| Service-to-service access control | AuthorizationPolicy |
| JWT authentication | RequestAuthentication |

---

## 1.1 PeerAuthentication (mTLS)

### Detailed Explanation

PeerAuthentication enforces **mutual TLS (mTLS)** inside the mesh.

With mTLS:

- Every service gets a certificate issued by Istio
- Both sides authenticate each other
- Traffic is encrypted automatically

Modes:

| Mode | Behavior |
|---|---|
| STRICT | Only encrypted connections allowed |
| PERMISSIVE | Accept both encrypted and plaintext |
| DISABLE | Disable mTLS |

STRICT is recommended for production environments.

Benefits:

- Prevents eavesdropping
- Ensures service identity verification
- Protects internal service traffic

---

## 1.2 AuthorizationPolicy

### Detailed Explanation

AuthorizationPolicy controls **who is allowed to call a service**.

Without this policy:

- Any authenticated service can call any other service.

AuthorizationPolicy allows rules like:

- Only specific namespaces can call a service
- Only specific service accounts can access an API
- Only certain HTTP methods or paths are allowed

Example rule:

```
Only kubeflow pipelines can call the MLRun API.
```

This provides **fine-grained zero-trust access control** within the cluster.

---

## 1.3 RequestAuthentication (JWT)

### Detailed Explanation

RequestAuthentication validates **JSON Web Tokens (JWT)**.

Many modern platforms rely on external identity providers such as:

- Auth0
- Keycloak
- Google Identity
- Azure AD

When a request reaches the service mesh:

1. Istio checks the JWT token
2. Validates the signature using the JWKS endpoint
3. Rejects invalid tokens
4. Forwards valid requests to the application

Benefits:

- Offloads authentication from the application
- Centralized security enforcement
- Prevents invalid requests from reaching services

---

# 2. mesh-networking

### Detailed Explanation

The mesh-networking chart defines how traffic **enters the cluster**.

It generates three important Istio resources:

| Resource | Purpose |
|---|---|
| Gateway | Entry point into the mesh |
| VirtualService | Routing rules |
| DestinationRule | Traffic policies |

Together they define **how external traffic reaches services**.

---

## 2.1 Domain

### Detailed Explanation

The domain value defines the **base domain for the entire platform**.

Instead of manually configuring hosts for every service, the platform generates them automatically.

Example:

```
domain: aib.vodafone.com
```

Then services become:

```
argocd.aib.vodafone.com
mlrun.aib.vodafone.com
mlflow.aib.vodafone.com
```

This simplifies environment configuration.

---

## 2.2 Gateway

### Detailed Explanation

The Istio Gateway configures the ingress proxy.

Think of it as similar to:

- NGINX Ingress
- Traefik
- HAProxy

But integrated with the service mesh.

It defines:

- Which ports to listen on
- Which hosts are accepted
- Optional TLS termination

Without a Gateway resource, the ingress proxy will not accept traffic.

---

## 2.3 Services (VirtualService)

### Detailed Explanation

VirtualServices define **routing logic**.

They answer questions such as:

- Which host maps to which service?
- Should requests be retried?
- Should traffic be split between versions?

Example routing rule:

```
mlrun.aib.vodafone.com → mlrun-api service
```

Advanced features include:

- Path-based routing
- Header-based routing
- Request retries
- Timeout configuration

This allows sophisticated traffic management.

---

## 2.4 DestinationRule (Traffic Policy)

### Detailed Explanation

DestinationRules define **how traffic behaves once routed**.

Common settings include:

| Feature | Purpose |
|---|---|
| Load balancing | Distribute traffic across pods |
| Connection pools | Limit concurrent connections |
| Outlier detection | Remove unhealthy instances |
| TLS mode | Configure secure upstream communication |

This improves reliability and resilience for production workloads.

---

# 3. mesh-egress

### Detailed Explanation

mesh-egress controls **outbound traffic** from services to the internet.

Without explicit configuration:

- External traffic may not be observable
- Security policies cannot be applied
- In strict environments it may be blocked

This chart registers external services so the mesh can manage them.

---

## 3.1 ServiceEntry

### Detailed Explanation

ServiceEntry registers external hosts inside the mesh.

Example:

```
api.openai.com
```

Once registered:

- Istio can route traffic to the host
- Metrics and tracing become available
- Traffic policies can be applied

This effectively makes external services **first-class citizens in the mesh**.

---

## 3.2 Egress Gateway Routing

### Detailed Explanation

Normally, traffic leaves the mesh directly from the application sidecar.

With an **egress gateway**, traffic is routed through a dedicated gateway pod.

Benefits:

- Centralized monitoring
- Security auditing
- Network policy enforcement
- Compliance with enterprise security requirements

Flow with egress gateway:

```
Application Pod
      │
      ▼
Sidecar Proxy
      │
      ▼
Egress Gateway
      │
      ▼
External API
```

This provides a single controlled exit point for external communication.

