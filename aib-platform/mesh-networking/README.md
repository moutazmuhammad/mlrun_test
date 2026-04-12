# mesh-networking — Istio Ingress Routing & Traffic Management

## What Is This Chart?

When someone outside your cluster wants to reach one of your services (ArgoCD, MLflow, a model API, etc.), they send a request to your domain — say `model-api.aib.vodafone.com`. But how does that request actually find your pod running inside Kubernetes?

**mesh-networking** is the traffic controller. It does three things:

1. **Opens the front door** (Gateway) — Tells the Istio ingress gateway pod: "Listen on port 80 and accept traffic for `*.aib.vodafone.com`"
2. **Routes traffic to the right service** (VirtualService) — Says: "If the host is `model-api.aib.vodafone.com`, send it to the `model-api` service on port 8080"
3. **Controls how traffic behaves** (DestinationRule) — Says: "Use round-robin load balancing, limit to 100 connections, and eject any pod that returns 5 consecutive errors"

Plus advanced features: retry policies, timeouts, fault injection (for testing), CORS, traffic mirroring, and canary (weighted) routing.

---

## How Traffic Flows

```
User browser / API client
        │
        ▼
Customer's Load Balancer (ELB, NLB, F5, etc.)
        │
        ▼
┌──────────────────────────────┐
│  Istio Ingress Gateway Pod   │  ← Gateway tells it what to listen for
│  (Envoy proxy)               │
└──────────────┬───────────────┘
               │
               │  ← VirtualService tells it where to route
               ▼
┌──────────────────────────────┐
│  Your Service Pod            │  ← DestinationRule controls HOW
│  (e.g., model-api)          │     (load balancing, circuit breaking)
└──────────────────────────────┘
```

**Why ClusterIP?** The platform never creates cloud load balancers (`type: LoadBalancer`). Your organization provides its own external load balancer and points it at the ingress gateway pods. This makes the chart cloud-agnostic — same config works on AWS, GCP, Azure, or bare-metal.

---

## Chart Structure

```
mesh-networking/
├── Chart.yaml                        # Chart metadata (name, version)
├── values.yaml                       # All configurable options with defaults
├── README.md                         # This file
└── templates/
    ├── _helpers.tpl                  # Shared Helm template helpers (labels)
    ├── gateway.yaml                  # Generates one Gateway resource
    ├── virtualservices.yaml          # Generates one VirtualService per service
    └── destination-rules.yaml        # Generates one DestinationRule per service (if trafficPolicy is set)
```

**How templates work:** `gateway.yaml` generates a single resource. `virtualservices.yaml` and `destination-rules.yaml` use Helm `range` loops — one resource per entry in the `services` list. If `services` is empty, nothing is generated.

---

## Prerequisites

- Istio installed with an ingress gateway deployment
- A Gateway resource (this chart creates one, or you can use an existing one)
- Helm 3.x

---

## 1. Domain

### What Is It?

A single base domain that all your services share. Instead of hardcoding `argocd.aib.vodafone.com`, `mlflow.aib.vodafone.com`, etc. in every service, you set the domain once:

```yaml
meshNetworking:
  domain: "aib.vodafone.com"
```

Then each service only needs a `subdomain`:

| Service Name | Subdomain | Resulting Host |
|---|---|---|
| `argocd-server` | `argocd` | `argocd.aib.vodafone.com` |
| `model-api` | `model` | `model.aib.vodafone.com` |
| `mlflow-server` | `mlflow` | `mlflow.aib.vodafone.com` |

If you omit `subdomain`, the service `name` is used as the subdomain.

**Why this matters:** When you move from dev to production, you change one value (`domain`) instead of updating every service entry.

---

## 2. Gateway

### What Is a Gateway?

The Istio ingress gateway pod is just a naked Envoy proxy. By itself, it does nothing — it doesn't know what port to listen on or what hosts to accept. A **Gateway** resource is the configuration that tells it: "Listen on port 80 for any host matching `*.aib.vodafone.com`."

Think of it as the building's front door. Without it, nobody gets in.

### How To Use

```yaml
meshNetworking:
  gateway:
    enabled: true                  # Set false to skip (if you have your own Gateway)
    name: platform-gateway         # Name of the Gateway resource
    selector:                      # Which pods to configure
      istio: ingressgateway        # Matches the label on the ingress gateway pods
    port:
      number: 80                   # Listen port
      name: http                   # Port name (required by Istio)
      protocol: HTTP               # Protocol: HTTP, HTTPS, TCP, TLS
```

