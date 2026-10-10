# Full Promotion Pipeline

The one-click commit → push → merge/PR → push sequence executed by
`/auto-git-workflow-cmd` option 1. Loaded on demand from the command router —
do not run this pipeline unprompted; it is only for an explicit "full promotion"
request. SKILL.md Core Rules govern every step.

## Contents

- Environment Detection
- Bash Tool Compatibility
- Section A: Git Bash / Linux / macOS (Phases 1-5b)
- Section B: Windows cmd.exe

## Environment Detection

```bash
echo $OSTYPE
# Git Bash / WSL: "msys" or "linux-gnu"
# macOS: "darwin"
# If variable empty: Windows cmd.exe
```

- Git Bash / Linux / macOS → Section A below (`.sh` scripts directly)
- Windows cmd.exe → Section B below (invoke wrappers via `bash`)

Git Bash cannot execute `.sh` files' Windows-only equivalents, and cmd.exe cannot run
`.sh` files at all — always go through `bash scripts/git/<name>.sh` on cmd.exe.

## ⚠️ Bash Tool Compatibility

Execute each numbered step as a **separate** Bash call. Do not combine steps with `&&`
or `;`. Check exit codes between steps.

## Section A: Git Bash / Linux / macOS

### Phase 1 — Pre-commit validation

1. `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1`
2. `git diff --quiet && git diff --cached --quiet`
   — exit 0: no changes, report "No changes to commit", stop. exit 1: continue.
3. `./scripts/git/check_lint.sh >/dev/null 2>&1`
   — exit 0: skip to Phase 2. exit ≠0: continue.
4. `./scripts/git/fix_lint.sh`
5. `./scripts/git/check_lint.sh`
   — local-only files (CLAUDE.md, MEMORY.md, etc.) failing lint is safe to ignore
     (SKILL.md Rule 3). Still fails otherwise: stop. Passes: continue to Phase 2.

### Phase 2 — Commit to source branch

Stage per SKILL.md Rule 5 (staging intent), then:

```bash
./scripts/git/commit_enhanced.sh --non-interactive "type: descriptive commit message"
```

(or with `--only <path>` per file for a selective commit — see SKILL.md Rule 5). Replace
`type:` with the correct conventional-commit prefix. Then capture:

```bash
git log -1 --format="%h %s"
```

