# Sandcastle Operator Guide

This document is the production reference for operators running a Sandcastle
bash harness. For the npm package overview and quick start, see `README.md`.

The bash harness lives in `examples/bash-harness/` — copy it into your project
as `.sandcastle/`.

## File map

| File | Purpose |
|---|---|
| `run.sh` | Host-side launcher. Pulls Claude OAuth from macOS Keychain, parses harness flags, invokes `main.ts`, runs allow-list + test gates after the run. |
| `recover.sh` | Merges a `sandcastle-failed-*` backup branch back onto main with a mandatory `--note` for the audit trail. |
| `queue.sh` | Runs Sandcastle sequentially against a list of issue numbers; prints a pass/fail summary at the end. |
| `Dockerfile` | Image definition. Pre-bake your project's runtime dependencies (see the `PROJECT SETUP` comment block), plus Playwright + Chromium, and the `claude` shim. |
| `claude-shim.sh` | Pinning shim that injects `--dangerously-skip-permissions` and the project MCP config when the in-container `claude` is invoked. |
| `mcp-settings.json` | MCP server list available to the in-container agent (Playwright). |
| `.env.example` | Template for `PROJECT_TEST_CMD` and `SANDCASTLE_AUTO_GENERATED_FILES`. Copy to `.env` and fill in. |
| `logs/` | Per-run logs (stream-json, agent stdout, build, app). Bind-mounted from the worktree so they survive container teardown. |

## Running

A normal feature/bug issue:

```bash
# 1. Edit .sandcastle/prompt.md so the top `gh issue view <N>` line names
#    the issue you want the agent to work on.
# 2. Commit the prompt change.
# 3. Fire it.
./.sandcastle/run.sh
```

The launcher will:

1. Pull a fresh Claude OAuth token from macOS Keychain.
2. Snapshot the current HEAD.
3. Detect the issue's labels (drives harness-change lifecycle, see below).
4. Invoke `main.ts` (which builds the worktree and runs the agent in Docker).
5. Retry up to 3 times on transient API/stream failures (no commits, no BLOCKED signal).
6. After the agent's run finishes:
   - Allow-list scope check (`## Allowed paths` from issue body).
   - Required-artifacts gate (`## Required artifacts` from issue body).
   - Host test gate (`$PROJECT_TEST_CMD` from `.env`).
7. On success: leave main fast-forwarded onto the agent's commits; close the issue.
8. On failure: capture worktree logs, preserve the agent's branch under a
   `sandcastle-failed-*` prefix, reset main to its pre-run SHA.

### Configuration

Copy `.env.example` to `.env` in your repo root and set:

```bash
# Your project's test runner, evaluated with `eval` from repo root
PROJECT_TEST_CMD=cd backend && .venv/bin/pytest tests/ -q

# Space-separated auto-generated files that should always pass the allow-list gate
SANDCASTLE_AUTO_GENERATED_FILES="frontend/src/routeTree.gen.ts"
```

### `onSandboxReady` hook

To start your application inside the sandbox (so the agent can hit it via
Playwright), add an `onSandboxReady` callback in your `main.ts`. Example
pattern — run a script that boots your backend and frontend before the agent
starts. See `main.ts.example` for the hook signature.

## Orchestrator turn-end discipline (autonomous-loop mode)

When Claude is driving Sandcastle unattended via `<<autonomous-loop-dynamic>>`
(polling progress, deciding when to queue the next slice, reporting back),
every turn MUST terminate in exactly one of two states:

1. **Continue autonomously.** Call `ScheduleWakeup` for the next tick.
   Do not ask the user a question in the user-facing text.
2. **Hand back to the user.** State the specific blocker concretely
   (the decision, mockup, credential, or scope choice only the user can
   supply). Do NOT call `ScheduleWakeup`.

The forbidden third state is ending the turn with no `ScheduleWakeup`
**and** a question the orchestrator could have answered itself. The
distinguishing test:

- **Could the orchestrator reasonably pick either option and have the
  user redirect on the next tick if they disagree?** Then the question
  is a hidden stop. Pick, queue, continue. Do not ask.
- **Is the choice genuinely the user's** (scope, policy, preference,
  reservation of HITL work, two materially different directions)?
  Then it's a real fork. Hand back, and phrasing the blocker as a
  concrete question with the offered options is fine — that's clearer
  than a flat statement. The marker is no `ScheduleWakeup`.

