# Agent First

"Agent first" is a design discipline — it describes how we build
interfaces, not who they're for. (Humans can use them too; they just
aren't the primary consumer.)

The anchor doc is at
<https://github.com/agentculture/afi-cli/blob/main/docs/agent-first.md>.
It states the three-surface rule (CLI, MCP, HTTP) and the per-surface
opinions (learnability on CLI, minimalism on MCP, discoverability on
HTTP).

## How cfafi applies it (v0.1.0)

**CLI surface (what we have):**

- Every verb has a markdown default and a `--json` opt-in.
- Errors never dump a Python traceback; they emit `error: <msg>` and
  `hint: <remediation>` (or a JSON envelope with the same fields).
- `cfafi learn` prints a self-teaching prompt; `cfafi explain <path>`
  resolves markdown docs per verb.
- Mutations default to dry-run; `--apply` commits. An agent that
  forgets to read the docs can still run `cfafi dns create ...`
  without mutating anything.

**MCP and HTTP surfaces:** planned for future minor releases. The CLI's
noun/verb structure is deliberately compatible with what MCP and a
sitemap-driven docs HTTP surface need.

## Tests as the contract

Every verb ships with a pytest file that asserts its agent-visible
behaviour: exit codes, markdown shape, JSON shape, and (for mutations)
the dry-run / `--apply` split. If an agent-observable behaviour
changes, a test changes with it — otherwise the CI gate rejects it.
