# Atrium — design

**Atrium is an agentic-OS platform.** A single repo you clone onto a fresh
host, run one procedure against, and end up with a Kubernetes cluster running
the [Hermes](https://hermes-agent.nousresearch.com/) agent on a tailnet,
ready to grow apps. Kubernetes is the kernel, Hermes is the shell, apps are
MCP "skills" that ship a `SKILL.md`. Single-node, single-tenant, tailnet-only.

This is the spine. It says what atrium *is*, what it contains, why the shape
is what it is, and exactly how to install it. One file. Read it top to
bottom.

If you only read three sections, read **[Provider abstraction](#4-provider-abstraction)**,
**[Goal 1](#5-goal-1-what-were-shipping)**, and **[Bootstrap runbook](#6-bootstrap-runbook)**.

---

## 1. What atrium is

A desktop OS, inverted.

A desktop OS gives a human a window manager and apps. **Atrium gives an
agent a cluster and skills.** The kernel (k3s) does isolation and
scheduling. The shell (Hermes) is the agent loop. Apps are MCP servers
exposing tools via `SKILL.md` manifests. The "user" is the operator reaching
in from the tailnet.

Three properties hold the platform together:

1. **One repo, one install motion.** Cluster wiring, the Hermes deploy, and
   platform contracts live in one tree. Per-app repos stay separate and
   register through one Flux pointer each.
2. **Configurable, not personal.** Everything host-specific — domain, node
   name, GitHub owner, mesh name, age recipient, active model provider —
   lives in a single `cluster.config.yaml` gitignored at the repo root.
   A stranger cloning atrium sees a platform, not someone else's snapshot.
3. **Provider-free at goal 1.** Atrium's first slice is Hermes + dashboard
   on a private mesh with **no model provider configured at all** —
   proving the platform is real before committing to a provider or auth
   flow.

The thesis: agent harness as kernel surface, MCP as the syscall ABI, apps
as skilled clients. The platform stays neutral about *which* agent runs
and *which* model provider feeds it. Today that's Hermes; tomorrow it could
be anything that speaks MCP and reads a `config.yaml`.

---

## 2. Topology (goal-1 state)

Atrium is **private-mesh-first**: ingress lives on a single-tenant overlay
network, not on the public internet. The principle is "no public surface."
Tailscale is the default implementation (zero-cost TLS via `.ts.net`,
MagicDNS, ACL out of the box); the principle is what's baked in, the
implementation is a sensible default. Swapping in self-hosted Headscale
preserves the model exactly; other private meshes (Nebula, Innernet,
ZeroTier) are a future seam (§8). Public-internet ingress
(Cloudflare Tunnel, public DNS + LE certs) is an explicit non-goal — it
contradicts the single-tenant thesis.

```
                  ┌─ operator's mesh member (laptop, phone) ────┐
                  │                                            │
                  ▼                                            │
        https://hermes.<tailnet>.ts.net                        │
              │  (MagicDNS; NXDOMAIN to non-members)           │
              │  TLS terminated by Tailscale (auto LE cert)    │
              ▼                                                │
        Tailscale Operator proxy pod  (ts-hermes-<hash>)       │
              │                                                │
              │  plaintext HTTP                                │
              ▼                                                │
        Service/hermes-dashboard  (ClusterIP :9119)            │
              │                                                │
              ▼                                                │
        Pod: hermes  (single replica)                          │
        ├── command: hermes dashboard --host 0.0.0.0 ...       │
        ├── /opt/data            (PVC, ~/.hermes)              │
        ├── /opt/skills-overlay  (empty)                       │
        └── envFrom: hermes-env  (Secret absent / empty)       │
                                                               │
        (no provider configured; chat tab errors on use;       │
         dashboard SPA, sessions/jobs/metrics tabs render)     │
                                                               ◄
```

Single node. Single tenant. Everything south of the mesh ingress proxy is
unencrypted plaintext — TLS lives at the mesh edge.
**The trust boundary is the private mesh.** No public DNS. No public
services. No public anything.

What's intentionally absent at goal 1:
- No Traefik routing (k3s ships it; we don't use it yet — see §8).
- No cert-manager / wildcard cert / Cloudflare API token.
- No Flux. Plain `kubectl apply -k`.
- No provider keys, OAuth tokens, or app pods.

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
│   └── hermes/                     Goal-1 kustomize bundle. Applied via kubectl.
│       ├── 00-namespace.yaml
│       ├── 10-pvc.yaml
│       ├── 20-config.yaml          Provider-less Hermes config (ConfigMap)
│       ├── 40-deployment.yaml      ServiceAccount + Hermes Deployment
│       ├── 50-service.yaml         ClusterIP + mesh-ingress annotations
│       ├── SOUL.md                 The agent's voice; rendered into the hermes-soul ConfigMap at kustomize build time
│       └── kustomization.yaml
│
├── docs/
│   └── architecture.md             This file. The only doc until goal 2.
│
└── (goal-2 seams, NOT present yet — listed for clarity)
    ├── platform/                   Will appear when Flux lands (§8)
    │   ├── clusters/default/
    │   ├── infrastructure/
    │   └── apps/
    ├── contracts/                  SKILL.md schema + network/ingress contracts
    ├── scripts/                    install-k3s.sh, render-config.sh, doctor.sh
    └── Taskfile.yml                `task bootstrap`, `task doctor`, etc.
```

### Why each top-level entry exists

| Entry | Why |
|---|---|
| `cluster.config.yaml` (gitignored) | One file is the difference between a platform and a snapshot. Everything host-specific lives here — domain, tailnet name, node hostname, GitHub owner, age recipient, *and* the active model provider config. Gitignored because it carries identity, not because it's secret in the SOPS sense. |
| `cluster.config.example.yaml` (checked in) | The template. Includes commented-out blocks for every supported provider+auth combination. A stranger cloning the repo sees the shape immediately. |
| `deploy/hermes/SOUL.md` (committed) | The agent's voice and character — direct, decisive, serves the mission. One good default that ships with the repo; fork and edit if you want a different voice. Rendered into the `hermes-soul` ConfigMap by the kustomize `configMapGenerator`. Operator-configurable SOUL (without forking) is a goal-2+ seam (§8). |
| `deploy/hermes/` | The goal-1 payload. Four manifests in a kustomize bundle. Flat structure on purpose — `platform/clusters/default/` lands when Flux lands. |
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
Hermes pod running, dashboard reachable over tailnet at
`https://hermes.<tailnet>.ts.net` with a valid TLS cert, dashboard SPA
renders, sessions/jobs/metrics tabs render (with empty data), no provider
configured, no apps.**

### Success criteria

A goal-1 install is done when, from a tailnet-connected workstation:

1. `curl -I https://hermes.<tailnet>.ts.net` returns `HTTP/2 200` with a
   valid Let's Encrypt cert (no `-k` flag).
2. A browser at the same URL renders the Hermes dashboard SPA.
3. The sessions, jobs, and metrics tabs render. Empty data is fine — chat
   is goal 2.
4. `kubectl -n hermes get pods` shows `hermes-<hash> 1/1 Running` with no
   restarts.
5. `kubectl -n hermes logs deploy/hermes` shows clean dashboard startup, no
   `OPENROUTER_API_KEY` / `ANTHROPIC_API_KEY` errors, no panics.

### What's in

- k3s `v1.36.0+k3s1` (current latest stable) on a single node (reference
  hardware: Ubuntu 24.04, ~4 GB RAM, 4 vCPU — atrium has been validated at
  this size; larger is fine).
- Tailscale Operator (HelmRelease applied via `kubectl apply` from upstream
  manifests).
- Hermes Deployment, ConfigMap (provider-less `config.yaml`), ConfigMap
  (`SOUL.md`), PVC, Service.
- Tailscale Operator exposes the Hermes dashboard Service as a tailnet
  device at `hermes.<tailnet>.ts.net`. Tailscale handles TLS via its built-in
  Let's Encrypt cert provisioning for `.ts.net` names.
- SOPS age private key installed into `flux-system` namespace (unused at
  goal 1; pre-seeded so goal 2 doesn't re-discover the requirement).

### What's out (explicitly deferred to goal 2 or later)

| Thing | Why deferred |
|---|---|
| Any model provider key or OAuth flow | The whole point of goal 1 — see §4. |
| Flux GitOps (source, kustomize, helm, image-reflector, image-automation controllers) | A 6-controller, ~400 MB dependency. Payoff (reconcile, image automation, SOPS) is wasted on a 4-manifest deploy. Returns in goal 2 with multi-app payload. |
| cert-manager + Cloudflare DNS-01 + `*.<domain>` wildcard | Tailscale's `.ts.net` cert is the goal-1 TLS story. Wildcard returns in goal 2 when the cluster has multiple ingresses. |
| Traefik IngressRoute + middleware (basic-auth, redirect) | Traefik ships with k3s and sits idle. We expose Hermes via a tailnet-annotated Service directly. Traefik returns in goal 2 for host-based routing across apps. |
| Shared Postgres (`database` namespace) | No app needs DB until goal 2 apps land. |
| Any MCP skill app | App lifecycle decoupled from platform. |
| Telegram / Discord / Slack / any chat platform | Channels need a provider. No provider in goal 1. |
| `letsencrypt-prod` (ACME) | Not used in goal 1 — Tailscale handles certs. Returns with cert-manager in goal 2. |
| NetworkPolicies | One pod, one path. Default-allow is fine. |
| htpasswd dashboard basic-auth | Tailscale ACLs are the auth boundary. |
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

### 6.1 Credentials checklist

Two, both pre-existing:

| Credential | Where | Used by |
|---|---|---|
| SOPS age private key (`~/.config/sops/age/keys.txt`) | Workstation. Generate with `age-keygen -o ~/.config/sops/age/keys.txt` if absent; remember to update `cluster.config.yaml.age.recipient`. | Pre-seeded into cluster for goal 2. Unused at goal 1. |
| Tailscale OAuth client | Tailscale admin → Settings → OAuth clients → Create. Scopes: `devices:write`, `auth_keys:write`. Tag with `tag:k8s-operator`. | Tailscale Operator authenticates to mint the Hermes ingress device. |

That's it. No Cloudflare, no provider keys, no Postgres, no Flux PAT, no
GitHub deploy keys.

### 6.2 Prepare `cluster.config.yaml`

```bash
cd ~/atrium
cp cluster.config.example.yaml cluster.config.yaml
$EDITOR cluster.config.yaml
```

Fill in:
- `cluster.name`, `cluster.domain`
- `cluster.tailnet.tailnet_name` (run `tailscale status --json | jq -r '.MagicDNSSuffix'` on any tailnet member)
- `age.recipient` (the public line from `~/.config/sops/age/keys.txt`)
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

### 6.7 Install Tailscale Operator

```bash
kubectl create namespace tailscale

kubectl create secret generic operator-oauth \
  --namespace=tailscale \
  --from-literal=client_id='PASTE_TS_CLIENT_ID' \
  --from-literal=client_secret='PASTE_TS_CLIENT_SECRET'

kubectl apply -f https://github.com/tailscale/tailscale/releases/latest/download/operator-manifests.yaml
```

If the latest-tag URL drifts, pin to a specific release.

Validate:

```bash
kubectl -n tailscale get pods
# operator-<hash>   1/1   Running

kubectl -n tailscale logs deploy/operator | head -30
# expect "starting operator", "starting reconcile loop"; no panic / oauth errors
```

### 6.8 Apply the Hermes deploy bundle

```bash
cd ~/atrium
kubectl apply -k deploy/hermes/
```

The bundle contains:

| File | What |
|---|---|
| `00-namespace.yaml` | `Namespace/hermes` |
| `10-pvc.yaml` | `PersistentVolumeClaim/hermes-data` 20Gi `local-path` |
| `20-config.yaml` | `ConfigMap/hermes-config` with provider-less `config.yaml` |
| `40-deployment.yaml` | `ServiceAccount` + `Deployment/hermes` (init container `bootstrap-home`, container `dashboard` running `hermes dashboard`) |
| `50-service.yaml` | `Service/hermes-dashboard` ClusterIP + `tailscale.com/expose: "true"` and `tailscale.com/hostname: "hermes"` annotations |
| `kustomization.yaml` | Lists the manifests above; `configMapGenerator` builds `hermes-soul` ConfigMap from `deploy/hermes/SOUL.md` (single source of truth); sets `namespace: hermes` |

Key shape decisions baked into the manifests:

- **Image pinned** to a specific Hermes SHA tag (`docker.io/nousresearch/hermes-agent:sha-<sha>`). The Flux image-policy marker comment is present but no-op without Flux.
- **Command override**: `command: ["hermes", "dashboard"]` with args `--host 0.0.0.0 --port 9119 --no-open --insecure`. Without this the image's default entrypoint runs interactive chat — wrong for headless.
- **`envFrom: hermes-env` with `optional: true`**. The Secret doesn't exist in goal 1; pod boots anyway.
- **No `API_SERVER_*` env vars**. We don't run `gateway run` or the api_server. That's a goal-2 capability and it needs a provider to be useful.
- **`bootstrap-home` init container kept** (seeds `config.yaml` + `SOUL.md` onto the PVC). **`collect-skills` init container dropped** (no skill ConfigMaps in goal 1).
- **Probes hit `/` on port 9119** — the dashboard returns 200 there. The api_server `/health` endpoint doesn't exist in this mode.
- **Service annotations**: `tailscale.com/expose: "true"`, `tailscale.com/hostname: "hermes"` → device lands at `hermes.<tailnet>.ts.net`. The Operator auto-provisions TLS via Tailscale's built-in Let's Encrypt.

Validate:

```bash
kubectl -n hermes get pods
# hermes-<hash>   1/1   Running   (after ~60s)

kubectl -n hermes logs deploy/hermes
# dashboard startup; no provider-key tracebacks (those fire only on chat)

kubectl -n hermes get svc hermes-dashboard
# ClusterIP assigned, port 9119

kubectl -n tailscale get pods
# additionally: ts-hermes-<hash>   1/1   Running    (the Operator-minted proxy)
```

### 6.9 Reach the dashboard

From any tailnet member:

```bash
curl -I https://hermes.<tailnet>.ts.net
# HTTP/2 200, valid LE cert
```

Browser to the same URL. Dashboard SPA loads. Sessions, jobs, metrics tabs
render. Chat tab errors on use — that's correct.

If you don't know your tailnet domain:
`tailscale status --json | jq -r '.MagicDNSSuffix'` on logos.

**Goal 1 done.**

### 6.10 End-to-end validation table

| Phase | Check | Expected |
|---|---|---|
| 6.3 | `which k3s; ls /var/lib/rancher 2>&1` | empty; "No such file or directory" |
| 6.4 | `sudo k3s kubectl get nodes` | `logos Ready control-plane,master v1.36.0+k3s1` |
| 6.5 | `kubectl get nodes -o wide` | `logos Ready ... <tailnet IP>` |
| 6.6 | `kubectl -n flux-system get secret sops-age` | one secret, Opaque |
| 6.7 | `kubectl -n tailscale get pods` | `operator 1/1 Running` |
| 6.8 | `kubectl -n hermes get pods` | `hermes 1/1 Running` after ~60s |
| 6.8 | `kubectl -n tailscale get pods` | additional `ts-hermes-<hash> 1/1 Running` |
| 6.9 | `curl -I https://hermes.<tailnet>.ts.net` | `HTTP/2 200`, valid TLS |
| 6.9 | Browser at same URL | SPA + tabs render |

### 6.11 Failure modes

**Tailscale Operator doesn't mint a proxy for the Service.**
Symptom: only `operator` pod in `tailscale` ns; no `ts-hermes-<hash>`.
Diagnose: `kubectl -n tailscale logs deploy/operator | tail -50`. Common
causes: OAuth scopes missing `devices:write` (401 in logs); annotation
typo (`tailscale.com/expose: true` without quotes — must be a quoted
string); operator hasn't picked it up yet (give it 60s).
Recover: fix annotation/secret;
`kubectl -n hermes annotate svc hermes-dashboard tailscale.com/expose-`
then re-annotate to trigger reconcile.

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

**Tailnet hostname doesn't resolve from workstation.**
`tailscale status` — workstation logged in? MagicDNS enabled in Tailscale
admin? Operator-minted device shows up there within 30s of the proxy pod
going Ready.

**PVC stuck Pending.**
`local-path-provisioner` pod in `kube-system` not Running → k3s install
didn't complete. Back to §6.4.

**k3s install fails with "k3s already installed".**
The uninstall script may have silently no-op'd. Manually
`sudo systemctl stop k3s; sudo systemctl disable k3s; sudo rm /usr/local/bin/k3s* /etc/systemd/system/k3s*`
and rerun §6.4.

### 6.12 You-are-here markers

- After §6.4: **k3s up. No workloads. No tailnet device for the cluster yet.**
- After §6.7: **Tailscale Operator running, idle (no Services to expose).**
- After §6.8: **Hermes pod running. ClusterIP-only — not yet reachable outside the cluster.**
- After §6.8 + ~30s: **Tailscale proxy pod up. `hermes.<tailnet>.ts.net` resolves.**
- After §6.9: **Goal 1 complete.**

---

## 7. Goal 1.5: Dashboard-config discovery

**A named milestone between goal 1 and goal 2.** Single owner: the operator.
Single deliverable: a decision on goal-2's provider-wiring shape.

### Why this milestone exists

The Hermes upstream docs (read at time of writing) describe configuration
exclusively as CLI- and config-file-driven: `hermes config edit`,
`hermes model`, `~/.hermes/config.yaml`, `~/.hermes/.env`,
`~/.hermes/auth.json`. The docs do not mention a settings UI inside the
dashboard.

But: the operator has hands-on familiarity with the dashboard and suspects
it may expose provider/model configuration in-app. The docs may lag the
build. Confirming or refuting this is a goal-1.5 task, not a goal-1
blocker.

### Inputs

- A running goal-1 cluster (this doc, §5–§6).
- Operator time at the dashboard, ~30–60 minutes.

### Tasks

1. Open the dashboard at `https://hermes.<tailnet>.ts.net`.
2. Click every tab. Note which surface configuration: settings, preferences,
   model selector, provider configuration, integrations, API keys.
3. For each settings surface, note:
   - What it can set (model name, provider, API key, OAuth token, base URL).
   - Where it persists (Hermes' PVC? In-memory? An API the dashboard exposes?).
   - Whether a config-file write happens on the back end (compare
     `kubectl -n hermes exec deploy/hermes -- cat /opt/data/config.yaml`
     before and after a UI change).
4. Decide: at goal 2, where does provider+auth configuration live?
   - (a) Only in `cluster.config.yaml` / `hermes-env` Secret / ConfigMap.
   - (b) Only in the dashboard (atrium ships minimal seeds).
   - (c) Both: atrium seeds, dashboard overrides for ad-hoc tweaks.
5. Record the decision in this doc (replace §7 with the outcome) and move
   to goal 2.

### Success criteria

- A written list of every dashboard surface that touches configuration.
- A documented choice between (a), (b), (c) above with a one-paragraph
  rationale.
- An updated §4 (Provider abstraction) reflecting the chosen mechanism.

### Why this isn't goal 2

Picking the wrong wiring mechanism is a one-month rework. Goal 1 ships the
platform; goal 1.5 informs the goal-2 design before any code lands.
**Twenty minutes of dashboard exploration saves a week of rebuild.**

---

## 8. Seams for later

Goal 1 is a launchpad. These are the named extension points so goal-1
choices don't paint goal-2 work into a corner.

| Future capability | Seam | Notes |
|---|---|---|
| **Model provider** (after goal 1.5) | `cluster.config.yaml.providers.<active>` block + `hermes-env` Secret + ConfigMap `model:` block. Mechanism (config-file vs dashboard vs both) TBD by goal 1.5. | The Deployment already does `envFrom: hermes-env` with `optional: true`. No manifest changes. |
| **Flux GitOps** | `platform/clusters/default/` Flux root, `platform/infrastructure/{secrets,controllers,configs}/`, `platform/apps/<app>.yaml` pointers. `flux bootstrap github --owner ... --repo atrium --path platform/clusters/default`. | Adds source/kustomize/helm/notification controllers + (optional) image-reflector/image-automation. |
| **cert-manager + wildcard cert** | `platform/infrastructure/controllers/cert-manager.yaml` (HelmRelease), `platform/infrastructure/configs/clusterissuer-letsencrypt.yaml`, `platform/infrastructure/configs/wildcard-cert.yaml`. Cloudflare API token in `cf-api-token` Secret (SOPS). Start with `letsencrypt-staging`; flip to `-prod` after a clean run. | Wildcard on `*.<cluster.domain>`. Replaces Tailscale-managed certs when we want to serve at a custom domain. |
| **Traefik routing** | `IngressRoute` per service. Host-based routing across many apps. Tailscale Operator can either front Traefik (single tailnet device for many ingresses) or front each Service individually (one device per service). Decide when the second service lands. | k3s already ships Traefik; nothing to install. |
| **Image automation** | `platform/infrastructure/image-automation/` + `--components-extra=image-reflector-controller,image-automation-controller` on `flux bootstrap`. Per-app `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`. Tag scheme `<unix-ts>-sha-<git-sha>` + a marker comment in each Deployment manifest. | Adds Flux-managed deploy keys per app repo. |
| **MCP skill apps** | `platform/apps/<app>.yaml` is a Flux `GitRepository` + `Kustomization` pointing at the app's `deploy/k8s/`. App ships its own `SKILL.md` ConfigMap labelled `role=skill` in the `hermes` namespace. Hermes' `collect-skills` init container (returned at goal 2) discovers it. | Zero changes to Hermes Deployment per new app. |
| **Shared Postgres** | `platform/infrastructure/controllers/postgres.yaml` + per-app `<app>-db` Secret. | Install when first app needs DB. |
| **Chat platforms (Telegram, Discord, Slack)** | `hermes-env` gets channel tokens; ConfigMap's `platforms:` block grows the platform name. Per-platform NetworkPolicy egress covered by "TCP/443 to public" when NetworkPolicy lands. | Requires a provider (goal 2+). |
| **App-to-app calls** | Hermes' `delegate_tool` + per-app `mcp_servers.<name>` in `config.yaml`. Always mediated by Hermes. | No direct app-to-app NetworkPolicy needed. |
| **RBAC / capability gating** | `metadata.atrium.auth-class` field in `SKILL.md` frontmatter. v1 enum `{open, hermes-only}`. | Field exists in the schema from day one of contracts; goal 1 doesn't enforce. |
| **Multi-tenant / multi-operator** | Not on the roadmap. | If it ever moves: per-tenant cluster, no cross-tenant resources. Explicitly not a seam. |
| **Alternative private-mesh ingress** | Replace the Tailscale Operator install (§6.7) and the `tailscale.com/expose` Service annotations with the equivalent for another mesh. **Headscale** (self-hosted Tailscale control plane) drops in without any change to atrium — same client, same operator, different coordination server. **Nebula / Innernet / ZeroTier** would need a different ingress mechanism (NodePort + the mesh's own routing, typically). | The platform principle is "private mesh"; Tailscale is the default implementation. Atrium ships Tailscale because it's the lowest-friction option (zero-cost TLS, MagicDNS, ACL). Swap the implementation, keep the principle. |
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
| Ingress posture | Private mesh, no public services | Public DNS + LE certs / Cloudflare Tunnel | Single-tenant by thesis; public ingress contradicts it. See §8 if you need an alternative private mesh. |
| Default private mesh | Tailscale | Headscale / Nebula / Innernet / ZeroTier | Tailscale is the lowest-friction implementation of the principle (zero-cost TLS via `.ts.net`, MagicDNS, ACL out of the box). The principle is "private mesh"; the implementation is a sensible default the operator can swap (§8). |
| Goal-1 GitOps | None — plain `kubectl apply -k` | Flux from day one | Flux is overkill for ~4 manifests. Returns at goal 2 when there are multiple apps and credential lifecycles. |
| Goal-1 TLS | Mesh-provided cert (Tailscale's `.ts.net` auto-LE) | cert-manager + DNS-01 wildcard from day one | The mesh handles certs for free. cert-manager returns at goal 2 if/when a custom domain is wanted. |
| Goal-1 ingress shape | Mesh Operator exposes the Hermes Service directly | Mesh Operator → Traefik → Service | Without a wildcard and multiple ingresses, Traefik adds no value. Returns at goal 2. |
| Ingress strategy (long-term) | Mesh Operator in front of (optionally) Traefik | per-service mesh sidecar | One mesh device per service today; can fan out via Traefik when the cluster has many services. |
| Secrets | SOPS + age | sealed-secrets / external-secrets-operator | Stable, well-supported, plays cleanly with Flux. age key pre-seeded at goal 1; SOPS encryption lands at goal 2 with Flux. |
| Runtime | k3s `v1.36.0+k3s1` | k0s, full k8s, microk8s | Small single-node target; k3s is the right size. v1.36.0 is current latest stable as of design time. |
| Goal-1 image pinning | Pin Hermes to a specific SHA tag | `:latest` | `:latest` drifts. Manual bump in goal 1; Flux image automation in goal 2. |
| First-cert issuer (goal 2) | `letsencrypt-staging`, flip to `-prod` after one clean run | `letsencrypt-prod` from day one | Avoid burning LE prod quota on iteration. |

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