For HTTPS (TLS termination at the gateway):

```yaml
    port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE                 # One-way TLS (gateway has cert, client doesn't)
      credentialName: my-tls-secret  # K8s Secret with the TLS cert and key
```

### What Gets Generated

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: aib-platform
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.aib.vodafone.com"      # ← Wildcard from your domain
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `gateway.enabled` | bool | no | `true` | Whether to generate the Gateway |
| `gateway.name` | string | no | `platform-gateway` | Gateway resource name |
| `namespace` | string | yes | — | Namespace where all CRs are created (Gateway, VirtualService, DestinationRule) |
| `gateway.selector` | map | no | `istio: ingressgateway` | Labels matching the ingress gateway pods |
| `gateway.port.number` | int | yes | `80` | Listen port |
| `gateway.port.name` | string | yes | `http` | Port name |
| `gateway.port.protocol` | string | yes | `HTTP` | Protocol: `HTTP`, `HTTPS`, `TCP`, `TLS` |
| `gateway.tls.mode` | string | no | — | TLS mode: `SIMPLE` or `MUTUAL` |
| `gateway.tls.credentialName` | string | no | — | K8s Secret name with TLS cert/key |

---

## 3. Services (VirtualService)

### What Is a VirtualService?

The Gateway accepts traffic, but it doesn't know where to send it. A **VirtualService** is the routing table. It says:

- "If the host is `model.aib.vodafone.com` → send to `model-api` service on port 8080"
- "If the path starts with `/api` → only then route to this service"
- "If the request fails with a 5xx → retry up to 3 times"
- "If no response within 10 seconds → give up"

One VirtualService is created for each entry in the `services` list.

### Basic Usage

```yaml
meshNetworking:
  domain: "aib.vodafone.com"
  services:
    # Simplest possible — name, serviceNamespace, port
    - name: argocd-server
      subdomain: argocd
      serviceNamespace: argocd
      port: 80

    # With path-based routing
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      pathPrefix: /api            # Only route requests starting with /api

    # With retries and timeout
    - name: mlrun-api
      subdomain: mlrun
      serviceNamespace: mlrun
      port: 8080
      timeout: 10s                # Give up after 10 seconds total
      retries:
        attempts: 3               # Retry up to 3 times
        perTryTimeout: 2s         # Each attempt gets 2 seconds
        retryOn: 5xx              # Only retry on server errors
```

### Understanding Retries

```
Client request
    │
    ├──→ Attempt 1 ──→ 503 error (within 2s) ──→ retry
    │
    ├──→ Attempt 2 ──→ 503 error (within 2s) ──→ retry
    │
    ├──→ Attempt 3 ──→ 200 OK ──→ Return to client
    │
    └── If all 3 fail → Return the last error to client

    Total timeout: 10s (all attempts must complete within this)
```

Common `retryOn` values:

| Value | What It Means |
|---|---|
| `5xx` | Retry on any 5xx server error |
| `connect-failure` | Retry when connection to upstream fails |
| `reset` | Retry when connection is reset |
| `retriable-4xx` | Retry on 409 Conflict |
| `gateway-error` | Retry on 502, 503, 504 |
| `5xx,connect-failure,reset` | Combine multiple (comma-separated) |

### Header-Based Routing

Route based on request headers (useful for A/B testing or version routing):

```yaml
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      headers:
        x-api-version:
          exact: "v2"             # Only route if this header matches
```

### What Gets Generated

Simple service:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: argocd-server-vs
  namespace: aib-platform
spec:
  hosts:
    - "argocd.aib.vodafone.com"
  gateways:
    - aib-platform/platform-gateway
  http:
    - route:
        - destination:
            host: argocd-server.argocd.svc.cluster.local
            port:
              number: 80
