# mesh-egress — Istio Egress Traffic Control

## What Is This Chart?

Your AI services don't live in isolation — they call external APIs all the time. A model might call OpenAI for embeddings, download weights from HuggingFace, or push logs to an external monitoring service. All of this is **egress traffic** (traffic leaving your cluster).

By default, Istio either:
- **Blocks** all outbound traffic to unknown hosts (if `outboundTrafficPolicy` is `REGISTRY_ONLY`) — your API calls fail silently
- **Allows** all outbound traffic untracked (if `outboundTrafficPolicy` is `ALLOW_ANY`) — you have zero visibility

Neither is good. **mesh-egress** solves this by:

1. **Registering external hosts** (ServiceEntry) — Tells Istio "these external hosts exist and are allowed"
2. **Routing through an egress gateway** (optional) — Forces all external traffic through a single exit point for auditing and control
3. **Encrypting outbound HTTP** (TLS Origination) — Your app sends plain HTTP; the egress gateway upgrades it to HTTPS before it leaves the cluster

Think of it as the building's exit door. Without it, tenants (pods) either can't leave, or they leave without anyone knowing where they went.

---

## Why Do You Need This?

### Without mesh-egress:

```
Your pod ──→ api.openai.com     ← Blocked (REGISTRY_ONLY) or Untracked (ALLOW_ANY)
Your pod ──→ huggingface.co     ← No metrics, no tracing, no visibility
Your pod ──→ malicious-site.com ← No way to prevent exfiltration
```

### With mesh-egress:

```
Your pod ──→ api.openai.com     ✓ Allowed, tracked in Istio metrics
Your pod ──→ huggingface.co     ✓ Allowed, visible in Kiali dashboard
Your pod ──→ malicious-site.com ✗ Blocked — not registered as a ServiceEntry
```

---

## Chart Structure

```
mesh-egress/
├── Chart.yaml                          # Chart metadata (name, version)
├── values.yaml                         # All configurable options with defaults
├── README.md                           # This file
└── templates/
    ├── _helpers.tpl                    # Shared Helm template helpers (labels)
    ├── service-entry.yaml              # Generates ServiceEntry resources (register external hosts)
    ├── egress-gateway.yaml             # Generates the shared egress Gateway resource
    ├── egress-virtualservices.yaml     # Generates VirtualService per external service (gateway routing)
    └── destination-rules.yaml          # Generates DestinationRule for gateway subsets + TLS origination
```

### What Gets Generated When?

| Condition | Resources Generated |
|---|---|
| `services[].enabled: true` | ServiceEntry (always) |
| `gateway.enabled: true` + `services[].enabled: true` | + Gateway, VirtualService, DestinationRule (egress routing) |
| `services[].tls.mode` is set | + Extra DestinationRule for TLS origination |
| `services[].enabled: false` | Nothing for that service |
| `services: []` (empty) | Nothing at all |

---

## Prerequisites

- Istio installed in your cluster
- For egress gateway routing: Istio egress gateway deployment running (pods with label `istio: egressgateway`)
- Helm 3.x

---

## 1. ServiceEntry (Registering External Hosts)

### What Is a ServiceEntry?

A **ServiceEntry** is a simple declaration: "Hey Istio, this external host exists. Let pods talk to it."

Without it, Istio's sidecar proxy doesn't know about the external host and will either block the request or let it through without tracking it.

### Why Register External Hosts?

Once registered:
- **Istio metrics work** — You can see request count, latency, and error rate to `api.openai.com` in Prometheus/Grafana
- **Tracing works** — External calls appear in Jaeger/Zipkin traces
- **Kiali visibility** — External services show up in the service mesh graph
- **Traffic policies work** — You can apply retries, timeouts, and circuit breaking to external calls
- **Security** — Only registered hosts are reachable (in `REGISTRY_ONLY` mode)

### How To Use

```yaml
meshEgress:
  services:
    # Most common: HTTPS external API
    - name: openai
      enabled: true                      # Set false to disable without deleting
      namespaces:                        # Namespaces to whitelist this URL in
        - ai-namespace
        - ml-namespace
      host: api.openai.com              # The external hostname
      port: 443                          # Port number
      resolution: DNS                    # How to resolve: DNS | STATIC | NONE
      location: MESH_EXTERNAL           # MESH_EXTERNAL = outside the cluster

    # External service with multiple ports
    - name: custom-api
      enabled: true
      namespace: ai-namespace
      host: api.custom.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL
      additionalPorts:
        - port: 8443
          name: grpc
          protocol: GRPC

    # Disabled service (kept for reference, generates nothing)
    - name: deprecated-api
      enabled: false
      host: old-api.example.com
      port: 443
```

