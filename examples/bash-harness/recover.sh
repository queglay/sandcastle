#!/usr/bin/env bash
# Recover work from a sandcastle-failed-* backup branch.
# Records the override with a mandatory --note for audit-log purposes.
# Adds sandcastle-recovered label, removes sandcastle-failed, closes the issue.
set -euo pipefail

usage() {
    echo "Usage: $0 <backup-branch> --note '<reason>' [--issue <number>]"
    echo "  <backup-branch>   sandcastle-failed-* branch to merge"
    echo "  --note '<reason>' mandatory free-form reason for overriding the revert"
    echo "  --issue <num>     issue number; auto-detected from prompt.md if omitted"
    exit 2
}

[ $# -lt 1 ] && usage
backup_branch="$1"; shift

note=""
issue_num=""
while [ $# -gt 0 ]; do
    case "$1" in
        --note)  note="$2"; shift 2 ;;
        --issue) issue_num="$2"; shift 2 ;;
        *) usage ;;
    esac
done

case "$backup_branch" in
    sandcastle-failed-*) ;;
    *) echo "Error: branch must start with 'sandcastle-failed-'" >&2; exit 1 ;;
esac

if [ -z "$note" ]; then
    echo "Error: --note is mandatory. Why is this revert being overridden?" >&2
    exit 1
fi

if ! git rev-parse --verify "$backup_branch" >/dev/null 2>&1; then
    echo "Error: branch '$backup_branch' does not exist." >&2
    exit 1
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "main" ]; then
    echo "Error: must be run on 'main' (currently on '$current_branch')." >&2
    echo "       Recovery merges the backup branch onto main; refusing to merge onto another branch." >&2
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree is dirty. Commit or stash before recovery." >&2
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
if [ -z "$issue_num" ]; then
    issue_num=$(grep -oE 'gh issue view [0-9]+' "$REPO_ROOT/.sandcastle/prompt.md" | head -1 | grep -oE '[0-9]+' || true)
fi
if [ -z "$issue_num" ]; then
    echo "Error: could not auto-detect issue number; pass --issue <num>." >&2
    exit 1
fi

gh label create sandcastle-failed --color "EE0000" --description "Sandcastle run reverted by host gate" 2>/dev/null || true
gh label create sandcastle-recovered --color "0E8A16" --description "Sandcastle backup branch manually recovered via recover.sh" 2>/dev/null || true

# Failure reason from branch suffix (allowlist, no-allowlist, artifacts, no-artifacts, preflight, test, ...).
# Anchor on the trailing -YYYYMMDD-HHMMSS timestamp so hyphenated reasons survive intact.
# Legacy branches without a reason segment fall back to "unknown".
reason=$(echo "$backup_branch" | sed -E 's/^sandcastle-failed-(.+)-[0-9]{8}-[0-9]{6}$/\1/')
if [ "$reason" = "$backup_branch" ]; then
    reason="unknown"
fi

git merge --no-ff "$backup_branch" -m "Recover from $backup_branch ($reason): $note"
recovered_sha=$(git rev-parse HEAD)

gh issue comment "$issue_num" --body "$(cat <<EOF
✅ **Recovered**: merged \`$recovered_sha\` from \`$backup_branch\`.
**Original failure**: $reason
**Reason for recovery**: $note
EOF
)"

gh issue edit "$issue_num" --remove-label sandcastle-failed 2>/dev/null || true
gh issue edit "$issue_num" --add-label sandcastle-recovered 2>/dev/null || true

gh issue close "$issue_num" --comment "Closed by recover.sh: $recovered_sha"

echo "==> Recovered: merged $backup_branch onto main as $recovered_sha"
echo "    Issue #$issue_num: labelled sandcastle-recovered, closed."