```

Advanced service (path + retries + timeout):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mlrun-api-vs
  namespace: aib-platform
spec:
  hosts:
    - "mlrun.aib.vodafone.com"
  gateways:
    - aib-platform/platform-gateway
  http:
    - match:
        - uri:
            prefix: "/api"
      route:
        - destination:
            host: mlrun-api.mlrun.svc.cluster.local
            port:
              number: 8080
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx
      timeout: 10s
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | K8s Service name |
| `subdomain` | string | no | same as `name` | Subdomain for the host |
| `serviceNamespace` | string | no | `default` | Namespace where the K8s Service runs (used for destination FQDN) |
| `port` | int | yes | — | Service port number |
| `pathPrefix` | string | no | — | URI prefix match |
| `headers` | map | no | — | Header match conditions |
| `timeout` | string | no | — | Total request timeout (e.g., `10s`) |
| `retries.attempts` | int | no | `3` | Number of retry attempts |
| `retries.perTryTimeout` | string | no | `2s` | Timeout per attempt |
| `retries.retryOn` | string | no | — | When to retry (e.g., `5xx`) |

---

## 4. DestinationRule (Traffic Policy & Circuit Breaking)

### What Is a DestinationRule?

VirtualServices define **where** traffic goes. DestinationRules define **how** it gets there:

- **Load balancing** — How to pick which pod gets the request
- **Connection pooling** — How many connections and requests to allow
- **Circuit breaking** (outlier detection) — When to stop sending traffic to a failing pod

### Why Do You Need Circuit Breaking?

Imagine you have 5 pods serving `model-api`. One of them starts crashing and returning 500 errors. Without circuit breaking, Istio keeps sending 20% of traffic to the broken pod — those requests all fail.

With circuit breaking (outlier detection), Istio notices the failures and **ejects** the broken pod from the pool. Traffic only goes to the 4 healthy pods. After a cooldown period, the ejected pod gets a chance to prove it's healthy again.

```
Before circuit breaking:         After circuit breaking:
  ┌─── Pod 1 ✓                     ┌─── Pod 1 ✓
  ├─── Pod 2 ✓                     ├─── Pod 2 ✓
  ├─── Pod 3 ✗ (failing)           ├─── Pod 3 ✗ (ejected — no traffic)
  ├─── Pod 4 ✓                     ├─── Pod 4 ✓
  └─── Pod 5 ✓                     └─── Pod 5 ✓
  20% of requests fail              0% fail (broken pod excluded)
```

### How To Use

A DestinationRule is only generated when you add `trafficPolicy` to a service:

```yaml
meshNetworking:
  services:
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      trafficPolicy:
        # 1. Load balancing algorithm
        loadBalancer: ROUND_ROBIN

        # 2. Connection pool limits
        connectionPool:
          tcp:
            maxConnections: 100        # Max TCP connections total
          http:
            h2UpgradePolicy: DEFAULT   # HTTP/2 upgrade behavior
            maxRequestsPerConnection: 100  # Close connection after N requests
            maxRequests: 2048          # Max concurrent HTTP requests

        # 3. Circuit breaking (outlier detection)
        outlierDetection:
          consecutive5xxErrors: 5      # Eject after 5 consecutive 5xx errors
          consecutive4xxErrors: 0      # Don't eject on 4xx (0 = disabled)
          interval: 30s               # Check every 30 seconds
          baseEjectionTime: 30s       # Ejected pod stays out for 30s
          maxEjectionPercent: 100     # Allow ejecting up to 100% of pods
          splitExternalLocalOriginErrors: false
```

### Load Balancing Algorithms

| Algorithm | How It Works | Best For |
|---|---|---|
| `ROUND_ROBIN` | Each pod gets requests in order: 1, 2, 3, 1, 2, 3... | Default — works well for most cases |
| `LEAST_REQUEST` | Send to the pod with the fewest active requests | AI inference — pods with long requests get fewer new ones |
| `RANDOM` | Pick a random pod | Large clusters where tracking state is expensive |
| `PASSTHROUGH` | Don't load balance — send directly | When the destination already handles it |

> **Tip for AI workloads:** Use `LEAST_REQUEST`. Model inference requests take variable time (some inputs are harder). `ROUND_ROBIN` might send a new request to a pod that's still busy with a long inference, while another pod is idle. `LEAST_REQUEST` picks the least busy pod.

### Outlier Detection Parameters Explained

| Parameter | What It Does | Example |
|---|---|---|
| `consecutive5xxErrors: 5` | After 5 consecutive 500/502/503 errors, eject the pod | Pod is crashing → eject it |
| `interval: 30s` | Check for errors every 30 seconds | How often to re-evaluate |
| `baseEjectionTime: 30s` | Ejected pod stays out for 30 seconds minimum | Cooldown before trying again |
| `maxEjectionPercent: 100` | Allow ejecting all pods if all are failing | Set lower (e.g., 50) to always keep some capacity |

### What Gets Generated

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: model-api-dr
  namespace: ai-namespace
spec:
  host: model-api.ai-namespace.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        h2UpgradePolicy: DEFAULT
        maxRequestsPerConnection: 100
        maxRequests: 2048
    outlierDetection:
      consecutive5xxErrors: 5
      consecutive4xxErrors: 0
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
      splitExternalLocalOriginErrors: false
```

