# mesh-security — Istio Security Policies

## What Is This Chart?

Think of your Kubernetes cluster as a big apartment building. Every pod (application) is a tenant. Without security, every tenant can walk into every other tenant's apartment, read their mail, and pretend to be anyone. That's a disaster.

**mesh-security** is the building's security system. It does four things:

1. **Locks all doors** (mTLS) — Forces every service-to-service conversation to be encrypted and authenticated
2. **Checks ID badges** (Authorization Policies) — Controls exactly who can talk to whom, on which ports, using which methods
3. **Validates visitor passes** (JWT Authentication) — Verifies that incoming requests carry a valid token from a trusted identity provider
4. **Limits how often someone can knock** (Rate Limiting) — Prevents any single caller from overwhelming a service with too many requests

Without this chart, your mesh is wide open — any pod can call any other pod, over plaintext, with no identity verification.

---

## Chart Structure

```
mesh-security/
├── Chart.yaml                        # Chart metadata (name, version)
├── values.yaml                       # All configurable options with defaults
├── README.md                         # This file
└── templates/
    ├── _helpers.tpl                  # Shared Helm template helpers (labels)
    ├── peer-authentication.yaml      # Generates PeerAuthentication resources (mTLS)
    ├── authorization-policy.yaml     # Generates AuthorizationPolicy resources (access control)
    ├── request-authentication.yaml   # Generates RequestAuthentication resources (JWT)
    └── rate-limit.yaml              # Generates EnvoyFilter resources (rate limiting)
```

**How templates work:** Every template uses Helm `range` loops to iterate over lists in `values.yaml`. You never edit templates — you only edit values. If a list is empty (`[]`), that template produces zero Kubernetes resources.

---

## Prerequisites

- Istio installed in your cluster (istiod running)
- Namespaces with `istio-injection: enabled` label (so sidecars are injected)
- Helm 3.x

---

## 1. PeerAuthentication (mTLS)

### What Is mTLS?

Normal HTTP traffic is like sending a postcard — anyone in the middle can read it. **TLS** encrypts traffic so only the sender and receiver can read it (like putting the postcard in a sealed envelope). **mTLS** (mutual TLS) goes further — both sides prove who they are with certificates. It's like both people showing their ID before opening the envelope.

In Istio, every sidecar proxy automatically gets a certificate from istiod. PeerAuthentication tells Istio whether to **require** that certificates are used.

### The Three Modes

| Mode | What It Does | When To Use |
|---|---|---|
| `STRICT` | **Reject** any connection that doesn't use mTLS | Production — full security |
| `PERMISSIVE` | **Accept** both plaintext and mTLS | Migration — when some services don't have sidecars yet |
| `DISABLE` | **Turn off** mTLS entirely | Debugging only — never in production |

### How To Use

```yaml
meshSecurity:
  mtls:
    enabled: true         # Set to false to skip generating any PeerAuthentication
    mode: STRICT          # Default mode for all namespaces below
    namespaces:
      # Simplest — apply STRICT mTLS to an entire namespace
      - name: ai-namespace

      # Override mode for a specific namespace (e.g., during migration)
      - name: legacy-namespace
        mode: PERMISSIVE

      # Target only one specific workload (not the whole namespace)
      - name: ai-namespace
        selector:
          app: model-api
        mode: STRICT

      # Allow plaintext on one specific port (useful for health checks)
      - name: ai-namespace
        portLevelMtls:
          8080:
            mode: PERMISSIVE    # Port 8080 accepts plaintext
                                # All other ports still require mTLS
```

### What Gets Generated

For each item in the `namespaces` list, one `PeerAuthentication` resource is created:

```yaml
# Input: { name: ai-namespace }  with global mode: STRICT
# Output:
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: ai-namespace-mtls
  namespace: ai-namespace
spec:
  mtls:
    mode: STRICT
```

