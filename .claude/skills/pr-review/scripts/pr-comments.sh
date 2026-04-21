#!/usr/bin/env bash
set -euo pipefail

# Fetch and display all PR feedback in one pass:
#   1. Inline review comments (with thread resolve status)
#   2. Issue comments (qodo summaries, sonarcloud quality-gate, etc.)
#   3. Top-level reviews with a non-empty body (copilot overviews, etc.)
#   4. SonarCloud new issues (public API; skipped if the project isn't
#      registered or the network call fails).
#
# Usage: pr-comments.sh [--repo OWNER/REPO] PR_NUMBER
#
# SonarCloud project key is derived from the GitHub convention
# "<org>_<repo>" (e.g. agentculture_cloudflare). Override with
# SONAR_PROJECT_KEY=<key> for non-standard naming.

REPO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        *) break ;;
    esac
done

PR_NUMBER="${1:?Usage: pr-comments.sh [--repo OWNER/REPO] PR_NUMBER}"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "ERROR: PR_NUMBER must be a positive integer, got: $PR_NUMBER" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

# ── Section 1: inline review comments ─────────────────────────────────────
# Fetch ALL comments per thread (not just the root) so reply comments can
# still be mapped back to their thread and resolved. For realistic PRs,
# `comments(first: 100)` is enough; a warning is emitted below if the
# reviewThreads page is also capped.
THREADS_RAW=$(gh api graphql -f query="
{
  repository(owner: \"${REPO%%/*}\", name: \"${REPO##*/}\") {
    pullRequest(number: $PR_NUMBER) {
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id
          isResolved
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes { databaseId }
          }
        }
      }
    }
  }
}")

THREADS_HAS_MORE=$(echo "$THREADS_RAW" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
if [[ "$THREADS_HAS_MORE" == "true" ]]; then
    echo "Warning: PR has >100 review threads; some threads may not appear below." >&2
fi

THREADS_JSON=$(echo "$THREADS_RAW" | jq '.data.repository.pullRequest.reviewThreads.nodes')

# Flatten: one entry per (comment_id, thread_id, resolved) so EVERY comment
# in the thread maps to its thread — not just the root. This is what
# lets callers look up the thread for a reply comment.
THREAD_MAP=$(echo "$THREADS_JSON" | jq -r '
  [.[] | . as $t | .comments.nodes[] | {
    comment_id: .databaseId,
    thread_id: $t.id,
    resolved: $t.isResolved
  }]
')

# gh api --paginate concatenates multiple JSON arrays (one per page) into
# its output. jq -s slurps them into an array-of-arrays; `add` flattens
# to a single array so length / iteration are correct regardless of page
# count.
INLINE=$(gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate | jq -s 'add // []')
INLINE_COUNT=$(echo "$INLINE" | jq 'length')

echo "════════════════ INLINE REVIEW COMMENTS ($INLINE_COUNT) ════════════════"
echo "$INLINE" | jq -r --argjson threads "$THREAD_MAP" '
  .[] | . as $c |
  ($threads | map(select(.comment_id == $c.id)) | first // {resolved: "unknown", thread_id: "?"}) as $t |
  "──────────────────────────────────────────────────",
  "ID: \($c.id)  |  Thread: \(if $t.resolved == true then "RESOLVED" elif $t.resolved == false then "UNRESOLVED" else "?" end)  |  Reply-to: \($c.in_reply_to_id // "none")",
  "File: \($c.path):\($c.original_line // $c.line // "?")",
  "Thread ID: \($t.thread_id)",
  "Author: \($c.user.login)",
  "",
  ($c.body | split("\n") | if length > 10 then .[:10] + ["... (truncated)"] else . end | join("\n")),
  ""
'

# ── Section 2: issue comments (general PR comments) ───────────────────────
ISSUE=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate | jq -s 'add // []')
ISSUE_COUNT=$(echo "$ISSUE" | jq 'length')

echo ""
echo "════════════════ ISSUE COMMENTS ($ISSUE_COUNT) ════════════════"
echo "$ISSUE" | jq -r '
  .[] |
  "──────────────────────────────────────────────────",
  "ID: \(.id)  |  Author: \(.user.login)  |  Created: \(.created_at)",
  "",
  (.body | split("\n") | if length > 10 then .[:10] + ["... (truncated)"] else . end | join("\n")),
  ""
'

# ── Section 3: top-level reviews with a body ──────────────────────────────
REVIEWS=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate | jq -s 'add // []')
REVIEWS_WITH_BODY=$(echo "$REVIEWS" | jq '[.[] | select((.body // "") != "")]')
REVIEW_COUNT=$(echo "$REVIEWS_WITH_BODY" | jq 'length')

echo ""
echo "════════════════ TOP-LEVEL REVIEWS ($REVIEW_COUNT) ════════════════"
echo "$REVIEWS_WITH_BODY" | jq -r '
  .[] |
  "──────────────────────────────────────────────────",
  "Review ID: \(.id)  |  Author: \(.user.login)  |  State: \(.state)  |  Submitted: \(.submitted_at)",
  "",
  (.body | split("\n") | if length > 10 then .[:10] + ["... (truncated)"] else . end | join("\n")),
  ""
'

# ── Section 4: SonarCloud new issues (optional) ────────────────────────
# Saves one manual curl per review cycle. Silently skipped if SonarCloud
# isn't configured for this repo (API returns an error, which we detect
# by the absence of an .issues field in the response).
SONAR_KEY="${SONAR_PROJECT_KEY:-${REPO/\//_}}"
SONAR_URL="https://sonarcloud.io/api/issues/search?componentKeys=${SONAR_KEY}&pullRequest=${PR_NUMBER}&resolved=false&ps=100"
SONAR_JSON=$(curl -sSf "$SONAR_URL" 2>/dev/null || true)

if [[ -n "$SONAR_JSON" ]] && echo "$SONAR_JSON" | jq -e '.issues' >/dev/null 2>&1; then
    SONAR_COUNT=$(echo "$SONAR_JSON" | jq '.issues | length')
    echo ""
    echo "════════════════ SONARCLOUD NEW ISSUES ($SONAR_COUNT) ════════════════"
    if (( SONAR_COUNT == 0 )); then
        echo "(quality gate passed — no new issues on this PR)"
    else
        echo "$SONAR_JSON" | jq -r '.issues[] |
          "──────────────────────────────────────────────────",
          "File: \(.component | sub(".*:"; ""))  |  Line: \(.line // "?")",
          "Severity: \(.severity // "?")  |  Type: \(.type // "?")  |  Rule: \(.rule // "?")",
          "Message: \(.message // "?")",
          ""'
    fi
fi
