# Full Promotion Pipeline

The one-click commit → push → merge/PR → push sequence executed by
`/auto-git-workflow-cmd` option 1. Loaded on demand from the command router —
do not run this pipeline unprompted; it is only for an explicit "full promotion"
request. SKILL.md Core Rules govern every step.

## Contents
- Environment Detection
- Bash Tool Compatibility
- Section A: Git Bash / Linux / macOS (Phases 1-5)
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

**Phase 4 — Merge or PR**

```bash
echo "${CGW_MERGE_MODE:-direct}"
```

- `direct` (default) → **4A**: `./scripts/git/merge_with_validation.sh --non-interactive`
  — exit 0: continue to Phase 5. exit ≠0: inspect conflict type, stop, see
  [error-recovery.md](error-recovery.md).
- `pr` → **4B**: `./scripts/git/create_pr.sh --non-interactive`, then
  `git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1`. Report:
  ```
  Workflow complete (PR mode)
  Source branch: [hash] "[message]" pushed
  PR: [url] — awaiting Charlie CI review
  ```
  and stop — CI takes over from here, do not proceed to Phase 5.

**Phase 5 — Push target branch (direct mode only)**

```bash
./scripts/git/push_validated.sh --non-interactive --skip-lint >/dev/null 2>&1
git checkout "${CGW_SOURCE_BRANCH:-development}" >/dev/null 2>&1
```

exit ≠0 on the push: rerun without suppression, stop.

**Final report (direct mode)**

```bash
git log "${CGW_SOURCE_BRANCH:-development}" -1 --format="%h %s"
git log "${CGW_TARGET_BRANCH:-main}" -1 --format="%h"
```

```
Workflow complete

Source branch: [hash] "[message]"
Target branch: [hash] merged & pushed
```

## Section B: Windows cmd.exe (Bash-mediated)

```batch
bash scripts/git/commit_enhanced.sh --non-interactive "feat: descriptive commit message"
bash scripts/git/push_validated.sh --non-interactive --skip-lint
bash scripts/git/merge_with_validation.sh --non-interactive
bash scripts/git/push_validated.sh --non-interactive --skip-lint
```

If `bash.exe` is unavailable (rare), STOP and ask the user to run from Git Bash instead
of bypassing the wrappers — SKILL.md's Core Rules are mandatory regardless of shell.