### Understanding the Fields

#### `resolution` — How Istio Finds the External Host

| Value | What It Means | When To Use |
|---|---|---|
| `DNS` | Resolve the hostname using DNS | **Most external APIs** — `api.openai.com`, `huggingface.co`, etc. |
| `STATIC` | Use a fixed IP address (you provide it in `endpoints`) | When you know the exact IP of the service |
| `NONE` | Don't resolve — just forward the request | Rarely used |

#### `location` — Where Is the Service?

| Value | What It Means | When To Use |
|---|---|---|
| `MESH_EXTERNAL` | Outside the cluster/mesh | **Almost always** — external APIs, SaaS services |
| `MESH_INTERNAL` | Inside the mesh but not auto-discovered | When manually registering internal services |

#### Port Protocol Logic

The template automatically picks the right protocol:

| Your config | Generated protocol | Why |
|---|---|---|
| `port: 443` (no `tls` field) | `TLS` | Traffic is already encrypted (HTTPS). Istio does TLS passthrough using SNI |
| `port: 80` + `tls.mode: SIMPLE` | `HTTP` | Traffic is HTTP internally. The egress gateway will originate TLS |

### What Gets Generated

For `port: 443` (standard HTTPS):

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: openai-se
  namespace: ai-namespace
spec:
  hosts:
    - api.openai.com
  location: MESH_EXTERNAL
  ports:
    - number: 443
      name: tls
      protocol: TLS           # ← TLS passthrough
  resolution: DNS
```

For `port: 80` with `tls.mode: SIMPLE` (TLS origination):

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: example-se
  namespace: ai-namespace
spec:
  hosts:
    - example.external.com
  location: MESH_EXTERNAL
  ports:
    - number: 80
      name: http
      protocol: HTTP           # ← HTTP, because TLS is originated by the gateway
  resolution: DNS
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes | — | Resource name prefix (`<name>-se`) |
| `enabled` | bool | yes | — | Whether to generate resources for this service |
| `namespaces` | list | no | inherits `meshEgress.namespace` | List of namespaces to create the ServiceEntry in |
| `namespace` | string | no | inherits `meshEgress.namespace` | Single namespace (use `namespaces` for multiple) |
| `host` | string | yes | — | External hostname |
| `port` | int | yes | — | Primary port number |
| `resolution` | string | no | `DNS` | Host resolution: `DNS`, `STATIC`, `NONE` |
| `location` | string | no | `MESH_EXTERNAL` | Service location |
| `additionalPorts` | list | no | `[]` | Extra ports |
| `additionalPorts[].port` | int | yes | — | Port number |
| `additionalPorts[].name` | string | yes | — | Port name |
| `additionalPorts[].protocol` | string | yes | — | Protocol: `HTTP`, `HTTPS`, `TCP`, `TLS`, `GRPC` |

---

## 2. Egress Gateway Routing

### What Is an Egress Gateway?

Without an egress gateway, external traffic goes directly from your pod's sidecar to the internet:

```
Pod → sidecar proxy → internet
```

With an egress gateway, traffic is routed through a dedicated gateway pod first:

```
Pod → sidecar proxy → egress gateway pod → internet
```

### Why Use an Egress Gateway?

| Benefit | Explanation |
|---|---|
| **Single exit point** | All external traffic goes through one place — easy to monitor and audit |
| **Network policies** | You can use Kubernetes NetworkPolicies to restrict which pods can reach the egress gateway |
| **Compliance** | Some regulations (PCI-DSS, HIPAA) require a controlled egress point |
| **Centralized logging** | One place to log all external API calls |
| **TLS origination** | Centralize certificate management at the gateway instead of every app |

### When NOT to Use an Egress Gateway

- **Development environments** — Adds complexity without much benefit
- **Simple setups** — If you just need basic external access, ServiceEntries alone are enough
- **Performance-sensitive paths** — Adds an extra network hop

### How It Works (Big Picture)

When you enable the egress gateway, three additional resources are created per external service:

```
                                 ┌─────────────────────────────┐
                                 │  What gets created           │
                                 │                             │
