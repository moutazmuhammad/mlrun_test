# AIB Platform — Istio Mesh Configuration

Umbrella Helm chart that manages all Istio mesh configuration for the AIB cloud platform. It provides a single, centralized place to control how services communicate (security), how traffic enters the cluster (networking), and how services reach external APIs (egress).

---

## Table of Contents

- [Network Topology](#network-topology)
- [Chart Structure](#chart-structure)
- [How It Works](#how-it-works)
- [1. mesh-security](#1-mesh-security)
  - [1.1 PeerAuthentication (mTLS)](#11-peerauthentication-mtls)
  - [1.2 AuthorizationPolicy (Fine-Grained)](#12-authorizationpolicy-fine-grained)
  - [1.3 RequestAuthentication (JWT)](#13-requestauthentication-jwt)
  - [1.4 Rate Limiting (Per Namespace)](#14-rate-limiting-per-namespace)
  - [1.5 External Authorization (oauth2-proxy)](#15-external-authorization-oauth2-proxy)
- [2. mesh-networking](#2-mesh-networking)
  - [2.1 Domain](#21-domain)
  - [2.2 Gateway](#22-gateway)
  - [2.3 Services (VirtualService)](#23-services-virtualservice)
  - [2.4 DestinationRule (Traffic Policy)](#24-destinationrule-traffic-policy)
  - [2.5 Fault Injection](#25-fault-injection)
  - [2.6 CORS Policy](#26-cors-policy)
  - [2.7 Traffic Mirroring](#27-traffic-mirroring)
  - [2.8 Weighted Routing (Canary)](#28-weighted-routing-canary)
- [3. mesh-egress](#3-mesh-egress)
  - [3.1 ServiceEntry](#31-serviceentry)
  - [3.2 Egress Gateway Routing](#32-egress-gateway-routing)
  - [3.3 TLS Origination (HTTP port 80)](#33-tls-origination-http-port-80)
- [Installation](#installation)
- [Environment Overrides](#environment-overrides)
- [Full Values Reference](#full-values-reference)

---

## Network Topology

```
Customer-managed ELB (external)
        │
        ▼
┌──────────────────────────────────────────────────────┐
│  istio-system namespace                              │
│  ┌──────────────────┐    ┌──────────────────┐        │
│  │  Istio Ingress   │    │  Istio Egress    │        │
│  │  Gateway (pod)   │    │  Gateway (pod)   │        │
│  └────────┬─────────┘    └────────▲─────────┘        │
│           │                       │                  │
│  istiod (control plane)           │                  │
└───────────┼───────────────────────┼──────────────────┘
            │                       │
┌───────────┼───────────────────────┼──────────────────┐
│  aib-platform namespace (CRs)     │                  │
│  Gateway, VirtualService,         │                  │
│  DestinationRule, EnvoyFilter,    │                  │
│  ServiceEntry                     │                  │
└───────────┼───────────────────────┼──────────────────┘
            │                       │
            ▼                       │
┌──────────────────┐                │
│  Platform        │  argocd, mlrun, mlflow, kubeflow, minio, etc.
│  Services        │────────────────┘
└────────┬─────────┘
         │  mesh-egress: ServiceEntry + optional egress gateway
         ▼
┌──────────────────┐
│  External APIs   │  api.openai.com, huggingface.co, etc.
└──────────────────┘
```

**Why ClusterIP?** The platform is cloud-agnostic. It never provisions cloud load balancers (`type: LoadBalancer`). The customer is responsible for creating their own external load balancer (AWS ELB/NLB, GCP LB, Azure LB, on-prem F5, etc.) and pointing it at the Istio ingress gateway pods. This means the same charts work identically across any cloud or bare-metal environment.

---

## Chart Structure

```
aib-platform/
├── Chart.yaml                           # Umbrella chart — declares 3 subchart dependencies
├── values.yaml                          # Default values for all subcharts
├── mesh-security/                       # Subchart: Istio security policies
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── README.md                        # Security subchart documentation
│   └── templates/
│       ├── _helpers.tpl                 # Shared labels
│       ├── peer-authentication.yaml     # PeerAuthentication resources
│       ├── authorization-policy.yaml    # AuthorizationPolicy resources (fine-grained)
│       ├── request-authentication.yaml  # RequestAuthentication resources
│       ├── rate-limit.yaml              # EnvoyFilter for local rate limiting
│       ├── extension-provider.yaml      # ConfigMap with extensionProvider mesh config (oauth2-proxy)
│       └── external-authorization.yaml  # AuthorizationPolicy CUSTOM action (per-service ext authz)
├── mesh-networking/                     # Subchart: Ingress routing & traffic management
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── README.md                        # Networking subchart documentation
│   └── templates/
│       ├── _helpers.tpl                 # Shared labels
│       ├── gateway.yaml                 # Gateway resource
│       ├── virtualservices.yaml         # VirtualService resources (routing, retries, fault injection, CORS, mirroring, canary)
│       └── destination-rules.yaml       # DestinationRule resources (circuit breaking, load balancing)
└── mesh-egress/                         # Subchart: External service access
    ├── Chart.yaml
    ├── values.yaml
    ├── README.md                        # Egress subchart documentation
    └── templates/
        ├── _helpers.tpl                 # Shared labels
        ├── service-entry.yaml           # ServiceEntry resources
        ├── egress-gateway.yaml          # Egress Gateway resource
        ├── egress-virtualservices.yaml   # VirtualService resources (egress routing)
        └── destination-rules.yaml       # DestinationRule resources (gateway subsets, TLS origination)
```

---

## How It Works

The umbrella chart (`aib-platform`) depends on three subcharts. When you install it, Helm renders all three subcharts together. You control what gets generated entirely through `values.yaml` — every list you populate produces Kubernetes resources, and every empty list produces nothing.

**Key principle:** All templates use Helm `range` loops. You never edit templates. You only edit values.

To override subchart values from the umbrella, prefix with the subchart name:

```yaml
# In umbrella values.yaml or environment override file
mesh-security:       # ← subchart name prefix
  meshSecurity:      # ← actual values key inside the subchart
    mtls:
      mode: STRICT
```

---

## 1. mesh-security

**What it does:** Controls how services authenticate and authorize each other inside the mesh, validates JWT tokens, and enforces per-namespace rate limits.

**Why you need it:** Without security policies, any pod in the cluster can talk to any other pod over plaintext. mesh-security lets you enforce encrypted communication (mTLS), restrict which namespaces/identities can call which services, validate JWT tokens, and limit request rates per namespace.

### 1.1 PeerAuthentication (mTLS)

**What it is:** An Istio resource that tells the mesh whether to require mutual TLS between services.

**Why:** mTLS encrypts all service-to-service traffic and verifies the identity of both sides. `STRICT` mode means plaintext connections are rejected — even if a pod is compromised, it cannot eavesdrop on mesh traffic without a valid certificate.

**Values:**

```yaml
mesh-security:
  meshSecurity:
    mtls:
      enabled: true       # Set to false to skip generating PeerAuthentication entirely
      mode: STRICT         # Default mode applied to all namespaces in the list
      namespaces: []       # List of namespaces to apply mTLS to
```

**How to use:**

```yaml
mesh-security:
  meshSecurity:
    mtls:
      enabled: true
      mode: STRICT
      namespaces:
        # Basic — apply STRICT mTLS to the entire namespace
        - name: mlrun

        # Override mode per namespace
        - name: legacy-namespace
          mode: PERMISSIVE          # Accept both plaintext and mTLS (migration period)

        # Target a specific workload instead of the whole namespace
        - name: mlrun
          selector:
            app: sensitive-api
          mode: STRICT

        # Override mTLS mode on specific ports
        - name: mlrun
          portLevelMtls:
            8080:
              mode: PERMISSIVE      # Allow plaintext on port 8080 only
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `enabled` | bool | no | `true` | Whether to generate PeerAuthentication resources at all |
| `mode` | string | no | `STRICT` | Global default mode: `STRICT`, `PERMISSIVE`, or `DISABLE` |
| `namespaces` | list | yes | `[]` | List of namespace entries to generate PeerAuthentication for |
| `namespaces[].name` | string | yes | — | Namespace name where the resource is created |
| `namespaces[].mode` | string | no | inherits global `mode` | Override mode for this specific namespace |
| `namespaces[].selector` | map | no | — | If set, targets only pods matching these labels instead of the whole namespace |
| `namespaces[].portLevelMtls` | map | no | — | Override mTLS mode on specific ports |

**Expected output** (for `name: mlrun`, `mode: STRICT`):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: mlrun-mtls
  namespace: mlrun
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  mtls:
    mode: STRICT
```

**If `namespaces` is empty (`[]`):** No PeerAuthentication resources are generated.

---

### 1.2 AuthorizationPolicy (Fine-Grained)

**What it is:** An Istio resource that controls which sources (namespaces, service accounts, JWT identities, IP ranges) are allowed or denied access to a service, with support for conditional rules.

**Why:** Even with mTLS, any authenticated service can call any other service. AuthorizationPolicy lets you define fine-grained rules — e.g., "only requests from `data-pipeline` namespace with a valid JWT `admin` role can call `model-api` on port 8080 using POST, except the `/admin/*` paths."

**Values:**

```yaml
mesh-security:
  meshSecurity:
    authorizationPolicies: []    # List of policies to generate
```

**How to use:**

```yaml
mesh-security:
  meshSecurity:
    authorizationPolicies:
      # Basic — namespace and service account based
      - name: allow-mlrun-api
        namespace: mlrun
        action: ALLOW
        selector:
          app: mlrun-api
        rules:
          - from:
              - namespaces:
                  - istio-system
                  - mlrun
              - principals:
                  - cluster.local/ns/kubeflow/sa/kubeflow-pipelines
            to:
              - ports:
                  - "8080"
                methods:
                  - GET
                  - POST
                paths:
                  - /predict
                  - /health

      # Fine-grained — JWT identity, IP blocks, exclusions, and conditions
      - name: model-api-fine-grained
        namespace: ai-namespace
        action: ALLOW
        selector:
          app: model-api
        rules:
          - from:
              - namespaces:
                  - data-pipeline
                  - monitoring
                notNamespaces:
                  - untrusted-ns
                requestPrincipals:                  # JWT-based identity
                  - "https://auth.aib.vodafone.com/*"
                ipBlocks:                            # IP-based access control
                  - "10.0.0.0/8"
                notIpBlocks:
                  - "10.0.99.0/24"
            to:
              - ports:
                  - "8080"
                methods:
                  - GET
                  - POST
                notMethods:
                  - DELETE
                paths:
                  - "/api/v1/*"
                notPaths:                           # Exclude admin endpoints
                  - "/api/v1/admin/*"
                hosts:
                  - "model-api.aib.vodafone.com"
            when:                                    # Conditional rules
              - key: request.auth.claims[role]      # Match JWT claim values
                values:
                  - admin
                  - editor
              - key: request.headers[x-custom-token]
                values:
                  - valid-token

      # DENY — block specific traffic patterns
      - name: deny-external-admin
        namespace: ai-namespace
        action: DENY
        rules:
          - from:
              - notNamespaces:
                  - ai-namespace
            to:
              - paths:
                  - "/admin/*"

      # CUSTOM — delegate to external authorization service
      - name: ext-authz-check
        namespace: ai-namespace
        action: CUSTOM
        provider: my-ext-authz                     # Provider name from meshConfig
        selector:
          app: model-api
        rules:
          - to:
              - paths:
                  - "/api/v1/*"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Name of the AuthorizationPolicy resource |
| `namespace` | string | yes | — | Namespace where the policy is created |
| `action` | string | no | `ALLOW` | Policy action: `ALLOW`, `DENY`, or `CUSTOM` |
| `provider` | string | no | — | External authorization provider name (only for `CUSTOM` action) |
| `selector` | map | no | — | Pod labels this policy targets. If omitted, applies to all pods in the namespace |
| `rules` | list | yes | — | List of access rules |
| `rules[].from` | list | no | — | Source conditions (who can call) |
| `rules[].from[].namespaces` | list | no | — | Allowed source namespaces |
| `rules[].from[].notNamespaces` | list | no | — | Excluded source namespaces |
| `rules[].from[].principals` | list | no | — | Allowed service account identities |
| `rules[].from[].notPrincipals` | list | no | — | Excluded service account identities |
| `rules[].from[].requestPrincipals` | list | no | — | Allowed JWT identities (issuer/subject) |
| `rules[].from[].notRequestPrincipals` | list | no | — | Excluded JWT identities |
| `rules[].from[].ipBlocks` | list | no | — | Allowed source IP CIDR ranges |
| `rules[].from[].notIpBlocks` | list | no | — | Excluded source IP CIDR ranges |
| `rules[].to` | list | no | — | Destination conditions (what they can access) |
| `rules[].to[].ports` | list | no | — | Allowed destination ports (as strings) |
| `rules[].to[].notPorts` | list | no | — | Excluded destination ports |
| `rules[].to[].methods` | list | no | — | Allowed HTTP methods |
| `rules[].to[].notMethods` | list | no | — | Excluded HTTP methods |
| `rules[].to[].paths` | list | no | — | Allowed URL paths (supports wildcards) |
| `rules[].to[].notPaths` | list | no | — | Excluded URL paths |
| `rules[].to[].hosts` | list | no | — | Allowed destination hosts |
| `rules[].to[].notHosts` | list | no | — | Excluded destination hosts |
| `rules[].when` | list | no | — | Conditional rules (must all match) |
| `rules[].when[].key` | string | yes | — | Istio attribute key (e.g., `request.auth.claims[role]`, `request.headers[x-token]`) |
| `rules[].when[].values` | list | no | — | Required values for the key |
| `rules[].when[].notValues` | list | no | — | Excluded values for the key |

**Expected output** (fine-grained example):

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: model-api-fine-grained
  namespace: ai-namespace
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  selector:
    matchLabels:
      app: model-api
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces:
              - data-pipeline
              - monitoring
            notNamespaces:
              - untrusted-ns
            requestPrincipals:
              - "https://auth.aib.vodafone.com/*"
            ipBlocks:
              - "10.0.0.0/8"
            notIpBlocks:
              - "10.0.99.0/24"
      to:
        - operation:
            ports:
              - "8080"
            methods:
              - GET
              - POST
            notMethods:
              - DELETE
            paths:
              - "/api/v1/*"
            notPaths:
              - "/api/v1/admin/*"
            hosts:
              - "model-api.aib.vodafone.com"
      when:
        - key: request.auth.claims[role]
          values:
            - admin
            - editor
        - key: request.headers[x-custom-token]
          values:
            - valid-token
```

**Common `when` condition keys:**

| Key | Description | Example |
|---|---|---|
| `request.auth.claims[role]` | JWT claim value | `["admin", "editor"]` |
| `request.auth.claims[groups]` | JWT groups claim | `["platform-team"]` |
| `request.auth.principal` | Full JWT principal (`issuer/subject`) | `["https://auth.issuer.com/user123"]` |
| `request.headers[x-api-key]` | Custom request header | `["valid-key-123"]` |
| `source.namespace` | Source namespace | `["mlrun", "kubeflow"]` |
| `source.ip` | Source IP address | `["10.0.1.0/24"]` |

**If `authorizationPolicies` is empty (`[]`):** No AuthorizationPolicy resources are generated. All mesh traffic is allowed by default (mTLS still applies if configured).

---

### 1.3 RequestAuthentication (JWT)

**What it is:** An Istio resource that validates JSON Web Tokens (JWT) on incoming requests.

**Why:** If your services need to verify that callers have a valid token from an identity provider (Auth0, Keycloak, Google, etc.), this validates the token at the mesh level before the request reaches your application. Invalid tokens are rejected by the sidecar — your app never sees them.

**Values:**

```yaml
mesh-security:
  meshSecurity:
    requestAuthentication: []    # List of JWT validation configs
```

**How to use:**

```yaml
mesh-security:
  meshSecurity:
    requestAuthentication:
      - name: jwt-auth
        namespace: mlrun
        selector:                            # Which pods validate JWT
          app: mlrun-api
        jwtRules:
          - issuer: "https://auth.aib.vodafone.com"
            jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
            audiences:                       # Optional — restrict to specific audiences
              - "mlrun-api"
            forwardOriginalToken: true       # Pass the original token to the app
            outputPayloadToHeader: x-jwt-payload  # Decode payload into a header
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Name of the RequestAuthentication resource |
| `namespace` | string | yes | — | Namespace where the resource is created |
| `selector` | map | no | — | Pod labels this applies to. If omitted, applies to all pods |
| `jwtRules` | list | yes | — | List of JWT validation rules |
| `jwtRules[].issuer` | string | yes | — | Expected `iss` claim in the JWT |
| `jwtRules[].jwksUri` | string | yes | — | URL to fetch the JSON Web Key Set for signature validation |
| `jwtRules[].audiences` | list | no | — | Expected `aud` claim values |
| `jwtRules[].forwardOriginalToken` | bool | no | `false` | Whether to forward the original token to the upstream service |
| `jwtRules[].outputPayloadToHeader` | string | no | — | If set, decoded JWT payload is added to this request header |

**Expected output:**

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: mlrun
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  selector:
    matchLabels:
      app: mlrun-api
  jwtRules:
    - issuer: "https://auth.aib.vodafone.com"
      jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
      audiences:
        - "mlrun-api"
      forwardOriginalToken: true
      outputPayloadToHeader: "x-jwt-payload"
```

**If `requestAuthentication` is empty (`[]`):** No JWT validation is applied. Requests are accepted without tokens.

> **Important:** RequestAuthentication only rejects requests with *invalid* tokens. Requests with *no* token are still allowed through. To block requests without tokens, combine this with an AuthorizationPolicy that requires authenticated identities:
>
> ```yaml
> authorizationPolicies:
>   - name: require-jwt
>     namespace: mlrun
>     action: ALLOW
>     selector:
>       app: mlrun-api
>     rules:
>       - from:
>           - requestPrincipals:
>               - "*"    # Requires any valid JWT
> ```

---

### 1.4 Rate Limiting (Per Namespace)

**What it is:** An Istio EnvoyFilter that applies local rate limiting to workloads in a specific namespace. It uses Envoy's built-in token bucket algorithm — no external rate limit service required.

**Why:** Without rate limiting, a misbehaving client or a burst of traffic can overwhelm your AI model serving endpoints. Per-namespace rate limiting protects individual services by rejecting excess requests with HTTP 429 (Too Many Requests) at the sidecar level, before they reach your application.

**How it works:**

```
Request → sidecar proxy → [token bucket check] → application
                              │
                              └─ if no tokens → 429 Too Many Requests
                                               + x-local-rate-limit: true header
```

**Values:**

```yaml
mesh-security:
  meshSecurity:
    rateLimiting: []    # List of rate limit configs
```

**How to use:**

```yaml
mesh-security:
  meshSecurity:
    rateLimiting:
      # Rate limit all inbound traffic in a namespace
      - name: ai-namespace-ratelimit
        namespace: ai-namespace
        maxTokens: 100            # Max burst size (requests)
        tokensPerFill: 50         # Tokens added per interval
        fillInterval: "60s"       # Refill interval

      # Rate limit a specific workload
      - name: model-api-ratelimit
        namespace: ai-namespace
        selector:                 # Target specific pods
          app: model-api
        maxTokens: 20             # Stricter limit for expensive model inference
        tokensPerFill: 10
        fillInterval: "60s"
        statusCode: 429           # HTTP status code on rate limit (default: 429)
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Name of the EnvoyFilter resource (`<name>-ratelimit`) |
| `namespace` | string | yes | — | Namespace where the rate limit is applied |
| `selector` | map | no | — | Pod labels to target. If omitted, applies to all pods in the namespace |
| `maxTokens` | int | no | `100` | Maximum number of tokens in the bucket (burst size) |
| `tokensPerFill` | int | no | `100` | Number of tokens added per fill interval |
| `fillInterval` | string | no | `60s` | How often tokens are refilled (e.g., `1s`, `30s`, `60s`) |
| `statusCode` | int | no | `429` | HTTP status code returned when rate limited |

**Expected output:**

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ai-namespace-ratelimit-ratelimit
  namespace: ai-namespace
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.local_ratelimit
          typed_config:
            "@type": type.googleapis.com/udpa.type.v1.TypedStruct
            type_url: type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
            value:
              stat_prefix: http_local_rate_limiter
              token_bucket:
                max_tokens: 100
                tokens_per_fill: 50
                fill_interval: 60s
              filter_enabled:
                runtime_key: local_rate_limit_enabled
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              filter_enforced:
                runtime_key: local_rate_limit_enforced
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              response_headers_to_add:
                - append_action: OVERWRITE_IF_EXISTS_OR_ADD
                  header:
                    key: x-local-rate-limit
                    value: "true"
```

**Rate limit sizing guide:**

| Use case | maxTokens | tokensPerFill | fillInterval | Effective rate |
|---|---|---|---|---|
| Model inference endpoint | 20 | 10 | 60s | ~10 req/min sustained, 20 burst |
| General API gateway | 200 | 100 | 60s | ~100 req/min sustained, 200 burst |
| High-throughput pipeline | 1000 | 500 | 10s | ~3000 req/min sustained |
| Strict protection | 5 | 5 | 60s | ~5 req/min, no burst |

**If `rateLimiting` is empty (`[]`):** No rate limiting is applied. Requests are not throttled.

---

### 1.5 External Authorization (oauth2-proxy)

**What it is:** Delegates authorization decisions to an external service (e.g., oauth2-proxy) using Istio's [Custom Authorization](https://istio.io/latest/docs/tasks/security/authorization/authz-custom/) feature. This creates an `AuthorizationPolicy` with `action: CUSTOM` that sends each request to an external authz provider before allowing it through.

**Why:** When you need a centralized login flow (OAuth2/OIDC) for web applications — e.g., protecting ArgoCD, MLflow, or Grafana dashboards behind Google/GitHub/Keycloak SSO — without modifying each application. The external oauth2-proxy handles the login redirect, token validation, and session management. Istio intercepts the request at the sidecar and checks with oauth2-proxy before forwarding it to your app.

**How it works:**

```
Browser → Istio Ingress → sidecar proxy → [ext authz check] → application
                                │
                                ├─ if allowed → forward request + user headers
                                └─ if denied  → redirect to login page (302)
```

**This is a per-service feature.** You choose which apps go through external authorization. Apps not listed are unaffected.

**Two-part configuration:**

1. **`extensionProviders`** — Registers the external authz service (oauth2-proxy) with Istio. Generates a reference ConfigMap that you merge into the Istio mesh config.
2. **`externalAuthorization`** — Creates per-service `AuthorizationPolicy` resources with `action: CUSTOM`, targeting only the apps you specify.

#### Part 1: Extension Provider (mesh config)

**Values:**

```yaml
mesh-security:
  meshSecurity:
    extensionProviders: []    # List of external authz providers
```

**How to use:**

```yaml
mesh-security:
  meshSecurity:
    extensionProviders:
      - name: oauth2-proxy
        enabled: true
        namespace: istio-system                                      # where the ConfigMap is created
        service: "oauth2-proxy.oauth2-proxy.svc.cluster.local"      # oauth2-proxy K8s service FQDN
        port: 4180                                                   # oauth2-proxy port
        includeRequestHeadersInCheck:                                # headers sent to oauth2-proxy
          - authorization
          - cookie
        headersToUpstreamOnAllow:                                    # headers forwarded to app on success
          - authorization
          - path
          - x-auth-request-user
          - x-auth-request-email
          - x-auth-request-access-token
        headersToDownstreamOnAllow:                                  # headers sent to browser on success
          - set-cookie
        headersToDownstreamOnDeny:                                   # headers sent to browser on deny
          - content-type
          - set-cookie
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Provider name (referenced by `externalAuthorization[].provider`) |
| `enabled` | bool | yes | — | Whether to generate the ConfigMap |
| `namespace` | string | no | `istio-system` | Namespace for the reference ConfigMap |
| `service` | string | yes | — | FQDN of the ext authz service (e.g., `oauth2-proxy.oauth2-proxy.svc.cluster.local`) |
| `port` | int | yes | — | Port the ext authz service listens on |
| `includeRequestHeadersInCheck` | list | no | — | Request headers forwarded to the ext authz service |
| `headersToUpstreamOnAllow` | list | no | — | Headers forwarded to the backend app when request is allowed |
| `headersToDownstreamOnAllow` | list | no | — | Headers sent back to the client when request is allowed |
| `headersToDownstreamOnDeny` | list | no | — | Headers sent back to the client when request is denied |
| `includeAdditionalHeadersInCheck` | map | no | — | Extra headers to add when checking (key-value pairs) |
| `pathPrefix` | string | no | — | Path prefix for authz check requests |
| `statusOnError` | string | no | — | HTTP status when ext authz is unreachable |
| `failOpen` | bool | no | `false` | If `true`, allow requests when ext authz is unreachable |

**Expected output:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-mesh-config-oauth2-proxy
  namespace: istio-system
  annotations:
    configmap.purpose: "Merge this into istio ConfigMap mesh key or IstioOperator meshConfig"
data:
  extension-provider.yaml: |
    extensionProviders:
      - name: "oauth2-proxy"
        envoyExtAuthzHttp:
          service: "oauth2-proxy.oauth2-proxy.svc.cluster.local"
          port: "4180"
          includeRequestHeadersInCheck:
            - authorization
            - cookie
          headersToUpstreamOnAllow:
            - authorization
            - path
            - x-auth-request-user
            - x-auth-request-email
            - x-auth-request-access-token
          headersToDownstreamOnAllow:
            - set-cookie
          headersToDownstreamOnDeny:
            - content-type
            - set-cookie
```

> **Important:** This ConfigMap is a **reference**. You must merge its `extensionProviders` content into your Istio mesh configuration. Depending on your Istio installation method:
>
> - **IstioOperator:** Add to `spec.meshConfig.extensionProviders`
> - **Helm-based Istio:** Add to `meshConfig.extensionProviders` in your istiod values
> - **Manual:** Edit the `istio` ConfigMap in `istio-system` and add to the `data.mesh` field

#### Part 2: Per-Service Authorization Policies

**Values:**

```yaml
mesh-security:
  meshSecurity:
    externalAuthorization: []    # List of per-service ext authz policies
```

**How to use:**

```yaml
mesh-security:
  meshSecurity:
    externalAuthorization:
      # Protect all requests to argocd-server
      - name: ext-authz-argocd
        enabled: true
        namespace: argocd
        provider: oauth2-proxy              # must match extensionProviders[].name
        selector:
          app: argocd-server
        rules: []                           # empty = ALL requests go through oauth2-proxy

      # Protect only /api/* paths on mlflow
      - name: ext-authz-mlflow
        enabled: true
        namespace: mlflow
        provider: oauth2-proxy
        selector:
          app: mlflow
        rules:
          - to:
              - paths:
                  - "/api/*"
                methods:
                  - GET
                  - POST

      # Protect grafana but skip health checks
      - name: ext-authz-grafana
        enabled: true
        namespace: monitoring
        provider: oauth2-proxy
        selector:
          app: grafana
        rules:
          - to:
              - notPaths:
                  - "/api/health"
                  - "/healthz"
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Name of the AuthorizationPolicy resource |
| `enabled` | bool | yes | — | Whether to generate this policy |
| `namespace` | string | yes | — | Namespace of the target workload |
| `provider` | string | yes | — | Extension provider name (must match `extensionProviders[].name`) |
| `selector` | map | no | — | Pod labels to target. If omitted, applies to all pods in the namespace |
| `rules` | list | no | `[{}]` | Rules defining which requests need ext authz. Empty list = all requests |
| `rules[].to` | list | no | — | Target operations to match |
| `rules[].to[].paths` | list | no | — | URL paths that require ext authz (supports wildcards) |
| `rules[].to[].notPaths` | list | no | — | URL paths to skip ext authz (e.g., health checks) |
| `rules[].to[].methods` | list | no | — | HTTP methods that require ext authz |
| `rules[].to[].ports` | list | no | — | Ports that require ext authz |
| `rules[].to[].hosts` | list | no | — | Hosts that require ext authz |
| `rules[].when` | list | no | — | Conditional rules for ext authz |
| `rules[].when[].key` | string | yes | — | Istio attribute key |
| `rules[].when[].values` | list | no | — | Required values |
| `rules[].when[].notValues` | list | no | — | Excluded values |

**Expected output** (for `ext-authz-argocd` with empty rules):

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ext-authz-argocd
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  selector:
    matchLabels:
      app: argocd-server
  action: CUSTOM
  provider:
    name: oauth2-proxy
  rules:
    - {}
```

**If `externalAuthorization` is empty (`[]`):** No external authorization is applied. No requests are sent to oauth2-proxy.

**If `extensionProviders` is empty (`[]`):** No reference ConfigMap is generated. You must still configure the extension provider in your Istio mesh config manually if using `externalAuthorization`.

---

## 2. mesh-networking

**What it does:** Controls how external traffic enters the cluster and reaches your services. It generates the Istio Gateway (the entry point), VirtualServices (routing rules with retries, timeouts, fault injection, CORS, mirroring, and canary routing), and DestinationRules (traffic policies like circuit breaking and load balancing).

**Why you need it:** Without this, there is no way for traffic from the external load balancer to reach your services through the mesh. This chart is the single place where all ingress routing is defined.

### 2.1 Domain

**What it is:** A base domain that all services share. Each service automatically gets `<subdomain>.<domain>` as its hostname.

**Why:** You define the domain once instead of repeating it for every service. When you move environments (dev → prod), you change one value.

**Values:**

```yaml
mesh-networking:
  meshNetworking:
    domain: "aib.vodafone.com"
```

**How it flows:**

| domain | Service name | subdomain (optional) | Resulting host |
|---|---|---|---|
| `aib.vodafone.com` | `argocd-server` | `argocd` | `argocd.aib.vodafone.com` |
| `aib.vodafone.com` | `mlrun-api` | `mlrun` | `mlrun.aib.vodafone.com` |
| `aib.vodafone.com` | `mlflow-server` | `mlflow` | `mlflow.aib.vodafone.com` |
| `aib.vodafone.com` | `kubeflow-central-dashboard` | `kubeflow` | `kubeflow.aib.vodafone.com` |
| `aib.vodafone.com` | `minio-console` | `minio` | `minio.aib.vodafone.com` |

---

### 2.2 Gateway

**What it is:** An Istio Gateway resource that configures the ingress gateway pod to listen on a port and accept traffic for `*.<domain>`.

**Why:** The Istio ingress gateway pod is just an Envoy proxy. Without a Gateway resource, it doesn't know which ports to listen on or which hosts to accept. This configuration tells it: "listen on port 80 for any subdomain of my domain."

**Values:**

```yaml
mesh-networking:
  meshNetworking:
    namespace: aib-platform              # Namespace where CRs are created (Gateway, VirtualService, etc.)

    gateway:
      enabled: true                    # Set to false to skip Gateway generation
      name: platform-gateway           # Name of the Gateway resource
      selector:                         # Which ingress gateway pods to configure
        istio: ingressgateway
      port:
        number: 80                      # Port to listen on
        name: http                      # Port name (used by Istio internally)
        protocol: HTTP                  # Protocol: HTTP, HTTPS, TCP, TLS
      # tls:                            # Optional — enable TLS termination
      #   mode: SIMPLE
      #   credentialName: my-tls-secret
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `namespace` | string | yes | — | Namespace where all mesh-networking CRs are created (Gateway, VirtualService, DestinationRule). Separate from `istio-system` where gateway pods run |
| `enabled` | bool | no | `true` | Whether to generate the Gateway resource |
| `name` | string | no | `platform-gateway` | Name of the Gateway resource |
| `selector` | map | no | `istio: ingressgateway` | Label selector matching the ingress gateway pods |
| `port.number` | int | yes | `80` | Port number the gateway listens on |
| `port.name` | string | yes | `http` | Port name identifier |
| `port.protocol` | string | yes | `HTTP` | Protocol: `HTTP`, `HTTPS`, `TCP`, `TLS` |
| `tls` | map | no | — | TLS configuration (only when protocol is HTTPS) |
| `tls.mode` | string | no | — | `SIMPLE` (one-way) or `MUTUAL` (two-way) |
| `tls.credentialName` | string | no | — | Name of the Kubernetes Secret containing TLS cert/key |

**Expected output:**

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-networking
    helm.sh/chart: mesh-networking-1.0.0
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.aib.vodafone.com"
```

> **Note:** The Gateway CR is created in the `aib-platform` namespace (or whichever namespace you set), but its `selector` matches the ingress gateway **pods** running in `istio-system`. Istio resolves selectors across the cluster.

**If `enabled` is `false`:** No Gateway resource is generated. You would need to provide your own Gateway or use an existing one.

---

### 2.3 Services (VirtualService)

**What it is:** For each entry in the `services` list, a VirtualService is generated that routes traffic from the Gateway to the target Kubernetes service.

**Why:** The Gateway accepts traffic, but doesn't know where to send it. VirtualServices define the routing rules — which host maps to which service, with optional path matching, retries, timeouts, fault injection, CORS, mirroring, and weighted routing.

**Values:**

```yaml
mesh-networking:
  meshNetworking:
    services: []
```

**How to use:**

```yaml
mesh-networking:
  meshNetworking:
    domain: "aib.vodafone.com"

    services:
      # Simple services — just name, serviceNamespace, port
      - name: argocd-server
        subdomain: argocd               # → argocd.aib.vodafone.com
        serviceNamespace: argocd
        port: 80

      - name: mlrun-api
        subdomain: mlrun                # → mlrun.aib.vodafone.com
        serviceNamespace: mlrun
        port: 8080

      # Advanced service — path routing, retries, timeout
      - name: model-api
        subdomain: model
        serviceNamespace: ai-namespace
        port: 8080
        pathPrefix: /api                 # Only match requests starting with /api
        timeout: 10s                     # Fail if no response within 10 seconds
        retries:
          attempts: 3                    # Retry up to 3 times
          perTryTimeout: 2s              # Each retry times out after 2 seconds
          retryOn: 5xx                   # Only retry on 5xx server errors
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Kubernetes Service name. Also used as the subdomain if `subdomain` is not set |
| `subdomain` | string | no | same as `name` | Override the subdomain portion of the host |
| `serviceNamespace` | string | no | `default` | Namespace where the Kubernetes Service runs (used for destination FQDN) |
| `port` | int | yes | — | Port number of the Kubernetes Service |
| `pathPrefix` | string | no | — | If set, only requests with this URI prefix are routed to this service |
| `headers` | map | no | — | If set, only requests matching these headers are routed |
| `timeout` | string | no | — | Overall request timeout (e.g., `10s`, `30s`) |
| `retries.attempts` | int | no | `3` | Number of retry attempts |
| `retries.perTryTimeout` | string | no | `2s` | Timeout for each retry attempt |
| `retries.retryOn` | string | no | — | Retry condition (e.g., `5xx`, `connect-failure`, `reset`) |

**Expected output** (simple entry):

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

**Expected output** (advanced entry with retries + timeout):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: model-api-vs
  namespace: aib-platform
spec:
  hosts:
    - "model.aib.vodafone.com"
  gateways:
    - aib-platform/platform-gateway
  http:
    - match:
        - uri:
            prefix: "/api"
      route:
        - destination:
            host: model-api.ai-namespace.svc.cluster.local
            port:
              number: 8080
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx
      timeout: 10s
```

**If `services` is empty (`[]`):** No VirtualService resources are generated. The Gateway exists but routes no traffic.

---

### 2.4 DestinationRule (Traffic Policy)

**What it is:** An Istio resource that defines traffic policies for a destination service — load balancing algorithm, connection pool limits, and circuit breaking (outlier detection).

**Why:** VirtualServices define *where* traffic goes. DestinationRules define *how* it gets there. Without them, Istio uses default round-robin with no circuit breaking. For production AI workloads, you want to control connection limits and eject unhealthy instances.

**When is it generated?** Only when a service has a `trafficPolicy` field. If you don't set `trafficPolicy`, no DestinationRule is created for that service.

**How to use:**

```yaml
mesh-networking:
  meshNetworking:
    services:
      - name: model-api
        subdomain: model
        serviceNamespace: ai-namespace
        port: 8080
        trafficPolicy:
          loadBalancer: ROUND_ROBIN         # ROUND_ROBIN | LEAST_REQUEST | RANDOM | PASSTHROUGH
          connectionPool:
            tcp:
              maxConnections: 100           # Max TCP connections to this service
            http:
              h2UpgradePolicy: DEFAULT      # HTTP/2 upgrade policy
              maxRequestsPerConnection: 100 # Close connection after 100 requests
              maxRequests: 2048             # Max concurrent HTTP requests
          outlierDetection:
            consecutive5xxErrors: 5         # Eject after 5 consecutive 5xx errors
            consecutive4xxErrors: 0         # 0 = disabled for 4xx
            interval: 30s                   # Check interval
            baseEjectionTime: 30s           # How long ejected instance stays out
            maxEjectionPercent: 100         # Max % of hosts that can be ejected
            splitExternalLocalOriginErrors: false
          tls:
            mode: ISTIO_MUTUAL              # Use Istio's auto-generated mTLS certs
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `trafficPolicy.loadBalancer` | string | no | — | Load balancing algorithm: `ROUND_ROBIN`, `LEAST_REQUEST`, `RANDOM`, `PASSTHROUGH` |
| `trafficPolicy.connectionPool.tcp.maxConnections` | int | no | — | Maximum TCP connections |
| `trafficPolicy.connectionPool.http.h2UpgradePolicy` | string | no | — | HTTP/2 upgrade: `DEFAULT`, `DO_NOT_UPGRADE`, `UPGRADE` |
| `trafficPolicy.connectionPool.http.maxRequestsPerConnection` | int | no | — | Max requests per connection before closing |
| `trafficPolicy.connectionPool.http.maxRequests` | int | no | — | Max concurrent HTTP requests |
| `trafficPolicy.outlierDetection.consecutive5xxErrors` | int | no | — | Consecutive 5xx errors before ejection |
| `trafficPolicy.outlierDetection.consecutive4xxErrors` | int | no | — | Consecutive 4xx errors before ejection (0 = disabled) |
| `trafficPolicy.outlierDetection.interval` | string | no | — | Health check interval |
| `trafficPolicy.outlierDetection.baseEjectionTime` | string | no | — | Duration an ejected host stays out |
| `trafficPolicy.outlierDetection.maxEjectionPercent` | int | no | — | Max percentage of hosts that can be ejected |
| `trafficPolicy.tls` | map | no | — | TLS settings for upstream connections |

**Expected output:**

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
    tls:
      mode: ISTIO_MUTUAL
```

**If `trafficPolicy` is not set on a service:** No DestinationRule is generated for that service. Istio defaults apply.

---

### 2.5 Fault Injection

**What it is:** Injects artificial delays or HTTP errors into requests matching a VirtualService route. Configured per service in the `fault` field.

**Why:** Fault injection lets you test how your system handles failures *before* they happen in production. You can simulate slow model inference endpoints, upstream timeouts, or service outages to validate retry policies, circuit breakers, and graceful degradation.

**How to use:**

```yaml
mesh-networking:
  meshNetworking:
    services:
      - name: model-api
        serviceNamespace: ai-namespace
        port: 8080
        fault:
          delay:
            percentage: 10          # Inject delay into 10% of requests
            fixedDelay: 5s          # Add 5 seconds latency
          abort:
            percentage: 5           # Abort 5% of requests
            httpStatus: 503         # Return HTTP 503
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `fault.delay.percentage` | float | yes | — | Percentage of requests to delay (0-100) |
| `fault.delay.fixedDelay` | string | yes | — | Fixed delay duration (e.g., `5s`, `500ms`) |
| `fault.abort.percentage` | float | yes | — | Percentage of requests to abort (0-100) |
| `fault.abort.httpStatus` | int | yes | — | HTTP status code to return for aborted requests |

**Expected output** (inside the VirtualService HTTP route):

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
```

> **Warning:** Fault injection is for testing/staging environments. Remove or set percentages to 0 before deploying to production.

---

### 2.6 CORS Policy

**What it is:** Cross-Origin Resource Sharing (CORS) configuration applied at the VirtualService level.

**Why:** If your AI platform has web UIs (dashboards, notebooks) that make API calls to services on different subdomains, the browser enforces CORS. Without a CORS policy, cross-origin API requests are blocked.

**How to use:**

```yaml
mesh-networking:
  meshNetworking:
    services:
      - name: model-api
        serviceNamespace: ai-namespace
        port: 8080
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

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `corsPolicy.allowOrigins` | list | yes | — | Origins allowed to make cross-origin requests |
| `corsPolicy.allowMethods` | list | no | — | Allowed HTTP methods for cross-origin requests |
| `corsPolicy.allowHeaders` | list | no | — | Allowed request headers |
| `corsPolicy.exposeHeaders` | list | no | — | Response headers the browser can access |
| `corsPolicy.maxAge` | string | no | — | How long preflight results are cached |
| `corsPolicy.allowCredentials` | bool | no | — | Whether credentials (cookies, auth headers) are allowed |

**Expected output** (inside the VirtualService HTTP route):

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

---

### 2.7 Traffic Mirroring

**What it is:** Sends a copy of live traffic to a secondary service for testing, without affecting the primary response.

**Why:** Before deploying a new model version or service update, you can mirror production traffic to the new version to compare behavior, validate correctness, or load test — without any risk to production users. The mirrored requests are "fire and forget"; the client always gets the response from the primary destination.

**How to use:**

```yaml
mesh-networking:
  meshNetworking:
    services:
      - name: model-api
        serviceNamespace: ai-namespace
        port: 8080
        mirror:
          host: model-api-v2.ai-namespace.svc.cluster.local
          port: 8080
          percentage: 50          # Mirror 50% of traffic
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `mirror.host` | string | yes | — | FQDN of the mirror destination service |
| `mirror.port` | int | yes | — | Port of the mirror destination service |
| `mirror.percentage` | float | no | `100` | Percentage of traffic to mirror (0-100) |

**Expected output** (inside the VirtualService HTTP route):

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

---

### 2.8 Weighted Routing (Canary)

**What it is:** Splits traffic between multiple destinations (subsets) with configurable weights.

**Why:** Canary deployments let you gradually shift traffic to a new version — e.g., 10% to the canary, 90% to stable. If the canary shows errors, you roll back by changing weights. This is safer than a full rollout.

**How to use:**

```yaml
mesh-networking:
  meshNetworking:
    services:
      - name: model-api
        subdomain: model
        serviceNamespace: ai-namespace
        port: 8080                    # Still required for schema, but overridden by weightedRouting
        weightedRouting:
          - host: model-api.ai-namespace.svc.cluster.local
            port: 8080
            subset: stable
            weight: 90
          - host: model-api.ai-namespace.svc.cluster.local
            port: 8080
            subset: canary
            weight: 10
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `weightedRouting` | list | no | — | If set, overrides the default single-destination route |
| `weightedRouting[].host` | string | yes | — | FQDN of the destination service |
| `weightedRouting[].port` | int | yes | — | Port of the destination service |
| `weightedRouting[].subset` | string | no | — | DestinationRule subset name (e.g., `stable`, `canary`) |
| `weightedRouting[].weight` | int | yes | — | Percentage of traffic (all weights must sum to 100) |

> **Note:** Subsets (`stable`, `canary`) must be defined in a DestinationRule. You can define them using the `trafficPolicy` on a separate DestinationRule, or create them manually.

**Expected output** (inside the VirtualService HTTP route):

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

---

## 3. mesh-egress

**What it does:** Controls outbound traffic from your services to external APIs (outside the cluster). By default, Istio blocks or does not track traffic to unknown external hosts. This chart registers external hosts so the mesh can resolve, route, and observe them.

**Why you need it:** If your AI services call external APIs (OpenAI, HuggingFace, cloud storage, etc.), you must register those hosts as ServiceEntries. Without this, Istio's sidecar proxy will either block the traffic (in `REGISTRY_ONLY` outbound mode) or let it pass untracked (in `ALLOW_ANY` mode). ServiceEntries give you visibility and control.

### 3.1 ServiceEntry

**What it is:** An Istio resource that registers an external host so the mesh knows about it.

**Why:** Once registered, external traffic appears in Istio metrics/tracing, and you can apply traffic policies (retries, timeouts) to it.

**Values:**

```yaml
mesh-egress:
  meshEgress:
    services: []
```

**How to use:**

```yaml
mesh-egress:
  meshEgress:
    services:
      - name: openai
        enabled: true                    # Set to false to disable without deleting
        namespace: mlrun       # Namespace for the ServiceEntry resource
        host: api.openai.com             # External hostname
        port: 443                        # External port
        resolution: DNS                  # How to resolve the host: DNS | STATIC | NONE
        location: MESH_EXTERNAL          # MESH_EXTERNAL (outside mesh) | MESH_INTERNAL

      # Additional ports example
      - name: custom-api
        enabled: true
        namespace: mlrun
        host: api.custom.com
        port: 443
        resolution: DNS
        additionalPorts:
          - port: 8443
            name: grpc
            protocol: GRPC
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Name used for the ServiceEntry resource (`<name>-se`) |
| `enabled` | bool | yes | — | Whether to generate this ServiceEntry. Set `false` to skip |
| `namespace` | string | no | inherits `meshEgress.namespace` | Namespace for the ServiceEntry resource |
| `host` | string | yes | — | External hostname (e.g., `api.openai.com`) |
| `port` | int | yes | — | Primary port number |
| `resolution` | string | no | `DNS` | How Istio resolves the host. `DNS` for most external services |
| `location` | string | no | `MESH_EXTERNAL` | `MESH_EXTERNAL` for external services, `MESH_INTERNAL` for internal services registered manually |
| `additionalPorts` | list | no | `[]` | Extra ports beyond the primary one |

> **Note:** The primary port protocol is auto-determined by the template: `HTTP` when `tls.mode` is set (TLS origination), `TLS` otherwise (passthrough). The `additionalPorts` entries require an explicit `protocol` field.

**Expected output:**

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: openai-se
  namespace: mlrun
spec:
  hosts:
    - api.openai.com
  location: MESH_EXTERNAL
  ports:
    - number: 443
      name: tls
      protocol: TLS
  resolution: DNS
```

**If `services` is empty (`[]`):** No ServiceEntry resources are generated. External traffic behavior depends on Istio's `outboundTrafficPolicy` setting (default is `ALLOW_ANY`).

---

### 3.2 Egress Gateway Routing

**What it is:** A shared egress gateway that routes all external traffic through a dedicated egress gateway pod. It generates a single Istio Gateway, per-service VirtualServices, and a DestinationRule with subsets for each service.

**Why:** Routing through an egress gateway gives you a single exit point for all outbound traffic. This is useful for:
- **Security auditing** — all external traffic passes through one point
- **Network policies** — restrict which pods can reach external APIs
- **Compliance** — some regulations require a controlled egress point

**When is it generated?** When `gateway.enabled` is `true`.

**How to use:**

```yaml
mesh-egress:
  meshEgress:
    namespace: aib-platform              # Namespace where CRs are created
    gateway:
      enabled: true
      name: platform-egress-gateway
      serviceNamespace: istio-system     # Namespace where egress gateway pods run
      selector:
        istio: egressgateway

    services:
      - name: openai
        enabled: true
        namespace: my-namespace
        host: api.openai.com
        port: 443
        resolution: DNS
        location: MESH_EXTERNAL
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `namespace` | string | yes | — | Namespace where all mesh-egress CRs are created (Gateway, VirtualService, DestinationRule). Separate from where gateway pods run |
| `gateway.enabled` | bool | no | `false` | Whether to create the shared egress gateway |
| `gateway.name` | string | no | `platform-egress-gateway` | Name of the Gateway resource |
| `gateway.serviceNamespace` | string | no | `istio-system` | Namespace where egress gateway pods run (used for `.svc.cluster.local` references) |
| `gateway.selector` | map | yes (if enabled) | — | Label selector for egress gateway pods |

**Expected output** (port 443 — TLS passthrough):

Gateway:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: platform-egress-gateway
  namespace: aib-platform
spec:
  selector:
    istio: egressgateway
  servers:
    - port:
        number: 443
        name: openai-tls
        protocol: TLS
      hosts:
        - api.openai.com
      tls:
        mode: PASSTHROUGH
```

> **Note:** The egress Gateway CR lives in `aib-platform`, but its `selector` matches egress gateway pods in `istio-system`.

VirtualService:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: openai-egress-vs
  namespace: aib-platform
spec:
  hosts:
    - api.openai.com
  gateways:
    - mesh
    - platform-egress-gateway
  tls:
    - match:
        - gateways:
            - mesh
          port: 443
          sniHosts:
            - api.openai.com
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: openai
            port:
              number: 443
    - match:
        - gateways:
            - platform-egress-gateway
          port: 443
          sniHosts:
            - api.openai.com
      route:
        - destination:
            host: api.openai.com
            port:
              number: 443
```

DestinationRule:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: platform-egress-gateway-dr
  namespace: aib-platform
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
    - name: openai
```

**If `gateway.enabled` is `false`:** Only ServiceEntry resources are generated. Traffic goes directly from the application sidecar to the external host.

---

### 3.3 TLS Origination (HTTP port 80)

**What it is:** When an external service uses port 80 (HTTP) but you want the egress gateway to upgrade the connection to TLS before sending it out, you configure TLS origination. The application sends plain HTTP; the egress gateway originates (initiates) TLS to the external host.

**Why:** Some external services accept both HTTP and HTTPS, or your internal applications only speak HTTP. TLS origination lets you:
- **Encrypt traffic** leaving the cluster even when the app sends HTTP
- **Centralize certificate management** at the egress gateway instead of every application
- **Enforce HTTPS** for all outbound traffic as a platform policy

**How it works:**

```
App (HTTP) → sidecar → egress gateway → [TLS origination] → external host (HTTPS)
```

The key difference from TLS passthrough (port 443):
- **Passthrough** (no `tls` field): traffic is already encrypted, the gateway forwards it as-is using SNI routing
- **TLS origination** (`tls.mode` set): traffic is plain HTTP internally, the gateway opens a new TLS connection to the external host

**How to use:**

```yaml
mesh-egress:
  meshEgress:
    namespace: aib-platform
    gateway:
      enabled: true
      name: platform-egress-gateway
      serviceNamespace: istio-system
      selector:
        istio: egressgateway

    services:
      - name: example-http-service
        enabled: true
        namespace: my-namespace
        host: example.external.com
        port: 80
        resolution: DNS
        location: MESH_EXTERNAL
        tls:
          mode: SIMPLE              # SIMPLE | MUTUAL | ISTIO_MUTUAL
          # sni: example.external.com  # Optional — override SNI hostname
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `tls.mode` | string | yes | — | TLS mode for origination: `SIMPLE` (one-way TLS), `MUTUAL` (mTLS with client cert), `ISTIO_MUTUAL` (use Istio certs) |
| `tls.sni` | string | no | — | Override the SNI hostname sent during TLS handshake |

**Expected output** (port 80 with `tls.mode: SIMPLE`):

Gateway:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: platform-egress-gateway
  namespace: aib-platform
spec:
  selector:
    istio: egressgateway
  servers:
    - port:
        number: 80
        name: example-http-service-http
        protocol: HTTP
      hosts:
        - example.external.com
```

VirtualService:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: example-http-service-egress-vs
  namespace: aib-platform
spec:
  hosts:
    - example.external.com
  gateways:
    - mesh
    - platform-egress-gateway
  http:
    - match:
        - gateways:
            - mesh
          port: 80
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: example-http-service
            port:
              number: 80
    - match:
        - gateways:
            - platform-egress-gateway
          port: 80
      route:
        - destination:
            host: example.external.com
            port:
              number: 80
```

DestinationRule for TLS origination:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: example-http-service-tls-origination-dr
  namespace: aib-platform
spec:
  host: example.external.com
  trafficPolicy:
    portLevelSettings:
      - port:
          number: 80
        tls:
          mode: SIMPLE
```

**If `tls` is not set on a service:** Standard TLS passthrough is used (the existing behavior for port 443 services).

---

## Installation

### Prerequisites

- Kubernetes cluster with Istio installed (`base`, `istiod`, ingress/egress gateways)
- Helm 3.x
- The `foundation` chart deployed first (creates namespaces with `istio-injection: enabled`)
- Customer-provisioned external load balancer pointing to the Istio ingress gateway pods

### Deploy as umbrella chart

```bash
# Build subchart dependencies
helm dependency build cloud/aib-platform

# Install with environment-specific values
helm install aib-platform cloud/aib-platform \
  -f cloud/values/dev/aib-platform-values.yaml \
  -n aib-platform

# Upgrade after changing values
helm upgrade aib-platform cloud/aib-platform \
  -f cloud/values/dev/aib-platform-values.yaml \
  -n aib-platform

# Dry run — preview generated YAML without applying
helm template aib-platform cloud/aib-platform \
  -f cloud/values/dev/aib-platform-values.yaml
```

### Deploy subcharts individually

```bash
helm install mesh-security cloud/aib-platform/mesh-security \
  -f my-security-values.yaml -n aib-platform

helm install mesh-networking cloud/aib-platform/mesh-networking \
  -f my-networking-values.yaml -n aib-platform

helm install mesh-egress cloud/aib-platform/mesh-egress \
  -f my-egress-values.yaml -n aib-platform
```

---

## Environment Overrides

Per-environment values files live in `cloud/values/<env>/`:

```
values/
└── dev/
    ├── aib-platform-values.yaml         # All mesh config for dev
    ├── istiod-values.yaml               # Istiod resource limits
    ├── istio-ingressgateway-values.yaml  # Ingress gateway pod config
    └── istio-egressgateway-values.yaml   # Egress gateway pod config
```

To add a new environment, create a new directory (e.g., `values/prod/`) with its own `aib-platform-values.yaml`. Example differences between environments:

| Setting | Dev | Prod |
|---|---|---|
| `domain` | `aib.vodafone.com` | `aib.vodafone.com` |
| `mtls.mode` | `STRICT` | `STRICT` |
| `gateway.tls` | not set (HTTP) | `mode: SIMPLE` with TLS cert |
| `retries.attempts` | 1 | 3 |
| `rateLimiting` | relaxed (1000 req/min) | strict (100 req/min per model) |
| `authorizationPolicies` | basic namespace rules | fine-grained JWT + IP policies |
| `fault injection` | enabled for testing | disabled |
| `services` | argocd only | argocd, mlrun, mlflow, kubeflow, minio |
| `egress services` | none | openai, huggingface |

---

## Dev Example & Expected Output

The following is the full dev values file (`values/dev/aib-platform-values.yaml`) and the exact Kubernetes resources it generates.

### Dev Values

```yaml
## Dev environment - AI Platform mesh configuration

## 1. mesh-security
mesh-security:
  meshSecurity:
    mtls:
      enabled: true
      mode: STRICT
      namespaces:
        - name: argocd
        - name: mlrun

    authorizationPolicies:
      - name: allow-argocd
        namespace: argocd
        action: ALLOW
        selector:
          app: argocd-server
        rules:
          - from:
              - namespaces:
                  - aib-platform
                  - argocd

    requestAuthentication:
      - name: jwt-auth
        namespace: mlrun
        selector:
          app: mlrun-api
        jwtRules:
          - issuer: "https://auth.aib.vodafone.com"
            jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
            forwardOriginalToken: true

    rateLimiting:
      - name: mlrun-ratelimit
        namespace: mlrun
        selector:
          app: mlrun-api
        maxTokens: 100
        tokensPerFill: 50
        fillInterval: "60s"

## 2. mesh-networking
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

      - name: mlrun-api
        subdomain: mlrun
        serviceNamespace: mlrun
        port: 8080
        pathPrefix: /api
        timeout: 10s
        retries:
          attempts: 3
          perTryTimeout: 2s
          retryOn: 5xx

## 3. mesh-egress
mesh-egress:
  meshEgress:
    namespace: aib-platform
    gateway:
      enabled: true
      name: platform-egress-gateway
      serviceNamespace: istio-system
      selector:
        istio: egressgateway

    services:
      - name: google
        enabled: true
        namespaces:
          - argocd
        host: google.com
        port: 443
        resolution: DNS
        location: MESH_EXTERNAL
```

### Expected Output — mesh-security

**PeerAuthentication** (2 resources — one per namespace):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: argocd-mtls
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: mlrun-mtls
  namespace: mlrun
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  mtls:
    mode: STRICT
```

**AuthorizationPolicy** (1 resource):

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-argocd
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  selector:
    matchLabels:
      app: argocd-server
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces:
              - aib-platform
              - argocd
```

**RequestAuthentication** (1 resource):

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: mlrun
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  selector:
    matchLabels:
      app: mlrun-api
  jwtRules:
    - issuer: "https://auth.aib.vodafone.com"
      jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
      forwardOriginalToken: true
```

**EnvoyFilter — Rate Limit** (1 resource):

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: mlrun-ratelimit-ratelimit
  namespace: mlrun
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-security
    helm.sh/chart: mesh-security-1.0.0
spec:
  workloadSelector:
    labels:
      app: mlrun-api
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.local_ratelimit
          typed_config:
            "@type": type.googleapis.com/udpa.type.v1.TypedStruct
            type_url: type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
            value:
              stat_prefix: http_local_rate_limiter
              token_bucket:
                max_tokens: 100
                tokens_per_fill: 50
                fill_interval: 60s
              filter_enabled:
                runtime_key: local_rate_limit_enabled
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              filter_enforced:
                runtime_key: local_rate_limit_enforced
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              response_headers_to_add:
                - append_action: OVERWRITE_IF_EXISTS_OR_ADD
                  header:
                    key: x-local-rate-limit
                    value: "true"
```

### Expected Output — mesh-networking

> All CRs created in `aib-platform` namespace. Gateway selector matches pods in `istio-system`.

**Gateway** (1 resource):

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-networking
    helm.sh/chart: mesh-networking-1.0.0
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.aib.vodafone.com"
```

**VirtualService — argocd-server** (CR in `aib-platform`, routes to service in `argocd`):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: argocd-server-vs
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-networking
    helm.sh/chart: mesh-networking-1.0.0
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

**VirtualService — mlrun-api** (CR in `aib-platform`, routes to service in `mlrun`):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mlrun-api-vs
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-networking
    helm.sh/chart: mesh-networking-1.0.0
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

### Expected Output — mesh-egress

> CRs in `aib-platform`. Service host references point to pods in `istio-system`.

**ServiceEntry** (1 resource — created in `argocd` namespace per `namespaces` list):

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: google-se
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-egress
    helm.sh/chart: mesh-egress-1.0.0
spec:
  hosts:
    - google.com
  location: MESH_EXTERNAL
  ports:
    - number: 443
      name: tls
      protocol: TLS
  resolution: DNS
```

**Egress Gateway** (1 resource — CR in `aib-platform`, selector matches pods in `istio-system`):

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: platform-egress-gateway
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-egress
    helm.sh/chart: mesh-egress-1.0.0
spec:
  selector:
    istio: egressgateway
  servers:
    ## TLS passthrough — forward encrypted traffic as-is
    - port:
        number: 443
        name: google-tls
        protocol: TLS
      hosts:
        - google.com
      tls:
        mode: PASSTHROUGH
```

**Egress VirtualService** (1 resource — CR in `aib-platform`):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: google-egress-vs
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-egress
    helm.sh/chart: mesh-egress-1.0.0
spec:
  hosts:
    - google.com
  gateways:
    - mesh
    - platform-egress-gateway
  tls:
    - match:
        - gateways:
            - mesh
          port: 443
          sniHosts:
            - google.com
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: google
            port:
              number: 443
    - match:
        - gateways:
            - platform-egress-gateway
          port: 443
          sniHosts:
            - google.com
      route:
        - destination:
            host: google.com
            port:
              number: 443
```

**Egress DestinationRule** (1 resource — CR in `aib-platform`, host points to pods in `istio-system`):

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: platform-egress-gateway-dr
  namespace: aib-platform
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: cloud-platform
    app.kubernetes.io/component: mesh-egress
    helm.sh/chart: mesh-egress-1.0.0
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
    - name: google
      labels:
        istio: egressgateway
```

### Namespace Summary

| Resource | Namespace | Why |
|---|---|---|
| Gateway (ingress) | `aib-platform` | CR namespace — configured via `meshNetworking.namespace` |
| Gateway (egress) | `aib-platform` | CR namespace — configured via `meshEgress.namespace` |
| VirtualService (ingress) | `aib-platform` | CR namespace — always `meshNetworking.namespace` |
| VirtualService (egress) | `aib-platform` | CR namespace — always `meshEgress.namespace` |
| DestinationRule (egress) | `aib-platform` | CR namespace — always `meshEgress.namespace` |
| ServiceEntry | `argocd` | Per-service `namespaces` list — where the workload needs DNS resolution |
| PeerAuthentication | `argocd`, `mlrun` | Per-namespace — applied where workloads run |
| AuthorizationPolicy | `argocd` | Per-policy — applied where the target workload runs |
| RequestAuthentication | `mlrun` | Per-policy — applied where the target workload runs |
| EnvoyFilter (rate limit) | `mlrun` | Per-policy — applied where the target workload runs |
| Ingress gateway pods | `istio-system` | Istio control plane namespace — not managed by this chart |
| Egress gateway pods | `istio-system` | Istio control plane namespace — referenced via `gateway.serviceNamespace` |

---

## Full Values Reference

Complete `values.yaml` with all available options:

```yaml
mesh-security:
  meshSecurity:
    mtls:
      enabled: true                      # Generate PeerAuthentication resources
      mode: STRICT                       # Default mTLS mode: STRICT | PERMISSIVE | DISABLE
      namespaces:                        # Per-namespace PeerAuthentication
        - name: mlrun             # Required — namespace name
          # mode: PERMISSIVE             # Optional — override default mode
          # selector:                    # Optional — target specific pods
          #   app: mlrun-api
          # portLevelMtls:              # Optional — override per port
          #   8080:
          #     mode: PERMISSIVE

    authorizationPolicies:               # List of AuthorizationPolicy resources
      - name: policy-name                # Required — resource name
        namespace: mlrun          # Required — target namespace
        action: ALLOW                    # Optional — ALLOW | DENY | CUSTOM
        # provider: ext-authz-name      # Optional — for CUSTOM action only
        selector:                        # Optional — target specific pods
          app: mlrun-api
        rules:                           # Required — access rules
          - from:
              - namespaces: [ns1, ns2]
                # notNamespaces: [ns3]
                principals: [sa1]
                # notPrincipals: [sa2]
                # requestPrincipals: ["https://issuer/*"]
                # notRequestPrincipals: []
                # ipBlocks: ["10.0.0.0/8"]
                # notIpBlocks: ["10.0.99.0/24"]
            to:
              - ports: ["8080"]
                # notPorts: ["9090"]
                methods: [GET, POST]
                # notMethods: [DELETE]
                paths: [/api]
                # notPaths: ["/api/admin/*"]
                # hosts: ["service.example.com"]
                # notHosts: []
            # when:
            #   - key: request.auth.claims[role]
            #     values: [admin]
            #     # notValues: [guest]

    requestAuthentication:               # List of RequestAuthentication resources
      - name: jwt-name                   # Required — resource name
        namespace: mlrun          # Required — target namespace
        selector:                        # Optional — target specific pods
          app: mlrun-api
        jwtRules:                        # Required — JWT validation rules
          - issuer: "https://..."        # Required — token issuer
            jwksUri: "https://..."       # Required — JWKS endpoint
            audiences: [aud1]            # Optional — expected audiences
            forwardOriginalToken: true   # Optional — forward token to app
            outputPayloadToHeader: name  # Optional — decoded payload header

    rateLimiting:                        # List of per-namespace rate limits
      - name: ratelimit-name             # Required — resource name
        namespace: ai-namespace          # Required — target namespace
        # selector:                      # Optional — target specific pods
        #   app: model-api
        maxTokens: 100                   # Optional — max burst size (default: 100)
        tokensPerFill: 50                # Optional — tokens per interval (default: 100)
        fillInterval: "60s"              # Optional — refill interval (default: 60s)
        # statusCode: 429                # Optional — HTTP status on limit (default: 429)

mesh-networking:
  meshNetworking:
    namespace: aib-platform                   # Required — namespace where CRs are created
    domain: "aib.vodafone.com"                # Required — base domain for all services

    gateway:
      enabled: true                      # Generate Gateway resource
      name: platform-gateway             # Gateway resource name
      selector:                          # Ingress gateway pod selector
        istio: ingressgateway
      port:
        number: 80                       # Listen port
        name: http                       # Port name
        protocol: HTTP                   # Protocol: HTTP | HTTPS | TCP | TLS
      # tls:                             # Optional — TLS termination
      #   mode: SIMPLE
      #   credentialName: tls-secret

    services:                            # List of services to route to
      - name: argocd-server              # Required — K8s Service name
        subdomain: argocd                # Optional — override subdomain (default: name)
        serviceNamespace: argocd         # Optional — namespace where the K8s Service runs (default: "default")
        port: 80                         # Required — Service port
        # pathPrefix: /api               # Optional — URI prefix match
        # headers: {}                    # Optional — header match conditions
        # timeout: 10s                   # Optional — request timeout
        # retries:                       # Optional — retry policy
        #   attempts: 3
        #   perTryTimeout: 2s
        #   retryOn: 5xx
        # fault:                         # Optional — fault injection
        #   delay:
        #     percentage: 10
        #     fixedDelay: 5s
        #   abort:
        #     percentage: 5
        #     httpStatus: 503
        # corsPolicy:                    # Optional — CORS configuration
        #   allowOrigins:
        #     - exact: "https://app.example.com"
        #   allowMethods: [GET, POST]
        #   allowHeaders: [Authorization]
        #   maxAge: "24h"
        # mirror:                        # Optional — traffic mirroring
        #   host: service-v2.ns.svc.cluster.local
        #   port: 8080
        #   percentage: 50
        # weightedRouting:               # Optional — canary / weighted routing
        #   - host: svc.ns.svc.cluster.local
        #     port: 8080
        #     subset: stable
        #     weight: 90
        #   - host: svc.ns.svc.cluster.local
        #     port: 8080
        #     subset: canary
        #     weight: 10
        # trafficPolicy:                 # Optional — generates DestinationRule
        #   loadBalancer: ROUND_ROBIN
        #   connectionPool:
        #     tcp:
        #       maxConnections: 100
        #     http:
        #       maxRequestsPerConnection: 100
        #       maxRequests: 2048
        #   outlierDetection:
        #     consecutive5xxErrors: 5
        #     consecutive4xxErrors: 0
        #     interval: 30s
        #     baseEjectionTime: 30s
        #     maxEjectionPercent: 100
        #   tls:
        #     mode: ISTIO_MUTUAL

mesh-egress:
  meshEgress:
    namespace: aib-platform                  # Required — namespace where CRs are created
    gateway:                             # Shared egress gateway (one for all services)
      enabled: true                      # Generate Gateway + VirtualServices + DestinationRule
      name: platform-egress-gateway      # Gateway resource name
      serviceNamespace: istio-system     # Namespace where egress gateway pods run
      selector:                          # Egress gateway pod selector
        istio: egressgateway

    services:                            # List of external services
      # Port 443 — TLS passthrough (default behavior)
      - name: openai                     # Required — resource name prefix
        enabled: true                    # Required — set false to skip
        # namespace: my-namespace        # Optional — default: inherits meshEgress.namespace
        host: api.openai.com             # Required — external hostname
        port: 443                        # Required — external port
        # resolution: DNS                # Optional — default: DNS
        # location: MESH_EXTERNAL        # Optional — default: MESH_EXTERNAL
        # additionalPorts: []            # Optional — extra ports

      # Port 80 — TLS origination (egress gateway upgrades HTTP→TLS)
      - name: example-http-service
        enabled: true
        host: example.external.com
        port: 80
        resolution: DNS
        location: MESH_EXTERNAL
        tls:                             # Optional — enables TLS origination
          mode: SIMPLE                   # SIMPLE | MUTUAL | ISTIO_MUTUAL
          # sni: example.external.com    # Optional — override SNI hostname
```

---

## Notes

**Applying STRICT mTLS on the istio-system namespace itself is generally not recommended.** Here's why:

- istio-system hosts control-plane components (istiod, ingress gateway, etc.) that need to accept connections from sidecars across all namespaces during initial setup and certificate bootstrapping.
- Setting STRICT there can break mTLS bootstrapping — a sidecar that hasn't yet received its certificate can't connect to istiod if istiod requires mTLS.
- The Istio ingress gateway also receives external plaintext traffic from the ELB (as shown in the architecture), so it can't enforce mTLS on its inbound port.

**What to do instead:**
- Apply PeerAuthentication with STRICT mode on your workload namespaces (where your platform services run).
- Leave istio-system at PERMISSIVE (the default), or apply STRICT only to specific workloads within it that you know are mesh-internal only.
