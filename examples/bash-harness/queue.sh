#!/usr/bin/env bash
# Run Sandcastle sequentially against a list of issue numbers.
# For each issue:
#   1. sed-swap prompt.md to point at it
#   2. commit the swap (Sandcastle's worktree is created from HEAD,
#      so an uncommitted swap would not be visible to the agent)
#   3. invoke .sandcastle/run.sh (which has its own retry loop for
#      transient API/stream failures)
# Failures on one issue do not abort the queue — the next issue runs
# anyway. Final summary at the end.
#
# Run from repo root:
#   ./.sandcastle/queue.sh 20 19 9
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <issue-number> [<issue-number> ...]" >&2
  exit 2
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree is dirty. Commit or stash before queue.sh." >&2
  exit 1
fi

PROMPT_FILE=".sandcastle/prompt.md"
declare -a RESULTS=()

for issue in "$@"; do
  if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    echo "Skipping non-numeric arg: $issue" >&2
    RESULTS+=("#${issue}: skipped (non-numeric)")
    continue
  fi

  before=$(git rev-parse HEAD)
  echo
  echo "================================================================"
  echo "==> Queue: targeting issue #${issue} (head=${before:0:10})"
  echo "================================================================"

  state=$(gh issue view "$issue" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
  if [ "$state" != "OPEN" ]; then
    echo "==> Issue #${issue} is ${state}; skipping."
    RESULTS+=("#${issue}: skipped (${state})")
    continue
  fi

  sed -i.tmp -E "s|gh issue view [0-9]+|gh issue view ${issue}|" "$PROMPT_FILE"
  rm -f "${PROMPT_FILE}.tmp"

  if git diff --quiet "$PROMPT_FILE"; then
    echo "==> prompt.md already targets #${issue}; no swap commit needed."
  else
    git add "$PROMPT_FILE"
    # --no-verify is used only for this mechanical swap commit; the swap itself
    # has no code changes and hooks would add noise without value here.
    git commit -m "Sandcastle: target issue #${issue}" \
      --no-verify >/dev/null
    echo "==> Swap committed: $(git rev-parse --short HEAD)"
  fi

  set +e
  ./.sandcastle/run.sh
  rc=$?
  set -e

  after=$(git rev-parse HEAD)
  if [ "$after" = "$before" ] || [ "$after" = "$(git rev-parse HEAD~0)" ]; then
    : # no-op placeholder
  fi

  closed_at=$(gh issue view "$issue" --json closedAt --jq '.closedAt // ""' 2>/dev/null || echo "")
  if [ -n "$closed_at" ]; then
    RESULTS+=("#${issue}: CLOSED at ${closed_at} (rc=${rc})")
  elif [ "$rc" -eq 0 ]; then
    RESULTS+=("#${issue}: rc=0 but issue still OPEN — agent may have committed without closing")
  else
    RESULTS+=("#${issue}: FAILED (rc=${rc}) — issue still OPEN")
  fi
done

echo
echo "================================================================"
echo "Queue complete."
echo "================================================================"
for line in "${RESULTS[@]}"; do
  echo "  $line"
done
