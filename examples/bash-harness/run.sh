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


MAX_ATTEMPTS=3
attempt=0
while : ; do
    attempt=$((attempt + 1))
    echo "==> Attempt ${attempt}/${MAX_ATTEMPTS}: launching Sandcastle..."
    set +e
    npx tsx .sandcastle/main.ts
    sandcastle_status=$?
    set -e

    after_head=$(git rev-parse HEAD)
    if [ "${HARNESS_MODE}" = "hold" ]; then
        if git show-ref --verify --quiet "refs/heads/${HARNESS_HOLD_BRANCH}" \
            && [ "$(git rev-list "main..${HARNESS_HOLD_BRANCH}" --count 2>/dev/null || echo 0)" -gt 0 ]; then
            break
        fi
    else
        if [ "$after_head" != "$before_head" ]; then
            break
        fi
    fi

    latest_log=$(ls -t "$REPO_ROOT/.sandcastle/logs/"main-*.log 2>/dev/null | head -1)
    if [ -n "$latest_log" ] && grep -q "<promise>BLOCKED</promise>" "$latest_log"; then
        echo "==> Agent signaled BLOCKED — not retrying. See ${latest_log}."
        exit 0
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "==> ${MAX_ATTEMPTS} attempts produced no commits and no BLOCKED signal. Giving up." >&2
        echo "    Latest run log: ${latest_log:-<none>}" >&2
        exit "${sandcastle_status:-1}"
    fi

    echo "==> Attempt ${attempt} produced no commits and no BLOCKED signal — likely a transient API/stream failure. Retrying."
done

ts=$(date +%Y%m%d-%H%M%S)

# ── Allow-list scope check ────────────────────────────────────────────────────
# Parses `## Allowed paths` (fenced code block of glob patterns) from the
# current issue's body and rejects diffs that touch files outside that list.
# Issues filed before this convention was established have no section; we warn
# and skip enforcement.

issue_num=$(grep -oE 'gh issue view [0-9]+' "$REPO_ROOT/.sandcastle/prompt.md" | head -1 | grep -oE '[0-9]+' || true)

if [ -z "$issue_num" ]; then
    echo "==> Warning: could not determine issue number from prompt.md; allow-list check skipped." >&2
