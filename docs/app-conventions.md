# App conventions

This document defines what it means to be an **atrium-installable app**.
App authors who follow these conventions get a one-command install motion
(`./scripts/apply-app.sh <name>` from the atrium clone) and clean
integration with the cluster's substrate (wildcard cert, ingress, mesh
routing, Hermes skill discovery).

Atrium does not own per-app deploy manifests. The app's repo ships its
own deploy bundle; atrium provides the substrate (cluster, certs,
ingress class) and a thin bridge that renders + applies the bundle
against a particular atrium instance.

## The third-party-app pattern

Atrium treats every app — first-party (the operator built it) or third-
party (Spotify, Airbnb, etc.) — the same way: as a self-contained
service with a public API and an optional consumer-facing frontend. The
operator's agent (Hermes) calls the API; the user reaches the frontend
directly. Atrium hosts the parts the operator owns. The rest is
somebody else's problem.

For a real third-party SaaS (Spotify), atrium hosts **nothing** — the
operator just registers a skill manifest pointing at the provider's
public API. For a first-party app (gustus), atrium hosts both the
backend and a frontend, but the **shape stays the same**: backend at
`api.<app>.<your-domain>`, frontend at `<app>.<your-domain>`, skill
manifest served from the backend.

## Deployment shapes

Atrium's role varies by where the app's backend lives. Four shapes; the
app's deploy bundle reflects which one applies.

### Shape A — Pure third-party (atrium hosts nothing)

The provider runs everything — backend, frontend, the lot — and the
user just reaches the provider's hosted product directly when they
want a UI. The operator just registers the skill with their Hermes:

```
operator → hermes auth spotify     # or hermes auth add <provider>
operator → hermes skills install https://<provider-domain>
```

No atrium-side YAML. No `apply-app.sh`. The app's repo doesn't even
need to exist on the operator's machine. **This is the common case for
real SaaS** — Spotify, GitHub, Linear, etc. Hermes ships native auth
flows for several providers (`hermes auth --help`). If the provider
later releases a self-hostable UI for atrium operators, the shape
shifts to B.

### Shape B — Third-party backend, operator-hosted frontend

The provider runs the API + holds the data (api.airbnb.com style). The
operator self-hosts a frontend that calls it. Atrium hosts **only the
frontend**. Where the frontend artifact comes from can vary:

- The operator wrote it (a custom UI tailored for atrium).
- The provider publishes a downloadable image, kustomize bundle, or
  Helm chart you pull and run as-is.
- The provider publishes an SPA as static files (npm/CDN/git release)
  and you serve them via nginx/caddy.

All three variants land in atrium the same way:

```
Namespaces:   <app>-fe   (no <app>-be — backend is provider-owned)
Hostnames:    <app>.<your-domain>          → frontend in <app>-fe
              api.<provider-domain>        → not yours; not in atrium
Skill manifest source: provider's own /.well-known/agent-skill on their domain
```

The frontend's job is to be a polished UI in front of the provider's
API + their OAuth. The MCP endpoint Hermes calls is the provider's,
not yours. Atrium doesn't care whether the FE was written locally or
pulled from a provider release; the deploy story is the same.

### Shape C — In-house monolith (single image, single namespace)

The operator built the app; it serves SPA + API + MCP from one process.
Atrium hosts the whole thing in one namespace.

```
Namespaces:   <app>     (no split)
Hostnames:    <app>.<your-domain>          → the one Service
              <app>.<your-domain>/api/*    → same Service, API routes
              <app>.<your-domain>/mcp      → same Service, MCP route
              <app>.<your-domain>/.well-known/agent-skill → same
```

This is the simplest shape and what most early in-house apps look like.
Gustus today is exactly this — Fastify with `SERVE_STATIC=true`.

### Shape D — In-house with backend/frontend split

The operator built the app and chose to split tiers — separate deploy
cadence for the UI, separate scaling, optional CORS-honest API
boundary. Atrium hosts both halves in separate namespaces.

```
Namespaces:   <app>-be   <app>-fe
Hostnames:    <app>.<your-domain>          → frontend in <app>-fe
              api.<app>.<your-domain>      → backend in <app>-be
              api.<app>.<your-domain>/mcp  → backend's MCP route
              api.<app>.<your-domain>/.well-known/agent-skill → backend
```

Backend needs CORS to allow the frontend origin. This is the shape that
mirrors a "real SaaS" pattern (api.* + the consumer-facing app).

### Which shape to pick

| Situation | Shape |
|---|---|
| Real third-party SaaS (Spotify, GitHub, …) | A — Hermes alone |
| Self-host a UI skin for a third-party API | B — frontend only |
| Building a new in-house app, simple | C — monolith |
| Building a new in-house app, want tier separation OR mirror a SaaS shape | D — split |

