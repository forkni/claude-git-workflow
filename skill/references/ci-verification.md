# CI Verification Gate

Every push CGW performs — direct `push_validated.sh`, a merge's target push, `create_pr.sh`,
or `create_release.sh --push` — is followed by this gate: subscribe to the CI runs the push
triggered, wait for a terminal verdict, and treat anything other than green as unfinished
work. Do not report a push, merge, or promotion "complete" while a resolved run is still
pending or red. This is an agent procedure (uses `gh`, not a `scripts/git/*.sh` wrapper) —
apply it manually at each push site listed in [SKILL.md](../SKILL.md).

## Contents
- Applicability Probe
- Baseline + Resolve Runs
- Watch
- Verdict
- Fix Loop
- Hard Prohibitions
- Config Knobs

---

## Applicability Probe

Skipping is silent and normal — most consumer projects installing CGW may have no GitHub
remote, no `gh`, or no auth. Run once per session, not per push:

```bash
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
  && gh repo view --json name >/dev/null 2>&1 && echo CI_AVAILABLE
```

No `CI_AVAILABLE` → record `CI: not applicable (no gh/auth/GitHub remote)` in the summary and
treat the push as complete. Same result if `CGW_CI_VERIFY=0` (see Config Knobs) — check this
before the probe:

```bash
[[ -f .cgw.conf ]] && . ./.cgw.conf; [[ "${CGW_CI_VERIFY:-1}" == "1" ]] && echo GATE_ENABLED
```

## Baseline + Resolve Runs

**Same commit can carry runs on two branches** — `merge_with_validation.sh` always merges
with `--no-ff`, so a *direct*-mode merge never fast-forwards and `CGW_TARGET_BRANCH` gets its
own merge-commit SHA. But other paths can still leave two branches pointing at the identical
commit — a PR merged on GitHub via "Rebase and merge" (or "Fast forward only") when the PR
reduces to one commit, or any manual `git merge --ff-only` outside the wrappers — and when
that happens, `gh run list --commit` alone returns runs from both branches. Filtering on
**commit AND branch** costs nothing and removes the ambiguity unconditionally, so do it even
on the direct-merge path where the collision cannot occur:

```bash
sha=$(git rev-parse HEAD)
branch=$(git branch --show-current)
gh run list --commit "$sha" --branch "$branch" --limit 20 \
  --json databaseId,workflowName,status,conclusion \
  --jq '.[] | "\(.databaseId)\t\(.workflowName)\t\(.status)\t\(.conclusion)"'
```

Runs take a few seconds to register after the push lands — poll the query above for up to
~30s (2-3s interval) until at least one run appears, or the window elapses. If nothing appears
after the window, report `CI: no workflow triggered` (e.g. a `paths:` filter didn't match, or
this branch isn't in the workflow's `branches:` list) — this is not a failure, do not treat it
as one.

Optionally, capture the highest existing `databaseId` for this branch *before* pushing; run
ids are monotonic, so anything greater after the push is unambiguously attributable to it —
useful when the branch already has recent runs and you want to avoid re-watching a stale one.

## Watch

For each resolved run id, watch it to a terminal state:

```bash
gh run watch <run-id> --exit-status --compact --interval "${CGW_CI_POLL_INTERVAL:-15}"
```

Issue this as a **background** Bash call (`run_in_background: true`) — a full
`branch-protection.yml` run (ShellCheck + shfmt + the 417-test Bats suite) regularly exceeds
the 300s default / 600s max Bash tool timeout, so a blocking call would time out mid-run
without a verdict. The completion notification carries the exit status (`0` = success,
non-zero = failure/cancelled). Multiple runs on the same push (e.g. `Branch Protection` +
`Documentation Validation`) can be backgrounded concurrently.

**Fallback** when backgrounding isn't available: poll the `--json status,conclusion` query
from the previous section (bounded, e.g. `timeout: 600000`) until every resolved run shows
`status == "completed"`.

