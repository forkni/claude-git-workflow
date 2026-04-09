# Shell Script Code Style

Rules for writing and modifying bash scripts in this repository.
Charlie also reads CLAUDE.md for project context.

## Scope

`scripts/git/*.sh`, `hooks/*`, `.githooks/*`

## Context

- All scripts are pure bash targeting bash 4.0+; no Python, JS, or build system
- Scripts run on Linux, macOS, and Windows (Git Bash / WSL)
- `set -e` is intentionally omitted — git uses non-zero exit codes as signals, not errors
- ShellCheck compliance is required; all scripts must pass without unacknowledged warnings

## Rules

- [R1] Always use `set -uo pipefail` at the top of every script — never add `set -e`
- [R2] Always source `_common.sh` (which sources `_config.sh`) — never source `_config.sh` directly
  - Pattern: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` then `source "${SCRIPT_DIR}/_common.sh"`
- [R3] Always use `[[ ... ]]` for conditionals — never `[ ... ]` or `test`
- [R4] Always use `"${var}"` expansion for variables — never bare `$var`
- [R5] Always use 2-space indentation — never tabs
- [R6] Always pass ShellCheck — add `# shellcheck disable=SCxxxx` with a one-line justification comment only when suppressing is unavoidable
- [R7] Add `# shellcheck source=scripts/git/_config.sh` directive on source statements for sourced files
- [R8] Never commit files listed in `CGW_LOCAL_FILES` (default: `CLAUDE.md MEMORY.md .claude/ logs/`)
- [R9] Use forward slashes in all paths — never backslashes (bash on Windows requires forward slashes)
- [R10] Use conventional commit prefixes: `feat|fix|docs|chore|test|refactor|style|perf` (extensible via `CGW_EXTRA_PREFIXES`)
- [R11] Handle cross-platform venv: check `.venv/Scripts/` (Windows) before `.venv/bin/` (Unix) — see `get_python_path()` in `_common.sh`

## Examples

### Good examples

- [R1] — Correct shebang and flags
```bash
#!/usr/bin/env bash
set -uo pipefail
# Note: set -e intentionally omitted — git uses exit codes for signaling
```

- [R2] — Correct source chain
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"
```

- [R6] — Acceptable shellcheck suppression
```bash
# shellcheck disable=SC2086  # Word splitting intentional: CGW_LINT_ARGS contains multiple flags
${lint_cmd} ${CGW_LINT_ARGS}
```

### Bad examples

- [R1] — Never add set -e
```bash
set -euo pipefail  # BAD: -e causes false failures on git diff exit codes
```

- [R3] — Never use single brackets
```bash
if [ "$branch" = "main" ]; then  # BAD: use [[ ]]
```

## References

1. ShellCheck wiki — https://www.shellcheck.net/wiki/
2. CGW config variables — ./cgw.conf.example