Pod → sidecar                    │  1. Gateway                 │
      │                          │     - Tells the egress      │
      │ VirtualService says:     │       gateway pod what       │
      │ "Send to egress gateway" │       to listen for         │
      ▼                          │                             │
Egress Gateway Pod               │  2. VirtualService          │
      │                          │     - Route 1: mesh → gw    │
      │ VirtualService says:     │     - Route 2: gw → external│
      │ "Forward to external"    │                             │
      ▼                          │  3. DestinationRule          │
api.openai.com                   │     - Subsets for each svc  │
                                 └─────────────────────────────┘
```

### How To Use

**Step 1:** Enable the gateway

```yaml
meshEgress:
  namespace: aib-platform                  # Where CRs are created
  gateway:
    enabled: true                        # This turns on egress gateway routing
    name: platform-egress-gateway        # Name for the Gateway resource
    serviceNamespace: istio-system       # Where the egress gateway pods run
    selector:
      istio: egressgateway               # Label on the egress gateway pods
```

**Step 2:** Add services (same as before — the template automatically generates gateway routing)

```yaml
  services:
    - name: openai
      enabled: true
      namespace: ai-namespace
      host: api.openai.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL
```

### What Gets Generated (Port 443 — TLS Passthrough)

**Gateway** (shared — one server block per service):

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
        mode: PASSTHROUGH       # Don't terminate TLS — just forward it
```

**VirtualService** (one per service — dual routing: mesh → gateway → external):

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
    - mesh                           # Matches traffic from pod sidecars
    - platform-egress-gateway        # Matches traffic at the gateway
  tls:
    # Route 1: From mesh (sidecar) → Send to egress gateway
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

    # Route 2: At the egress gateway → Send to the actual external host
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

> **Why two routes?** The first route intercepts traffic in the mesh and redirects it to the egress gateway. The second route, running at the egress gateway itself, forwards it to the actual external host.

**DestinationRule** (shared — one subset per service):

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
      labels:
        istio: egressgateway
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `namespace` | string | yes | — | Namespace where all egress CRs are created (Gateway, VirtualService, DestinationRule) |
| `gateway.enabled` | bool | no | `false` | Enable egress gateway routing |
| `gateway.name` | string | no | `platform-egress-gateway` | Gateway resource name |
| `gateway.serviceNamespace` | string | no | `istio-system` | Namespace where egress gateway pods run (for `.svc.cluster.local` references) |
| `gateway.selector` | map | yes (if enabled) | — | Labels matching the egress gateway pods |

---

## 3. TLS Origination

### What Is TLS Origination?

Some external APIs accept both HTTP and HTTPS. Your internal app might only speak HTTP. **TLS origination** means the egress gateway takes your plain HTTP request and opens a new HTTPS (TLS) connection to the external host.

```
App (HTTP, port 80) → sidecar → egress gateway → [TLS handshake] → external API (HTTPS, port 443)
```

### Why Use It?

| Benefit | Explanation |
|---|---|
| **Encrypt everything** | Even if your app sends HTTP, traffic leaving the cluster is encrypted |
| **Centralized certs** | Certificate management happens at the gateway, not in every app |
| **Enforce HTTPS** | Platform policy: no plaintext traffic leaves the cluster |
| **Simpler apps** | Apps don't need TLS libraries or certificate configs |

### The Two Modes: Passthrough vs. Origination

| Mode | Port | TLS Config | What Happens |
|---|---|---|---|
| **Passthrough** | 443 | No `tls` field | Traffic is already encrypted. Gateway forwards it as-is using SNI to pick the destination |
| **TLS Origination** | 80 | `tls.mode: SIMPLE` | Traffic is HTTP internally. Gateway opens a new TLS connection to the external host |

### How To Use