```yaml
# Input: { name: ai-namespace, selector: { app: model-api }, portLevelMtls: { 8080: { mode: PERMISSIVE } } }
# Output:
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: ai-namespace-mtls
  namespace: ai-namespace
spec:
  selector:
    matchLabels:
      app: model-api
  mtls:
    mode: STRICT
  portLevelMtls:
    8080:
      mode: PERMISSIVE
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `mtls.enabled` | bool | no | `true` | Whether to generate any PeerAuthentication resources |
| `mtls.mode` | string | no | `STRICT` | Default mode applied when a namespace doesn't specify its own |
| `mtls.namespaces` | list | yes | `[]` | Namespaces to generate PeerAuthentication for |
| `mtls.namespaces[].name` | string | yes | — | The namespace name |
| `mtls.namespaces[].mode` | string | no | inherits `mtls.mode` | Override mode for this namespace |
| `mtls.namespaces[].selector` | map | no | — | Target specific pods instead of all pods |
| `mtls.namespaces[].portLevelMtls` | map | no | — | Override mTLS mode on specific ports |

### Common Mistakes

- **Don't apply STRICT to `istio-system`** — The ingress gateway receives external plaintext traffic from your load balancer. STRICT would break that. Apply STRICT to your workload namespaces only.
- **PERMISSIVE doesn't mean insecure** — It still uses mTLS when both sides support it. It just doesn't reject plaintext connections. Use it temporarily during migration.

---

## 2. AuthorizationPolicy (Fine-Grained Access Control)

### The Problem It Solves

mTLS encrypts traffic and verifies identity, but it doesn't restrict access. With mTLS alone, **any** authenticated service can call **any** other service. That's like giving every employee in a company a badge that opens every door.

AuthorizationPolicy is the access control list (ACL). It says:
- "Only the `data-pipeline` namespace can call `model-api`"
- "Only `POST` to `/api/predict` is allowed, not `DELETE`"
- "Only users with the `admin` JWT role can access `/api/admin/*`"
- "Block all traffic from IP range `10.0.99.0/24`"

### The Three Actions

| Action | What It Does | When To Use |
|---|---|---|
| `ALLOW` | Only traffic matching the rules is allowed. Everything else is denied. | Default — whitelist approach |
| `DENY` | Traffic matching the rules is blocked. Everything else is allowed. | Block specific bad patterns |
| `CUSTOM` | Delegate the decision to an external authorization service | Complex auth logic that doesn't fit in Istio rules |

> **Important rule:** If you have **any** ALLOW policy on a workload, all traffic that doesn't match an ALLOW policy is denied. This is called "deny by default" and it's the safest approach.

### Building Blocks of a Rule

Every rule has three parts — think of it as answering three questions:

```
WHO can talk?     → from  (source: namespace, service account, JWT identity, IP)
WHAT can they do? → to    (operation: port, method, path, host)
UNDER WHAT CONDITIONS? → when  (attributes: JWT claims, headers, etc.)
```

Each part supports **inclusion** (allow these) and **exclusion** (except these):

```yaml
rules:
  - from:
      - namespaces: [allow-these]         # Include
        notNamespaces: [except-this-one]  # Exclude
    to:
      - paths: ["/api/*"]                 # Include
        notPaths: ["/api/admin/*"]        # Exclude — admin is off limits
    when:
      - key: request.auth.claims[role]
        values: [admin, editor]           # Include — only these roles
        # notValues: [guest]              # Exclude — except guests
```

### How To Use

**Example 1: Basic namespace-level access control**

"Only the `istio-system` and `monitoring` namespaces can call `model-api` on port 8080."

```yaml
meshSecurity:
  authorizationPolicies:
    - name: allow-model-api
      namespace: ai-namespace
      action: ALLOW
      selector:
        app: model-api
      rules:
        - from:
            - namespaces:
                - istio-system
                - monitoring
          to:
            - ports:
                - "8080"
```

**Example 2: Service account identity**

"Only the `pipeline-runner` service account from the `data-pipeline` namespace can POST to `/api/predict`."

```yaml
    - name: allow-predict-only
      namespace: ai-namespace
      action: ALLOW
      selector:
        app: model-api
      rules:
        - from:
            - principals:
                - cluster.local/ns/data-pipeline/sa/pipeline-runner
          to:
            - methods:
                - POST
              paths:
                - "/api/predict"
```

**Example 3: JWT-based fine-grained access**

"Allow requests only if they carry a valid JWT with the `admin` or `editor` role. Block access to `/admin/*` unless the role is `admin`."

```yaml
    - name: jwt-role-access
      namespace: ai-namespace
      action: ALLOW
      selector:
        app: model-api
      rules:
        - from:
            - requestPrincipals:
                - "https://auth.aib.vodafone.com/*"
          to:
            - paths:
                - "/api/*"
              notPaths:
                - "/api/admin/*"
          when:
            - key: request.auth.claims[role]
              values:
                - admin
                - editor

    - name: admin-only
      namespace: ai-namespace
      action: ALLOW
      selector:
        app: model-api
      rules:
        - from:
            - requestPrincipals:
                - "https://auth.aib.vodafone.com/*"
          to:
            - paths:
                - "/api/admin/*"
          when:
            - key: request.auth.claims[role]
              values:
                - admin
```

**Example 4: IP-based access control**

"Allow only traffic from the `10.0.0.0/8` range, but block the `10.0.99.0/24` subnet."

```yaml
    - name: ip-based-access
      namespace: ai-namespace
      action: ALLOW
      rules:
        - from:
            - ipBlocks:
                - "10.0.0.0/8"
              notIpBlocks:
                - "10.0.99.0/24"
```

**Example 5: DENY pattern — block specific traffic**

"Block all DELETE requests to any service in the namespace."

```yaml
    - name: deny-deletes
      namespace: ai-namespace
      action: DENY
      rules:
        - to:
            - methods:
                - DELETE
```

**Example 6: CUSTOM — external authorization**

"Delegate auth decisions to an ext-authz service defined in Istio's meshConfig."

```yaml
    - name: ext-authz
      namespace: ai-namespace
      action: CUSTOM
      provider: my-ext-authz-provider    # Must match a provider in meshConfig
      selector:
        app: model-api
      rules:
        - to:
            - paths:
                - "/api/*"
```

### What Gets Generated

```yaml
# Example 1 output:
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-model-api
  namespace: ai-namespace
spec:
  selector:
    matchLabels:
      app: model-api
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces:
              - istio-system
              - monitoring
      to:
        - operation:
            ports:
              - "8080"
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Resource name |
| `namespace` | string | yes | — | Namespace where the policy is created |
| `action` | string | no | `ALLOW` | `ALLOW`, `DENY`, or `CUSTOM` |
| `provider` | string | no | — | External auth provider (only for `CUSTOM`) |
| `selector` | map | no | — | Pod labels to target (omit = all pods in namespace) |
| **from (source)** | | | | |
| `rules[].from[].namespaces` | list | no | — | Allowed source namespaces |
| `rules[].from[].notNamespaces` | list | no | — | Excluded source namespaces |
| `rules[].from[].principals` | list | no | — | Allowed service accounts (format: `cluster.local/ns/<ns>/sa/<sa>`) |
| `rules[].from[].notPrincipals` | list | no | — | Excluded service accounts |
| `rules[].from[].requestPrincipals` | list | no | — | Allowed JWT identities (format: `<issuer>/<subject>` or `<issuer>/*`) |
| `rules[].from[].notRequestPrincipals` | list | no | — | Excluded JWT identities |
| `rules[].from[].ipBlocks` | list | no | — | Allowed source IP CIDRs |
| `rules[].from[].notIpBlocks` | list | no | — | Excluded source IP CIDRs |
| **to (operation)** | | | | |
| `rules[].to[].ports` | list | no | — | Allowed ports (strings: `"8080"`) |
| `rules[].to[].notPorts` | list | no | — | Excluded ports |
| `rules[].to[].methods` | list | no | — | Allowed HTTP methods |
| `rules[].to[].notMethods` | list | no | — | Excluded HTTP methods |
| `rules[].to[].paths` | list | no | — | Allowed URL paths (supports `*` wildcard) |
| `rules[].to[].notPaths` | list | no | — | Excluded URL paths |
| `rules[].to[].hosts` | list | no | — | Allowed destination hosts |
| `rules[].to[].notHosts` | list | no | — | Excluded destination hosts |
| **when (conditions)** | | | | |
| `rules[].when[].key` | string | yes | — | Istio attribute key to check |
| `rules[].when[].values` | list | no | — | Required values for the key |
| `rules[].when[].notValues` | list | no | — | Excluded values for the key |

### Common `when` Keys

| Key | What It Matches | Example Values |
|---|---|---|
| `request.auth.claims[role]` | JWT claim named "role" | `["admin", "editor"]` |
| `request.auth.claims[groups]` | JWT claim named "groups" | `["platform-team"]` |
| `request.auth.principal` | Full JWT identity (issuer/subject) | `["https://auth.issuer.com/user123"]` |
| `request.headers[x-api-key]` | Value of a request header | `["my-secret-key"]` |
| `source.namespace` | Namespace the request came from | `["mlrun"]` |
| `source.ip` | Source IP address | `["10.0.1.5"]` |

---

## 3. RequestAuthentication (JWT Validation)

### What Is JWT?

A **JSON Web Token (JWT)** is a signed token that a user gets after logging in. It contains information like "who are you" (subject), "who issued this token" (issuer), and "what permissions do you have" (claims/roles). The signature proves the token hasn't been tampered with.

### What Does RequestAuthentication Do?

It tells Istio: "Before letting a request reach my application, check if it has a JWT. If it does, validate it against this issuer's public keys (JWKS). If the token is invalid or expired, reject the request immediately."

This means your application code doesn't need to validate tokens — the sidecar proxy does it for you.

### The Gotcha: No Token = No Rejection

**This is the most common mistake:** RequestAuthentication only rejects **invalid** tokens. If a request has **no token at all**, it passes through! To block unauthenticated requests, you must **combine it with an AuthorizationPolicy** that requires a `requestPrincipal`:

```yaml
# Step 1: Validate tokens that are present
requestAuthentication:
  - name: jwt-auth
    namespace: ai-namespace
    selector:
      app: model-api
    jwtRules:
      - issuer: "https://auth.aib.vodafone.com"
        jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"

# Step 2: Require that every request has a valid token
authorizationPolicies:
  - name: require-jwt
    namespace: ai-namespace
    action: ALLOW
    selector:
      app: model-api
    rules:
      - from:
          - requestPrincipals:
              - "*"          # Any valid JWT identity — blocks no-token requests
```

### How To Use

```yaml
meshSecurity:
  requestAuthentication:
    - name: jwt-auth
      namespace: ai-namespace
      selector:                                 # Which pods validate JWT
        app: model-api
      jwtRules:
        - issuer: "https://auth.aib.vodafone.com"
          jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
          audiences:                            # Optional — reject if audience doesn't match
            - "model-api"
          forwardOriginalToken: true            # Pass the raw JWT to your app
          outputPayloadToHeader: x-jwt-payload  # Decoded payload as a header
```

### What Gets Generated

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: ai-namespace
spec:
  selector:
    matchLabels:
      app: model-api
  jwtRules:
    - issuer: "https://auth.aib.vodafone.com"
      jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
      audiences:
        - "model-api"
      forwardOriginalToken: true
      outputPayloadToHeader: "x-jwt-payload"
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Resource name |
| `namespace` | string | yes | — | Namespace where the resource is created |
| `selector` | map | no | — | Pod labels to target (omit = all pods) |
| `jwtRules[].issuer` | string | yes | — | Expected `iss` claim value |
| `jwtRules[].jwksUri` | string | yes | — | URL to fetch public keys for signature validation |
| `jwtRules[].audiences` | list | no | — | Expected `aud` claim values |
| `jwtRules[].forwardOriginalToken` | bool | no | `false` | Forward the raw JWT to the upstream app |
| `jwtRules[].outputPayloadToHeader` | string | no | — | Put the decoded JWT payload into this header |

### How It Flows

```
Client sends request with JWT
        │
        ▼
┌──────────────────────┐
│  Istio Sidecar       │
│                      │
│  1. Extract JWT      │
│  2. Fetch JWKS keys  │──→ https://auth.aib.vodafone.com/.well-known/jwks.json
│  3. Verify signature │
│  4. Check expiry     │
│  5. Check audience   │
│                      │
│  Valid? → forward    │──→ Application (with optional x-jwt-payload header)
│  Invalid? → 401     │──→ Client gets "Jwt verification fails"
│  No token? → forward│──→ Application (unless AuthorizationPolicy blocks it)
└──────────────────────┘
```

---

## 4. Rate Limiting (Per Namespace)

### The Problem It Solves

Imagine your model inference endpoint takes 5 seconds per request. If a misbehaving client sends 1000 requests per second, your pods will become overwhelmed, queues will back up, and the service will become unresponsive for **everyone** — not just the misbehaving client.

Rate limiting is a protective wall. It says: "This service accepts at most N requests per time window. If you exceed that, you get a `429 Too Many Requests` response."

### How It Works: Token Bucket Algorithm

Think of a bucket that holds tokens. Every request takes one token from the bucket. If the bucket is empty, the request is rejected. The bucket refills at a steady rate.

```
                    ┌─────────────┐
  Tokens refill     │  Token      │    maxTokens = 20 (bucket size)
  every interval →  │  Bucket     │    tokensPerFill = 10 (refill amount)
                    │  ████████░░ │    fillInterval = 60s (refill every 60s)
                    └──────┬──────┘
                           │
              Request arrives ─── Has token? ─── Yes → Pass through
                                      │
                                      No → 429 Too Many Requests
                                           + x-local-rate-limit: true header
```

**Key insight:** `maxTokens` is your burst size (how many rapid-fire requests you allow), and `tokensPerFill / fillInterval` is your sustained rate.

### How To Use

```yaml
meshSecurity:
  rateLimiting:
    # Rate limit all pods in a namespace
    - name: ai-namespace-limit
      namespace: ai-namespace
      maxTokens: 100             # Allow burst of 100 requests
      tokensPerFill: 50          # Refill 50 tokens per interval
      fillInterval: "60s"        # Refill every 60 seconds
                                 # → Sustained rate: ~50 req/min

    # Rate limit a specific workload more strictly
    - name: model-inference-limit
      namespace: ai-namespace
      selector:                  # Only target model-api pods
        app: model-api
      maxTokens: 20              # Small burst
      tokensPerFill: 10          # 10 requests per minute sustained
      fillInterval: "60s"
      statusCode: 429            # HTTP status code (default: 429)
```

### Sizing Guide

| Use Case | maxTokens | tokensPerFill | fillInterval | Effective Rate |
|---|---|---|---|---|
| Expensive model inference | 20 | 10 | 60s | ~10 req/min sustained, 20 burst |
| General API | 200 | 100 | 60s | ~100 req/min sustained, 200 burst |
| High-throughput pipeline | 1000 | 500 | 10s | ~3000 req/min sustained |
| Emergency protection | 5 | 5 | 60s | ~5 req/min, no burst |

### What Gets Generated

An `EnvoyFilter` resource that patches the Envoy sidecar proxy configuration:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ai-namespace-limit-ratelimit
  namespace: ai-namespace
spec:
  workloadSelector:           # Only present if selector is set
    labels:
      app: model-api
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
                max_tokens: 20
                tokens_per_fill: 10
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

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Name prefix for the EnvoyFilter (`<name>-ratelimit`) |
| `namespace` | string | yes | — | Namespace where the rate limit is enforced |
| `selector` | map | no | — | Pod labels to target (omit = all pods in namespace) |
| `maxTokens` | int | no | `100` | Maximum bucket size (burst capacity) |
| `tokensPerFill` | int | no | `100` | Tokens added per fill interval |
| `fillInterval` | string | no | `60s` | How often tokens are refilled |
| `statusCode` | int | no | `429` | HTTP status code when rate limited |

### Important Notes

- **Local rate limiting** means each pod has its own independent token bucket. If you have 3 replicas of `model-api`, the effective total rate is 3x what you configure per pod.
- **No external service needed** — this uses Envoy's built-in rate limiter, not an external rate limit service like `ratelimit`.
- Rate limited responses include the `x-local-rate-limit: true` header so you can identify them in logs and monitoring.

---

## Installation

### As part of the umbrella chart (recommended)

```yaml
# In aib-platform values.yaml or environment override:
mesh-security:
  meshSecurity:
    mtls:
      enabled: true
      mode: STRICT
      namespaces:
        - name: ai-namespace
    authorizationPolicies: []
    requestAuthentication: []
    rateLimiting: []
```

### Standalone

```bash
helm install mesh-security ./mesh-security \
  -f my-security-values.yaml \
  -n istio-system
```

---

## Quick Recipes

### Recipe 1: Lock down a namespace completely

```yaml
meshSecurity:
  mtls:
    enabled: true
    mode: STRICT
    namespaces:
      - name: ai-namespace
  authorizationPolicies:
    - name: deny-all
      namespace: ai-namespace
      action: ALLOW
      rules: []    # No rules = deny everything (no traffic matches ALLOW)
```

### Recipe 2: Allow only the ingress gateway to reach a service

```yaml
meshSecurity:
  authorizationPolicies:
    - name: ingress-only
      namespace: ai-namespace
      action: ALLOW
      selector:
        app: model-api
      rules:
        - from:
            - namespaces:
                - istio-system
```

### Recipe 3: JWT + role-based access + rate limiting

```yaml
meshSecurity:
  requestAuthentication:
    - name: jwt-auth
      namespace: ai-namespace
      selector:
        app: model-api
      jwtRules:
        - issuer: "https://auth.aib.vodafone.com"
          jwksUri: "https://auth.aib.vodafone.com/.well-known/jwks.json"
          forwardOriginalToken: true
  authorizationPolicies:
    - name: require-admin-role
      namespace: ai-namespace
      action: ALLOW
      selector:
        app: model-api
      rules:
        - from:
            - requestPrincipals:
                - "*"
          when:
            - key: request.auth.claims[role]
              values:
                - admin
  rateLimiting:
    - name: model-api-limit
      namespace: ai-namespace
      selector:
        app: model-api
      maxTokens: 20
      tokensPerFill: 10
      fillInterval: "60s"
```

This combination means: every request to `model-api` must have a valid JWT with the `admin` role, and even valid requests are limited to ~10 per minute per pod.