**If `trafficPolicy` is not set:** No DestinationRule is generated. Istio uses its defaults (round-robin, no circuit breaking, no connection limits).

---

## 5. Fault Injection

### What Is It?

Fault injection deliberately injects **bad behavior** into your system to test how it handles failures. You can inject:

- **Delays** — Add artificial latency to responses (simulates a slow database or model)
- **Aborts** — Return error codes immediately (simulates a crashed service)

### Why Use It?

Before going to production, you need to know:
- Does my retry policy actually work when the service returns 503?
- Does my UI show a loading spinner gracefully when the model takes 10 seconds?
- Does my circuit breaker eject the failing pod?

Fault injection lets you test all of these scenarios **on purpose**, instead of waiting for them to happen accidentally.

### How To Use

```yaml
meshNetworking:
  services:
    - name: model-api
      serviceNamespace: ai-namespace
      port: 8080
      fault:
        # Add 5-second delay to 10% of requests
        delay:
          percentage: 10        # 10% of requests get delayed
          fixedDelay: 5s        # Add 5 seconds of latency

        # Return 503 for 5% of requests
        abort:
          percentage: 5         # 5% of requests get aborted
          httpStatus: 503       # Return HTTP 503

      # Combine with retries to test retry behavior:
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx
```

### What Gets Generated (inside the VirtualService)

```yaml
http:
  - route:
      - destination:
          host: model-api.ai-namespace.svc.cluster.local
          port:
            number: 8080
    fault:
      delay:
        percentage:
          value: 10
        fixedDelay: 5s
      abort:
        percentage:
          value: 5
        httpStatus: 503
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `fault.delay.percentage` | float | yes | — | % of requests to delay (0-100) |
| `fault.delay.fixedDelay` | string | yes | — | Delay duration (e.g., `5s`, `500ms`) |
| `fault.abort.percentage` | float | yes | — | % of requests to abort (0-100) |
| `fault.abort.httpStatus` | int | yes | — | HTTP status to return |

> **Warning:** Remove fault injection before deploying to production! Set percentages to 0 or remove the `fault` block entirely.

---

## 6. CORS Policy

### What Is CORS?

When your web browser loads a page from `https://dashboard.aib.vodafone.com` and that page tries to make an API call to `https://model-api.aib.vodafone.com`, the browser blocks it. This is called the **Same-Origin Policy** — a browser security feature that prevents websites from accessing resources on different domains.

**CORS (Cross-Origin Resource Sharing)** is the mechanism to relax this restriction. It tells the browser: "It's okay, `dashboard.aib.vodafone.com` is allowed to call `model-api.aib.vodafone.com`."

### Why Do You Need It?

If your platform has:
- A web dashboard that calls backend APIs
- Jupyter notebooks that call model endpoints
- A frontend app on one subdomain calling an API on another

...then you need CORS, or the browser will block those API calls.

### How To Use

```yaml
meshNetworking:
  services:
    - name: model-api
      serviceNamespace: ai-namespace
      port: 8080
      corsPolicy:
        allowOrigins:
          - exact: "https://dashboard.aib.vodafone.com"
          - prefix: "https://notebook."        # Any notebook.* subdomain
        allowMethods:
          - GET
          - POST
          - PUT
          - DELETE
        allowHeaders:
          - Authorization
          - Content-Type
          - X-Custom-Header
        exposeHeaders:                         # Headers the browser can read from response
          - X-Request-Id
        maxAge: "24h"                          # Cache preflight response for 24 hours
        allowCredentials: true                 # Allow cookies/auth headers
```

### What Gets Generated (inside the VirtualService)

```yaml
http:
  - route:
      - destination:
          host: model-api.ai-namespace.svc.cluster.local
          port:
            number: 8080
    corsPolicy:
      allowOrigins:
        - exact: "https://dashboard.aib.vodafone.com"
        - prefix: "https://notebook."
      allowMethods:
        - GET
        - POST
        - PUT
        - DELETE
      allowHeaders:
        - Authorization
        - Content-Type
        - X-Custom-Header
      exposeHeaders:
        - X-Request-Id
      maxAge: "24h"
      allowCredentials: true
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `corsPolicy.allowOrigins` | list | yes | — | Origins allowed to make requests (use `exact` or `prefix`) |
| `corsPolicy.allowMethods` | list | no | — | Allowed HTTP methods |
| `corsPolicy.allowHeaders` | list | no | — | Allowed request headers |
| `corsPolicy.exposeHeaders` | list | no | — | Response headers the browser can access |
| `corsPolicy.maxAge` | string | no | — | How long browsers cache preflight results |
| `corsPolicy.allowCredentials` | bool | no | — | Whether cookies/auth headers are allowed |

---

## 7. Traffic Mirroring (Shadow Traffic)

### What Is It?

Traffic mirroring sends a **copy** of live production traffic to a secondary service (the "shadow"). The client always gets the response from the primary service — the shadow's response is thrown away.

```
Client request
    │
    ├──→ Primary (model-api v1) ──→ Response sent to client
    │
    └──→ Shadow (model-api v2) ──→ Response discarded (but logged/monitored)
