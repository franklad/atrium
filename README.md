# atrium

An agentic-OS platform. Kubernetes is the kernel,
[Hermes](https://hermes-agent.nousresearch.com/) is the shell, apps are MCP
"skills" that ship a `SKILL.md`. Single-tenant, tailnet-only, single-node.
Provider-agnostic by construction — the platform boots without any model
provider; Anthropic (API key or OAuth), OpenRouter, OpenAI, and any
OpenAI-compatible endpoint all plug into the same seam.

Clone, fill in `cluster.config.yaml`, run the bootstrap procedure — you end
up with a Hermes-fronted cluster reachable over Tailscale. The full design,
the install runbook, and the seams for what comes after live in
[`docs/architecture.md`](docs/architecture.md). One file. Read it top to bottom.