The failure mode this rule blocks is the first kind: "want me to keep
going on the visual-parity slices, or pause for review?" — both options
were reasonable, the orchestrator could have picked, the question
surrendered control. Compare with: "design-system doc could go in
user-global config or project config, tradeoff is reach-vs-scope —
which?" — this is the user's policy call, not the orchestrator's.

### When to choose continue
- `afk-ready` issues remain in the queue and their dependencies are met.
- A long-running process is pending (Sandcastle run, build, test).
- The next step is mechanical (verify a finished run, summarise, report).

If you find yourself wanting to ask "should I keep going?", you are NOT
blocked — choose continue, queue the next slice, and let the user
redirect on the next tick if they disagree.

### When to choose hand-back
- A direction not previously approved (e.g. starting a new PRD, picking
  between materially different design options).
- An action with high blast radius the user hasn't authorised in this
  session (`git push`, mass issue close, force-push, dependency bumps).
- A decision the user has been deliberately reserving (HITL slices,
  mockup approvals).
- The `afk-ready` queue is empty or only HITL items remain.
- **An agent-authored artifact gates a cascade and the user hasn't
  reviewed it yet.** Design docs, schemas, contracts, and taste-laden
  patterns produced by the inner Sandcastle agent often gate >1
  downstream slice (whose ACs say "match this artifact"). If the user
  has not seen the gating artifact, surface it for review before
  cascading — a flawed gate replicated across N slices is dramatically
  more expensive to fix than a single review pass now. Frame it as a
  genuine fork: "review first" vs "trust-and-cascade", with the
  artifact path and the dependent slice list named explicitly.

When handing back, state the blocker concretely. If there are 2–3
reasonable options the user owns the choice between, list them — that
is clearer than a flat "blocked." Either way, do not call
`ScheduleWakeup`; the next user turn re-engages the loop on its own
terms.

### Editing this policy

This is the single control point for autonomous turn-end behaviour.
Tighten it (e.g. require explicit approval before queueing each slice)
or loosen it (e.g. permit `git push` when 20+ commits accumulate) by
editing the bullets above. The orchestrator reads `.sandcastle/README.md`
(or `OPERATOR.md`) during long Sandcastle work, so changes take effect
on the next turn.

## Harness-change two-phase lifecycle

Harness changes — anything modifying `.sandcastle/**` — cannot self-verify
within the run that produces them: the version of `run.sh` / `prompt.md` /
`main.ts` driving the agent is the version *before* the agent's edit. A broken
harness only manifests on the *next* invocation.

To prevent broken harness changes from auto-merging into `main`, those
issues follow a two-phase commit lifecycle.

### Detection

The launcher uses a single signal: the issue is labelled `harness-change`.

### Phase 1 — hold

When `run.sh` detects the `harness-change` label:

- It generates a held branch name `sandcastle-harness-pending-<ts>`.
- It exports `SANDCASTLE_HARNESS_PENDING_BRANCH=<name>`. `main.ts` reads this
  and sets Sandcastle's `branchStrategy` to `branch` mode (instead of
  `merge-to-head`), so Sandcastle creates the branch but does not
  fast-forward the host's current branch.
- After the gates pass, `run.sh` prints a "HELD" banner with the validation
  command and exits 0.

`main` HEAD does not move. The held branch sits in the local repo until
the operator validates it.

### Phase 2 — validate

The operator validates by re-running Sandcastle with the held branch
checked out as the launcher base, against a benign feature issue:

```bash
# 1. Retarget .sandcastle/prompt.md at a benign feature issue (the
#    harness-change issue is already closed, so this must be a different
#    issue — typically the next feature in the queue).
# 2. Commit the prompt change (commit lands on main).
# 3. Run validation:
./.sandcastle/run.sh --harness-branch sandcastle-harness-pending-<ts>
```

The launcher will:

1. `git checkout sandcastle-harness-pending-<ts>` (worktree's current HEAD
   is now the held branch — the agent runs under the new harness code).
2. Run the agent against the feature issue. Sandcastle's merge-to-head
   merges the agent's commits onto the held branch.
3. Run the allow-list + test gates against the resulting tree.
4. On success: `git checkout main && git merge --ff-only <held-branch>`.
   Both the harness change and the validation feature work ship into
   `main` together. The held branch is deleted.
5. On failure: leave the operator on `main` with the held branch
   preserved under `sandcastle-failed-*-<ts>` so the operator can inspect
   what broke.

Two runs and a passing feature-validation are the only honest verification
that the new harness code actually works.