```yaml
meshEgress:
  namespace: aib-platform
  gateway:
    enabled: true
    name: platform-egress-gateway
    serviceNamespace: istio-system
    selector:
      istio: egressgateway

  services:
    # Standard passthrough (port 443 — most common)
    - name: openai
      enabled: true
      namespace: ai-namespace
      host: api.openai.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL
      # No tls field → passthrough

    # TLS origination (port 80 — gateway encrypts for you)
    - name: legacy-api
      enabled: true
      namespace: ai-namespace
      host: legacy.external.com
      port: 80
      resolution: DNS
      location: MESH_EXTERNAL
      tls:
        mode: SIMPLE              # One-way TLS (most common)
        # sni: legacy.external.com  # Optional: override SNI hostname
```

### TLS Modes

| Mode | What It Does | When To Use |
|---|---|---|
| `SIMPLE` | Gateway presents no client cert. Just encrypts the connection | **Most external APIs** — they don't require client certificates |
| `MUTUAL` | Gateway presents a client certificate too | When the external service requires mTLS (client cert auth) |
| `ISTIO_MUTUAL` | Use Istio's auto-generated certificates | Rare — for services within the Istio trust domain |

### What Gets Generated (Port 80 + TLS Origination)

**Gateway** (HTTP instead of TLS):

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
        name: legacy-api-http         # ← HTTP, not TLS
        protocol: HTTP
      hosts:
        - legacy.external.com
```

**VirtualService** (HTTP routes instead of TLS routes):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: legacy-api-egress-vs
  namespace: aib-platform
spec:
  hosts:
    - legacy.external.com
  gateways:
    - mesh
    - platform-egress-gateway
  http:                                  # ← HTTP, not TLS
    - match:
        - gateways:
            - mesh
          port: 80
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: legacy-api
            port:
              number: 80
    - match:
        - gateways:
            - platform-egress-gateway
          port: 80
      route:
        - destination:
            host: legacy.external.com
            port:
              number: 80
```

**DestinationRule for TLS origination** (extra — this is what actually does the encryption):

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: legacy-api-tls-origination-dr
  namespace: aib-platform
spec:
  host: legacy.external.com
  trafficPolicy:
    portLevelSettings:
      - port:
          number: 80
        tls:
          mode: SIMPLE              # ← Originate TLS here
```

### Values Reference

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `tls.mode` | string | yes | — | `SIMPLE`, `MUTUAL`, or `ISTIO_MUTUAL` |
| `tls.sni` | string | no | — | Override SNI hostname in the TLS handshake |

---

## Installation

### As part of the umbrella chart (recommended)

```yaml
# In aib-platform values.yaml or environment override:
mesh-egress:
  meshEgress:
    namespace: aib-platform
    gateway:
      enabled: false              # Start without egress gateway
    services:
      - name: openai
        enabled: true
        namespace: ai-namespace
        host: api.openai.com
        port: 443
        resolution: DNS
        location: MESH_EXTERNAL
```

### Standalone

```bash
helm install mesh-egress ./mesh-egress \
  -f my-egress-values.yaml \
  -n aib-platform
```

---

## Quick Recipes

### Recipe 1: Allow access to external AI APIs (simplest)

```yaml
meshEgress:
  services:
    - name: openai
      enabled: true
      namespace: ai-namespace
      host: api.openai.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL

    - name: huggingface
      enabled: true
      namespace: ai-namespace
      host: huggingface.co
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL
```

No egress gateway needed. Pods talk directly to external hosts through their sidecars.

### Recipe 2: Egress gateway for compliance/auditing

```yaml
meshEgress:
  namespace: aib-platform
  gateway:
    enabled: true
    name: platform-egress-gateway
    serviceNamespace: istio-system
    selector:
      istio: egressgateway

  services:
    - name: openai
      enabled: true
      namespace: ai-namespace
      host: api.openai.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL

    - name: huggingface
      enabled: true
      namespace: ai-namespace
      host: huggingface.co
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL
```

All external traffic flows through the egress gateway — visible in access logs and Istio telemetry.

### Recipe 3: TLS origination for a legacy HTTP API

```yaml
meshEgress:
  namespace: aib-platform
  gateway:
    enabled: true
    name: platform-egress-gateway
    serviceNamespace: istio-system
    selector:
      istio: egressgateway

  services:
    - name: legacy-api
      enabled: true
      namespace: ai-namespace
      host: legacy.partner.com
      port: 80
      resolution: DNS
      location: MESH_EXTERNAL
      tls:
        mode: SIMPLE              # Encrypt at the gateway
```

Your app sends `http://legacy.partner.com:80`. The egress gateway upgrades it to HTTPS before it leaves the cluster.