```

### Why Use It?

Before deploying a new model version to production, you want to know: "Will it break with real traffic?" Mirroring lets you:

1. **Compare outputs** — Run v1 and v2 side by side with the same input
2. **Load test** — See how v2 handles real production load
3. **Validate correctness** — Check that v2 returns the same predictions as v1
4. **Zero risk** — The client never sees v2's response; if v2 crashes, nobody notices

### How To Use

```yaml
meshNetworking:
  services:
    - name: model-api
      serviceNamespace: ai-namespace
      port: 8080
      mirror:
        host: model-api-v2.ai-namespace.svc.cluster.local
        port: 8080
        percentage: 50        # Mirror 50% of traffic (to limit load)
```

### What Gets Generated (inside the VirtualService)

```yaml
http:
  - route:
      - destination:
          host: model-api.ai-namespace.svc.cluster.local
          port:
            number: 8080
    mirror:
      host: model-api-v2.ai-namespace.svc.cluster.local
      port:
        number: 8080
    mirrorPercentage:
      value: 50
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `mirror.host` | string | yes | — | FQDN of the shadow service |
| `mirror.port` | int | yes | — | Port of the shadow service |
| `mirror.percentage` | float | no | `100` | % of traffic to mirror (0-100) |

---

## 8. Weighted Routing (Canary Deployments)

### What Is Canary Routing?

Instead of deploying a new version to 100% of traffic at once (risky), you gradually shift traffic:

```
Day 1:   stable = 100%,  canary = 0%    (just deployed, no traffic yet)
Day 2:   stable = 90%,   canary = 10%   (small test)
Day 3:   stable = 50%,   canary = 50%   (looking good)
Day 4:   stable = 0%,    canary = 100%  (full rollout)
```

If the canary shows errors at any point, you change the weights back — instant rollback.

### How It Works

When you set `weightedRouting`, it **replaces** the default single-destination route. Instead of all traffic going to one place, it splits across multiple destinations with different weights.

### How To Use

```yaml
meshNetworking:
  services:
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080                  # Required by schema but overridden by weightedRouting
      weightedRouting:
        - host: model-api.ai-namespace.svc.cluster.local
          port: 8080
          subset: stable          # Must match a subset in a DestinationRule
          weight: 90              # 90% of traffic
        - host: model-api.ai-namespace.svc.cluster.local
          port: 8080
          subset: canary
          weight: 10              # 10% of traffic
```

> **Important:** Weights must add up to 100. Subsets (`stable`, `canary`) are version labels defined in a DestinationRule — you need to create these separately.

### What Gets Generated (inside the VirtualService)

```yaml
http:
  - route:
      - destination:
          host: model-api.ai-namespace.svc.cluster.local
          subset: stable
          port:
            number: 8080
        weight: 90
      - destination:
          host: model-api.ai-namespace.svc.cluster.local
          subset: canary
          port:
            number: 8080
        weight: 10
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `weightedRouting` | list | no | — | If set, overrides the default single route |
| `weightedRouting[].host` | string | yes | — | FQDN of the destination |
| `weightedRouting[].port` | int | yes | — | Port of the destination |
| `weightedRouting[].subset` | string | no | — | DestinationRule subset name |
| `weightedRouting[].weight` | int | yes | — | % of traffic (must sum to 100) |

---

## Installation

### As part of the umbrella chart (recommended)

```yaml
# In aib-platform values.yaml or environment override:
mesh-networking:
  meshNetworking:
    namespace: aib-platform
    domain: "aib.vodafone.com"
    gateway:
      enabled: true
      name: platform-gateway
      selector:
        istio: ingressgateway
      port:
        number: 80
        name: http
        protocol: HTTP
    services:
      - name: argocd-server
        subdomain: argocd
        serviceNamespace: argocd
        port: 80
