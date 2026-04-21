---
name: pr-review
description: >
  Handle PR review comments: fetch, reply, and resolve threads.
  Use when: working with PR reviews, responding to review comments,
  resolving review threads, or the user says "review comments",
  "PR comments", "resolve threads", or "reply to reviews".
---

# PR Review

Fetch, reply to, and resolve PR review comments via `gh` CLI.

## When to Use

- Before fixing PR review comments (fetch first to understand them)
- After fixing issues flagged in a PR review (reply and resolve)
- When the user asks to handle, respond to, or resolve PR comments

## Workflow

### 1. Fetch comments

Read all PR feedback before acting. One call returns inline review comments,
issue comments (qodo code reviews, sonarcloud quality gate, etc.), and
top-level review bodies (copilot overviews):

```bash
bash .claude/skills/pr-review/scripts/pr-comments.sh PR_NUMBER
```

### 2. Triage

For each comment, decide:

- **FIX** — valid concern, make the code change
- **PUSHBACK** — disagree, explain why in the reply

### 3. Fix code

Make changes, commit, and push.

### 4. Respond

Reply to each comment. Use batch mode for multiple comments:

```bash
bash .claude/skills/pr-review/scripts/pr-batch.sh --resolve PR_NUMBER <<'EOF'
{"comment_id": 123, "body": "Fixed -- removed from repo"}
{"comment_id": 456, "body": "Intentional -- this is a dev tool"}
EOF
```

Or reply to a single comment:

```bash
bash .claude/skills/pr-review/scripts/pr-reply.sh --resolve PR_NUMBER COMMENT_ID "Fixed -- updated the code"
```

## Scripts

### pr-comments.sh

Fetch and display all PR feedback in one pass, grouped into three sections:

1. **Inline review comments** — file/line comments on the diff, with thread
   resolve status and thread ID (these are what `pr-reply.sh` acts on).
2. **Issue comments** — general PR comments (qodo summary + code review,
   sonarcloud quality gate, cloudflare pages deploy preview, etc.).
3. **Top-level reviews** — PR-level review bodies with content (e.g. copilot
   PR overviews). Reviews whose only content is inline comments are skipped
   to avoid duplicating section 1.

```bash
bash .claude/skills/pr-review/scripts/pr-comments.sh [--repo OWNER/REPO] PR_NUMBER
```

Bodies are truncated at 10 lines. Only inline review comments have thread IDs
and can be resolved via `pr-reply.sh`/`pr-batch.sh`; the other sections are
listed for visibility only.

### pr-reply.sh

Reply to a single review comment, optionally resolve its thread.

```bash
bash .claude/skills/pr-review/scripts/pr-reply.sh [--repo OWNER/REPO] [--resolve] PR_NUMBER COMMENT_ID "body"
```

### pr-batch.sh

Batch reply (and optionally resolve) from JSONL on stdin.

```bash
bash .claude/skills/pr-review/scripts/pr-batch.sh [--repo OWNER/REPO] [--resolve] PR_NUMBER <<'EOF'
{"comment_id": 123, "body": "Fixed"}
{"comment_id": 456, "body": "Intentional"}
EOF
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--repo OWNER/REPO` | auto-detect | Override repository (default: from `gh repo view`) |
| `--resolve` | off | Also resolve the thread after replying |

## Branch Hygiene

If the current branch already has an open PR, **do not** add unrelated commits to it. Instead:

1. Branch off `main` with a descriptive name (e.g., `docs/irc-rationale`)
2. Commit and push there
3. Open a separate PR

Only add commits to an existing PR's branch if they are directly related to that PR's scope.

## Notes

- All scripts auto-detect `owner/repo` from the current git repo
- Replies are auto-signed with `\n\n- Claude` so recipients know the reply was written by an AI assistant
- Thread resolution uses GitHub GraphQL API (REST doesn't support it)
- Requires `gh` CLI authenticated and `jq` installed
- `reviewThreads(first: 100)` is not paginated; the scripts warn to stderr on PRs with more than 100 review threads. If you hit that, either narrow the PR scope or extend the scripts with full GraphQL pagination

## Argument validation

`PR_NUMBER` and `COMMENT_ID` must be positive integers — the scripts interpolate them into GraphQL query strings and jq filters, and reject non-numeric input with exit status 2.
