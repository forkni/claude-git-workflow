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

**Phase 1 — Pre-commit validation**

1. `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1`
2. `git diff --quiet && git diff --cached --quiet`
   — exit 0: no changes, report "No changes to commit", stop. exit 1: continue.
3. `./scripts/git/check_lint.sh >/dev/null 2>&1`
   — exit 0: skip to Phase 2. exit ≠0: continue.
4. `./scripts/git/fix_lint.sh`
5. `./scripts/git/check_lint.sh`
   — local-only files (CLAUDE.md, MEMORY.md, etc.) failing lint is safe to ignore
     (SKILL.md Rule 3). Still fails otherwise: stop. Passes: continue to Phase 2.

**Phase 2 — Commit to source branch**

Stage per SKILL.md Rule 5 (staging intent), then:

```bash
./scripts/git/commit_enhanced.sh --non-interactive "type: descriptive commit message"
```

(or with `--only <path>` per file for a selective commit — see SKILL.md Rule 5). Replace
`type:` with the correct conventional-commit prefix. Then capture:

```bash
git log -1 --format="%h %s"
```

**Phase 3 — Push source branch**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
```

exit 0: continue. exit ≠0: rerun without suppression to show the error, stop.

**Phase 3b — CI gate on source (blocking)**

SKILL.md Rule 6 is a hard gate here, not a courtesy: apply
[references/ci-verification.md](ci-verification.md) against `CGW_SOURCE_BRANCH`. Resolve the
runs this push triggered, watch them to a terminal state, and only continue to Phase 4 once
the verdict is green or not-applicable (no `gh`/auth/remote, or `CGW_CI_VERIFY=0`).

Red and unfixable within `CGW_CI_MAX_FIX_ROUNDS` → **stop here, do not enter Phase 4.** This
is what stops a broken commit from ever reaching `CGW_TARGET_BRANCH`. Report the failing
workflow/job and the `gh run view` URL, and hand back to the user.

**Phase 4 — Merge or PR**

```bash
[[ -f .cgw.conf ]] && . ./.cgw.conf
echo "${CGW_MERGE_MODE:-direct}"
```

- `direct` (default) → **4A**: `./scripts/git/merge_with_validation.sh --non-interactive`
  — exit 0: continue to Phase 5. exit ≠0: inspect conflict type, stop, see
  [error-recovery.md](error-recovery.md).
- `pr` → **4B**: `./scripts/git/create_pr.sh --non-interactive`, then watch the PR's own
  checks in place of a plain branch-run watch:
  ```bash
  pr_number=$(gh pr view --json number --jq .number)
  gh pr checks "$pr_number" --watch --fail-fast --interval "${CGW_CI_POLL_INTERVAL:-15}"
  ```
  (exit `8` = still pending — `--watch` normally blocks past that to a terminal state.) Red →
  run the Fix Loop from [ci-verification.md](ci-verification.md): commit the fix on
  `CGW_SOURCE_BRANCH`, `push_validated.sh` (this updates the open PR automatically), re-watch.
  Bounded by `CGW_CI_MAX_FIX_ROUNDS`; exhausted → stop and hand back to the user. Green →
  `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1` and report:
  ```
  Workflow complete (PR mode)
  Source branch: [hash] "[message]" pushed
  PR: [url] — checks: green, Charlie review: [pending|approved|changes requested]
  ```
  Charlie's review is tracked separately from checks (a reviewer, not a required check) —
  mention its status but don't block on it. Stop here regardless — merging into
  `CGW_TARGET_BRANCH` happens on GitHub once the PR is approved and merged, outside this
  pipeline, so Phase 5/5b do not apply in PR mode.

**Phase 5 — Push target branch (direct mode only)**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

exit ≠0 on the push: rerun without suppression, stop.

**Phase 5b — CI gate on target**

Apply [references/ci-verification.md](ci-verification.md) again, this time against
`CGW_TARGET_BRANCH`. A direct merge fast-forwards, so `CGW_TARGET_BRANCH` and
`CGW_SOURCE_BRANCH` can share the exact same commit SHA — resolve runs with **both**
`--commit` and `--branch` (ci-verification.md → *Baseline + Resolve Runs*), never commit
alone, or this ends up re-watching Phase 3b's already-green runs and calling it done.

Red and unfixable → do **not** report success. A fix here is still authored on
`CGW_SOURCE_BRANCH` and re-promoted through Phases 2-5 (never committed directly to
`CGW_TARGET_BRANCH` — ci-verification.md → *Hard Prohibitions*); check out
`CGW_SOURCE_BRANCH` and hand back to the user with the failing workflow/job and the
`gh run view` URL.

**Final report (direct mode)**

```bash
git log "${CGW_SOURCE_BRANCH:-development}" -1 --format="%h %s"
git log "${CGW_TARGET_BRANCH:-main}" -1 --format="%h"
```

```
Workflow complete

Source branch: [hash] "[message]"  CI: [green|n/a]
Target branch: [hash] merged & pushed  CI: [green|n/a]
```

## Section B: Windows cmd.exe (Bash-mediated)

```batch
bash scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
bash scripts/git/push_validated.sh --non-interactive --skip-lint
bash -c "sha=$(git rev-parse HEAD); branch=$(git branch --show-current); gh run list --commit \"$sha\" --branch \"$branch\" --json databaseId --jq '.[].databaseId' | xargs -n1 gh run watch --exit-status --compact --interval 15"
bash scripts/git/merge_with_validation.sh --non-interactive
bash scripts/git/push_validated.sh --non-interactive --skip-lint
bash -c "sha=$(git rev-parse HEAD); branch=$(git branch --show-current); gh run list --commit \"$sha\" --branch \"$branch\" --json databaseId --jq '.[].databaseId' | xargs -n1 gh run watch --exit-status --compact --interval 15"
```

Same gate as Section A applies at both watch points — see
[references/ci-verification.md](ci-verification.md) for the full resolve/watch/verdict/fix-loop
procedure; it's run via `bash -c "..."` here because the `gh` logic itself is shell-agnostic but
still needs a POSIX shell to invoke. Red and unfixable at the first watch point → stop before
the merge step, same as Phase 3b. Red at the second → same prohibitions as Phase 5b (fix on
`CGW_SOURCE_BRANCH`, never directly on `CGW_TARGET_BRANCH`).

If `bash.exe` is unavailable (rare), STOP and ask the user to run from Git Bash instead
of bypassing the wrappers — SKILL.md's Core Rules are mandatory regardless of shell.