### Dockerfile-touched harness changes

The image used by the validation run is whatever was last built. If the
held branch's diff includes `.sandcastle/Dockerfile`, that change is NOT
exercised by the validation run unless the operator rebuilds the image
first:

```bash
docker build -f .sandcastle/Dockerfile -t <your-image-name> .
```

Then run `--harness-branch <name>` as above.

For purely host-side harness changes (`run.sh`, `prompt.md`, `main.ts`),
no rebuild is needed — the worktree files are read live.

### Held-branch hygiene

Held branches are the operator's responsibility. There is no auto-prune
or accumulation warning. Two things to watch for:

- A held branch from weeks ago may conflict with current `main` when the
  validation tries to fast-forward. Resolve by rebasing the held branch
  onto current `main` before validating, or abandon it and file a fresh
  harness-change issue.
- Multiple held branches in flight are unsupported. Validate one at a
  time; back-to-back harness changes should be sequenced.

## Allow-list scope check

Every issue body must include an `## Allowed paths` section listing
glob patterns the agent is permitted to touch. `run.sh` parses the
section, computes `git diff <merge-base>..<work-branch> -- :(glob)<patterns>`,
and rejects diffs touching files outside the list.

### Issue body convention

```markdown
## Allowed paths

\`\`\`
backend/app/api/v1/some_endpoint.py
backend/tests/test_some_endpoint.py
frontend/src/routes/some-page.tsx
\`\`\`
```

Glob patterns are supported (e.g. `backend/app/**`). Literal paths (no
wildcards) trigger a pre-flight check: the parent directory must exist
before the run. The file itself may be new (slices that legitimately
create files are allowed), but the directory anchor must be real — this
catches typo'd paths before the run.

### Auto-allowed files

