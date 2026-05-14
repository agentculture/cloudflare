---
name: poll
description: >
  Spawn a background subagent that waits for a GitHub PR's automated
  reviewers via `agex pr read --wait`, and notifies you ONLY when the
  reviewers have finished or the PR is merged/closed. Cheaper than
  self-paced ScheduleWakeup because the main session does NOT wake on
  every heartbeat. Use when: right after `gh pr create` /
  `workflow.sh open`, the user says "poll", "/poll", "wait for
  reviewers", "babysit the PR", or anything else where the point is
  to hand off until reviewer feedback is ready. Args:
  PR_NUMBER [OWNER/REPO].
---

# poll

Spawns a background subagent that owns the wait. The main session
returns immediately and gets a single completion notification when
the subagent's `agex pr read --wait` returns.

## When to use

- **Right after `gh pr create` / `workflow.sh open`.** The cicd skill
  delegates the async wait here — invoke once, then resume other work.
- Whenever the user wants to wait for automated reviewer feedback
  without burning main-session context on heartbeat polls.

## Why a subagent instead of `/loop` + ScheduleWakeup

`agex pr read --wait N` polls in-session for up to N seconds until the
required reviewers post (or the PR closes). Run directly in the main
session, that wait replays the conversation context on every
cache-window miss — a lot of churn for "still waiting."

A background subagent owns its own context. It runs `agex pr read
--wait` once, blocks until readiness fires, emits a single
notification, and the main session pays the context cost once — at the
end.

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
4. Confirm to the user in one line: *"Background poller spawned for PR (N) at OWNER/REPO. Will notify when the automated reviewers are done (or the PR closes)."*
5. **Stop.** Do not poll further from the main session, do not call ScheduleWakeup. The subagent's completion is the next event.

## Subagent prompt template

Copy this into the `Agent` tool's `prompt` parameter, with the PR
number and `OWNER/REPO` substituted in:

````text
You are a background poller for GitHub PR PR_NUMBER at OWNER/REPO. Your
only job is to wait until the automated reviewers have posted their
feedback, or until the PR is merged/closed. Then return a short
outcome summary.

Use the project's own workflow script — do NOT hand-roll gh api calls.
Run from the cultureflare repo root (parent agent's CWD):

```sh
bash .claude/skills/cicd/scripts/workflow.sh read PR_NUMBER --wait 1800
```

`agex pr read --wait` owns the readiness loop: it polls in-process for
up to 1800 seconds (~30 min) and returns a one-shot briefing — CI
checks, SonarCloud gate, all comments, a "Next step:" footer — as soon
as the required reviewers are ready, or when the wait cap is hit.

Before invoking, sanity-check the PR state once:
`gh pr view PR_NUMBER --repo OWNER/REPO --json state -q .state`
If state is already MERGED or CLOSED, skip the wait and report that.

Final report (≤10 lines):

- PR URL: https://github.com/OWNER/REPO/pull/PR_NUMBER
- Final state: OPEN / MERGED / CLOSED
- Reviewers: ready / wait cap hit (1800s elapsed, reviewers not yet posted)
- Headline from the `agex pr read` briefing (CI + SonarCloud + comment counts)
- Suggested next step: "Run /cicd for PR PR_NUMBER" if the briefing is
  ready; "PR was merged before reviewers finished" if MERGED; "Hit the
  30-minute wait cap, may need to re-poll" if the wait timed out.

DO NOT do triage or fixes — that's the parent agent's job once you
return. You only run the wait and report.
````

## What the parent does on completion

When the subagent's notification arrives, the parent should:

1. Run `bash .claude/skills/cicd/scripts/workflow.sh read PR_NUMBER` to
   refetch the now-ready briefing (the subagent's report is just
   headlines), or `workflow.sh await PR_NUMBER` for the briefing plus
   the SonarCloud / unresolved-thread gate.
2. Invoke the `cicd` skill to triage, fix, push, reply, and resolve.

## Stopping early

The user can interrupt the subagent at any time with "stop" / "cancel"
/ "that's enough." Use `TaskList` to find the background task ID and
`TaskStop` to terminate it.
