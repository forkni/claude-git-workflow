# Shell Style Guide Compliance Audit

**Date**: 2026-04-23
**Guide**: Google Shell Style Guide (adapted — `SHELL_STYLE_GUIDE.md`)
**Scope**: 25 scripts in `scripts/git/*.sh` + `tests/benchmark/install_benchmark.sh`
**Tools**: ShellCheck, shfmt, manual grep + file inspection

---

## Summary

| Area | Status |
|---|---|
| Tabs / indentation style | PASS |
| Control flow (`; do` / `; then`) | PASS |
| Backtick command substitution | PASS |
| `[[ ]]` vs `[ ]` tests | PASS |
| `let` / `expr` arithmetic | PASS |
| Naming (functions, vars, files) | PASS |
| `local` in functions | PASS |
| File header comments | PASS |
| Return-value guards (`mv`/`cp`/`cd`) | PASS |
| `main "$@"` pattern | PASS |
| **`eval` usage** | **RESOLVED in v0.3.0 — 3 sites fixed** |
| **Pipe-to-while** | **RESOLVED in v0.3.0 — 5 sites fixed** |
| **STDERR routing for `[FAIL]` messages** | **RESOLVED in v0.3.0 — ~35 sites fixed** |
| **`${var}` vs `$var` consistency** | **RESOLVED in v0.3.0 — 2 files fixed** |
| Line length > 80 chars | OUT OF SCOPE |
| Shebangs (`#!/usr/bin/env bash`) | OUT OF SCOPE |
| Function `Globals/Arguments/Returns` headers | OUT OF SCOPE |

---

## Clean Areas (no action required)

- **§2.1 Indentation** — zero tab characters; consistent 2-space indent in all
  `scripts/git/*.sh`. `install_benchmark.sh` uses 4-space (accepted as-is).
- **§2.4 Control flow** — `; do` / `; then` always on same line as `for`/`while`/`if`.
- **§2.7 Backticks** — zero command-substitution backticks. All `\`` hits are
  inside markdown heredocs (escaped, non-executing).
- **§2.8 Tests** — zero `[ ... ]` or `test` conditionals. All use `[[ ... ]]`.
- **§2.9 Arithmetic** — zero `let` or `expr`. All arithmetic uses `$(( ... ))`.
- **§3.1/3.2/3.3 Naming** — snake_case functions/vars, UPPER_CASE constants,
  snake_case filenames: fully compliant.
- **§3.4 `local`** — spot-checked `_common.sh`, `commit_enhanced.sh`,
  `push_validated.sh`, `configure.sh`, `merge_with_validation.sh`: all compliant.
- **§4.2 File headers** — all 26 scripts have top-of-file comment blocks with
  Purpose/Usage/Globals/Arguments/Returns documentation.
- **§4.3 Return values** — no bare `mv`/`cp`/`rm`/`cd` without `|| exit` or `if`
  guards. (Note: `set -e` is intentionally omitted; exit codes signal state.)
- **§4.5 `main "$@"`** — every executable script ends with `main "$@"`. Library
  files (`_common.sh`, `_config.sh`) correctly have no `main`.

---

## Out-of-scope Findings (accepted)

| Finding | Reason |
|---|---|
| Shebangs use `#!/usr/bin/env bash` | More portable on macOS/Windows Git Bash; switching to `#!/bin/bash` would regress the cross-platform guarantee in CLAUDE.md |
| 700+ lines > 80 chars | Churn/benefit ratio too high; most long lines are descriptive `echo`/heredoc content |
| Function-level `Globals/Arguments/Returns` headers incomplete in `_common.sh`, `configure.sh`, `rebase_safe.sh` | Deferred to a dedicated documentation pass |
| `CGW_LINT_EXCLUDES`/`CGW_FORMAT_EXCLUDES` as strings vs arrays (§2.10) | Requires multi-file consumer refactor + ruff regression testing; deferred |

---

## In-scope Findings and Fixes

### §1.3 `eval` — 3 violations

| File | Line | Context |
|---|---|---|
| `scripts/git/_config.sh` | 66 | `eval "${_line}"` — guarded by strict regex but still `eval` |
| `tests/benchmark/install_benchmark.sh` | 189 | `eval "$cmd"` in `exec_check()` |
| `tests/benchmark/install_benchmark.sh` | 214 | `eval "$cmd"` in `warn_check()` |

**Fix for `_config.sh:66`**: Use regex capture group 3 to extract the value part
(`BASH_REMATCH[3]`), then assign with `printf -v`. Removes `eval` entirely.