### Phase 3 — Push source branch

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
```

exit 0: continue. exit ≠0: rerun without suppression to show the error, stop.

### Phase 3b — CI gate on source (blocking)

SKILL.md Rule 6 is a hard gate here, not a courtesy: apply
[references/ci-verification.md](ci-verification.md) against `CGW_SOURCE_BRANCH`. Resolve the
runs this push triggered, watch them to a terminal state, and only continue to Phase 4 once
the verdict is green or not-applicable (no `gh`/auth/remote, or `CGW_CI_VERIFY=0`).

Red and unfixable within `CGW_CI_MAX_FIX_ROUNDS` → **stop here, do not enter Phase 4.** This
is what stops a broken commit from ever reaching `CGW_TARGET_BRANCH`. Report the failing
workflow/job and the `gh run view` URL, and hand back to the user.

### Phase 4 — Merge or PR

```bash
[[ -f .cgw.conf ]] && . ./.cgw.conf
echo "${CGW_MERGE_MODE:-direct}"
```

- `direct` (default) → **4A**: `./scripts/git/merge_with_validation.sh --non-interactive`
  — exit 0: continue to Phase 5. exit ≠0: inspect conflict type, stop, see
  [error-recovery.md](error-recovery.md).
- `pr` → **4B**: `./scripts/git/create_pr.sh --non-interactive`, then watch the PR's own
  checks in place of a plain branch-run watch. Take the PR number from the `PR number: N`
  line `create_pr.sh` prints (not `gh pr view` on the current branch, which can name a
  different PR) and its `Head SHA:` line as the commit to wait for. `gh pr checks` has no SHA
  and reports whatever head GitHub currently holds, so bind it first — wait for the PR's
  `headRefOid` to equal that SHA, then for checks to exist ("no checks reported" means *not
  yet* here, not *no CI*), then watch. Run the bounded three-step snippet in
  ci-verification.md → *PR Checks (PR mode)* with `pr` = the printed PR number and `sha` = the
  printed Head SHA — do not shortcut it to a bare `gh pr checks --watch`, which is exactly the
  stale-head race. If either wait runs out it reports `CI: unverified`: not green, so do not
  report the PR as done.

  (exit `8` from `gh pr checks` = still pending — `--watch` normally blocks past that to a
  terminal state.) Red →
  run the Fix Loop from [ci-verification.md](ci-verification.md): commit the fix on
  `CGW_SOURCE_BRANCH`, `push_validated.sh` (this updates the open PR automatically), re-watch.
  Bounded by `CGW_CI_MAX_FIX_ROUNDS`; exhausted → stop and hand back to the user. Green →
  `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1` and report:

  ```text
  Workflow complete (PR mode)
  Source branch: [hash] "[message]" pushed
  PR: [url] — checks: green, Charlie review: [pending|approved|changes requested]
  ```

  Charlie's review is tracked separately from checks (a reviewer, not a required check) —
  mention its status but don't block on it. Stop here regardless — merging into
  `CGW_TARGET_BRANCH` happens on GitHub once the PR is approved and merged, outside this
  pipeline, so Phase 5/5b do not apply in PR mode. (If the user asks you to merge the PR,
  use `./scripts/git/merge_pr.sh <N>` — never without their go.)

### Phase 5 — Push target branch (direct mode only)

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

exit ≠0 on the push: rerun without suppression, stop.

### Phase 5b — CI gate on target

Apply [references/ci-verification.md](ci-verification.md) again, this time against
`CGW_TARGET_BRANCH` — name it explicitly and take its SHA from the remote
(`git ls-remote`), because Phase 5 has already checked out `CGW_SOURCE_BRANCH`, so `HEAD` and
`git branch --show-current` now point at the *source* branch and its already-green runs.
`merge_with_validation.sh`'s `--no-ff` merge gives `CGW_TARGET_BRANCH`
its own merge-commit SHA, distinct from `CGW_SOURCE_BRANCH` — but resolve runs with **both**
`--commit` and `--branch` regardless (ci-verification.md → *Baseline + Resolve Runs*), never
commit alone. Other paths (a GitHub "Rebase and merge" PR, a manual `--ff-only`) can still
leave the two branches sharing a SHA, and commit-only filtering would then re-watch Phase 3b's
already-green runs and call it done.

Red and unfixable → do **not** report success. A fix here is still authored on
`CGW_SOURCE_BRANCH` and re-promoted through Phases 2-5 (never committed directly to
`CGW_TARGET_BRANCH` — ci-verification.md → *Hard Prohibitions*); check out
`CGW_SOURCE_BRANCH` and hand back to the user with the failing workflow/job and the
`gh run view` URL.

### Final report (direct mode)

```bash
git log "${CGW_SOURCE_BRANCH:-development}" -1 --format="%h %s"
git log "${CGW_TARGET_BRANCH:-main}" -1 --format="%h"
```

```text
Workflow complete

