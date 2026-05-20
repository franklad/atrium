# atrium

A **distribution of [Hermes](https://hermes-agent.nousresearch.com/)** —
Ubuntu to Hermes' Linux kernel. The agent harness is upstream; atrium
curates an opinionated bundle on top: an opinionated deploy substrate
(k3s + Tailscale + cert-manager today), an extended skill contract that
makes third-party apps cleanly callable, an install motion for those
apps, and a stance on auth/trust between user, agent, and apps.

The platform thesis: **the user pays one model provider once;
SaaS apps don't run AI for their users — they expose a contract that any
agent harness can call.** Atrium's job is making sure that contract is
real, the harness has a place to run, and the install motion is sane.

Clone, fill in `cluster.config.yaml`, run `./scripts/apply.sh` against a
fresh k3s host — you end up with a Hermes dashboard reachable at
`https://hermes.<your-domain>` over a private mesh. The full design,
the install runbook, the substrate seams, and the contract spec live in
[`docs/architecture.md`](docs/architecture.md). One file. Read it top
to bottom.