Shapes C and D can convert into each other later. A→D would require
the operator to take over the backend entirely (different problem).
B→D similarly requires you to build a replacement for the third-party
backend (possible but rare).

### What goes where, summary

| Resource | Shape A | Shape B | Shape C | Shape D |
|---|---|---|---|---|
| `<app>-be` namespace | — | — | — | yes |
| `<app>-fe` namespace | — | yes | — | yes |
| `<app>` namespace (single) | — | — | yes | — |
| `apply-app.sh` runs | no | yes | yes | yes |
| `hermes skills install` runs | yes | yes (against provider) | yes (against `<app>.<domain>`) | yes (against `api.<app>.<domain>`) |

Apps **must not** deploy anything into the `hermes` namespace. That
namespace is reserved for the agent.

### Hostnames

Public DNS A records point at the node's mesh IP. The wildcard cert
(`*.<CLUSTER_DOMAIN>`) covers every `<anything>.<CLUSTER_DOMAIN>` host
the app uses — no per-app cert work.

The MCP endpoint **is publicly reachable** (gated by bearer auth at the
app's discretion). This is intentional: the same shape works whether
Hermes runs in the same cluster or on a different machine entirely.
Cluster-internal MCP URLs (`<svc>.<ns>.svc.cluster.local`) are an
implementation detail apps shouldn't rely on.

### Env vars atrium provides

The bridge script (`scripts/apply-app.sh`) exports these via `envsubst`
when rendering the app's bundle. Apps use **whichever ones their shape
needs** — unused env vars are harmless.

| Variable | Value | Used by shape |
|---|---|---|
| `CLUSTER_DOMAIN` | The atrium operator's domain (e.g. `example.com`) | B, C, D |
| `ACME_EMAIL` | LE contact email | (rarely; cert-manager owns it) |
| `APP_NAME` | The app's identifier (lowercase, kebab) | B, C, D |
| `APP_FE_HOSTNAME` | Frontend hostname *prefix* (default: `${APP_NAME}`) | B, D (and C if the app wants the symbolic name) |
| `APP_BE_HOSTNAME` | Backend hostname *prefix* (default: `api.${APP_NAME}`) | D only |

All defaults can be overridden in `cluster.config.yaml.apps.<app>.{fe,be}_hostname`.

App manifests reference these with shell-style placeholders
(`${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}`) — not Helm-style or Flux
postBuild — because envsubst is the chosen rendering layer. When
goal-2 Flux lands, the same placeholders work natively via
`Kustomization.spec.postBuild.substituteFrom`.

The app's manifests reference these with shell-style placeholders
(`${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}`) — *not* Helm-style or Flux
postBuild — because envsubst is the chosen rendering layer. When goal-2
Flux lands, the same placeholders work natively via
`Kustomization.spec.postBuild.substituteFrom`.

### Labels

Every Kubernetes resource the app ships should carry:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/component: <backend|frontend|database>
    app.kubernetes.io/part-of: atrium-app
```

The `part-of: atrium-app` label distinguishes per-app resources from
atrium's substrate (`part-of: atrium`). Useful for sweeping (e.g.
`kubectl get all -l app.kubernetes.io/part-of=atrium-app -A`).

### Ingress

Both ingresses (`<app>-fe` and `<app>-be`):

```yaml
spec:
  ingressClassName: traefik
  tls:
    - hosts: [${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}]   # or APP_BE_HOSTNAME
      secretName: wildcard-tls                         # exists in the app's ns
  rules:
    - host: ${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <svc>
                port: { number: 80 }
```

The `wildcard-tls` Secret must exist in the app's namespace. Atrium's
`deploy/platform/wildcard-cert.yaml` issues the cert into the `hermes`
namespace today; cross-namespace replication will land at goal 2
(via the `reflector` controller or per-namespace `Certificate`
resources). For now, app namespaces mint their own `Certificate` against
the shared `ClusterIssuer/letsencrypt-prod` — one extra manifest per
app, costs nothing.

## SKILL.md (Hermes-native — atrium just recommends conventions)

Every app that exposes MCP tools ships a `SKILL.md`. The schema is
Hermes-native — the same one `hermes skills install` reads. Atrium
adds no fields. Place the file at `deploy/k8s/skill-md/<app>.SKILL.md`
in the app's repo, and serve its content at
`/.well-known/agent-skill` from the backend so `hermes skills install
https://api.<app>.<domain>` finds it (this is one of Hermes' six
built-in install sources — see `hermes skills install --help`).

### Recommended frontmatter (mirrors Hermes' schema)

```yaml
---
name: <app-name>
description: <one-line summary that triggers tool use; verb-first>
version: <semver>
author: <github-handle or org>
license: <SPDX, e.g. MIT>
platforms: [linux, macos, windows]   # optional; agent-side platforms
metadata:
  hermes:
    tags: [<verb>, <noun>, <domain>]
    homepage: https://<app>.<domain>
prerequisites:
  commands: []   # optional; CLI tools the app expects on the host
---
```

**Do not** add `metadata.atrium.*` or `metadata.homelab.*` blocks unless
they encode behavior the agent or atrium tooling will act on. Hermes
treats unknown frontmatter as opaque — fields that nothing reads are
dead weight.

### Body sections (Hermes-canonical)

Hermes' planner looks for these section headers; matching them improves
how the skill gets surfaced:

- `## When to Use` — trigger conditions. Be specific. Verb phrases.
- `## Procedure` — what to do, in order. Tool surface table belongs here.
- `## Pitfalls` — known failure modes and how to recover.
- `## Verification` — how to confirm the result after taking action.

### Substrate-neutrality

The SKILL.md must not reference the operator's substrate. Don't write
"tailnet-only", "lives in `gustus-be` namespace", "Hermes is connected
via `mcp_servers.<app>`" — these are atrium-instance details that
break the moment somebody installs the same SKILL.md on a different
Hermes (a vanilla one, a different distro, a hosted service). Stick to
**what the app does**, **when to call it**, **what tools to use**.

## Skill discovery + install (Hermes-native)

Apps publish their SKILL.md at `https://${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}/.well-known/agent-skill`.
**Hermes ships the install motion** — atrium doesn't write any
discovery code. The operator runs:

```bash
kubectl -n hermes exec deploy/hermes -c dashboard -- \
  /opt/hermes/.venv/bin/hermes skills install https://api.<app>.<domain>
```

`well-known` is one of Hermes' six install sources (alongside
`official`, `skills-sh`, `github`, `clawhub`, `claude-marketplace`).
Skill lands on the PVC under `~/.hermes/skills/`. Update by running the
same command; remove with `hermes skills uninstall <name>`. Bundle
multiple installed skills under one `/<bundle>` slash command with
`hermes bundles create`. None of this is atrium code — atrium just
ensures your app exposes the well-known endpoint correctly.