Source branch: [hash] "[message]"  CI: [green|n/a]
Target branch: [hash] merged & pushed  CI: [green|n/a]
```

## Section B: Windows cmd.exe / PowerShell (Git Bash-mediated)

> [!IMPORTANT]
> On Windows, do **not** invoke bare `bash` — on machines with WSL installed, bare `bash` resolves to WSL (`C:\Users\...\Microsoft\WindowsApps\bash.exe`), whose Linux git environment lacks access to the Windows Git Credential Manager (`credential.helper=manager`) and will hang waiting for terminal credentials. Always resolve and use Git for Windows (`C:\Program Files\Git\bin\bash.exe`), matching `cgw-install.cmd` (`PI-03`).

In PowerShell:

```powershell
$BASH = "C:\Program Files\Git\bin\bash.exe"
$WATCH = 'branch=$CGW_CI_BRANCH; set -- $(git ls-remote origin refs/heads/$branch); sha=$1; prev=-1; stable=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do set -- $(gh run list --commit $sha --branch $branch --json databaseId --jq ''.[].databaseId''); if [ $# -gt 0 -a $# -eq $prev ]; then stable=$((stable+1)); else stable=0; fi; prev=$#; if [ $stable -ge 2 ]; then break; fi; sleep 5; done; if [ $# -eq 0 ]; then set -- $(gh workflow list --json id --jq ''.[].id''); if [ $# -eq 0 ]; then echo CI: no workflow triggered; exit 0; fi; echo CI: unverified - no runs registered for $sha; exit 1; fi; n0=$#; fail=0; for id; do gh run watch $id --exit-status --compact --interval 15; rc=$?; if [ $rc -ne 0 ]; then fail=1; fi; done; set -- $(gh run list --commit $sha --branch $branch --json databaseId --jq ''.[].databaseId''); if [ $# -ne $n0 ]; then echo CI: unverified - run set changed during the watch, re-resolve; fail=1; fi; exit $fail'
& $BASH scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
& $BASH scripts/git/push_validated.sh --non-interactive --skip-lint
$env:CGW_CI_BRANCH = "development"; & $BASH -c $WATCH
& $BASH scripts/git/merge_with_validation.sh --non-interactive
& $BASH scripts/git/push_validated.sh --non-interactive --skip-lint
$env:CGW_CI_BRANCH = "main"; & $BASH -c $WATCH
Remove-Item Env:CGW_CI_BRANCH
```

In cmd.exe:

```cmd
set "BASH=C:\Program Files\Git\bin\bash.exe"
set "WATCH=branch=$CGW_CI_BRANCH; set -- $(git ls-remote origin refs/heads/$branch); sha=$1; prev=-1; stable=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do set -- $(gh run list --commit $sha --branch $branch --json databaseId --jq '.[].databaseId'); if [ $# -gt 0 -a $# -eq $prev ]; then stable=$((stable+1)); else stable=0; fi; prev=$#; if [ $stable -ge 2 ]; then break; fi; sleep 5; done; if [ $# -eq 0 ]; then set -- $(gh workflow list --json id --jq '.[].id'); if [ $# -eq 0 ]; then echo CI: no workflow triggered; exit 0; fi; echo CI: unverified - no runs registered for $sha; exit 1; fi; n0=$#; fail=0; for id; do gh run watch $id --exit-status --compact --interval 15; rc=$?; if [ $rc -ne 0 ]; then fail=1; fi; done; set -- $(gh run list --commit $sha --branch $branch --json databaseId --jq '.[].databaseId'); if [ $# -ne $n0 ]; then echo CI: unverified - run set changed during the watch, re-resolve; fail=1; fi; exit $fail"
"%BASH%" scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
"%BASH%" scripts/git/push_validated.sh --non-interactive --skip-lint
set "CGW_CI_BRANCH=development" & "%BASH%" -c "%WATCH%"
"%BASH%" scripts/git/merge_with_validation.sh --non-interactive
"%BASH%" scripts/git/push_validated.sh --non-interactive --skip-lint
set "CGW_CI_BRANCH=main" & "%BASH%" -c "%WATCH%"
set "CGW_CI_BRANCH="
```

`$CGW_CI_BRANCH` is the branch just pushed (your `CGW_SOURCE_BRANCH` for the first watch,
`CGW_TARGET_BRANCH` for the second — substitute your configured names for `development` /
`main`); it is cleared afterwards so a later reuse of `WATCH` cannot silently target a stale
branch. The watch script implements the *Baseline + Resolve Runs* rules in miniature:

- names that branch and takes its SHA from the remote instead of using `HEAD`;
- polls until the run list is non-empty and unchanged for two polls (~10 s), up to ~60 s;
- watches **every** run (a red one does not stop the others being watched) and exits `1` if
  any failed;
- re-queries after the watches and reports `CI: unverified` if the run set changed;
- with no runs: `gh workflow list` empty → `CI: no workflow triggered` (exit `0`); active
  workflows → `CI: unverified` (exit `1`).

It does **not** enforce `CGW_CI_REQUIRED_WORKFLOWS` (workflow names contain spaces, which this
quoting-safe one-liner cannot compare) — when that is set, check the named workflows were
among the watched runs. It avoids `|`, `&&`, `||`, `%` and inner double quotes so it survives
cmd.exe's quoting, and was exercised against a stub `gh` (no runs / no workflows / one red /
all green); the cmd.exe quoting itself is documented behaviour, not covered by a bats test.

Same gate as Section A applies at both watch points — see
[references/ci-verification.md](ci-verification.md) for the full resolve/watch/verdict/fix-loop
procedure; it's run via `"$BASH" -c "..."` here because the `gh` logic itself is shell-agnostic but
still needs a POSIX shell to invoke. Red and unfixable at the first watch point → stop before
the merge step, same as Phase 3b. Red at the second → same prohibitions as Phase 5b (fix on
`CGW_SOURCE_BRANCH`, never directly on `CGW_TARGET_BRANCH`).

If `bash.exe` is unavailable (rare), STOP and ask the user to run from Git Bash instead
of bypassing the wrappers — SKILL.md's Core Rules are mandatory regardless of shell.
