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

SKILL.md Rule 6 is a hard gate here, not a courtesy. Run (in the background — see
[references/ci-verification.md](ci-verification.md)):

```bash
./scripts/git/verify_ci.sh --branch "${CGW_SOURCE_BRANCH:-development}"
```

Only continue to Phase 4 on exit `0` (`CI: green`) or `3` (not applicable: no `gh`/auth/remote,
`CGW_CI_VERIFY=0`, or no workflow). Exit `2` (`CI: unverified`) is not green: re-run after a
moment, and stop and report if it persists.

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
- `pr` → **4B**: `./scripts/git/create_pr.sh --non-interactive` (add `--body-file <path>` for a written body), then gate on the PR's own
  checks in place of a plain branch watch. Take the PR number from the `PR number: N`
  line `create_pr.sh` prints (not `gh pr view` on the current branch, which can name a
  different PR) and its `Head SHA:` line, and run (in the background):

  ```bash
  ./scripts/git/verify_ci.sh --pr <N> --sha <Head SHA>
  ```

  The script waits for the PR's head to equal that SHA before reading checks (`gh pr checks`
  has no SHA and would otherwise report the previous head), then for checks to exist, then
  watches them — do not shortcut it to a bare `gh pr checks --watch`, which is exactly the
  stale-head race. Exit `2` (`CI: unverified`) is not green: do not report the PR as done.

  Exit `1` (`CI: red`) →
  run the Fix Loop from [ci-verification.md](ci-verification.md): commit the fix on
  `CGW_SOURCE_BRANCH`, `push_validated.sh` (this updates the open PR automatically), re-run
  `verify_ci.sh --pr <N> --sha <new sha>`.
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

Run the gate again, this time against `CGW_TARGET_BRANCH` — named explicitly, because
Phase 5 has already checked out `CGW_SOURCE_BRANCH`, so `HEAD` and `git branch --show-current`
now point at the *source* branch and its already-green runs:

```bash
./scripts/git/verify_ci.sh --branch "${CGW_TARGET_BRANCH:-main}"
```

The script takes the target's SHA from the remote and queries runs by commit **and** branch,
so a GitHub "Rebase and merge" PR or a manual `--ff-only` that leaves both branches on one
SHA cannot make it re-judge Phase 3b's already-green runs
([ci-verification.md](ci-verification.md)).

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
& $BASH scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
& $BASH scripts/git/push_validated.sh --non-interactive --skip-lint
& $BASH scripts/git/verify_ci.sh --branch development
& $BASH scripts/git/merge_with_validation.sh --non-interactive
& $BASH scripts/git/push_validated.sh --non-interactive --skip-lint
& $BASH scripts/git/verify_ci.sh --branch main
```

In cmd.exe:

```cmd
set "BASH=C:\Program Files\Git\bin\bash.exe"
"%BASH%" scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
"%BASH%" scripts/git/push_validated.sh --non-interactive --skip-lint
"%BASH%" scripts/git/verify_ci.sh --branch development
"%BASH%" scripts/git/merge_with_validation.sh --non-interactive
"%BASH%" scripts/git/push_validated.sh --non-interactive --skip-lint
"%BASH%" scripts/git/verify_ci.sh --branch main
```

`verify_ci.sh --branch` names the branch just pushed (your `CGW_SOURCE_BRANCH` at the first
gate, `CGW_TARGET_BRANCH` at the second — substitute your configured names for `development` /
`main`); it reads `CGW_CI_*` from `.cgw.conf` like every other wrapper, so the gate is the same
as Section A's — see [references/ci-verification.md](ci-verification.md) for the exit codes
and fix loop. Exit `1` and unfixable at the first gate → stop before the merge step, same as
Phase 3b. Exit `1` at the second → same prohibitions as Phase 5b (fix on `CGW_SOURCE_BRANCH`,
never directly on `CGW_TARGET_BRANCH`). Exit `2` → report `CI: unverified`, not green.

If `bash.exe` is unavailable (rare), STOP and ask the user to run from Git Bash instead
of bypassing the wrappers — SKILL.md's Core Rules are mandatory regardless of shell.
