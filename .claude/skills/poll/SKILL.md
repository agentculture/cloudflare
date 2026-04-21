---
name: poll
description: >
  Spawn a background subagent that polls a GitHub PR every 60 seconds
  via pr-comments.sh and notifies you ONLY when both automated
  reviewers (qodo and Copilot) have finished, or when the PR is
  merged/closed. Cheaper than self-paced ScheduleWakeup because the
  main session does NOT wake on every heartbeat. Use when: right
  after `gh pr create`, the user says "poll", "/poll", "wait for
  reviewers", "babysit the PR", or anything else where the point is
  to hand off until reviewer feedback is ready. Args:
  PR_NUMBER [OWNER/REPO].
---

# poll

Spawns a background subagent that owns the wait. The main session
returns immediately and gets a single completion notification when the
subagent decides reviews are ready.

## When to use

- **Right after `gh pr create`.** The pr-review skill's *Auto-poll
  after PR creation* section delegates here — invoke once, then
  resume other work.
- Whenever the user wants to wait for automated reviewer feedback
  without burning main-session context on heartbeat polls.

## Why a subagent instead of `/loop` + ScheduleWakeup

`/loop` in dynamic mode wakes the main session every iteration: each
ScheduleWakeup tick replays the conversation, calls a bash command,
checks state, and reschedules. For a 5–15 minute wait that's a lot of
cache-window churn for "still waiting."

A background subagent owns its own context. It polls with
`bash .claude/skills/pr-review/scripts/pr-comments.sh` (the same
single-call fetcher the pr-review skill uses), only emits a
notification when the wait is over, and the main session pays the
context cost once — at the end.

## Args

```text
/poll PR_NUMBER [OWNER/REPO]
```

`OWNER/REPO` defaults to the current `gh repo view --json nameWithOwner -q .nameWithOwner`.

## Behavior

1. Parse `PR_NUMBER` (required positional). If absent, print usage and stop.
2. Resolve `OWNER/REPO` (second positional or `gh repo view`).
3. Invoke the **Agent** tool with:
    - `subagent_type: general-purpose`
    - `run_in_background: true`
    - `description: "Poll PR <N> for reviewer readiness"`
    - `prompt`: the subagent prompt template below, with the PR number and repo substituted.
4. Confirm to the user in one line: *"Background poller spawned for PR (N) at OWNER/REPO. Will notify when qodo and Copilot are both done (or the PR closes)."*
5. **Stop.** Do not poll further from the main session, do not call ScheduleWakeup. The subagent's completion is the next event.

## Subagent prompt template

Copy this into the `Agent` tool's `prompt` parameter, with the PR
number and `OWNER/REPO` substituted in:

````text
You are a background poller for GitHub PR PR_NUMBER at OWNER/REPO. Your
only job is to wait until both automated reviewers
(qodo-code-review and Copilot) have posted their full reviews, or
until the PR is merged/closed. Then return a short outcome summary.

Use the project's own fetch script — do NOT hand-roll gh api calls:

```sh
cd /home/spark/git/cloudflare
bash .claude/skills/pr-review/scripts/pr-comments.sh PR_NUMBER
```

Loop up to 30 times with `sleep 60` between iterations (~30-minute
hard cap). Each iteration:

1. Check PR state:
   `gh pr view PR_NUMBER --repo OWNER/REPO --json state -q .state`
   If state is MERGED or CLOSED, stop and report.

2. Fetch comments via pr-comments.sh and inspect the output for
   readiness signals:

   - **qodo ready** when the ISSUE COMMENTS section contains a qodo
     comment whose body includes "Code Review by Qodo" AND does NOT
     include "Looking for bugs?" (qodo's placeholder while analysis
     runs). The first qodo "Walkthroughs" summary comment alone is
     not enough.

   - **Copilot ready** when the TOP-LEVEL REVIEWS section header
     reports a count > 0 (e.g. `TOP-LEVEL REVIEWS (1)`).

3. If both ready: stop and report success.

4. Otherwise sleep 60 seconds and try again.

Final report (≤10 lines):

- PR URL: https://github.com/OWNER/REPO/pull/PR_NUMBER
- Final state: OPEN / MERGED / CLOSED / TIMEOUT (after 30 iterations)
- qodo: ready / placeholder-only / not-posted
- Copilot: ready / not-posted
- SonarCloud (from the script's section 4): N issues / quality gate passed
- Iterations used / 30
- Suggested next step: "Run /pr-review for PR PR_NUMBER" if both ready;
  "PR was merged before reviewers finished" if MERGED; "Hit
  30-iteration cap, may need to re-poll" if TIMEOUT.

DO NOT do triage or fixes — that's the parent agent's job once you
return. You only verify readiness and report.
````

## What the parent does on completion

When the subagent's notification arrives, the parent should:

1. Run `bash .claude/skills/pr-review/scripts/pr-comments.sh PR_NUMBER` to refetch the now-ready feedback (the subagent's report is just headlines).
2. Invoke the `pr-review` skill to triage, fix, push, reply, and resolve.

## Stopping early

The user can interrupt the subagent at any time with "stop" / "cancel"
/ "that's enough." Use `TaskList` to find the background task ID and
`TaskStop` to terminate it.
