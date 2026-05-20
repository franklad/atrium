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

## Required shape

### Namespaces

| Namespace | Hosts | Notes |
|---|---|---|
| `<app>-be` | Backend (API + MCP + per-app data store) | The "SaaS-shaped" half. Stays put even if the frontend gets replaced. |
| `<app>-fe` | Frontend (SPA, Next.js, static site, whatever) | The "consumer app" half. Optional — apps without a UI (CLI-shaped tools, headless integrations) skip this. |

Apps may use a single `<app>` namespace if they don't need the tier
split (e.g. a CLI-shaped tool with no frontend). Skip `<app>-fe` in
that case; keep `<app>-be` for consistency with the SaaS-shaped pattern.

Apps **must not** deploy anything into the `hermes` namespace. That
namespace is reserved for the agent.

### Hostnames

| Surface | Hostname | Served by |
|---|---|---|
| Frontend | `${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}` (default: `<app>.<domain>`) | `<app>-fe/Service` via Traefik Ingress |
| Backend API + MCP | `${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}` (default: `api.<app>.<domain>`) | `<app>-be/Service` via Traefik Ingress |
| Skill manifest | `${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}/.well-known/agent-skill` | Same backend, dedicated route |
| MCP endpoint | `${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}/mcp` | Same backend, dedicated route |

Both hostnames must have a public DNS A record pointing at the node's
mesh IP. The wildcard cert (`*.<CLUSTER_DOMAIN>`) covers both — no
per-app cert work.

The MCP endpoint **is publicly reachable** (gated by bearer auth at the
app's discretion). This is intentional: the same shape works whether
Hermes runs in the same cluster or on a different machine entirely.
Cluster-internal MCP URLs (`<svc>.<ns>.svc.cluster.local`) are an
implementation detail apps shouldn't rely on.

### Env vars atrium provides

The bridge script (`scripts/apply-app.sh`) renders the app's bundle via
`envsubst`. These variables are populated from `cluster.config.yaml`
and the app's identity:

| Variable | Value | Source |
|---|---|---|
| `CLUSTER_DOMAIN` | The atrium operator's domain (e.g. `example.com`) | `cluster.config.yaml.cluster.domain` |
| `ACME_EMAIL` | LE contact email | `cluster.config.yaml.acme.email` |
| `APP_NAME` | The app's identifier (lowercase, kebab) | `apply-app.sh` arg |
| `APP_FE_HOSTNAME` | Frontend hostname *prefix* (default: `${APP_NAME}`) | Convention; override in `cluster.config.yaml.apps.<app>.fe_hostname` |
| `APP_BE_HOSTNAME` | Backend hostname *prefix* (default: `api.${APP_NAME}`) | Convention; override in `cluster.config.yaml.apps.<app>.be_hostname` |

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

For an app author asking "is my app atrium-shape-compliant":

- [ ] Repo contains `deploy/k8s/kustomization.yaml` with the full bundle
- [ ] Namespaces are `<app>-be` (+ `<app>-fe` if there's a UI)
- [ ] No resources in the `hermes` namespace
- [ ] Hostnames use `${APP_FE_HOSTNAME}.${CLUSTER_DOMAIN}` and
      `${APP_BE_HOSTNAME}.${CLUSTER_DOMAIN}` placeholders
- [ ] TLS via `wildcard-tls` Secret (mint a `Certificate` resource in
      each namespace against `ClusterIssuer/letsencrypt-prod`)
- [ ] Labels include `app.kubernetes.io/{name,component,part-of}` with
      `part-of: atrium-app`
- [ ] Backend serves `/.well-known/agent-skill` returning the SKILL.md
      content (or pointing at it)
- [ ] Backend serves `/mcp` as a streamable HTTP MCP endpoint
- [ ] CORS configured to allow the frontend's origin (if FE + BE split)
- [ ] SKILL.md is substrate-neutral: no references to atrium, k8s
      internals, or specific mesh implementations

That's the contract. Apps that match it install in one command and run
correctly. Apps that don't can still be deployed — atrium just won't
help.
