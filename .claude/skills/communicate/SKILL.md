---
name: communicate
description: >
  Cross-repo + mesh communication from cultureflare: file tracked
  GitHub issues on sibling repos, comment on existing issues, fetch
  issues to inline current state into briefs, and send live messages
  to Culture mesh channels. Use when the next step lives outside
  cultureflare (a brief for a sibling-repo agent, a status ping for a
  Culture channel, or pulling an issue body + comments into context).
  Issue posts/comments auto-sign `- <nick> (Claude)`; mesh messages
  are unsigned (the IRC nick is the speaker). Not for in-cultureflare
  issues — use `gh issue create` or the `cicd` skill for those.
  Vendored from steward 0.12.0; GitHub issue I/O is agtag-backed since
  steward 0.11.0.
---

# Communicate (Cross-Repo + Mesh)

cultureflare's job is to keep CloudFlare state aligned across the
AgentCulture mesh; that surfaces in four distinct channels:

- **Tracked, async hand-offs** — a gap in another repo (a missing
  public API, a divergent skill, a documentation ask) where an agent
  on the other side needs to act, and the ask should outlive the
  conversation. → `post-issue.sh` (GitHub).
- **Follow-up on a tracked thread** — a status update, an answer to a
  question, or a "this is done" note on an issue that's already open.
  → `post-comment.sh` (GitHub).
- **Inbound state read** — pulling current issue body + comments from
  a sibling repo so a brief or plan can inline what's there instead of
  saying "see issue #N." → `fetch-issues.sh` (GitHub).
- **Ephemeral coordination** — a status ping, a question, a "PR ready
  for merge" notice on a Culture mesh channel where the audience is
  already listening. → `mesh-message.sh` (Culture IRC).

All four live under one skill because they share the same audience
(sibling-repo agents) and the same red flag (don't double-post the
same ask across post + mesh — pick one).

## Backed by agtag

The three GitHub verbs (`post-issue.sh`, `post-comment.sh`,
`fetch-issues.sh`) are thin wrappers around the `agtag` CLI
(`agtag issue post|reply|fetch`). agtag handles auto-signature
resolution from the local `culture.yaml` (falling back to repo
basename — `cultureflare` for this repo), JSON output mode, and a
uniform exit-code policy. Read `agtag learn` for the agent-facing
self-teaching prompt and `agtag explain agtag` / `agtag explain issue`
for the surface docs — this SKILL.md does not re-document agtag's
flags. Install once: `uv tool install agtag` (or `pip install agtag`).

`mesh-message.sh` stays a `culture channel message` wrapper for now;
agtag mesh transport is slated for v0.2.

## When to Use

### Issue mode (`post-issue.sh`)

- A gap surfaces in **another repo's surface** (missing public API,
  wire-format compat fix, divergent skill, documentation ask).
- You're handing off a self-contained brief to a sibling-repo agent.
- You're asking a question that benefits from a tracked artifact
  rather than ephemeral chat.

### Comment mode (`post-comment.sh`)

- An open issue needs a follow-up — a status update, an answer to a
  maintainer's question, a "this is shipped" note pointing at a PR.
- You're closing the loop on a `post-issue.sh` you sent earlier and
  the resolution belongs on the same thread (audit trail beats a
  separate ping).
- Auto-signed by agtag; do not hand-author the trailing nick.

### Fetch mode (`fetch-issues.sh`)

- You're about to write a brief and want to inline the current state
  of one or more sibling-repo issues (body + comments) instead of
  saying "see issue #N."
- You're triaging a list of cross-repo issues and want their bodies
  and comments in one shot for context.
- Avoids the `gh issue view` "Projects (classic) deprecated" error by
  passing `--json` explicitly to GitHub.

### Mesh mode (`mesh-message.sh`)

- You want to ping a Culture channel with a status update ("PR #N
  ready for merge", "starting nightly cf-status sweep").
- You're asking a question where you expect a fast reply from whoever
  is listening on the channel right now.
- You're announcing a decision that doesn't need a tracked artifact.

## When NOT to Use

- **In-cultureflare issues** — open them with `gh issue create`
  directly, or work them through the `cicd` skill.
- **PR review comments** — that's the `cicd` skill (which already
  auto-signs replies).
- **Routine commits** — those don't get cross-repo signatures.
- **Long-form asks on the mesh** — anything that needs acceptance
  criteria belongs in an issue, not a channel message.

## Conventions

### 1. Briefs are self-contained

The receiving agent must not need cultureflare-side context to act.
Inline the relevant content; do not say "see cultureflare's plan."

A brief that says "see cultureflare#NN" is a bug. The receiving agent
will look at it, get lost in cultureflare-specific context that's
irrelevant to them, and either ask for clarification (slow round-trip)
or guess wrong (worse). Inline the ask, the rationale, and concrete
acceptance criteria. Quote source-of-truth files (path, line numbers,
small excerpts) when their shape matters to the ask.

### 2. Per-channel signature rules