Files listed in `SANDCASTLE_AUTO_GENERATED_FILES` (in `.env`) are
unconditionally added to the allow-list pathspec for every issue. Use
this for files that build tooling regenerates on every build regardless
of what the agent touched (e.g. a router's generated route-tree file).

Files declared in `## Required artifacts` are also auto-whitelisted
(the two gates must not conflict).

### Strictness for `afk-ready` issues

If an issue is labelled `afk-ready` and its body has no
`## Allowed paths` section, `run.sh` aborts after the agent's run
(commits preserved on `sandcastle-failed-no-allowlist-<ts>`) instead
of silent-skipping the gate.

Issues without the `afk-ready` label keep warn-and-skip behaviour.

## Required-artifacts gate

Some ACs require fail-first evidence ("revert the fix, run the new test,
see it fail"). Without a check, the agent can skip the cycle and the harness
can't tell. The required-artifact gate forces the agent to commit a named
evidence file per declared AC and rejects runs that don't.

### How it works

1. The issue body's `## Required artifacts` section lists filenames inside a
   fenced code block (same convention as `## Allowed paths`).
2. The agent writes evidence to `.sandcastle/artifacts/<name>` and commits it
   alongside its code commit.
3. After the agent commits, `run.sh` parses the section and runs
   `git cat-file -s <work-branch>:.sandcastle/artifacts/<name>` for each
   declared file. Size 0 (missing or empty) → BLOCK + revert.

### Issue body convention

```markdown
## Required artifacts

\`\`\`
failing-test-output.txt
before-screenshot.png
\`\`\`
```

Leave the fenced block empty to declare the section but skip the gate
(templates seed the section empty by default for issues with no
fail-first ACs).

### What the gate does and does NOT prove

- Does prove: the agent physically wrote a non-empty file at the expected
  path. Implies it had to think about the AC's evidence step.
- Does NOT prove: the file's contents are real test output. `echo ok > file`
  passes the gate.

This is by design. The gate's value is audit-cost shifting — turning
"invisible until manual transcript review" into "trivially spot-checkable
in the worktree." Operators should still glance at artifact contents
during review; the green gate is not a proof of correctness.

### When to use it

- Issues with fail-first regression ACs.
- Harness self-tests where the AC requires producing a specific signal in a
  log.

When in doubt: leave the section's fenced block empty (silent-skip).

## Failure recovery

### `sandcastle-failed-*` backup branches

When any gate (allow-list, required-artifacts, host tests) rejects a run,
`run.sh`:

1. Renames the agent's work branch (or creates a backup branch) as
   `sandcastle-failed-<reason>-<ts>`.
2. Resets `main` to its pre-run SHA.
3. Copies agent worktree logs to `.sandcastle/logs/host-side-<ts>/`.
4. Posts a structured diagnostic comment to the issue with the backup
   branch name and a `recover.sh` command.
5. Applies the `sandcastle-failed` label to the issue.

The agent's work is never lost — it lives on the backup branch until
the operator reviews it.

### `recover.sh` — manual override

When you have reviewed the diff and judged it correct:

```bash
./.sandcastle/recover.sh sandcastle-failed-<reason>-<ts> \
  --note "<why this revert is being overridden>"
```

This:
1. `git merge --no-ff <backup-branch>` onto main.
2. Posts a recovery comment to the issue with the merge SHA and your note.
3. Removes the `sandcastle-failed` label; adds `sandcastle-recovered`.
4. Closes the issue.

The `--note` argument is mandatory — it is the audit trail for every
manual override. The backup branch is not deleted; it remains for
historical inspection.

Auto-detection reads the issue number from the `gh issue view <N>` line
in `prompt.md`. Pass `--issue <N>` explicitly if that detection fails.

### Issue lifecycle labels

| Label | Meaning |
|---|---|
| `sandcastle-failed` | Run reverted by a host gate. Work is on a `sandcastle-failed-*` backup branch. |
| `sandcastle-recovered` | Backup branch was manually merged via `recover.sh`. Issue closed by the wrapper. |

Both labels are created idempotently by `run.sh` and `recover.sh` on first use.

### Three layers of allow-list defence

**Layer 1 — Agent Step 0 scope sanity check**

Before the agent edits anything, your `prompt.md` can ask it to list all
intended files and verify each one matches the issue's `## Allowed paths`
block. If any file is out of scope, the agent posts a `BLOCKED:` comment
naming the mismatch and stops without committing. This catches semantic
mismatches — where the issue prose and the allow-list block disagree —
before any work is done.

**Layer 2 — Pre-flight literal-path parent-directory check**

After the agent's run and before the diff is inspected, `run.sh` checks
every literal path (non-glob) in `## Allowed paths` against the working
tree. If any literal path's parent directory doesn't exist, the run calls
`gate_revert_with_logs` and posts a diagnostic comment. The operator fixes
the allow-list and can recover the work via `recover.sh` without
re-running the agent.

**Layer 3 — Revert-time diagnostic comment + label**

When any gate reverts a run, `run.sh` posts a structured comment to the
issue with the failure reason, the backup branch name, and the `recover.sh`
command to merge the branch with an override note.

## Queue

Run Sandcastle against multiple issues back-to-back:

```bash
./.sandcastle/queue.sh <issue-number> [<issue-number> ...]
# Example:
./.sandcastle/queue.sh 20 19 9
```

`queue.sh`:
1. Checks each issue is still OPEN before running (skips closed issues).
2. `sed`-swaps `prompt.md` to target the issue and commits the swap.
3. Calls `run.sh` (which has its own retry loop).
4. Failures on one issue do not abort the queue.
5. Prints a pass/fail/closed summary table at the end.

## Per-run logs

`logs/` (bind-mounted from the worktree) survives container teardown.
On run failure, `run.sh` copies the agent worktree's logs out to
`logs/host-side-<ts>/` for post-mortem.

Files in a typical run:

| Filename | Source |
|---|---|
| `main-<run-name>-<ts>.log` | Sandcastle's TS launcher stdout (stream-json, agent transcript) |
| `host-test-<ts>.log` | Host test suite output from `run.sh`'s gate |
| `host-side-<ts>/` | Agent worktree logs copied out on failure |

## Troubleshooting

- **"Could not read Claude OAuth credentials from macOS Keychain"** —
  run `claude` once on the host to authenticate, then retry.
- **"Uncommitted changes detected"** — Sandcastle's bind-mount would let
  the agent see and possibly commit them. Stash or commit before retrying.
- **"PROJECT_TEST_CMD is not set"** — set it in `.env` at the repo root
  (see `.env.example`).
- **Allow-list violation** — agent edited files outside the issue's
  declared scope. The diff is preserved on `sandcastle-failed-allowlist-<ts>`
  for inspection. Either narrow what the agent did (next iteration) or
  expand the issue's `## Allowed paths` section if the change is
  legitimately needed.
- **`<promise>BLOCKED</promise>` in the run log** — agent voluntarily
  aborted. Check the log for the reason.
- **3 attempts produced no commits** — likely a transient API/stream
  failure. The launcher gives up after 3 attempts; rerun manually.
