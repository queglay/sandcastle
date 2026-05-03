#!/usr/bin/env bash
# Sandcastle launcher — extracts the live Claude OAuth token from macOS
# Keychain and exports it as CLAUDE_CODE_OAUTH_TOKEN so the in-container
# `claude` CLI can authenticate with the host's subscription.
#
# The bind-mounted ~/.claude/.credentials.json file is unreliable on macOS:
# Claude Code writes credentials to the Keychain, and the file on disk is
# typically stale (the access token in it is expired). The env var path is
# what the official `claude-sandbox.sh` uses and what we mirror here.
#
# Run from repo root:  ./.sandcastle/run.sh
#                or:   bash .sandcastle/run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Argument parsing ──────────────────────────────────────────────────────────
# Long-flag --harness-branch <name> activates validation mode: check out the
# held branch, run the agent against it, fast-forward main on success.
HARNESS_VALIDATE_BRANCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --harness-branch)
            shift
            [ -z "${1:-}" ] && { echo "Error: --harness-branch requires a value." >&2; exit 1; }
            HARNESS_VALIDATE_BRANCH="$1"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'." >&2
            exit 1
            ;;
    esac
done

if ! command -v security >/dev/null 2>&1; then
    echo "Error: 'security' command not found — this script requires macOS." >&2
    exit 1
fi

raw_creds=$(security find-generic-password -s "Claude Code-credentials" -a "user" -w 2>/dev/null || true)
if [ -z "$raw_creds" ]; then
    echo "Error: Could not read Claude OAuth credentials from macOS Keychain." >&2
    echo "       Run 'claude' once on the host to authenticate, then retry." >&2
    exit 1
fi

token=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['claudeAiOauth']['accessToken'])" "$raw_creds" 2>/dev/null || true)
if [ -z "$token" ]; then
    echo "Error: Keychain entry exists but does not have the expected OAuth shape." >&2
    exit 1
fi

export CLAUDE_CODE_OAUTH_TOKEN="$token"

echo "==> Live OAuth token extracted from Keychain (length=${#token})."

current_branch=$(git rev-parse --abbrev-ref HEAD)
before_head=$(git rev-parse HEAD)
echo "==> Pre-run state: branch=${current_branch} head=${before_head:0:10}"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: Uncommitted changes detected in the working tree." >&2
    echo "       Sandcastle's bind-mount would let the agent see and possibly commit them." >&2
    echo "       Stash or commit before retrying." >&2
    exit 1
fi

# (feature gates added below)