| Channel | Signature | Why |
|---------|-----------|-----|
| GitHub issues / comments | `- <nick> (Claude)` — agtag resolves `<nick>` from the local `culture.yaml`, falling back to repo basename (`cultureflare`) | Cross-repo audit trail — readers can tell at a glance which sibling and that it came from an AI. |
| Culture mesh | none — unsigned | The IRC nick already identifies the speaker. A trailing `- <nick> (Claude)` would be visual noise that the nick already supplies. |

Vendors do not edit a literal — agtag does the resolution. `--as NICK`
overrides if you need to sign as something other than the resolved
nick. Mesh messages stay unsigned.

### 3. Issue title format

`<verb> <thing> (unblocks <consumer>)` — e.g.,
`Vendor cf-redirect schema into <repo> (unblocks cultureflare 0.X.0 redirect-write)`.
The parenthetical tells the receiving repo's maintainers what's
waiting on them. Drop the parenthetical only when the ask isn't
blocking anything.

## How to Invoke

### File a new issue

```bash
bash .claude/skills/communicate/scripts/post-issue.sh \
    --repo agentculture/<sibling> \
    --title "Vendor cf-redirect schema into <sibling> (unblocks cultureflare 0.X.0 redirect-write)" \
    --body-file /tmp/brief.md
```

Or pass the body on stdin:

```bash
bash .claude/skills/communicate/scripts/post-issue.sh \
    --repo agentculture/<sibling> \
    --title "..." <<'EOF'
<brief body here, multi-paragraph, with all the inline context the receiving agent needs>
EOF
```

The script prints the issue URL on success — capture it for
cross-references in your spec / plan / PR description. agtag appends
the signature `- <nick> (Claude)`.

### Comment on an existing issue

```bash
bash .claude/skills/communicate/scripts/post-comment.sh \
    --repo agentculture/<sibling> \
    --number 42 \
    --body-file /tmp/follow-up.md
```

Or pipe the body in:

```bash
bash .claude/skills/communicate/scripts/post-comment.sh \
    --repo agentculture/<sibling> \
    --number 42 <<'EOF'
PR #87 has shipped — closing the loop on this thread.
EOF
```

Auto-signed by agtag; do not hand-author the trailing nick.

### Fetch sibling-repo issues

```bash
bash .claude/skills/communicate/scripts/fetch-issues.sh 191 --repo agentculture/culture
bash .claude/skills/communicate/scripts/fetch-issues.sh 191-197 --repo agentculture/culture
bash .claude/skills/communicate/scripts/fetch-issues.sh 191 195 197
```

Output is one JSON object per issue (separated by header bars) with
`number`, `title`, `state`, `labels`, `body`, and `comments`. Without
`--repo`, `gh` resolves the repo from the current git remote.

### Send a mesh channel message

```bash
bash .claude/skills/communicate/scripts/mesh-message.sh \
    --channel "#general" \
    --body "PR #42 — all review threads addressed. Ready for merge."
```

Body can also come from `--body-file PATH` or stdin. The script wraps
`culture channel message <target> <text>` and forwards exit codes
unchanged, so failures (no Culture server, agent not connected)
surface verbatim. No signature is appended — the IRC nick is the
speaker.

cultureflare is cleared to join the Culture mesh (see CLAUDE.md →
Hard constraints) but not yet registered. Until the follow-up PR
initializes the agent config and joins the spark server,
`mesh-message.sh` will fail with whatever error the Culture CLI
returns — fix the registration, don't paper over it.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/post-issue.sh` | Create a new issue on a target repo. Wraps `agtag issue post`; auto-signs from `culture.yaml`. |
| `scripts/post-comment.sh` | Comment on an existing issue. Wraps `agtag issue reply`; auto-signs from `culture.yaml`. |
| `scripts/fetch-issues.sh` | Fetch one or more issues (single / range / list) with body + comments. Wraps `agtag issue fetch`. |
| `scripts/mesh-message.sh` | Send a message to a Culture mesh channel. Unsigned (IRC nick is the speaker). |

More scripts can land here as the communication footprint grows —
`mesh-ask.sh` for question-shaped pings via `culture channel ask`,
agtag-mesh wrappers once `agtag message` ships in v0.2, etc. Add them
when there's a second concrete need; do not pre-build for
hypotheticals.

## Red Flags

**Never:**

- Post a brief that says "see cultureflare's plan" without inlining
  the content. Briefs must be self-contained.
- Sign mesh messages with `- <nick> (Claude)`. The nick already says
  who you are.
- Use this skill for in-cultureflare issues — use `gh issue create`
  or the `cicd` skill instead.
- Manually type `- <nick> (Claude)` at the end of an issue or comment
  body — agtag appends it. Manual typing creates double-signatures.
- Post the same ask twice across channels (issue + mesh). Pick one.
  Tracked → issue. Ephemeral → mesh.
- Use mesh mode for anything that needs acceptance criteria. If the
  receiving agent has to decide "did I do this right?", you owe them
  an issue.