Bound the whole wait by `CGW_CI_TIMEOUT_SECONDS` (default 900s) — if runs are still
non-terminal past that, report `CI: timed out waiting for <workflow>` rather than waiting
indefinitely.

## Verdict

Green — every resolved run's `conclusion` is `success` or `skipped`.

Red — any run concludes `failure`, `cancelled`, `timed_out`, `startup_failure`, or
`action_required`.

(`docs-validation.yml`'s jobs all carry `continue-on-error: true`, so they always conclude
`success` — this is by design, not a gap to work around. `branch-protection.yml`'s `shfmt`
step is likewise advisory. Judging on `conclusion` inherits that intent automatically; no
special-casing needed.)

## Fix Loop

Bounded by `CGW_CI_MAX_FIX_ROUNDS` (default 3 attempts). On red:

1. **Inspect** — pull failing steps only, not the whole log:
   ```bash
   gh run view <run-id> --log-failed
   ```
2. **Infrastructural failure** (runner outage, transient network/auth error unrelated to the
   diff) — try one rerun before touching code: `gh run rerun <run-id> --failed`. Re-watch.
3. **Otherwise, reproduce locally before editing.** Map the failing job to its local
   equivalent (see [error-recovery.md](error-recovery.md) → *CI Failures*):
   `shellcheck -x --source-path=scripts/git scripts/git/*.sh`, `tests/run.sh`,
   `bash scripts/git/check_local_files.sh`, `./scripts/git/setup_attributes.sh`.
4. **Fix, then re-promote through the wrappers** — never bypass Rule 1. Author the fix on
   `CGW_SOURCE_BRANCH`:
   ```bash
   ./scripts/git/commit_enhanced.sh --non-interactive "fix: <what CI caught>"
   ./scripts/git/push_validated.sh --non-interactive --skip-lint
   ```
   Re-watch from **Baseline + Resolve Runs** against the new SHA.
5. **Budget exhausted** — stop. Report the failing workflow name, job, and the `gh run view`
   URL, and hand back to the user. Never silently give up mid-loop, and never report success
   while red.

## Hard Prohibitions

These are the ways this gate gets quietly subverted — call them out, don't just imply them:

- **Never** `--amend` + force-push to "fix" a CI failure — the commit is already published;
  amend rewrites history other clones may have fetched. Push a new fix commit instead.
- **Never** commit a CI fix directly on the target branch. Author it on
  `CGW_SOURCE_BRANCH` and re-promote through the normal merge/PR path, so the target branch
  only ever receives reviewed, gated content.
- **Never** reach for `--skip-lint` to make a red run go green faster — local lint and remote
  CI are different checks; skipping one doesn't satisfy the other.
- **Never** report "Workflow complete" / "Push successful" while a watched run is still
  `in_progress`, `queued`, or concluded anything other than `success`/`skipped`.

## Config Knobs

Not read by any `scripts/git/*.sh` — these are agent-facing conventions for this procedure,
sourced from `.cgw.conf` (or overridden by environment, per the usual three-tier resolution).

| Variable | Default | Purpose |
|---|---|---|
| `CGW_CI_VERIFY` | `1` | `0` disables the gate entirely |
| `CGW_CI_TIMEOUT_SECONDS` | `900` | Max wait for all resolved runs to reach a terminal state |
| `CGW_CI_POLL_INTERVAL` | `15` | Seconds between `gh run watch` refreshes |
| `CGW_CI_MAX_FIX_ROUNDS` | `3` | Fix → push → re-watch attempts before stopping |
| `CGW_CI_REQUIRED_WORKFLOWS` | *(empty)* | Space-separated workflow-name allow-list; empty = judge every triggered workflow |

```bash
[[ -f .cgw.conf ]] && . ./.cgw.conf
echo "verify=${CGW_CI_VERIFY:-1} timeout=${CGW_CI_TIMEOUT_SECONDS:-900} poll=${CGW_CI_POLL_INTERVAL:-15} rounds=${CGW_CI_MAX_FIX_ROUNDS:-3}"
```