else
    gh label create sandcastle-failed --color "EE0000" --description "Sandcastle run reverted by host gate" 2>/dev/null || true
    gh label create sandcastle-recovered --color "0E8A16" --description "Sandcastle backup branch manually recovered via recover.sh" 2>/dev/null || true

    issue_body=$(gh issue view "$issue_num" --json body --jq '.body' 2>/dev/null || true)
    issue_labels=$(gh issue view "$issue_num" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || true)
    case ",${issue_labels}," in
        *,afk-ready,*) issue_is_afk_ready=1 ;;
        *)             issue_is_afk_ready=0 ;;
    esac

    allowed_paths=$(printf '%s\n' "$issue_body" | awk '
      /^## Allowed paths/ {found=1; capture=0; next}
      /^## / {found=0; capture=0; next}
      found && /^```/ {capture=!capture; next}
      capture && NF > 0 {print}
    ')

    if [ -z "$allowed_paths" ]; then
        if [ "$issue_is_afk_ready" = "1" ]; then
            echo "!! Issue #${issue_num} is labelled 'afk-ready' but has no '## Allowed paths' section." >&2
            echo "   The allow-list scope check cannot run without it. Refusing to merge." >&2
            echo "   Fix: edit the issue body to add a fenced '## Allowed paths' block, then rerun." >&2
            gate_revert_with_logs "sandcastle-failed-no-allowlist-${ts}"
            post_revert_comment_and_label "$issue_num" "missing '## Allowed paths' section on afk-ready issue" "sandcastle-failed-no-allowlist-${ts}" "Add a fenced '## Allowed paths' block to the issue body, then re-run."
            exit 1
        fi
        echo "==> Warning: issue #${issue_num} has no '## Allowed paths' section — scope check skipped." >&2
        echo "    Add a fenced '## Allowed paths' block to the issue body to enforce scope on future runs." >&2
    else
        # Pre-flight: each literal path's parent directory must exist. The
        # file itself may be new (slices that legitimately create files), but
        # the directory anchor must be real — that catches typo'd paths before
        # the run, while allowing genuinely new files inside existing directories.
        preflight_violations=()
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            case "$p" in
                *'*'*|*'?'*|*'['*) continue ;;
            esac
            parent_dir=$(dirname "$p")
            if [ ! -d "$REPO_ROOT/$parent_dir" ]; then
                preflight_violations+=("$p")
            fi
        done <<< "$allowed_paths"

        if [ ${#preflight_violations[@]} -gt 0 ]; then
            echo "!! Pre-flight: literal path(s) in '## Allowed paths' have non-existent parent directory:" >&2
            for p in "${preflight_violations[@]}"; do
                echo "     - $p (parent: $(dirname "$p")/)" >&2
            done
            gate_revert_with_logs "sandcastle-failed-preflight-${ts}"
            post_revert_comment_and_label "$issue_num" "pre-flight: literal path(s) in allow-list have non-existent parent directory" "sandcastle-failed-preflight-${ts}" "$(printf 'Literal path(s) in ## Allowed paths whose parent directory does not exist:\n%s\n\nThe file may be new, but the directory must already exist. Fix the directory portion of the allow-list and re-run.' "$(for p in "${preflight_violations[@]}"; do echo "- \`$p\` (parent \`$(dirname "$p")/\` missing)"; done)")"
            exit 1
        fi

        pathspec_args=()
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            pathspec_args+=(":(glob)$p")
        done <<< "$allowed_paths"

        # Auto-allow `.sandcastle/artifacts/<file>` for every filename declared
        # in the issue's `## Required artifacts` block. The required-artifact
        # gate below MANDATES the agent commit those files there; the allow-list
        # gate must therefore whitelist them implicitly. Without this the two
        # gates conflict — the agent ships exactly what was asked and gets
        # reverted.
        required_artifacts_for_allow=$(printf '%s\n' "$issue_body" | awk '
          /^## Required artifacts/ {found=1; capture=0; next}
          /^## / {found=0; capture=0; next}
          found && /^```/ {capture=!capture; next}
          capture && NF > 0 {print}
        ')
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            pathspec_args+=(":(glob).sandcastle/artifacts/$f")
        done <<< "$required_artifacts_for_allow"

        # Always-allowed auto-generated files. Tooling can regenerate certain
        # files on every build (e.g. a router's route-tree file), so any slice
        # that triggers a rebuild would trip the allow-list otherwise.
        # Populate SANDCASTLE_AUTO_GENERATED_FILES in your .env as a
        # space-separated list of repo-relative paths.
        read -ra AUTO_GENERATED_ALLOWED <<< "${SANDCASTLE_AUTO_GENERATED_FILES:-}"
        for f in "${AUTO_GENERATED_ALLOWED[@]}"; do
            pathspec_args+=(":(glob)${f}")
        done

        all_changed=$(git diff --name-only "${DIFF_RANGE}" | sort -u)
        allowed_changed=$(git diff --name-only "${DIFF_RANGE}" -- "${pathspec_args[@]}" | sort -u)
        violations=$(comm -23 <(printf '%s\n' "$all_changed") <(printf '%s\n' "$allowed_changed"))

        if [ -n "$violations" ]; then
            echo
            echo "!! Allow-list violation: agent edited files outside #${issue_num}'s declared scope. Capturing worktree logs before revert." >&2
            echo "   Out-of-scope files:" >&2
            printf '%s\n' "$violations" | sed 's/^/     - /' >&2
            echo "   Allowed patterns:" >&2
            printf '%s\n' "$allowed_paths" | sed 's/^/     /' >&2
            echo

            gate_revert_with_logs "sandcastle-failed-allowlist-${ts}"
            post_revert_comment_and_label "$issue_num" "allow-list violation" "sandcastle-failed-allowlist-${ts}" "$(printf 'Out-of-scope files:\n%s' "$(printf '%s\n' "$violations" | sed 's/^/- /')")"
            exit 1
        fi

        echo "==> Allow-list check passed (issue #${issue_num})."
    fi
fi

# ── Required-artifact gate ────────────────────────────────────────────────────
# Parses `## Required artifacts` (fenced code block of filenames, relative to
# .sandcastle/artifacts/) from the current issue's body and rejects runs where
# any declared artifact is missing or empty in the work-branch's git tree.
# Issues without the section are skipped with a warning. Issues with an empty
# section are skipped silently (templates seed the section empty by default).

if [ -z "$issue_num" ]; then
    : # already warned during allow-list parse
elif [ -z "$issue_body" ]; then
    : # already warned during allow-list parse
else
    section_present=$(printf '%s\n' "$issue_body" | grep -c '^## Required artifacts' || true)
    required_artifacts=$(printf '%s\n' "$issue_body" | awk '
      /^## Required artifacts/ {found=1; capture=0; next}
      /^## / {found=0; capture=0; next}
      found && /^```/ {capture=!capture; next}
      capture && NF > 0 {print}
    ')

    if [ "$section_present" = "0" ]; then
        if [ "$issue_is_afk_ready" = "1" ]; then
            echo "!! Issue #${issue_num} is labelled 'afk-ready' but has no '## Required artifacts' section." >&2
            echo "   The required-artifact gate cannot run without it. Refusing to merge." >&2
            echo "   Fix: edit the issue body to add a fenced '## Required artifacts' block (empty fenced block is fine for issues with no fail-first ACs), then rerun." >&2
            gate_revert_with_logs "sandcastle-failed-no-artifacts-${ts}"
            post_revert_comment_and_label "$issue_num" "missing '## Required artifacts' section on afk-ready issue" "sandcastle-failed-no-artifacts-${ts}" "Add a fenced '## Required artifacts' block (empty fenced block is fine if there are no fail-first ACs), then re-run."
            exit 1
        fi
        echo "==> Warning: issue #${issue_num} has no '## Required artifacts' section — artifact check skipped." >&2
        echo "    Add a fenced '## Required artifacts' block to enforce evidence on future runs." >&2
    elif [ -z "$required_artifacts" ]; then
        : # section present but empty body — silent skip
    else
        missing_artifacts=()
        while IFS= read -r artifact_name; do
            [ -z "$artifact_name" ] && continue
            artifact_path=".sandcastle/artifacts/${artifact_name}"
            obj_type=$(git cat-file -t "${WORK_HEAD}:${artifact_path}" 2>/dev/null || echo missing)
            blob_size=$(git cat-file -s "${WORK_HEAD}:${artifact_path}" 2>/dev/null || echo 0)
            if [ "${obj_type}" != "blob" ] || [ "${blob_size}" -eq 0 ]; then
                missing_artifacts+=("${artifact_name}")
            fi
        done <<< "$required_artifacts"

        if [ ${#missing_artifacts[@]} -gt 0 ]; then
            echo
            echo "!! Required-artifact gate FAILED: agent did not commit non-empty evidence for #${issue_num}. Capturing worktree logs before revert." >&2
            echo "   Missing or empty (under .sandcastle/artifacts/):" >&2
            printf '     - %s\n' "${missing_artifacts[@]}" >&2
            echo

            gate_revert_with_logs "sandcastle-failed-artifacts-${ts}"
            post_revert_comment_and_label "$issue_num" "missing required artifacts" "sandcastle-failed-artifacts-${ts}" "$(printf 'Missing or empty under .sandcastle/artifacts/:\n%s' "$(printf '- %s\n' "${missing_artifacts[@]}")")"
            exit 1
        fi

        artifact_count=$(printf '%s\n' "$required_artifacts" | grep -c .)
        echo "==> Required-artifact gate passed (issue #${issue_num}, ${artifact_count} declared)."
    fi
fi

# ── Host test gate ────────────────────────────────────────────────────────────
# Loads PROJECT_TEST_CMD from .env at repo root (or inherits from environment)
# and runs the project's test suite on the host against the merged commit(s).
# On failure: preserve the agent's commits on a backup branch, reset main.

if [ -f "$REPO_ROOT/.env" ]; then
    set -o allexport
    source "$REPO_ROOT/.env"
    set +o allexport
fi

if [ -z "${PROJECT_TEST_CMD:-}" ]; then
    echo "Error: PROJECT_TEST_CMD is not set." >&2
    echo "       Set it in $REPO_ROOT/.env or export it before running run.sh." >&2
    exit 1
fi

host_log="$REPO_ROOT/.sandcastle/logs/host-test-${ts}.log"
mkdir -p "$(dirname "$host_log")"

set +e
eval "${PROJECT_TEST_CMD}" 2>&1 | tee "$host_log"
test_status=${PIPESTATUS[0]}
set -e

if [ "$test_status" -eq 0 ]; then
    case "${HARNESS_MODE}" in
        hold)
            echo
            echo "============================================================="
            echo "==> Harness change HELD on branch: ${HARNESS_HOLD_BRANCH}"
            echo "    main HEAD unchanged: $(git rev-parse --short main)"
            echo
            echo "    To validate this harness change:"
            echo "        ./.sandcastle/run.sh --harness-branch ${HARNESS_HOLD_BRANCH}"
            echo
            echo "    First retarget .sandcastle/prompt.md at a benign feature issue."
            echo "    Successful validation fast-forwards main onto the held branch"
            echo "    (both harness change and validation feature work)."
            echo "    NOTE: if your harness change touched .sandcastle/Dockerfile,"
            echo "    rebuild the image first or the validation runs against stale state."
            echo "============================================================="
            exit 0
            ;;
        validate)
            echo "==> Validation gates passed. Fast-forwarding main onto ${HARNESS_VALIDATE_BRANCH}."
            git checkout main
            git merge --ff-only "${HARNESS_VALIDATE_BRANCH}"
            git branch -D "${HARNESS_VALIDATE_BRANCH}"
            echo "==> main is now at: $(git rev-parse --short HEAD). Run complete."
            exit 0
            ;;
        *)
            echo "==> Host tests passed. Run complete."
            if [ -n "$issue_num" ]; then
                gh issue close "$issue_num" --comment "Closed by Sandcastle: $(git rev-parse HEAD)" || true
            fi
            exit 0
            ;;
    esac
fi

echo
echo "!! Host tests FAILED on the merged commit(s). Capturing worktree logs before revert." >&2
backup_branch="sandcastle-failed-${ts}"
gate_revert_with_logs "${backup_branch}"
echo "   - Test log: ${host_log}" >&2
if [ -n "$issue_num" ]; then
    post_revert_comment_and_label "$issue_num" "host tests failed" "$backup_branch" "Test log: \`.sandcastle/logs/$(basename "$host_log")\`"
fi
exit 1
