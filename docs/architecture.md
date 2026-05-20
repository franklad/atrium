# Atrium — design

**Atrium is a distribution of [Hermes](https://hermes-agent.nousresearch.com/).**
Ubuntu to Hermes' Linux kernel. Hermes is the agent harness — model
routing, OAuth, channels, plugins, skills, the dashboard control plane.
Atrium curates an opinionated bundle on top: a deploy substrate (k3s +
Tailscale + cert-manager today; lighter substrates planned), an extended
skill contract that makes third-party apps cleanly callable, an install
motion for those apps, and a stance on auth/trust between user, agent,
and apps.

This is the spine. It says what atrium *is*, what it contains, why the
shape is what it is, and exactly how to install it. One file. Read it
top to bottom.

If you only read three sections, read **[What atrium adds above Hermes](#1-5-what-atrium-adds-above-hermes)**,
**[Provider abstraction](#4-provider-abstraction)**, and **[Bootstrap runbook](#6-bootstrap-runbook)**.

---

## 1. The platform thesis

The "agentic OS" is the runtime where **client-side apps live such that an
agent can dispatch to them and a user can reach them directly.** A
desktop OS gives a human a window manager and apps. **Atrium gives an
agent (and through it, the user) a fleet of callable apps.**

The division of labor that makes it work:

| Layer | Who owns it | What they bring |
|---|---|---|
| **Model** | Model providers (Anthropic, OpenAI, OpenRouter, local…) | The brain. Tokens. |
| **Harness** | Agent runtimes (Hermes, others) | The shell. Planning. Tool dispatch. Channel adapters. Cron. Sessions. |
| **Apps** | Third parties (Spotify, Airbnb…) and the operator (local CLIs, custom tools) | A capability and a contract. **Not AI.** |
| **Distribution** | Atrium | Substrate, contract layer, install UX, opinions, brand |

The non-obvious point: **SaaS apps don't run AI.** They expose a contract
that any agent harness can call. The user pays one model provider once
(via their harness), and that one subscription animates every app they
install. Spotify shouldn't ship a chat UI with their own LLM; they
should ship a manifest that any agent can read and act on.

This unblocks composition:

```
User: "extract the artist from this album cover and queue their top tracks"
  → Hermes
    → local image-parser app  (operator's laptop)        → "Pink Floyd"
    → Spotify app             (Spotify's infrastructure) → spotify:artist:...
    → Spotify app             → queue updated
  → Hermes → User: "queued."
```

Three apps. Two clouds (or one cloud + one laptop). One agent. One model
subscription. Zero coordination between Spotify and the image parser.
That's the platform.

Three properties hold the distribution together:

1. **One repo, one install motion** for the operator's substrate. Cluster
   wiring, the Hermes deploy, and the contract layer live in one tree.
2. **Configurable, not personal.** Everything host-specific lives in a
   single `cluster.config.yaml` gitignored at the repo root. A stranger
   cloning atrium sees a platform, not someone else's snapshot.
3. **Provider-free at goal 1.** Atrium boots Hermes + dashboard on a
   private mesh with **no model provider configured** — proving the
   platform is real before committing to a provider or auth flow.

The platform stays neutral about *which* agent runs and *which* model
provider feeds it. Today that's Hermes; the contract is portable to
anything that speaks MCP and reads a `config.yaml`.

---

## 1.5. What atrium adds above Hermes

Hermes is already most of the runtime. The dashboard's `/api/*` surface
exposes config, models, providers, keys, plugins, skills, profiles,
cron, sessions, auth, and the channel gateway — every Hermes
functionality is programmable, not just viewable. Atrium does not
duplicate any of that.

What atrium adds, by category:

| Layer | Hermes-native | Atrium adds |
|---|---|---|
| **Skill contract** | `SKILL.md` with name/description/triggers — instruction-flavored | Extended SKILL.md with OAuth flow spec, capability semantics, trust class, UI hint, versioning — service-contract-flavored. See `docs/skill-contract.md` (forthcoming). |
| **Skill discovery** | Filesystem rglob over `~/.hermes/skills/` | A convention for public skill manifests (`/.well-known/agent-skill.json` on the app's domain), so a user can `atrium install <url>` for any third-party app |
| **App auth** | API-key + OAuth flows *for model providers* | OAuth orchestration *for apps* (Spotify, Google, etc.) with per-skill trust profiles |
| **Substrate** | None — Hermes is a binary/image; where it runs is the operator's problem | Opinionated deployments: k3s+Tailscale+cert-manager today; docker-compose planned; native-systemd planned |
| **First-party app runtime** | None — Hermes calls remote MCP endpoints, doesn't host them | A place to run the operator's own apps (gustus/pantry-shaped) alongside Hermes, with shared infra (Postgres, certs, ingress) |
| **Curated defaults** | Neutral on channels/plugins/SOUL | An opinionated default `SOUL.md`, default channel set, default plugin posture, default secret-management (SOPS+age) |

The split is intentional: anything that benefits every Hermes user
(richer SKILL.md fields, OAuth orchestration primitives) gets proposed
upstream once proven in atrium. Anything that's an *opinion* (this
particular substrate, this particular default voice, this particular
trust model) stays in atrium where opinions are welcome.

Atrium does not fork Hermes. It depends on Hermes upstream and
contributes back. The relationship is the same as Ubuntu's to the
Linux kernel.

---

## 2. Topology (goal-1 state, k3s substrate)

This section describes the **k3s + Tailscale + cert-manager substrate** —
atrium's first opinionated deployment, currently the only one. Other
substrates (docker-compose, native systemd) will live as peers under
`deploy/` and follow the same principles below; only the realization
changes.

Atrium is **private-mesh-first**: ingress lives on a single-tenant overlay
network, not on the public internet. The principle is *no public
services* — the IPs that serve traffic are mesh-only routable. Tailscale
is the default mesh implementation (Headscale is a drop-in alternative;
other meshes — Nebula, Innernet, ZeroTier — are a future seam, §8).
Public-internet ingress (Cloudflare Tunnel, internet-facing LoadBalancers)
is an explicit non-goal — it contradicts the single-tenant thesis.

DNS is the one place we *do* use public infrastructure, and it's
intentional. Public DNS publishes `<host>.<your-domain>` as an A record
to the node's **mesh address** (e.g. a Tailscale CGNAT 100.x.y.z). The
DNS answer is public; the IP it resolves to is private — only mesh
members can route to it. Non-members get the DNS answer, attempt the
connection, and time out. This shape gives us standard LE certs over
DNS-01 (no service ever needs to be publicly reachable for cert
validation) and avoids browser DNS-over-HTTPS interop pain (DoH bypasses
the OS resolver, so MagicDNS-style private resolution silently breaks
in modern browsers).

```
              ┌─ operator's mesh member (laptop, phone) ──────┐
              │                                              │
              ▼                                              │
    https://hermes.<your-domain>                             │
          │  (public DNS A record → node's mesh IP)          │
          │  IP only routable from mesh members              │
          ▼                                                  │
    k3s Traefik :443  (binds node's mesh IP via ServiceLB)   │
          │  Host: hermes.<your-domain>                      │
          │  TLS: wildcard-tls (cert-manager + LE DNS-01)    │
          ▼                                                  │
    Service/hermes-dashboard  (ClusterIP :9119)              │
          │                                                  │
          ▼                                                  │
    Pod: hermes  (single replica)                            │
    ├── command: /opt/hermes/.venv/bin/hermes dashboard      │
    │     --host 0.0.0.0 --port 9119 --no-open --insecure   │
    ├── /opt/data            (PVC, ~/.hermes)                │
    └── envFrom: hermes-env  (Secret absent / empty)         │
                                                             │
    (no provider configured; chat tab errors on use;         │
     dashboard SPA, sessions/jobs/metrics tabs render)       │
                                                             ◄
```

Single node. Single tenant. Everything south of the node's mesh edge is
unencrypted plaintext between k8s services — TLS lives at the Traefik
ingress. **The trust boundary is the private mesh.** Public DNS leaks
"hostname → private IP"; that's useless to anyone outside the mesh.

What's intentionally absent at goal 1:
- No Flux. Plain kustomize+envsubst render via `scripts/apply.sh`.
- No image automation (manual SHA tag bumps).
- No app pods (gustus, pantry, future MCP skills — all goal 2).
- No provider keys, OAuth tokens, or active chat surface.
- No SOPS-encrypted Secrets in git (age key pre-seeded for goal 2;
  Cloudflare token created out-of-band; provider Secrets are TBD).

---

## 3. Repo layout

```
atrium/
├── README.md                       Short. Points here.
├── cluster.config.example.yaml     Template. Checked in.
├── cluster.config.yaml             Gitignored. Per-host values live here.
├── .gitignore                      Ignores cluster.config.yaml + age key + secrets.
│
├── deploy/
│   ├── platform/                   Cluster-wide infra (cert-manager Issuer + wildcard cert).
│   │   ├── cluster-issuer.yaml     ClusterIssuer letsencrypt-prod w/ Cloudflare DNS-01
│   │   ├── wildcard-cert.yaml      Certificate *.${CLUSTER_DOMAIN}
│   │   └── kustomization.yaml
│   └── hermes/                     Hermes deploy bundle.
│       ├── 00-namespace.yaml
│       ├── 10-pvc.yaml
│       ├── 20-config.yaml          Provider-less Hermes config (ConfigMap)
│       ├── 40-deployment.yaml      ServiceAccount + Hermes Deployment
│       ├── 50-service.yaml         ClusterIP for the dashboard
│       ├── 60-ingress.yaml         Traefik Ingress on ${HERMES_HOSTNAME}.${CLUSTER_DOMAIN}
│       ├── SOUL.md                 The agent's voice; rendered into the hermes-soul ConfigMap at kustomize build time
│       └── kustomization.yaml
│
├── scripts/
│   └── apply.sh                    Reads cluster.config.yaml, renders templates via envsubst, applies.
│
├── docs/
│   └── architecture.md             This file. The only doc until goal 2.
│
└── (goal-2 seams, NOT present yet — listed for clarity)
    ├── platform/clusters/default/  Flux root, lands when Flux returns at goal 2 (§8)
    ├── platform/infrastructure/    Flux-managed infra additions
    ├── platform/apps/              Flux pointers to per-app repos
    └── contracts/                  SKILL.md schema + network/ingress contracts
```

### Two-bundle layout

`deploy/platform/` and `deploy/hermes/` are separate kustomize bundles
because they have different change cadences: platform infra (issuers,
wildcard certs, future cluster-scoped wiring) churns rarely; the Hermes
deploy churns with image bumps and config tweaks. The `scripts/apply.sh`
applies them in order — platform first, hermes second — so the wildcard
cert exists before the Ingress references its Secret.

### Why each top-level entry exists

| Entry | Why |
|---|---|
| `cluster.config.yaml` (gitignored) | One file is the difference between a platform and a snapshot. Everything host-specific lives here — domain, mesh suffix, node hostname, age recipient, ACME email, active model provider config. Gitignored because it carries identity, not because it's secret in the SOPS sense. Templates reference its values via `${CLUSTER_DOMAIN}`, `${HERMES_HOSTNAME}`, `${ACME_EMAIL}`; `scripts/apply.sh` does the substitution at install time. |
| `cluster.config.example.yaml` (checked in) | The template. Includes commented-out blocks for every supported provider+auth combination. A stranger cloning the repo sees the shape immediately. |
| `scripts/apply.sh` | The install command. Reads `cluster.config.yaml`, exports its values as env vars, runs `kubectl kustomize <dir> \| envsubst \| kubectl apply -f -` for `deploy/platform/` then `deploy/hermes/`. Prereqs: yq, envsubst, kubectl. |
| `deploy/platform/` | Cluster-wide infra: cert-manager `ClusterIssuer` (Let's Encrypt prod, Cloudflare DNS-01) + wildcard `Certificate` for `*.${CLUSTER_DOMAIN}`. cert-manager itself is installed once via Helm — see §6.7. |
| `deploy/hermes/` | The Hermes deploy. Provider-less ConfigMap, Deployment running `hermes dashboard`, Service, Traefik Ingress. |
| `deploy/hermes/SOUL.md` (committed) | The agent's voice and character — direct, decisive, serves the mission. One good default that ships with the repo; fork and edit if you want a different voice. Rendered into the `hermes-soul` ConfigMap by the kustomize `configMapGenerator`. Operator-configurable SOUL (without forking) is a goal-2+ seam (§8). |
| `docs/architecture.md` | Why the system is what it is. One file. |

### What atrium does *not* contain

- **Per-app source or per-app deploy manifests.** Each MCP skill app lives in its own repo. Atrium registers them via Flux pointers in goal 2.
- **The Hermes container image.** Pulled from `docker.io/nousresearch/hermes-agent`. Atrium owns the *deploy*, not the agent.
- **Secrets in plaintext.** Goal 1 has no real secrets; goal 2 adds SOPS-encrypted Secrets under `platform/infrastructure/secrets/`.
- **Multi-cluster wiring.** One cluster. The would-be Flux root is named `default/` so it's obvious it's the only one.

### Hermes lives in atrium

| Component | Where | Why |
|---|---|---|
| Cluster wiring (k3s, Tailscale Operator, certs later, Flux later) | `atrium/` | This is the platform. |
| Hermes deploy manifests | `atrium/deploy/hermes/` (goal 1), `atrium/platform/apps/hermes/` (goal 2) | Hermes is *part of* the platform. Without it there is no agentic OS. |
| Hermes container image | upstream `nousresearch/hermes-agent` | Third party. Pin a tag. |
| MCP skill apps | their own repos with `deploy/k8s/` | App lifecycle is decoupled from platform lifecycle. New app == new repo + one Flux pointer (goal 2). |

---

## 4. Provider abstraction

**The most load-bearing section of this doc. Read it twice.**

Atrium does not commit to any model provider or any auth flow. The platform
boots without one. The seam to add one is neutral across every combination
the operator might choose now or later.

### The principle

The cluster is the platform. The agent is the shell. **The model provider is
configuration.** The platform must:

1. Boot to a working state with **no provider configured at all**.
2. Accept any of the supported provider+auth combinations through a single
   neutral seam.
3. Not bake provider-specific assumptions into manifests, scripts, docs, or
   contracts anywhere outside the seam itself.

The operator is going to settle on a provider+auth combination later. The
design has no opinion on which one.

### Supported combinations (5)

| # | Combination | Auth model | Where credentials live |
|---|---|---|---|
| A | **Anthropic API key** | Static API key | `ANTHROPIC_API_KEY` in `hermes-env` Secret |
| B | **Anthropic OAuth (Claude.ai subscription)** | OAuth (browser flow), refreshable token | `~/.hermes/auth.json` on the PVC (initial flow run from a pod exec or sidecar; see "OAuth seam" below) |
| C | **OpenRouter** | Static API key | `OPENROUTER_API_KEY` in `hermes-env` Secret |
| D | **OpenAI** | Static API key | `OPENAI_API_KEY` in `hermes-env` Secret |
| E | **Local / OpenAI-compatible (Ollama, vLLM, LM Studio, any `base_url`)** | Optional API key or none | `base_url` in Hermes `config.yaml`; optional `api_key` env |

These five cover the realistic operator choices. Anything else
OpenAI-compatible drops into (E) by changing one `base_url`.

### What the goal-1 cluster ships

- **No provider configured.** Hermes `config.yaml` has no `model:` block, no
  `auxiliary:` block, no `fallback_model:`, no `platforms:` chat
  integrations. The dashboard SPA renders; chat returns "no provider
  configured" on use.
- **`hermes-env` Secret absent** (or present-and-empty). Hermes' Deployment
  references it via `envFrom` with `optional: true` so its absence doesn't
  block scheduling.
- **`cluster.config.example.yaml` carries a `providers:` section** with all
  five combinations spelled out, **all commented out**. The operator
  uncomments one when ready.

### Shape of `providers:` in `cluster.config.example.yaml`

Sketch only — the example file in the repo carries the full version. The
shape:

```
providers:
  active: null               # set to one of: anthropic-api, anthropic-oauth,
                             # openrouter, openai, local
  # anthropic-api:
  #   model:
  #     provider: anthropic
  #     model: claude-opus-4
  #   env:
  #     ANTHROPIC_API_KEY: <set via SOPS in goal 2>
  #
  # anthropic-oauth:
  #   model:
  #     provider: codex          # Hermes' codex/Anthropic-OAuth slot
  #     model: claude-opus-4
  #   auth:
  #     flow: oauth-browser      # initial flow runs once; token in auth.json on PVC
  #   env: {}                    # OAuth doesn't carry an API key
  #
  # openrouter:
  #   model:
  #     provider: openrouter
  #     model: anthropic/claude-opus-4
  #   env:
  #     OPENROUTER_API_KEY: <set via SOPS in goal 2>
  #
  # openai:
  #   model:
  #     provider: openai
  #     model: gpt-5
  #   env:
  #     OPENAI_API_KEY: <set via SOPS in goal 2>
  #
  # local:
  #   model:
  #     provider: openai            # OpenAI-compatible client
  #     model: qwen2.5-coder:32b
  #     base_url: http://ollama.ollama.svc.cluster.local:11434/v1
  #     api_key: ollama             # placeholder; Ollama ignores it
  #   env: {}
```

### Three artifacts the seam touches, and only these

1. **`cluster.config.yaml`** (gitignored, per-host) carries `providers.active`
   plus the active block. The example file documents all five.
2. **`hermes-env` Secret** in the `hermes` namespace carries the env vars
   the active provider needs (zero, one, or more keys). Plain `Opaque`
   Secret at goal 1; SOPS-encrypted at goal 2.
3. **Hermes' `config.yaml`** carries the `model:` / `auxiliary:` /
   `fallback_model:` blocks the active provider expects. **At goal 1, it has
   no provider blocks at all.**

Nothing in `deploy/hermes/40-deployment.yaml`, `50-service.yaml`, or any
script changes when the operator picks a provider. The Deployment already
does `envFrom: [{secretRef: {name: hermes-env, optional: true}}]`. The
ConfigMap is the only manifest that grows a `model:` block.

### OAuth seam (for combinations B and similar)

Anthropic OAuth, MiniMax OAuth, xAI Grok OAuth, and future OAuth providers
need a browser-driven initial flow that lands a token at
`~/.hermes/auth.json` on the PVC. Token refresh after that is Hermes'
problem, not the platform's.

The seam:

- **One-time initial flow**: `kubectl -n hermes exec -it deploy/hermes -- hermes model`,
  pick the OAuth provider, follow the URL printed in the pod logs from a
  tailnet-connected browser. Token lands on the PVC and survives pod
  restarts.
- **Token refresh**: Hermes refreshes in-process. Nothing for the platform
  to do.
- **If a sidecar/init container is ever needed** (e.g. for headless re-auth),
  it lives at `deploy/hermes/45-oauth-sidecar.yaml`. Not designed yet.
  Listed here so the seam is named.

### What goal-2 picks (deferred)

The operator explicitly defers the goal-2 wiring mechanism. Two shapes are
viable; **do not pick one until after goal 1.5**:

- **Config-file-driven**: operator edits `cluster.config.yaml`, edits the
  Hermes `config.yaml` ConfigMap (or has a `render-config.sh` script that
  generates the ConfigMap from `cluster.config.yaml.providers.<active>`),
  edits the SOPS-encrypted `hermes-env` Secret, commits, Flux reconciles.
  Everything in git, everything auditable.
- **Dashboard-driven**: operator logs into the Hermes dashboard, configures
  the provider through whatever UI Hermes exposes. Hermes writes through to
  `~/.hermes/config.yaml` and `~/.hermes/.env` on the PVC. Atrium's
  ConfigMap and Secret become bootstrap seeds that the dashboard overrides
  at runtime.
- **Both**: atrium's ConfigMap+Secret are the bootstrap; the dashboard can
  also mutate the PVC copies for ad-hoc tweaks; periodic reconcile would
  blow away dashboard changes. This combination needs the most thought.

Implication for goal 1: **do not bake the canonical Hermes `config.yaml`
into a committed file that the platform reconciles on every Flux loop until
we know whether the dashboard wants to write to it.** Goal 1 ships the
ConfigMap; that's fine because there's no Flux yet. Goal 2 needs to revisit
this.

### Banned assumptions

| Anti-pattern | Atrium's rule |
|---|---|
| A specific provider env var referenced as "the upstream" anywhere outside the seam | The active provider, whichever it is, is the only upstream. No prose, no manifest, no script names a specific provider as the default. |
| Manifests `envFrom` a Secret whose absence crashes the pod | `envFrom` carries `optional: true`. Provider-less boot is a first-class state. |
| Provider-specific health checks | Health checks probe Hermes' dashboard, not any provider. |
| Provider-specific egress NetworkPolicies | Goal-1 has no NetworkPolicy. Goal-2 egress allow is "TCP/443 to public" — provider-neutral. |

---

## 5. Goal 1: what we're shipping

The smallest atrium that does something real: **k3s on a single node,
Hermes pod running, dashboard reachable from mesh members at
`https://hermes.<your-domain>` with a valid LE wildcard cert, SPA renders
in any browser (no DoH workarounds), sessions/jobs/metrics tabs render
with empty data, no provider configured, no apps.**

### Success criteria

A goal-1 install is done when, from a mesh-connected workstation:

1. `curl -I https://hermes.<your-domain>` returns `HTTP/2` with a valid
   Let's Encrypt cert (no `-k` flag).
2. A browser at the same URL renders the Hermes dashboard SPA with a
   green lock icon. Works in Chromium-based browsers (Arc, Chrome, Edge,
   Brave) with DoH on — the DNS name is publicly resolvable, the IP is
   mesh-only routable.
3. The sessions / jobs / metrics / logs tabs render. Empty data is fine.
4. `kubectl -n hermes get pods` shows `hermes-<hash> 1/1 Running` with
   no restarts.
5. `kubectl -n hermes logs deploy/hermes` shows clean dashboard startup.
   Auxiliary-provider warnings (openrouter / Nous "unhealthy for 60s")
   are *expected* with no provider configured — they're not errors.

### What's in

- k3s `v1.36.0+k3s1` on a single node (reference hardware: Ubuntu 24.04,
  ~4 GB RAM, 4 vCPU — atrium is validated at this size; larger is fine).
- Tailscale Operator (Helm-installed; provides outbound device identity
  in goal 2 but isn't on the goal-1 ingress path).
- cert-manager (Helm-installed) with a `letsencrypt-prod` ClusterIssuer
  using Cloudflare DNS-01, plus a wildcard Certificate for
  `*.<your-domain>` issued into the `hermes` namespace.
- k3s' bundled Traefik fronts the dashboard via a standard Ingress.
- Hermes Deployment (provider-less `config.yaml`), Service, Ingress, PVC,
  `hermes-soul` ConfigMap (generated from `deploy/hermes/SOUL.md`).
- A public DNS A record `hermes.<your-domain> → <node's mesh IP>` (e.g.
  the node's Tailscale CGNAT 100.x.y.z). The IP is mesh-only routable.
- SOPS age private key pre-seeded into `flux-system/sops-age` (unused at
  goal 1; future-proofs goal 2 SOPS adoption).

### What's out (explicitly deferred to goal 2 or later)

| Thing | Why deferred |
|---|---|
| Any model provider key or OAuth flow | The whole point of goal 1 — see §4. Active chat needs a provider. |
| Flux GitOps (source, kustomize, helm, image-reflector, image-automation) | A 6-controller, ~400 MB dependency. Payoff is wasted on ~10 manifests. Returns in goal 2 with multi-app payload + image automation. |
| Image automation (auto-bump on new SHA tags) | Manual SHA tag bump in `deploy/hermes/40-deployment.yaml` for now. |
| Shared Postgres (`database` namespace) | No app needs DB until goal 2 apps land. |
| Any MCP skill app | App lifecycle decoupled from platform. |
| Telegram / Discord / Slack / any chat platform | Channels need a provider. No provider in goal 1. |
| NetworkPolicies | One pod, one path. Default-allow is fine until apps land. |
| htpasswd / OIDC dashboard auth | Mesh ACL is the auth boundary. |
| Backups | No state worth backing up at goal 1. |
| Multi-tenant, multi-operator, multi-cluster | Out of scope forever. |

---

## 6. Bootstrap runbook

The exact procedure. Every command. Run from a workstation with `kubectl`,
`ssh`, `sops`, `age`, `gh` installed, and SSH access to the target node as
a user with sudo.

Total wall time, fresh start to dashboard reachable: ~10–15 minutes.

> **Example values used throughout this runbook:** host `logos`, tailnet IP
> `100.83.47.56`, LAN IP `192.168.2.200`. These are the reference cluster.
> Substitute your own from `cluster.config.yaml` everywhere they appear.

### 6.1 Prereqs and credentials

**Tools on the workstation:** `kubectl`, `helm`, `yq`, `envsubst`,
`ssh`, `scp`. mise users: `mise use -g yq` covers yq.

**Credentials (three):**

| Credential | Where | Used by |
|---|---|---|
| SOPS age private key (`~/.config/sops/age/keys.txt`) | Workstation. Generate with `age-keygen -o ~/.config/sops/age/keys.txt` if absent. Note the public `age1...` line — that's the `age.recipient` for `cluster.config.yaml`. | Pre-seeded into cluster for goal 2. Unused at goal 1. |
| Tailscale OAuth client | Tailscale admin → Settings → OAuth clients → Generate. Scopes: **Devices: Core (Read+Write), Auth Keys: Write**. Tag with **`tag:atrium-operator`** (must be declared in your tailnet ACL `tagOwners` first — see below). | Tailscale Operator mints tailnet devices and auth keys. |
| Cloudflare API token | https://dash.cloudflare.com/profile/api-tokens → Create Custom Token. Scope: **Zone:DNS:Edit on `<your-domain>`** (Zone:Zone:Read on the same zone is also useful). | cert-manager's DNS-01 solver writes `_acme-challenge.<domain>` TXT records to validate the LE wildcard cert. |

**Tailscale ACL prereq.** Before Tailscale will accept `tag:atrium-operator`
on a device, the tag must be declared as ownable in your tailnet ACL. At
https://login.tailscale.com/admin/acls/file add to the `tagOwners` block:

```jsonc
"tagOwners": {
  "tag:atrium-operator": ["autogroup:admin"],
},
```

**DNS prereq.** A public A record at your DNS provider:

```
hermes.<your-domain>   A   <node's mesh IP>
```

For Tailscale, "node's mesh IP" is the CGNAT 100.x.y.z the tailnet
assigned to the node (find with `tailscale ip --4 <hostname>` from a
mesh member). The record is normal public DNS — but the IP it resolves
to is only routable from mesh members. Non-members get the DNS answer
and time out trying to connect.

### 6.2 Prepare `cluster.config.yaml`

```bash
cd ~/atrium
cp cluster.config.example.yaml cluster.config.yaml
$EDITOR cluster.config.yaml
```

Fill in:
- `cluster.name`, `cluster.domain`
- `cluster.node.{hostname, mesh_ip, lan_ip}`
- `mesh.magic_dns_suffix` (run `tailscale status --json | jq -r '.MagicDNSSuffix'` on any mesh member)
- `mesh.hermes_hostname` (defaults to `hermes` — leave it unless you have a reason)
- `age.recipient` (the public line from `~/.config/sops/age/keys.txt`)
- `acme.email` (your contact address for LE expiry warnings)
- Leave `providers.active: null` — goal 1 ships provider-less.

`cluster.config.yaml` is gitignored. It never enters version control.

### 6.3 Pre-flight on logos

SSH to logos. Idempotent nuke of any prior k3s state:

```bash
sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
sudo /usr/local/bin/k3s-killall.sh   2>/dev/null || true

sudo rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet
sudo rm -rf /opt/appdata /mnt/data
sudo rm -rf /var/lib/cni /etc/cni
sudo rm -f /etc/systemd/system/k3s*.service

sudo systemctl daemon-reload
sudo systemctl reset-failed
```

What survives: Tailscale daemon, SSH host keys, user accounts, non-k3s
packages.

What dies: all k3s state including PVC backing store at
`/var/lib/rancher/k3s/storage`, every ad-hoc manifest applied to prior
clusters.

> If any prior PVC carries data you want to keep (e.g. a Postgres in some
> namespace), dump it BEFORE this step.

Validate:

```bash
which k3s                     # empty
sudo ls /var/lib/rancher 2>&1 # "No such file or directory"
```

### 6.4 Install k3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.0+k3s1 sh -s - \
  --write-kubeconfig-mode=0644 \
  --tls-san=logos \
  --tls-san=100.83.47.56 \
  --tls-san=192.168.2.200 \
  --node-external-ip=100.83.47.56 \
  --cluster-domain=cluster.local
```

Substitute the actual tailnet IP and LAN IP from your `cluster.config.yaml`.

Flag rationale:

| Flag | Why |
|---|---|
| `--write-kubeconfig-mode=0644` | A non-root user can `cp /etc/rancher/k3s/k3s.yaml ~/.kube/config` without sudo. |
| `--tls-san=logos` + tailnet IP + LAN IP | API server cert covers every name a workstation might dial it by. |
| `--node-external-ip=<tailnet IP>` | Tailscale Operator pins its proxy to the right interface. |
| (defaults kept) | Bundled Traefik, ServiceLB, local-path StorageClass, flannel CNI. Idle cost ~0; we'll exercise them as we grow. |

Validate (on logos):

```bash
sudo k3s kubectl get nodes
# logos   Ready   control-plane,master   <age>   v1.36.0+k3s1

sudo systemctl is-active k3s
# active
```

### 6.5 Copy kubeconfig to workstation

From the workstation:

```bash
mkdir -p ~/.kube/configs
scp logos:/etc/rancher/k3s/k3s.yaml ~/.kube/configs/logos

sed -i \
  -e 's|server: https://127.0.0.1:6443|server: https://logos:6443|' \
  -e 's|name: default|name: logos|g' \
  -e 's|cluster: default|cluster: logos|' \
  -e 's|user: default|user: logos|' \
  -e 's|current-context: default|current-context: logos|' \
  ~/.kube/configs/logos

export KUBECONFIG=~/.kube/configs/logos
kubectl config use-context logos
```

If `logos` doesn't resolve from the workstation, substitute the tailnet IP
in the server URL.

Validate:

```bash
kubectl get nodes -o wide
# logos   Ready   ...   100.83.47.56   ...
kubectl get ns
# default, kube-system, kube-public, kube-node-lease
```

### 6.6 Pre-seed the SOPS age key

Unused in goal 1; pre-seeded so goal 2 doesn't re-discover the requirement.

```bash
kubectl create namespace flux-system
cat ~/.config/sops/age/keys.txt | \
  kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin
```

Validate:

```bash
kubectl -n flux-system get secret sops-age
# sops-age   Opaque   1
```

### 6.7 Install Tailscale Operator (Helm)

```bash
kubectl create namespace tailscale

kubectl create secret generic operator-oauth \
  --namespace=tailscale \
  --from-literal=client_id="$TS_CLIENT_ID" \
  --from-literal=client_secret="$TS_CLIENT_SECRET"

helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update tailscale

helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --set-string oauth.clientId="" \
  --set-string oauth.clientSecret="" \
  --set 'operatorConfig.defaultTags={tag:atrium-operator}' \
  --set-string proxyConfig.defaultTags="tag:atrium-operator" \
  --wait --timeout=180s
```

Two non-obvious bits:

- `oauth.clientId`/`clientSecret` are set **empty** so the chart picks up
  the pre-existing `operator-oauth` Secret instead of overwriting it.
- The chart has **two separate tag fields**: `operatorConfig.defaultTags`
  for the operator's own tailnet device, and `proxyConfig.defaultTags`
  for proxies the operator spawns. Both must be in your ACL `tagOwners`.
  Setting only one is a common partial fix that fails reconcile.

Validate:

```bash
kubectl -n tailscale get pods
# operator-<hash>   1/1   Running

kubectl -n tailscale logs deploy/operator --tail=20
# expect AuthLoop "state is Running; done"; no scope/tag errors
```

### 6.8 Install cert-manager (Helm) + Cloudflare Secret

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout=180s

kubectl create secret generic cloudflare-api-token \
  --namespace=cert-manager \
  --from-literal=api-token="$CF_API_TOKEN"
```

Validate:

```bash
kubectl -n cert-manager get pods
# cert-manager / cainjector / webhook all 1/1 Running
kubectl -n cert-manager get secret cloudflare-api-token
# Opaque, 1 data key
```

### 6.9 Render and apply atrium manifests

```bash
cd ~/atrium
./scripts/apply.sh
```

What this does:

1. Reads `cluster.config.yaml`, exports `CLUSTER_DOMAIN`,
   `HERMES_HOSTNAME`, `ACME_EMAIL`.
2. Renders + applies `deploy/platform/` (ClusterIssuer + wildcard
   Certificate). cert-manager validates via Cloudflare DNS-01 and
   produces the `wildcard-tls` Secret in the `hermes` namespace.
3. Renders + applies `deploy/hermes/` (namespace, PVC, ConfigMaps,
   ServiceAccount, Deployment, Service, Ingress).

Manifest set:

| File | What |
|---|---|
| `deploy/platform/cluster-issuer.yaml` | `ClusterIssuer/letsencrypt-prod`, Cloudflare DNS-01 |
| `deploy/platform/wildcard-cert.yaml` | `Certificate wildcard-tls` in `hermes` ns for `*.${CLUSTER_DOMAIN}` |
| `deploy/hermes/00-namespace.yaml` | `Namespace/hermes` |
| `deploy/hermes/10-pvc.yaml` | `PersistentVolumeClaim/hermes-data` 20Gi `local-path` |
| `deploy/hermes/20-config.yaml` | `ConfigMap/hermes-config` (provider-less) |
| `deploy/hermes/40-deployment.yaml` | `ServiceAccount` + `Deployment/hermes` |
| `deploy/hermes/50-service.yaml` | `Service/hermes-dashboard` ClusterIP :9119 |
| `deploy/hermes/60-ingress.yaml` | Traefik Ingress at `${HERMES_HOSTNAME}.${CLUSTER_DOMAIN}` |
| `deploy/hermes/kustomization.yaml` | `configMapGenerator` builds `hermes-soul` from `SOUL.md` |

Key shape decisions baked into the manifests:

- **Image pinned** to a specific Hermes SHA tag (`docker.io/nousresearch/hermes-agent:sha-<sha>`).
- **Binary at an absolute path.** The upstream image doesn't put the
  hermes CLI on `$PATH`; the Deployment uses
  `command: ["/opt/hermes/.venv/bin/hermes"]`.
- **Dashboard-only command.** Args `dashboard --host 0.0.0.0 --port 9119
  --no-open --insecure`. `--insecure` is what *permits* binding non-
  localhost — it's not a TLS-disable flag.
- **`envFrom: hermes-env` with `optional: true`.** Secret may not exist;
  pod boots anyway. This is what makes provider-less boot work.
- **No `API_SERVER_*` env vars.** We don't run `gateway run` / api_server
  — those need a provider to be useful (goal 2).
- **`bootstrap-home` init container** seeds `config.yaml` + `SOUL.md` onto
  the PVC on first boot (`cp -n`).
- **Probes hit `/` on port 9119.** The dashboard returns 200 there;
  the `/health` endpoint belongs to the api_server, not the dashboard.
- **Ingress is class `traefik`.** k3s' bundled Traefik fronts it on the
  node's mesh IP:443 with the cert-manager-issued wildcard.

Watch cert issuance + pod rollout:

```bash
kubectl -n hermes get certificate wildcard-tls -w   # wait for READY=True
kubectl -n hermes get pods                          # hermes-<hash> 1/1 Running
kubectl -n hermes get ingress hermes-dashboard      # ADDRESS = node mesh IP
```

DNS-01 cert issuance can take 30s–3min (one challenge per name; LE
sometimes races on `_acme-challenge.<domain>` when both apex and
wildcard share the TXT name).

### 6.10 Reach the dashboard

From any mesh member:

```bash
curl -I https://hermes.<your-domain>
# HTTP/2 200 (HEAD may return 405 — only GET is allowed; SPA loads fine)
```

Browser to the same URL. Dashboard SPA loads. Sessions / jobs / metrics /
logs tabs render. Chat tab errors on use — that's correct (no provider).

**Goal 1 done.**

### 6.11 End-to-end validation table

| Phase | Check | Expected |
|---|---|---|
| 6.3 | `which k3s; ls /var/lib/rancher 2>&1` | empty; "No such file or directory" |
| 6.4 | `sudo k3s kubectl get nodes` | `<host> Ready control-plane v1.36.0+k3s1` |
| 6.5 | `kubectl get nodes -o wide` | shows `<mesh IP>` as EXTERNAL-IP |
| 6.6 | `kubectl -n flux-system get secret sops-age` | one secret, Opaque |
| 6.7 | `kubectl -n tailscale get pods` | `operator 1/1 Running`; logs show `AuthLoop ... done` |
| 6.8 | `kubectl -n cert-manager get pods` | 3 pods all 1/1 Running |
| 6.9 | `kubectl -n hermes get certificate wildcard-tls` | `READY True` within ~3 min |
| 6.9 | `kubectl -n hermes get pods` | `hermes 1/1 Running` |
| 6.9 | `kubectl -n hermes get ingress` | ADDRESS = node mesh IP, PORTS = 80,443 |
| 6.10 | `curl -I https://hermes.<your-domain>` | `HTTP/2`, valid TLS |
| 6.10 | Browser at same URL | SPA + tabs render, green lock |

### 6.12 Failure modes

**Tailscale Operator reconcile fails with `requested tags [...] invalid or not permitted`.**
The chart's `proxyConfig.defaultTags` (default `tag:k8s`) is separate
from `operatorConfig.defaultTags`. Both tags must exist in your tailnet
ACL `tagOwners`. Fix: either add the missing tag to `tagOwners` in the
ACL, or `helm upgrade` with both set to the same declared tag (see
§6.7).

**cert-manager Certificate stays `READY=False` for >5 min.**
`kubectl -n hermes describe certificate wildcard-tls` and check the
linked `Challenge` resource. Common: Cloudflare token lacks
`Zone:DNS:Edit` scope (challenge logs show 403); DNS propagation is slow
(cert-manager polls authoritative ns; wait or
`kubectl -n cert-manager rollout restart deploy/cert-manager`); ACME
account-key mismatch (delete `letsencrypt-prod-account-key` Secret in
`cert-manager` ns and let it re-register).

**Hermes pod CrashLoopBackOff.**
Diagnose: `kubectl -n hermes logs deploy/hermes --previous`,
`kubectl -n hermes describe pod -l app=hermes | tail -30`.
Common causes: init container `bootstrap-home` choked on a non-empty PVC
from a prior install (`kubectl -n hermes delete pvc hermes-data`,
re-apply); image pull fail (`docker pull` the pinned SHA tag to verify
existence); config parse error (delete PVC, re-apply).

**Dashboard returns 401 / 403.**
The `--insecure` flag is what permits binding to a non-localhost host
(`0.0.0.0`); without it Hermes refuses non-localhost binds. If a 401 or
403 fires anyway, check the dashboard hasn't picked up an unexpected
auth env var; verify the args in the Deployment match the runbook.

**Dashboard URL doesn't resolve from workstation, but `curl` from the workstation works.**
Almost always browser DNS-over-HTTPS. Public DNS publishes
`hermes.<your-domain>` → mesh CGNAT IP correctly, but a browser with DoH
on still queries Cloudflare/Google, which return the answer fine because
the name is publicly resolvable. If a browser fails: check the browser
DNS settings (Arc/Chrome: `arc://settings/security` → Secure DNS to "use
system DNS"). Note this entire issue is *avoided* by using a custom
domain rather than `<host>.<tailnet>.ts.net` — the latter requires
MagicDNS, which DoH bypasses; the former is normal public DNS.

**Workstation can curl but can't ping the node mesh IP.**
Not actually a problem. Tailscale ACL defaults often block ICMP between
devices. The TCP connection on port 443 still works (that's what
`curl` uses). Ignore unless you actually need ping.

**PVC stuck Pending.**
`local-path-provisioner` pod in `kube-system` not Running → k3s install
didn't complete. Back to §6.4.

**k3s install fails with "k3s already installed".**
The uninstall script may have silently no-op'd. Manually
`sudo systemctl stop k3s; sudo systemctl disable k3s; sudo rm /usr/local/bin/k3s* /etc/systemd/system/k3s*`
and rerun §6.4.

### 6.13 You-are-here markers

- After §6.4: **k3s up, no workloads.**
- After §6.6: **age key planted for goal-2 SOPS use. Still no workloads.**
- After §6.7: **Tailscale Operator running, has a tailnet identity.**
- After §6.8: **cert-manager + CRDs ready; Cloudflare token in cluster.**
- After §6.9 (`./scripts/apply.sh`): **wildcard cert issued; Hermes pod 1/1 Running; Traefik routing `hermes.<your-domain>` → dashboard.**
- After §6.10: **Goal 1 complete — dashboard reachable in any browser.**

---

## 7. Hermes is the control plane (goal-1.5 outcome)

The dashboard isn't just a viewer — it's a **programmable control plane**.
Every Hermes capability has a corresponding `/api/*` endpoint with the
same access model the dashboard uses (session bearer):

```
/api/config       /api/models       /api/providers    /api/keys
/api/plugins      /api/skills       /api/profiles     /api/auth
/api/sessions     /api/cron         /api/gateway      /api/system
/api/agents       /api/dashboard    /api/version      /api/health
```

All confirmed reachable (returned `200`) against a goal-1 install with
the SPA's session token. Implications for the rest of atrium:

- **Goal-2 provider wiring is dashboard- and API-driven**, not
  config-file-driven. Atrium's `deploy/hermes/20-config.yaml` is the
  *initial seed* of Hermes' on-disk `config.yaml`; once Hermes boots,
  the dashboard owns mutations. The ConfigMap is read on first boot
  (via `cp -n`) and not reconciled after that.
- **`cluster.config.yaml.providers.*` is for operators who prefer
  declarative-everything**, not the canonical path. The default
  goal-2 motion is: log into the dashboard, paste credentials, done.
- **App install motion targets `/api/skills`**. Atrium's future
  `atrium install <skill-url>` CLI fetches a SKILL.md, runs any OAuth
  flow the manifest declares, then POSTs to Hermes' `/api/skills`.
  No k8s manifest changes; no pod restarts; live registration.

The `metadata.atrium.*` extensions to SKILL.md (OAuth flow, trust
class, capability semantics) are precisely the fields the install
motion reads. The contract lives in `docs/skill-contract.md`
(forthcoming); §4 of this document describes the provider seam that
hangs off it.

---

## 8. Seams for later

Goal 1 is a launchpad. These are the named extension points so goal-1
choices don't paint goal-2 work into a corner.

| Future capability | Seam | Notes |
|---|---|---|
| **Model provider** (goal-1.5 resolved → dashboard/API) | Operator configures providers via the Hermes dashboard or `/api/providers`/`/api/keys`. Atrium's role is shipping a sensible empty seed (`deploy/hermes/20-config.yaml`) and not getting in the way. `cluster.config.yaml.providers.*` is the optional declarative path for operators who want everything in git. | Deployment already does `envFrom: hermes-env` with `optional: true`. No manifest changes when a provider is added; just a Secret + a dashboard config. |
| **Extended SKILL.md contract** | `docs/skill-contract.md` (forthcoming) specs the `metadata.atrium.*` fields: OAuth flow, capability semantics, trust class, UI hint, versioning. Hermes reads these as opaque frontmatter today; atrium tooling interprets them. Reference designs: a SaaS app (Spotify-style) and a local CLI tool. | This is atrium's unique value above Hermes — see §1.5. Mature fields get proposed upstream. |
| **App install motion** | `atrium install <skill-url>` CLI: fetches the SKILL.md, runs any OAuth flow it declares, POSTs to Hermes' `/api/skills`. Companion to a `/.well-known/agent-skill.json` convention for public skill manifests. | Maps to Hermes' existing `/api/skills` programmatic surface (confirmed §7). No Hermes changes needed for v1. |
| **Public skill discovery** | A loose convention: app authors publish their SKILL.md at `https://<their-domain>/.well-known/agent-skill.json` so any harness's install tooling can pick it up. Like `robots.txt` but for agent skills. | The convention only needs adoption by app authors. Atrium's tooling reads it; Hermes upstream could too. |
| **Alternative substrates** | `deploy/docker-compose/` for single-host without k3s; `deploy/native/` for systemd units on the operator's machine. Same `cluster.config.yaml` schema; the substrate is the part that changes. | The k3s+Tailscale substrate (`deploy/platform/` + `deploy/hermes/`) is one opinion. Lighter substrates reduce the operational floor for new operators. |
| **Upstream contributions** | Promote `metadata.atrium.*` fields, OAuth orchestration primitives, and install-motion patterns into Hermes proper once validated. | Atrium stays the *distribution* — opinions, defaults, substrate. The contract layer dissolves into Hermes upstream over time, the way GNU/Linux conventions become POSIX. |
| **Flux GitOps** | `platform/clusters/default/` Flux root, `platform/apps/<app>.yaml` pointers per app, `platform/infrastructure/` for shared resources. `flux bootstrap github --owner ... --repo atrium --path platform/clusters/default`. Existing `deploy/platform/` + `deploy/hermes/` move under `platform/`. | Adds source/kustomize/helm/notification controllers + (optional) image-reflector/image-automation. Flux's `postBuild.substituteFrom` replaces `scripts/apply.sh` for the templating dance. |
| **SOPS-encrypted Secrets in git** | Encrypt provider Secrets, Cloudflare token, etc. with the age key pre-seeded in `flux-system/sops-age` (§6.6). Flux's kustomize-controller decrypts on apply. | Today: Secrets are created out-of-band (kubectl create + tempfile). Goal 2 brings them into git. |
| **Image automation** | `--components-extra=image-reflector-controller,image-automation-controller` on `flux bootstrap`. Per-app `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`. Tag scheme `<unix-ts>-sha-<git-sha>` + a `$imagepolicy` marker comment on each `image:` line. | Today: manual SHA bump in `deploy/hermes/40-deployment.yaml`. |
| **Multiple Ingresses + Traefik middleware** | Per-app Ingress with `ingressClassName: traefik`; shared wildcard cert (already in place). Optional middleware like basic-auth via `Middleware` CRD. | Today: only the Hermes Ingress exists. Wildcard cert already covers any future `<app>.<cluster.domain>` Host. |
| **MCP skill apps** | `platform/apps/<app>.yaml` is a Flux `GitRepository` + `Kustomization` pointing at the app's `deploy/k8s/`. App ships its own `SKILL.md` ConfigMap labelled `role=skill` in the `hermes` namespace. Hermes' `collect-skills` init container (returned at goal 2) discovers it. | Zero changes to Hermes Deployment per new app. |
| **Shared Postgres** | `platform/infrastructure/controllers/postgres.yaml` + per-app `<app>-db` Secret. | Install when first app needs DB. |
| **Chat platforms (Telegram, Discord, Slack)** | `hermes-env` gets channel tokens; ConfigMap's `platforms:` block grows the platform name. Per-platform NetworkPolicy egress covered by "TCP/443 to public" when NetworkPolicy lands. | Requires a provider (goal 2+). |
| **App-to-app calls** | Hermes' `delegate_tool` + per-app `mcp_servers.<name>` in `config.yaml`. Always mediated by Hermes. | No direct app-to-app NetworkPolicy needed. |
| **RBAC / capability gating** | `metadata.atrium.auth-class` field in `SKILL.md` frontmatter. v1 enum `{open, hermes-only}`. | Field exists in the schema from day one of contracts; goal 1 doesn't enforce. |
| **Multi-tenant / multi-operator** | Not on the roadmap. | If it ever moves: per-tenant cluster, no cross-tenant resources. Explicitly not a seam. |
| **Alternative private-mesh ingress** | Atrium's traffic path is "public DNS → mesh CGNAT IP → k3s Traefik" — the mesh layer is only there to make the IP reachable from operator devices. Headscale slots in identically (same Tailscale client, different coordination server). Other meshes (Nebula, Innernet, ZeroTier) need a different IP-assignment story but the rest (DNS, Traefik, cert-manager) is unchanged. | The principle is "private mesh"; Tailscale is the default implementation. |
| **SOUL configurability** | `cluster.config.yaml.soul` block (path to a SOUL.md or inline content); the ConfigMap `hermes-soul` gets rendered from it. Today: committed `deploy/hermes/SOUL.md` is the source. | Lets a stranger cloning atrium ship their own agent voice without forking. Shape TBD — `inline:` field vs `file:` reference vs library of named souls (`steward`, `mentor`, `gardener`, …). |
| **`contracts/` as a published artifact** | Folder for now. Re-evaluate when a second person writes an atrium app. | Could become a Go module, npm package, docs site. |

---

## 9. Decisions

| Decision | Choice | Alternative considered | Why |
|---|---|---|---|
| Repo shape | One mono-repo (atrium) + per-app repos | Cluster wiring, agent deploy, and apps each in their own repo | Bootstrap is one motion; platform release is one release; app lifecycles stay independent. |
| Hermes location | In atrium (`deploy/hermes/` at goal 1, `platform/apps/hermes/` at goal 2) | A separate `hermes-deploy` repo | Hermes is the shell, not an app. Without it atrium is just k3s on a mesh. |
| Cluster scope | Single cluster, single host | Multi-host k3s, multi-cluster | Target footprint; complexity doesn't earn its keep at goal 1. |
| Config surface | `cluster.config.yaml` gitignored + `cluster.config.example.yaml` checked in | Helm values / env vars / sed templates | One file the operator edits; the rest of the repo is platform-shape, not personal. Gitignored because per-host identity, not because secret. |
| SOUL | One committed `SOUL.md` shipping a direct, decisive default voice | `SOUL.example.md` + operator-authored real one / no SOUL at all / operator-supplied SOUL at install time | The agent shell needs *a* voice at goal 1; operator-configurable SOUL is a goal-2+ seam (§8). One committed default unblocks goal 1. |
| Goal-1 provider posture | None | Wire one provider key (any of the five in §4) at goal 1 | Provider abstraction is core (§4); goal 1 proves the platform without committing. |
| Ingress posture | Private mesh, no public services | Public DNS + public LoadBalancer / Cloudflare Tunnel | Single-tenant by thesis. Public DNS names point at *mesh-only* IPs — the DNS answer leaks publicly, the IP doesn't. |
| Default private mesh | Tailscale | Headscale / Nebula / Innernet / ZeroTier | Tailscale is the lowest-friction implementation (auto CGNAT IP, MagicDNS, ACL). Headscale is the self-hosted slot-in. Others would need a different IP-assignment story. |
| Dashboard URL shape | `https://hermes.<your-domain>` (custom domain) | `https://hermes.<tailnet>.ts.net` (MagicDNS) | Custom-domain DNS resolves in every browser. MagicDNS resolution silently breaks in Chromium-family browsers with DoH on — DoH bypasses the OS resolver. |
| Templating | Placeholder values in committed YAML + `scripts/apply.sh` renders via envsubst | Helm chart / Flux postBuild / kustomize replacements | `kubectl kustomize \| envsubst \| kubectl apply` is the smallest tool chain that keeps committed files generic. Goal 2 substitutes Flux's `postBuild.substituteFrom` for the same job. |
| Goal-1 GitOps | None — `scripts/apply.sh` | Flux from day one | Flux is overkill for ~10 manifests. Returns at goal 2 with multi-app payload + image automation. |
| Secrets | SOPS + age (encryption lands at goal 2) | sealed-secrets / external-secrets-operator | Stable, well-supported, plays cleanly with Flux. age key pre-seeded at goal 1; Secrets created out-of-band until then. |
| Runtime | k3s `v1.36.0+k3s1` | k0s, full k8s, microk8s | Small single-node target; k3s is the right size. v1.36.0 is current latest stable as of design time. |
| Image pinning | Pin Hermes to a specific SHA tag | `:latest` / `:main` | `:latest` drifts. Manual SHA bump at goal 1; Flux image automation at goal 2. |
| ClusterIssuer | `letsencrypt-prod` from day one | Staging first, flip later | The DNS-01 flow worked end-to-end against prod LE on first try with the documented Cloudflare token scopes. Staging recipe is commented in `cluster-issuer.yaml` if iteration ever burns the rate limit. |

---

## 10. Design principles

The rules atrium upholds across every section above. Each is a decision
that wasn't free — alternatives exist; we chose this shape on purpose.

| # | Principle | Why |
|---|---|---|
| 1 | **No host-specific value appears anywhere except `cluster.config.yaml`.** Domain, node name, mesh name, GitHub owner, age recipient — all in one gitignored file. | A platform isn't a snapshot. A stranger cloning the repo sees the shape, not someone else's identity. |
| 2 | **No cluster-name baked into paths.** Flux root is `platform/clusters/default/`, not `platform/clusters/<hostname>/`. | The cluster doesn't need to know what the host is named. Renames cost nothing. |
| 3 | **The agent (Hermes) is part of the platform, not an app.** Hermes manifests live in atrium, not in a separate `hermes-deploy` repo. | One install motion. Hermes is the shell — without it atrium is just k3s on a mesh. |
| 4 | **Provider-free is a first-class state.** The platform boots, the dashboard is reachable, no provider is configured. | Lets the operator verify the platform without committing to a provider. The seam to add one is neutral across every supported combination (§4). |
| 5 | **No specific provider is "the upstream."** Prose, manifests, scripts — none of them name Anthropic / OpenRouter / OpenAI as the default. Whichever the operator picks is the only upstream. | Provider-neutral by construction. Future providers slot in without grep-and-replace. |
| 6 | **App authors need a contract, not a tour of the cluster.** `atrium/contracts/` (goal 2) is the canonical, versioned contract surface with a reference app. | Apps are independent repos. Their authors should be able to ship against atrium without reading every line of this doc. |
| 7 | **The current mechanism is documented; the history isn't.** When a mechanism is replaced, the old one stops appearing in the doc. | New readers shouldn't have to learn the wrong shape first. |
| 8 | **Goal-1 is "platform up." Optimization is goal-2.** Image automation, GitOps reconcile loops, monitoring — all earn their keep only when there are multiple apps and multiple credential lifecycles. | Smallest thing that works first. Bigger pieces land when they actually pay for themselves. |
| 9 | **One source of truth per host-specific value.** Mesh name, domain, node name each appear in `cluster.config.yaml` exactly once and are read from there everywhere. | Drift between copies is how clusters break at 2am. |
| 10 | **One canonical doc, not many.** Architecture, decisions, runbook, seams, principles — one file (this one), read top to bottom. | Reviewers shouldn't have to cross-reference to make either kind of decision. |
| 11 | **Single-operator, single-cluster, single-tenant are explicit choices, not accidents.** Stated as axioms in §1. | Multi-tenant lives at a different abstraction (one atrium per tenant); ACL lives at the mesh layer, not in atrium itself. |
| 12 | **Private-mesh-first, not public-internet.** Tailscale is the default implementation; the principle is what's baked in. | The single-tenant thesis only holds if the surface is private. Public ingress is a different platform. |

---

## 11. Open questions

Not blockers for goal-1 design. Operator should know they exist.

1. **Does the Hermes dashboard expose configuration?** Answered by goal 1.5 (§7). Determines goal-2 wiring mechanism.
2. **Where does `cluster.config.yaml` live long-term?** Today: in the repo, gitignored. Tomorrow: maybe a separate `atrium-config` repo per cluster, or some operator-controlled blob store. Don't decide yet.
3. **`contracts/` as folder or published artifact?** Folder for now. Re-evaluate when a second person writes an atrium app.
4. **Repo name.** "Atrium" works. If the operator ever wants `agentic-os` as the repo name, rename is cheap before any external user lands.
5. **OAuth re-auth UX**. Anthropic OAuth tokens refresh in-process. If a token ever fully expires and needs the browser dance again, what does that look like? (Probably `kubectl exec` + `hermes model` from a tailnet-connected workstation.) Not a goal-1 problem.
6. **Multi-replica Hermes**. PVC is `ReadWriteOnce` local-path. Goal-1 is single-replica. If Hermes ever needs HA, the storage class and replica model both change. Out of scope.
7. **SOUL configurability shape**. Goal 1 ships one committed `SOUL.md`. Later: `cluster.config.yaml.soul` knob? Named library of souls? Inline vs file reference? Decide when a second persona is actually wanted.