**Fix for `install_benchmark.sh:189,214`**: Replace `eval "$cmd"` with
`bash -c "$cmd"` — same behaviour for trusted command strings, but explicit
about intent. (Full array-based refactor deferred.)

**Resolution (v0.3.0):** All three sites fixed. `_config.sh` now uses a regex-based parser with `printf -v`; `.cgw.conf` values are treated as literal strings. `install_benchmark.sh` uses `bash -c "${cmd}"` with justification comment.

---

### §1.4 Pipe-to-while — 5 violations

All five are degenerate: `git log -1 --oneline` produces exactly one line,
making the `while` loop unnecessary.

| File | Line | Code |
|---|---|---|
| `scripts/git/cherry_pick_commits.sh` | 301 | `git log -1 --oneline \| while read -r line; do ... done` |
| `scripts/git/merge_with_validation.sh` | 479 | same pattern |
| `scripts/git/rollback_merge.sh` | 301 | `git log --oneline -1 \| while read -r line; do ... done` |
| `scripts/git/rollback_merge.sh` | 335 | same pattern |
| `scripts/git/merge_docs.sh` | 260 | `git log -1 --oneline \| while read -r line; do ... done` |

**Fix**: Replace with `line="$(git log -1 --oneline)"` + direct `echo`.

**Resolution (v0.3.0):** All five sites eliminated — replaced with plain command substitution.

---

### §4.1 STDERR routing — ~35 violations

Error-level messages (`[FAIL]`, `[ERROR]`) are piped through
`tee -a "$logfile"` which writes to **stdout + file**, not **stderr + file**.
The existing `err()` helper in `_common.sh` writes to stderr but not the log.

**Fix**: Add `err_tee()` to `_common.sh` that writes to both stderr and the
active `${logfile}`. Replace all `[FAIL]`/`[ERROR]` echo-tee lines with
`err_tee`. Also redirect three `[!]` warnings in `configure.sh` to `>&2`.

All affected files (sampled sites):

| File | Lines |
|---|---|
| `merge_with_validation.sh` | 82, 94, 103, 144, 262, 282, 303, 374, 386, 410, 425, 439, 460 |
| `cherry_pick_commits.sh` | 137, 156, 164, 213, 258, 339 |
| `rollback_merge.sh` | 110, 317, 353 |
| `sync_branches.sh` | 103, 130, 254 |
| `rebase_safe.sh` | 384, 516 |
| `merge_docs.sh` | 125, 143, 224, 279 |
| `install_hooks.sh` | 75 |
| `push_validated.sh` | 270 |
| `bisect_helper.sh` | 327 |
| `configure.sh` | 307, 361, 390 (direct echo, no tee — add `>&2`) |

**Resolution (v0.3.0):** `err_tee()` helper added to `_common.sh`; ~34 `[FAIL]`/`[ERROR]` sites across 9 scripts replaced with `err_tee` calls. Three `configure.sh` warning lines redirected to `>&2`.

---

### §2.6 `${var}` consistency — 2 files

`commit_enhanced.sh` and `tests/benchmark/install_benchmark.sh` mix bare
`$var` with properly braced `${var}` throughout.

**Fix**: Sweep both files converting bare `$name` → `${name}`. Skip: positional
`$1`–`$9`, special vars (`$?`, `$#`, `$*`, `$@`, `$$`), single-quoted strings,
already-braced expansions, and heredoc content prefixed with `\$`.

**Resolution (v0.3.0):** Sweep applied to both files; 49 sites in `commit_enhanced.sh` and 238 sites in `install_benchmark.sh` updated.

---

## Verification Checklist

After applying fixes:

- [x] `shellcheck -x --source-path=scripts/git scripts/git/*.sh` — clean
- [x] `shellcheck tests/benchmark/install_benchmark.sh` — clean
- [x] `shfmt -d -i 2 -ci scripts/` — no diffs
- [x] `bats tests/unit/` — all pass
- [x] `bats tests/integration/commit_enhanced.bats` — all pass
- [x] Smoke-test `_config.sh`: verify `.cgw.conf` with `export CGW_FOO=bar`,
  `CGW_BAZ="quoted value"`, comment lines, and one rejected line produces
  `[WARN]` and correct variable resolution
- [x] Smoke-test STDERR routing: `./script ... 2>/dev/null` suppresses `[FAIL]`
  lines; `./script ... >/dev/null` still shows them on stderr
