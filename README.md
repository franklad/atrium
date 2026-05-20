# atrium

The operational layer for self-hosting [Hermes](https://hermes-agent.nousresearch.com/).
Hermes ships the runtime — model providers, OAuth, skills, channels,
the dashboard control plane. **Atrium ships the substrate**: an
opinionated deploy (k3s + Tailscale + cert-manager today), conventions
for hosting operator-authored apps alongside Hermes, and a one-script
install motion.

The platform thesis the substrate enables: **the user pays one model
provider once; SaaS apps don't run AI for their users — they expose a
contract that any agent harness can call.** Hermes implements the
contract (`hermes skills install <url>` against `.well-known/agent-skill`,
plus five other registries). Atrium just makes sure the harness has a
real place to live.

Clone, fill in `cluster.config.yaml`, run `./scripts/apply.sh` against a
fresh k3s host — you end up with a Hermes dashboard reachable at
`https://hermes.<your-domain>` over a private mesh. Everything else
([`docs/architecture.md`](docs/architecture.md)) is one file. Read it
top to bottom.