```

### Standalone

```bash
helm install mesh-networking ./mesh-networking \
  -f my-networking-values.yaml \
  -n aib-platform
```

---

## Quick Recipes

### Recipe 1: Simple service with retry + timeout

```yaml
meshNetworking:
  services:
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      timeout: 10s
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx
```

### Recipe 2: Circuit breaker for AI inference

```yaml
meshNetworking:
  services:
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      timeout: 30s               # Model inference can be slow
      retries:
        attempts: 2
        perTryTimeout: 10s
        retryOn: 5xx,connect-failure
      trafficPolicy:
        loadBalancer: LEAST_REQUEST    # Send to least busy pod
        connectionPool:
          tcp:
            maxConnections: 50
          http:
            maxRequests: 100
            maxRequestsPerConnection: 10
        outlierDetection:
          consecutive5xxErrors: 3      # Eject after 3 errors
          interval: 10s
          baseEjectionTime: 30s
```

### Recipe 3: Full canary deployment setup

```yaml
meshNetworking:
  services:
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      timeout: 10s
      weightedRouting:
        - host: model-api.ai-namespace.svc.cluster.local
          port: 8080
          subset: stable
          weight: 90
        - host: model-api.ai-namespace.svc.cluster.local
          port: 8080
          subset: canary
          weight: 10
      trafficPolicy:
        loadBalancer: LEAST_REQUEST
        outlierDetection:
          consecutive5xxErrors: 3
          interval: 10s
          baseEjectionTime: 30s
```

### Recipe 4: Test resilience with fault injection

```yaml
meshNetworking:
  services:
    - name: model-api
      subdomain: model
      serviceNamespace: ai-namespace
      port: 8080
      fault:
        delay:
          percentage: 20
          fixedDelay: 3s
        abort:
          percentage: 10
          httpStatus: 503
      retries:
        attempts: 3
        perTryTimeout: 5s
        retryOn: 5xx
      trafficPolicy:
        outlierDetection:
          consecutive5xxErrors: 3
          interval: 10s
          baseEjectionTime: 30s
```

This tests the full resilience chain: fault injection triggers errors → retries handle transient failures → circuit breaker ejects consistently failing pods.

---

## Full Values Reference

```yaml
meshNetworking:
  namespace: aib-platform              # Required — namespace where CRs are created
  domain: "aib.vodafone.com"

  gateway:
    enabled: true
    name: platform-gateway
    selector:
      istio: ingressgateway
    port:
      number: 80
      name: http
      protocol: HTTP
    # tls:
    #   mode: SIMPLE
    #   credentialName: tls-secret

  services:
    - name: service-name               # Required
      subdomain: custom-subdomain       # Optional (default: name)
      serviceNamespace: target-namespace  # Optional — namespace where K8s Service runs (default: "default")
      port: 8080                        # Required
      # pathPrefix: /api                # Optional — URI prefix match
      # headers: {}                     # Optional — header match
      # timeout: 10s                    # Optional — total timeout
      # retries:                        # Optional — retry policy
      #   attempts: 3
      #   perTryTimeout: 2s
      #   retryOn: 5xx
      # fault:                          # Optional — fault injection
      #   delay:
      #     percentage: 10
      #     fixedDelay: 5s
      #   abort:
      #     percentage: 5
      #     httpStatus: 503
      # corsPolicy:                     # Optional — CORS
      #   allowOrigins:
      #     - exact: "https://app.example.com"
      #   allowMethods: [GET, POST]
      #   allowHeaders: [Authorization]
      #   maxAge: "24h"
      # mirror:                         # Optional — traffic mirroring
      #   host: svc-v2.ns.svc.cluster.local
      #   port: 8080
      #   percentage: 50
      # weightedRouting:                # Optional — canary routing
      #   - host: svc.ns.svc.cluster.local
      #     port: 8080
      #     subset: stable
      #     weight: 90
      #   - host: svc.ns.svc.cluster.local
      #     port: 8080
      #     subset: canary
      #     weight: 10
      # trafficPolicy:                  # Optional — DestinationRule
      #   loadBalancer: ROUND_ROBIN
      #   connectionPool:
      #     tcp:
      #       maxConnections: 100
      #     http:
      #       maxRequestsPerConnection: 100
      #       maxRequests: 2048
      #   outlierDetection:
      #     consecutive5xxErrors: 5
      #     interval: 30s
      #     baseEjectionTime: 30s
      #     maxEjectionPercent: 100
      #   tls:
      #     mode: ISTIO_MUTUAL
```
