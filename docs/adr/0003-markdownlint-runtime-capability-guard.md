# Markdown-lint runtime capability check and two-tier infrastructure crash handling

**Status**: accepted

## Context

In `scripts/git/_config.sh`, `_cgw_detect_markdownlint()` auto-detects markdown lint tooling when
`CGW_MARKDOWNLINT_CMD` is unconfigured. Prior to this decision, if neither `markdownlint-cli2` nor
`markdownlint` was found as a standalone binary on `PATH`, the function fell back to
`npx --yes markdownlint-cli2` whenever `command -v npx` succeeded.

However, modern versions of `markdownlint-cli2` (and its transitive dependencies such as
`string-width@7`) require Node.js ≥ 20 (and declare `"engines": { "node": ">=22" }`), utilizing
ECMAScript 2024 features like the RegExp `v` flag (`/.../v`).

In heterogeneous developer environments—most notably Windows installations using Git Bash / MSYS2—a
legacy Node.js binary (e.g. Node v18.19.1 in `/usr/bin/node`) can shadow a modern Windows-native Node
installation (e.g. Node v22.17.1 in `C:\Program Files\nodejs\node.exe`) due to MSYS2's `$PATH`
precedence. On such systems, `command -v npx` succeeded, causing `_config.sh` to configure
`CGW_MARKDOWNLINT_CMD="npx --yes markdownlint-cli2"`.

When `commit_enhanced.sh` ran against staged `.md` files, `cgw_run_markdownlint_check` invoked `npx`,
triggering a fatal `SyntaxError: Invalid regular expression flags` in Node v18. Prior to this decision,
`commit_enhanced.sh` treated any non-zero exit code as a markdown formatting violation, announced
`[!] Markdown lint errors detected`, and invoked `_fix_restage_recheck md`. The `--fix` pass crashed with
the exact same SyntaxError, aborting the commit with `[ERROR] Markdown lint errors remain after fix`.
This trapped automated workflows and AI agents in an unrecoverable failure loop on an optional linting
step due to a host runtime mismatch.

## Decision

We implement a Two-Tier capability check and crash-handling architecture:

1. **Config-time detection capability probe (Tier 1)**:
   In `_config.sh`, `_cgw_detect_markdownlint()` validates Node runtime capability before returning the
   `npx` fallback:
   `node -e 'new RegExp("", "v")' >/dev/null 2>&1`
   If `node` is missing or lacks support for the RegExp `v` flag (Node < 20), auto-detection fails open,
   returning `""` (opt-out / unconfigured). An optional tool auto-detection must never assign a command
   known to be unexecutable on the active runtime.

2. **Runtime execution crash defense (Tier 2)**:
   In `_common.sh`, `cgw_run_markdownlint_check` inspects the outcome of `run_tool_with_logging`. If
   the command fails (`exit_code != 0`):
   - If `TOOL_ERROR_COUNT > 0` (matched by `CGW_TOOL_ERROR_REGEX`): these are real markdown formatting
     errors; return `1`.
   - If `TOOL_ERROR_COUNT == 0`: the tool process crashed (engine `SyntaxError`, missing runtime,
     exit 127); return `2`.

3. **Commit gate bypass on infrastructure crash**:
   In `commit_enhanced.sh`:
   - On return code `1` (markdown errors): execute normal auto-fix / recheck loop (`_fix_restage_recheck`).
   - On return code `2` (infrastructure crash): emit an explanatory advisory notice (`[!] Markdown lint tool failed to execute (environment/runtime failure, not markdown formatting errors)`), bypass the doomed `_fix_restage_recheck` loop, and proceed with the commit in non-interactive mode (or prompt in interactive mode).
   - In both cases where markdown validation is bypassed on crash, set `skip_md_lint=1` so that the
     downstream `[3.5]` congruence guard (`cgw_validated_path_set`) correctly excludes `.md` files
     from the validated path set.

## Considered and rejected

- **Fail-closed on capability mismatch**: Hard-aborting during config or commit when Node < 20 was
  rejected because markdownlint is an optional code-quality check, not a core git invariant. Halting git
  workflows for environment incompatibilities in an auto-detected secondary tool violates CGW's
  usability contract.
- **Auto-searching Windows PATH for `node.exe`**: Probing every entry in `which -a node` or rewriting
  PATH to prioritize `C:\Program Files\nodejs` was rejected as overly invasive. Reordering shell `$PATH`
  inside a git wrapper script can have unpredictable side effects on other tools and child processes.
  Host PATH configuration belongs to developer dotfiles/environment configuration.
- **Version-pinning `markdownlint-cli2`**: Pinning `markdownlint-cli2` to an ancient version compatible
  with Node 18 was rejected because it freezes rule updates and penalizes the majority of developers who
  have modern Node (≥ 20) installed.

## Consequences

- Environments with Node < 20 gracefully skip markdownlint auto-detection, remaining able to commit
  cleanly.
- Developers who intentionally configure a broken `CGW_MARKDOWNLINT_CMD` receive clear notices
  identifying engine crashes rather than misleading markdown syntax accusations.
- The `[3.5]` congruence guard stays mathematically sound: unvalidated markdown files are not tracked in
  `cgw_validated_path_set`.