## What the bridge script does

`./scripts/apply-app.sh <app-name> [--path /path/to/app/repo]`:

1. Reads `cluster.config.yaml` from atrium.
2. Resolves the app's repo path (default: `../<app-name>/`).
3. Exports `CLUSTER_DOMAIN`, `ACME_EMAIL`, `APP_NAME`, `APP_FE_HOSTNAME`,
   `APP_BE_HOSTNAME`.
4. Validates the app has a `deploy/k8s/kustomization.yaml`.
5. Runs `kubectl kustomize <app-repo>/deploy/k8s | envsubst | kubectl apply -f -`.
6. Prints a one-liner showing how to install the skill once the pods
   are ready.

No magic. The bridge is 50 lines of bash. Goal 2 replaces it with a
Flux `Kustomization` that pulls the app's repo via `GitRepository` and
applies it on every reconcile.

## Conventions checklist

For an app author asking "is my app atrium-shape-compliant" — items
apply per the deployment shape (A/B/C/D above):

- [ ] **(B/C/D)** Repo contains `deploy/k8s/kustomization.yaml` with the full bundle
- [ ] Namespaces match the shape: `<app>` for C, `<app>-fe` for B, `<app>-be`+`<app>-fe` for D
- [ ] No resources in the `hermes` namespace
- [ ] Hostnames use the right env vars per shape: `${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}` (B/C/D) and `${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}` (D only)
- [ ] TLS via `wildcard-tls` Secret (mint a `Certificate` resource in
      each namespace against `ClusterIssuer/letsencrypt-prod`)
- [ ] Labels include `app.kubernetes.io/{name,component,part-of}` with
      `part-of: atrium-app`
- [ ] **(C/D)** Backend serves `/.well-known/agent-skill` returning the SKILL.md
      content. **(B)** Skill manifest lives on the *provider's* domain — not atrium's responsibility.
- [ ] **(C/D)** Backend serves `/mcp` as a streamable HTTP MCP endpoint
- [ ] **(D only)** CORS configured to allow the frontend's origin
- [ ] SKILL.md is substrate-neutral: no references to atrium, k8s
      internals, or specific mesh implementations

That's the contract. Apps that match it install in one command and run
correctly. Apps that don't can still be deployed — atrium just won't
help.
