#!/usr/bin/env bash
set -euo pipefail

# Reply to a PR review comment, optionally resolve its thread.
# Usage: pr-reply.sh [--repo OWNER/REPO] [--resolve] PR_NUMBER COMMENT_ID "body"

REPO=""
RESOLVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --resolve) RESOLVE=true; shift ;;
        *) break ;;
    esac
done

PR_NUMBER="${1:?Usage: pr-reply.sh [--repo OWNER/REPO] [--resolve] PR_NUMBER COMMENT_ID \"body\"}"
COMMENT_ID="${2:?Missing COMMENT_ID}"
BODY="${3:?Missing reply body}"

# PR_NUMBER and COMMENT_ID are interpolated into GraphQL / jq strings.
# Accept only integers to prevent query breakage or injection from a
# badly-shaped caller argument.
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "ERROR: PR_NUMBER must be a positive integer, got: $PR_NUMBER" >&2; exit 2; }
[[ "$COMMENT_ID" =~ ^[0-9]+$ ]] || { echo "ERROR: COMMENT_ID must be a positive integer, got: $COMMENT_ID" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

# Append signature so recipients know the reply came from an AI assistant.
BODY="${BODY}

- Claude"

# Post reply
REPLY_URL=$(gh api "repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" \
    -f body="$BODY" \
    --jq '.html_url')
echo "Replied: $REPLY_URL"

# Resolve thread if requested
if [[ "$RESOLVE" == true ]]; then
    # Match COMMENT_ID against ANY comment in each thread, not just the
    # root comment — replies share the thread with their root and need
    # to resolve the same thread. `comments(first: 100)` covers realistic
    # thread depths; deeper threads will warn below.
    THREAD_ID=$(gh api graphql -f query="
    {
      repository(owner: \"${REPO%%/*}\", name: \"${REPO##*/}\") {
        pullRequest(number: $PR_NUMBER) {
          reviewThreads(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              id
              comments(first: 100) {
                pageInfo { hasNextPage }
                nodes { databaseId }
              }
            }
          }
        }
      }
    }" --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select([.comments.nodes[].databaseId] | index($COMMENT_ID)) | .id" | head -1)

    # Warn (don't fail) if the query hit the first-page cap — resolve may
    # silently miss if the target thread is beyond thread 100 or comment 100.
    HAS_MORE=$(gh api graphql -f query="
    {
      repository(owner: \"${REPO%%/*}\", name: \"${REPO##*/}\") {
        pullRequest(number: $PR_NUMBER) {
          reviewThreads(first: 100) { pageInfo { hasNextPage } }
        }
      }
    }" --jq '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    if [[ "$HAS_MORE" == "true" ]]; then
        echo "Warning: PR has >100 review threads; thread lookup may miss older threads." >&2
    fi

    if [[ -n "$THREAD_ID" ]]; then
        RESOLVED=$(gh api graphql -f query="
          mutation { resolveReviewThread(input: {threadId: \"$THREAD_ID\"}) { thread { isResolved } } }
        " --jq '.data.resolveReviewThread.thread.isResolved')
        echo "Resolved: $RESOLVED (thread $THREAD_ID)"
    else
        echo "Warning: could not find thread for comment $COMMENT_ID"
    fi
fi
