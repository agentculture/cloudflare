#!/bin/bash
# Background poller for PR 25 — up to 30 iterations of 60s sleep.
SCRIPT="/home/spark/git/cfafi/.claude/skills/pr-review/scripts/pr-comments.sh"
DIR="/home/spark/git/cfafi/.poll"
LOG="$DIR/log"
RESULT="$DIR/result"
LAST="$DIR/last"
: > "$LOG"
: > "$RESULT"
: > "$LAST"
i=0
while [ $i -lt 30 ]; do
  i=$((i+1))
  state=$(gh pr view 25 --repo agentculture/cfafi --json state -q .state 2>/dev/null || echo OPEN)
  if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
    bash "$SCRIPT" 25 > "$LAST" 2>&1 || true
    echo "FINAL_STATE=$state ITER=$i" > "$RESULT"
    echo "DONE_TERMINAL"
    exit 0
  fi
  out=$(bash "$SCRIPT" 25 2>&1 || true)
  printf '%s' "$out" > "$LAST"
  qodo_full=0
  if printf '%s' "$out" | grep -q "Code Review by Qodo"; then
    if ! printf '%s' "$out" | grep -q "Looking for bugs?"; then
      qodo_full=1
    fi
  fi
  copilot_count=$(printf '%s' "$out" | grep -oE "TOP-LEVEL REVIEWS \([0-9]+\)" | grep -oE "[0-9]+" | head -1)
  copilot_count=${copilot_count:-0}
  echo "ITER=$i STATE=$state qodo_full=$qodo_full copilot=$copilot_count" >> "$LOG"
  if [ "$qodo_full" = "1" ] && [ "$copilot_count" -gt 0 ]; then
    echo "BOTH_READY ITER=$i" > "$RESULT"
    echo "DONE_BOTH_READY"
    exit 0
  fi
  sleep 60
done
echo "TIMEOUT ITER=$i" > "$RESULT"
echo "DONE_TIMEOUT"
