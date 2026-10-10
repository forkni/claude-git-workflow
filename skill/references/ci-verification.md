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
- PR Checks (PR mode)
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

**Name the branch you pushed, and take its SHA from the remote.** Never use `HEAD` or the
current branch: the wrappers return you to `CGW_SOURCE_BRANCH` after a target push (`Phase 5`
in [full-promotion.md](full-promotion.md) runs `git checkout` right after pushing), so `HEAD`
is then the *source* branch and the query would find its already-green runs and call the
unverified target green. Set `branch` explicitly (`$CGW_SOURCE_BRANCH` or `$CGW_TARGET_BRANCH`
for the push just performed) and resolve the SHA from what the remote now holds:

```bash
branch="${CGW_SOURCE_BRANCH:-development}"   # or "${CGW_TARGET_BRANCH:-main}" after a target push
sha=$(git ls-remote "${CGW_REMOTE:-origin}" "refs/heads/$branch" | awk 'NR==1 {print $1}')
gh run list --commit "$sha" --branch "$branch" --limit 20 \
  --json databaseId,workflowName,status,conclusion \
  --jq '.[] | "\(.databaseId)\t\(.workflowName)\t\(.status)\t\(.conclusion)"'
```

Runs take a few seconds to register after the push lands, and different workflows register at
different times. So resolve the run set in two steps:

1. **Wait for the first run**: poll the query above (2-3s interval) until at least one run
   appears, up to ~30s.
2. **Wait for the set to settle**: keep polling until the list is unchanged for ~10s, and — if
   `CGW_CI_REQUIRED_WORKFLOWS` is set — until every named workflow is present. Watch the full
   set, and re-run the query once more when the watches finish: a workflow that registered
   late and was never watched means the verdict covers only part of the CI.

If nothing appears after the window, do not assume there is no CI. Check whether the repo
defines any:

```bash
gh workflow list --json name,state --jq '.[] | select(.state=="active") | .name'
```

- **No active workflows** → report `CI: no workflow triggered` (not a failure).
- **Active workflows exist, or `CGW_CI_REQUIRED_WORKFLOWS` names one that never appeared** →
  report `CI: unverified — no runs registered for <sha>` and do **not** call the push complete.
  Retry once after `CGW_CI_POLL_INTERVAL`; a `paths:` filter that legitimately didn't match is
  the only benign cause, and you can confirm it from the workflow's `on:` block. Registration
  lag is the usual cause, and an empty list during lag is not a verdict.

Optionally, capture the highest existing `databaseId` for this branch *before* pushing; run
ids are monotonic, so anything greater after the push is unambiguously attributable to it —
useful when the branch already has recent runs and you want to avoid re-watching a stale one.

## PR Checks (PR mode)

In PR mode (`create_pr.sh`, or a fix pushed to an open PR) watch the PR's own checks — but
`gh pr checks` has no commit SHA: it reports on whatever head GitHub currently has for the PR.
Straight after a push that is either the **previous** head (its old green or red checks) or the
new head with **no checks registered yet**. Watching immediately therefore reports a stale
verdict: a false red right after a fix push, or a pass on a commit that never ran. So bind the
watch to the pushed SHA first:

```bash
remote="${CGW_REMOTE:-origin}"
# owner/repo from the remote's own URL, as create_pr.sh does -- NOT `gh repo view`, which
# resolves a fork to its parent/upstream repo and would query the wrong PR.
repo=$(git remote get-url --push "$remote" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')
pr=<number>   # from create_pr.sh's "PR number: N" line, not `gh pr view` on the current branch
sha=<sha>     # create_pr.sh's "Head SHA:" line; after a fix push: git ls-remote "$remote" "refs/heads/<branch>"

# 1. wait (12 x 5s = ~60s) until GitHub's PR head is the commit that was pushed
for _ in $(seq 12); do
  [[ "$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null)" == "$sha" ]] && break
  sleep 5
done
[[ "$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null)" == "$sha" ]] \
  || echo "CI: unverified -- PR #$pr head has not caught up with $sha"   # STOP: do not watch

# 2. wait (18 x 5s = ~90s) for checks to exist; a count > 0 is the only "exists" signal, so
#    "no checks reported", empty output and gh errors (auth, network) all mean "not yet"
for _ in $(seq 18); do
  n=$(gh pr checks "$pr" --repo "$repo" --json name --jq length 2>/dev/null)
  [[ "${n:-0}" -gt 0 ]] && break
  sleep 5
done
[[ "${n:-0}" -gt 0 ]] || echo "CI: unverified -- no checks registered on $sha"   # see below

# 3. only now watch to a terminal state; --watch redraws the whole table every interval, so
#    discard that stream and read one final snapshot instead
gh pr checks "$pr" --repo "$repo" --watch --fail-fast --interval "${CGW_CI_POLL_INTERVAL:-15}" >/dev/null 2>&1
gh pr checks "$pr" --repo "$repo"   # the verdict: exit 0 = all green, 1 = a check failed, 8 = still pending
```

If step 2 ends empty, apply the same rule as *Baseline + Resolve Runs*: `gh workflow list`
shows no active workflows → `CI: no workflow triggered`; otherwise `CI: unverified`, never
green. After the watch, re-read `headRefOid`; if it changed, someone pushed mid-wait — restart
from step 1. `merge_pr.sh` applies this same binding itself (`--wait-checks`, plus
`--match-head-commit`), so it is the model to follow when merging.

## Watch

For each resolved run id, watch it to a terminal state:

```bash
gh run watch <run-id> --exit-status --compact --interval "${CGW_CI_POLL_INTERVAL:-15}"
```

Issue this as a **background** Bash call (`run_in_background: true`) — a full
`branch-protection.yml` run (ShellCheck + shfmt + the full Bats suite) regularly exceeds
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
- **Never** resolve runs from `HEAD` / the current branch, or read an empty run list or
  "no checks reported" shortly after a push as "no CI" — name the pushed branch, take its SHA
  from the remote, and treat absence inside the registration window as *not yet*.
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