### Recipe 4: Multiple external services for a production AI platform

```yaml
meshEgress:
  namespace: aib-platform
  gateway:
    enabled: true
    name: platform-egress-gateway
    serviceNamespace: istio-system
    selector:
      istio: egressgateway

  services:
    - name: openai
      enabled: true
      namespace: ai-namespace
      host: api.openai.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL

    - name: huggingface
      enabled: true
      namespace: ai-namespace
      host: huggingface.co
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL

    - name: aws-s3
      enabled: true
      namespace: ai-namespace
      host: s3.amazonaws.com
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL

    - name: docker-registry
      enabled: true
      namespace: ai-namespace
      host: registry-1.docker.io
      port: 443
      resolution: DNS
      location: MESH_EXTERNAL
```

---

## Full Values Reference

```yaml
meshEgress:
  namespace: aib-platform                    # Required — namespace where CRs are created
  gateway:
    enabled: false                         # Enable egress gateway routing
    name: platform-egress-gateway          # Gateway resource name
    serviceNamespace: istio-system         # Namespace where egress gateway pods run
    selector:                              # Labels on egress gateway pods
      istio: egressgateway

  services:
    - name: service-name                   # Required — resource name prefix
      enabled: true                        # Required — set false to skip
      namespace: target-namespace          # Optional (default: inherits meshEgress.namespace)
      host: api.external.com              # Required — external hostname
      port: 443                            # Required — external port
      resolution: DNS                      # Optional (default: DNS)
      location: MESH_EXTERNAL             # Optional (default: MESH_EXTERNAL)
      # additionalPorts:                   # Optional — extra ports
      #   - port: 8443
      #     name: grpc
      #     protocol: GRPC
      # tls:                               # Optional — enables TLS origination
      #   mode: SIMPLE                     # SIMPLE | MUTUAL | ISTIO_MUTUAL
      #   sni: override-hostname.com       # Optional — override SNI
```

---

## Common Questions

### Q: Do I need an egress gateway?

**For development:** No. Just use ServiceEntries. Traffic goes directly from the pod sidecar to the external host.

**For production/compliance:** Yes, if you need:
- Centralized audit logging of all external API calls
- Network policies restricting which pods can reach external services
- A single exit point for compliance requirements

### Q: What happens if I don't register a ServiceEntry?

It depends on Istio's `outboundTrafficPolicy` mode:
- `ALLOW_ANY` (default): Traffic goes through but **untracked** — no metrics, no tracing
- `REGISTRY_ONLY`: Traffic is **blocked** — your API call returns a connection error

### Q: Can I use port 443 with TLS origination?

Technically yes, but it's unusual. TLS origination is designed for the pattern where your app sends HTTP (port 80) and the gateway encrypts it. If your app already sends HTTPS to port 443, just use passthrough (no `tls` field).

### Q: Should I use `host: "*"` (wildcard) on the Gateway instead of per-service hosts?

**No — keep explicit per-service hosts.** Here's why:

| | Per-service hosts (current) | Wildcard `host: "*"` |
|---|---|---|
| **Security** | Gateway rejects traffic to unapproved hosts — defense in depth | Gateway accepts traffic for *any* host on that port; you rely entirely on VirtualServices to restrict it |
| **Compliance** | The allow-list is visible and enforceable at multiple layers (Gateway + VirtualService + ServiceEntry) | Allow-list only enforced at VirtualService/ServiceEntry level |
| **Maintenance** | No overhead — the template loops over services and generates server blocks automatically | Slightly less YAML, but saves almost nothing since the template handles it |
| **Risk** | Minimal — adding a new service is just a values entry | If someone creates a ServiceEntry but forgets the VirtualService, traffic may still flow through the gateway uncontrolled |

The only case where `host: "*"` makes sense is if you have a **large, dynamic** number of egress destinations and managing them individually is impractical — but that contradicts the purpose of a controlled egress pattern.

**Bottom line:** Explicit hosts = defense in depth. The current design is correct for egress.

### Q: How do I temporarily disable an external service?

Set `enabled: false`. The service entry stays in your values file for reference but generates no resources:

```yaml
    - name: deprecated-api
      enabled: false          # Generates nothing
      host: old.api.com
      port: 443
```
