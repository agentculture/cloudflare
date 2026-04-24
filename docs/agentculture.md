# AgentCulture

This repo belongs to the **AgentCulture** OSS organisation — the
`github.com/agentculture` umbrella for agent-first tooling.

The anchor document lives in the `afi-cli` repo at
<https://github.com/agentculture/afi-cli/blob/main/docs/agentculture.md>.
That explains:

- the "agents are first-class org members" stance,
- what "agent-first" means as a build discipline,
- why `afi-cli` is the foundational scaffolder, and
- the cite-don't-import pattern (which cfafi uses: patterns from
  afi-cli are copied into this repo and adapted, not installed).

## cfafi's place in the org

cfafi is the first concrete product built using afi-cli's patterns.
Its purpose is narrow: make CloudFlare state safely usable by AI
agents. The shape is general — noun/verb CLI, `--json` opt-in,
dry-run-by-default mutations — but the domain is specific.

The conventions that apply everywhere in this repo:

- Every PR bumps the version in `pyproject.toml` (+ `cfafi/__init__.py`
  - `CHANGELOG.md`).
- Trusted Publishing to PyPI; no long-lived tokens.
- Bash-skills-as-fallback during migration; Python CLI as the primary
  going forward.
- Zero runtime Python deps.
