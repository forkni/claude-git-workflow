#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexander Korneev
# SPDX-License-Identifier: MIT
# _lib_lint.sh - Lint, format, markdownlint and typecheck pipeline for claude-git-workflow scripts
# Usage: sourced automatically by _common.sh -- do not source directly
#
# Functions: cgw_resolve_lint_binary, cgw_strip_path_arg, cgw_fill_path_placeholder, cgw_modified_files_for_lint, cgw_snapshot_tree, cgw_pushed_files_for_lint, cgw_lint_plan, _cgw_run_pipeline_tool, cgw_run_lint_check, cgw_run_format_check, cgw_run_lint_fix, cgw_run_markdownlint_check, cgw_run_markdownlint_fix, cgw_staged_files_for_md, cgw_modified_files_for_md, cgw_staged_files_for_lint, cgw_path_is_diff_blind, cgw_paths_diverging_from_index, cgw_lint_files_diverging_from_index, cgw_staged_paths_diverging_from_index, cgw_validated_path_set, cgw_crlf_in_index_files, cgw_run_typecheck.
#
# Uses run_tool_with_logging(), get_python_path(), log_section_end() and the CGW_* settings
# from _common.sh / _config.sh at call time.

# ── lint pipeline module ───────────────────────────────────────────────────────
# Shared helpers for venv-aware binary resolution, file-list selection, lint
# check, format check, lint/format fix, markdownlint, and typecheck. Callers:
# commit_enhanced.sh, check_lint.sh, fix_lint.sh, .githooks/pre-commit.
#
# cgw_resolve_lint_binary <cmd>
#   Stdout: absolute path to .venv/<cmd>${PYTHON_EXT} when the binary exists in
#   the active venv, else <cmd> verbatim (falls back to system PATH).
#   Reads PYTHON_BIN and PYTHON_EXT — caller must pre-populate via get_python_path.
#   Returns 0 always; pure path resolution, no side effects.

cgw_resolve_lint_binary() {
  local cmd="$1"
  if [[ -n "${PYTHON_BIN:-}" ]] && [[ -f "${PYTHON_BIN}/${cmd}${PYTHON_EXT:-}" ]]; then
    echo "${PYTHON_BIN}/${cmd}${PYTHON_EXT:-}"
  else
    echo "${cmd}"
  fi
}

# cgw_strip_path_arg <args-string>
#   Echo args-string with its file-position placeholder removed, so a scoped
#   caller can append an explicit file list. Recognizes an explicit "{files}"
#   token (preferred convention) anywhere in the string; otherwise removes a
#   standalone "." token (legacy convention). All other tokens — flags and
#   non-dot paths — are preserved. This is the A3 fix: the old implementation
#   stripped only the LAST token, so args like "check . --fix" silently kept the
#   whole-repo "." and reverted to an unscoped scan. Space-safe (read -r -a).
cgw_strip_path_arg() {
  local -a toks=() out=()
  read -r -a toks <<<"${1:-}"
  local tok has_placeholder=0 has_dot=0
  for tok in "${toks[@]+"${toks[@]}"}"; do
    [[ "${tok}" == "{files}" ]] && has_placeholder=1
    [[ "${tok}" == "." ]] && has_dot=1
  done
  # No identifiable path token in a multi-token string: we can't know whether a
  # token like "src/" is a scan target (should be replaced) or a flag argument
  # (must be kept), so we keep everything and append files. Hint the explicit
  # convention. Single tokens ("check", "run") are subcommands, not paths.
  if [[ ${has_placeholder} -eq 0 && ${has_dot} -eq 0 && ${#toks[@]} -gt 1 ]]; then
    echo "[cgw-lint] cannot identify a path token in '${1}'; appending files -- put {files} where the scan target goes to make scoping explicit" >&2
  fi
  for tok in "${toks[@]+"${toks[@]}"}"; do
    if [[ ${has_placeholder} -eq 1 ]]; then
      [[ "${tok}" == "{files}" ]] && continue
    else
      [[ "${tok}" == "." ]] && continue
    fi
    out+=("${tok}")
  done
  echo "${out[*]+"${out[*]}"}"
}

# cgw_fill_path_placeholder <args-string> [default-path]
#   Echo args-string with the "{files}" placeholder replaced by <default-path>
#   (default "."). Used by the whole-repo/audit branch so an args template that
#   carries "{files}" (e.g. "check {files}") expands to a real path ("check .")
#   instead of leaking the literal token to the tool. Legacy args without
#   "{files}" pass through unchanged (they already carry their own path).
cgw_fill_path_placeholder() {
  local args="${1:-}" default_path="${2:-.}"
  echo "${args//\{files\}/${default_path}}"
}

# cgw_modified_files_for_lint
#   Stdout: newline-separated list of modified/added files matching
#   CGW_LINT_EXTENSIONS (default: *.py). Outputs nothing when no files match.
#   Caller checks for empty output and decides whether to skip early.
cgw_modified_files_for_lint() {
  local -a lint_exts
  read -r -a lint_exts <<<"${CGW_LINT_EXTENSIONS:-*.py}"
  git diff --name-only --diff-filter=ACMR HEAD -- "${lint_exts[@]}"
}

# cgw_snapshot_tree <rev> <dest-dir>
#   Materialize the COMMITTED tree of <rev> into the existing directory
#   <dest-dir> (checkout-index through a throwaway index file, so the real
#   index, HEAD and working tree are never touched). Applies .gitattributes
#   eol/text conversion like a normal checkout. Deliberately not `git archive`
#   (drops export-ignore paths a typechecker may need) and not `git worktree
#   add` (registers a worktree and trips the worktree guardrail/shims).
#   Submodule entries come out as empty directories. Returns 0 on success.
cgw_snapshot_tree() {
  local rev="${1:-}" dest="${2:-}"
  if [[ -z "${rev}" || -z "${dest}" || ! -d "${dest}" ]]; then
    echo "cgw_snapshot_tree: usage: cgw_snapshot_tree <rev> <existing-dest-dir>" >&2
    return 1
  fi
  local idx_dir rc=0
  idx_dir="$(mktemp -d "${TMPDIR:-/tmp}/cgw-snapidx.XXXXXX")" || return 1
  GIT_INDEX_FILE="${idx_dir}/index" git -C "${PROJECT_ROOT:-.}" read-tree "${rev}" &&
    GIT_INDEX_FILE="${idx_dir}/index" git -C "${PROJECT_ROOT:-.}" checkout-index -a -f --prefix="${dest%/}/" ||
    rc=1
  rm -rf "${idx_dir}"
  return "${rc}"
}

# cgw_pushed_files_for_lint <rev> <base|""> [glob-string]
#   Stdout: newline-separated files a push of <rev> adds/changes, filtered to
#   [glob-string] (default CGW_LINT_EXTENSIONS, else *.py), deduplicated, and
#   limited to paths that still exist in <rev>.
#   <base> non-empty: files changed in <base>...<rev> (three-dot, so a rebased
#     or force-pushed branch still diffs from the merge-base). If there is no
#     merge-base the base is ignored and the unpushed-commits form is used.
#   <base> empty: files touched by commits reachable from <rev> but from no
#     remote-tracking ref (new branch) -- the "unvetted commits" range that
#     hooks/pre-push uses.
cgw_pushed_files_for_lint() {
  local rev="${1:-}" base="${2:-}"
  local globs="${3:-${CGW_LINT_EXTENSIONS:-*.py}}"
  local -a exts=()
  read -r -a exts <<<"${globs}"
  [[ -z "${rev}" ]] && return 1
  local files="" have=0 diffed=0
  if [[ -n "${base}" ]] && git -C "${PROJECT_ROOT:-.}" merge-base "${base}" "${rev}" >/dev/null 2>&1; then
    files="$(git -C "${PROJECT_ROOT:-.}" -c core.quotePath=false diff --name-only --diff-filter=ACMR "${base}...${rev}" -- "${exts[@]}")" || return 1
    have=1
    diffed=1
  fi
  if [[ ${have} -eq 0 ]]; then
    files="$(git -C "${PROJECT_ROOT:-.}" -c core.quotePath=false log -m --format= --name-only --diff-filter=ACMR "${rev}" --not --remotes -- "${exts[@]}")" || return 1
  fi
  local f
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    # A three-dot diff with ACMR already excludes paths absent from <rev>; only
    # the log form (add then delete within the range) needs the existence check.
    if [[ ${diffed} -eq 1 ]] || git -C "${PROJECT_ROOT:-.}" cat-file -e "${rev}:${f}" 2>/dev/null; then
      printf '%s\n' "${f}"
    fi
  done < <(printf '%s\n' "${files}" | sort -u)
  return 0
}

# cgw_lint_plan <check|fix> [flags...]
#   Pure query returning the execution plan for the lint pipeline.
#   Outputs line-delimited records: step:action:reason
#     step:   lint | format | typecheck | markdown
#     action: run | skip
#     reason: explanation (e.g. configured, CGW_SKIP_LINT=1, --skip-lint,
#             CGW_LINT_CMD not set, --skip-typecheck, --md-only, --modified-only, etc.)
#   Validates flag combinations (e.g. --skip-md-lint + --md-only is an error).
#   Returns 0 on successful plan generation, 1 on invalid arguments or mutually exclusive flags.
cgw_lint_plan() {
  local mode="${1:-}"
  if [[ "${mode}" != "check" && "${mode}" != "fix" ]]; then
    echo "cgw_lint_plan: mode must be 'check' or 'fix'" >&2
    return 1
  fi
  shift

  local skip_lint_flag=0
  local skip_md_lint_flag=0
  local skip_typecheck_flag=0
  local md_only=0
  local modified_only=0
  local has_ref=0 has_base=0 has_unpushed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref | --base)
        if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
          echo "cgw_lint_plan: $1 requires a revision argument" >&2
          return 1
        fi
        [[ "$1" == "--ref" ]] && has_ref=1 || has_base=1
        shift 2
        ;;
      --unpushed)
        has_unpushed=1
        shift
        ;;
      --skip-lint)
        skip_lint_flag=1
        shift
        ;;
      --skip-md-lint)
        skip_md_lint_flag=1
        shift
        ;;
      --skip-typecheck)
        skip_typecheck_flag=1
        shift
        ;;
      --md-only)
        md_only=1
        shift
        ;;
      --modified-only)
        modified_only=1
        shift
        ;;
      --no-venv | --interactive | --non-interactive | --all | --staged-only | --sign | --no-sign | -h | --help)
        # Recognized harmless flags that do not alter the step plan
        shift
        ;;
      --only)
        shift 2 2>/dev/null || shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ ${skip_md_lint_flag} -eq 1 ]] && [[ ${md_only} -eq 1 ]]; then
    echo "cgw_lint_plan: --skip-md-lint and --md-only are mutually exclusive" >&2
    return 1
  fi

  if [[ "${mode}" == "check" ]] && [[ ${modified_only} -eq 1 ]] && [[ ${md_only} -eq 1 ]]; then
    echo "cgw_lint_plan: --modified-only and --md-only are not supported together" >&2
    return 1
  fi

  # --ref selects a committed snapshot to check; --base/--unpushed only narrow
  # which files lint/format/markdown see inside it.
  if [[ ${has_ref} -eq 0 ]] && [[ ${has_base} -eq 1 || ${has_unpushed} -eq 1 ]]; then
    echo "cgw_lint_plan: --base/--unpushed require --ref" >&2
    return 1
  fi
  if [[ ${has_base} -eq 1 ]] && [[ ${has_unpushed} -eq 1 ]]; then
    echo "cgw_lint_plan: --base and --unpushed are mutually exclusive" >&2
    return 1
  fi
  if [[ ${has_ref} -eq 1 ]] && [[ ${modified_only} -eq 1 || ${md_only} -eq 1 ]]; then
    echo "cgw_lint_plan: --ref cannot be combined with --modified-only or --md-only" >&2
    return 1
  fi

  # Umbrella skip resolution: --skip-lint or CGW_SKIP_LINT=1
  local umbrella_reason=""
  if [[ ${skip_lint_flag} -eq 1 ]]; then
    umbrella_reason="--skip-lint"
  elif [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    umbrella_reason="CGW_SKIP_LINT=1"
  fi

  if [[ -n "${umbrella_reason}" ]]; then
    echo "lint:skip:${umbrella_reason}"
    echo "format:skip:${umbrella_reason}"
    echo "typecheck:skip:${umbrella_reason}"
    echo "markdown:skip:${umbrella_reason}"
    return 0
  fi

  # If --md-only
  if [[ ${md_only} -eq 1 ]]; then
    echo "lint:skip:--md-only"
    echo "format:skip:--md-only"
    echo "typecheck:skip:--md-only"
    if [[ ${skip_md_lint_flag} -eq 1 ]]; then
      echo "markdown:skip:--skip-md-lint"
    elif [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]]; then
      echo "markdown:skip:CGW_SKIP_MD_LINT=1"
    elif [[ -z "${CGW_MARKDOWNLINT_CMD:-}" ]]; then
      echo "markdown:skip:CGW_MARKDOWNLINT_CMD not set"
    else
      echo "markdown:run:configured"
    fi
    return 0
  fi

  # Step: lint
  if [[ -z "${CGW_LINT_CMD:-}" ]]; then
    echo "lint:skip:CGW_LINT_CMD not set"
  else
    echo "lint:run:configured"
  fi

  # Step: format
  if [[ -z "${CGW_FORMAT_CMD:-}" ]]; then
    echo "format:skip:CGW_FORMAT_CMD not set"
  else
    echo "format:run:configured"
  fi

  # Step: typecheck
  if [[ "${mode}" == "fix" ]]; then
    echo "typecheck:skip:no fix support"
  elif [[ ${modified_only} -eq 1 ]]; then
    echo "typecheck:skip:--modified-only"
  elif [[ ${skip_typecheck_flag} -eq 1 ]]; then
    echo "typecheck:skip:--skip-typecheck"
  elif [[ "${CGW_SKIP_TYPECHECK:-0}" == "1" ]]; then
    echo "typecheck:skip:CGW_SKIP_TYPECHECK=1"
  elif [[ -z "${CGW_TYPECHECK_CMD:-}" ]]; then
    echo "typecheck:skip:CGW_TYPECHECK_CMD not set"
  else
    echo "typecheck:run:configured"
  fi

  # Step: markdown
  if [[ "${mode}" == "check" ]] && [[ ${modified_only} -eq 1 ]]; then
    echo "markdown:skip:--modified-only"
  elif [[ ${skip_md_lint_flag} -eq 1 ]]; then
    echo "markdown:skip:--skip-md-lint"
  elif [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]]; then
    echo "markdown:skip:CGW_SKIP_MD_LINT=1"
  elif [[ -z "${CGW_MARKDOWNLINT_CMD:-}" ]]; then
    echo "markdown:skip:CGW_MARKDOWNLINT_CMD not set"
  else
    echo "markdown:run:configured"
  fi

  return 0
}

# _cgw_run_pipeline_tool <mode> <section_name> <log_path> <cmd...>
#   Executes a tool under either 'logged' mode (via run_tool_with_logging)
#   or 'plain' mode (raw command output, no log section headers/footers).
#   In both modes, TOOL_OUTPUT and TOOL_ERROR_COUNT are set dynamically.
#   Returns the exit code of the executed command.
_cgw_run_pipeline_tool() {
  local mode="$1"
  local section_name="$2"
  local log_path="$3"
  shift 3

  if [[ "${mode}" == "plain" ]]; then
    TOOL_OUTPUT=$("$@" 2>&1)
    local exit_code=$?
    TOOL_ERROR_COUNT=$(echo "$TOOL_OUTPUT" | grep -cE "${CGW_TOOL_ERROR_REGEX:-${_CGW_DEFAULT_DIAG_REGEX}}" || true)
    if [[ -n "$TOOL_OUTPUT" ]]; then
      echo "$TOOL_OUTPUT"
    fi
    return $exit_code
  else
    run_tool_with_logging "${section_name}" "${log_path:-/dev/null}" "$@"
  fi
}

# cgw_run_lint_check [--mode <logged|plain>] [--result-var <var>] [files...]
#   Runs ${CGW_LINT_CMD} check against the project (no files) or a given file
#   list (strips trailing path token from CGW_LINT_CHECK_ARGS when files given).
#   Honors CGW_SKIP_LINT=1 and empty CGW_LINT_CMD (returns 0, emits skip line).
#   Assigns 'Lint:status:count' into the result variable (default: CGW_RESULT).
#   Sets TOOL_ERROR_COUNT for backward compatibility.
#   Returns 0 = clean, 1 = errors found.
cgw_run_lint_check() {
  local mode="logged"
  local result_var="CGW_RESULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --result-var)
        result_var="$2"
        shift 2
        ;;
      --result-var=*)
        result_var="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (lint check skipped -- CGW_SKIP_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "Lint" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  if [[ -z "${CGW_LINT_CMD:-}" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (lint check skipped -- CGW_LINT_CMD not set)"
    printf -v "${result_var}" '%s:%s:%s' "Lint" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  get_python_path 2>/dev/null || true
  local lint_bin
  lint_bin=$(cgw_resolve_lint_binary "${CGW_LINT_CMD}")
  local status=0
  if [[ $# -gt 0 ]]; then
    local stripped_args
    stripped_args=$(cgw_strip_path_arg "${CGW_LINT_CHECK_ARGS:-}")
    # shellcheck disable=SC2086  # Word splitting intentional: stripped_args/CGW_LINT_EXCLUDES contain multiple flags
    _cgw_run_pipeline_tool "${mode}" "LINT CHECK" "${logfile:-/dev/null}" "${lint_bin}" ${stripped_args} "$@" ${CGW_LINT_EXCLUDES:-} || status=$?
  else
    local filled_args
    filled_args=$(cgw_fill_path_placeholder "${CGW_LINT_CHECK_ARGS:-}")
    # shellcheck disable=SC2086  # Word splitting intentional: filled_args/CGW_LINT_EXCLUDES contain multiple flags
    _cgw_run_pipeline_tool "${mode}" "LINT CHECK" "${logfile:-/dev/null}" "${lint_bin}" ${filled_args} ${CGW_LINT_EXCLUDES:-} || status=$?
  fi
  local status_str="PASSED"
  [[ ${status} -ne 0 ]] && status_str="FAILED"
  printf -v "${result_var}" '%s:%s:%s' "Lint" "${status_str}" "${TOOL_ERROR_COUNT:-0}"
  return $status
}

# cgw_run_format_check [--mode <logged|plain>] [--result-var <var>] [files...]
#   Runs ${CGW_FORMAT_CMD} format check. Same file-list and skip conventions as
#   cgw_run_lint_check. Returns 0 silently when CGW_FORMAT_CMD is unset.
#   Honors CGW_FORMAT_CHECK_NONBLOCKING=1 (internal knob, not meant to be
#   exported by users) -- when set, a failing check's log-section footer
#   reads "WARN" instead of "FAILED" (via CGW_SECTION_FAIL_LABEL below).
#   Assigns 'Format:status:count' into the result variable (default: CGW_RESULT).
#   The exit code / return value are unaffected either way; callers that
#   want non-blocking behavior (check_lint.sh) decide that separately by
#   not gating their own overall_status on this function's return code.
cgw_run_format_check() {
  local mode="logged"
  local result_var="CGW_RESULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --result-var)
        result_var="$2"
        shift 2
        ;;
      --result-var=*)
        result_var="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    printf -v "${result_var}" '%s:%s:%s' "Format" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  if [[ -z "${CGW_FORMAT_CMD:-}" ]]; then
    printf -v "${result_var}" '%s:%s:%s' "Format" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  get_python_path 2>/dev/null || true
  local format_bin
  format_bin=$(cgw_resolve_lint_binary "${CGW_FORMAT_CMD}")
  # shellcheck disable=SC2034  # read via dynamic scope by log_section_end
  local CGW_SECTION_FAIL_LABEL=""
  [[ "${CGW_FORMAT_CHECK_NONBLOCKING:-0}" == "1" ]] && CGW_SECTION_FAIL_LABEL="WARN"
  local status=0
  if [[ $# -gt 0 ]]; then
    local stripped_args
    stripped_args=$(cgw_strip_path_arg "${CGW_FORMAT_CHECK_ARGS:-}")
    # shellcheck disable=SC2086  # Word splitting intentional: stripped_args/CGW_FORMAT_EXCLUDES contain multiple flags
    _cgw_run_pipeline_tool "${mode}" "FORMAT CHECK" "${logfile:-/dev/null}" "${format_bin}" ${stripped_args} "$@" ${CGW_FORMAT_EXCLUDES:-} || status=$?
  else
    local filled_args
    filled_args=$(cgw_fill_path_placeholder "${CGW_FORMAT_CHECK_ARGS:-}")
    # shellcheck disable=SC2086
    _cgw_run_pipeline_tool "${mode}" "FORMAT CHECK" "${logfile:-/dev/null}" "${format_bin}" ${filled_args} ${CGW_FORMAT_EXCLUDES:-} || status=$?
  fi
  local status_str="PASSED"
  if [[ ${status} -ne 0 ]]; then
    status_str="${CGW_SECTION_FAIL_LABEL:-FAILED}"
  fi
  printf -v "${result_var}" '%s:%s:%s' "Format" "${status_str}" "${TOOL_ERROR_COUNT:-0}"
  return $status
}

# cgw_run_lint_fix [--mode <logged|plain>] [--result-var <var>] [files...]
#   Runs lint --fix then format --fix (bundled, since every caller pairs them).
#   Honors CGW_SKIP_LINT=1. Returns 0 if all fixers exited clean; 1 on any error.
#   Returns 0 when neither CGW_LINT_CMD nor CGW_FORMAT_CMD is set.
#   Assigns 'LintFix:status:count' into the result variable (default: CGW_RESULT).
cgw_run_lint_fix() {
  local mode="logged"
  local result_var="CGW_RESULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --result-var)
        result_var="$2"
        shift 2
        ;;
      --result-var=*)
        result_var="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (lint fix skipped -- CGW_SKIP_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "LintFix" "SKIPPED" "0"
    return 0
  fi
  local fix_failed=0
  if [[ -n "${CGW_LINT_CMD:-}" ]]; then
    get_python_path 2>/dev/null || true
    local lint_bin
    lint_bin=$(cgw_resolve_lint_binary "${CGW_LINT_CMD}")
    if [[ $# -gt 0 ]]; then
      local stripped_args
      stripped_args=$(cgw_strip_path_arg "${CGW_LINT_FIX_ARGS:-}")
      # shellcheck disable=SC2086  # Word splitting intentional: stripped_args/CGW_LINT_EXCLUDES contain multiple flags
      _cgw_run_pipeline_tool "${mode}" "LINT AUTO-FIX" "${logfile:-/dev/null}" "${lint_bin}" ${stripped_args} "$@" ${CGW_LINT_EXCLUDES:-} || fix_failed=1
    else
      local filled_args
      filled_args=$(cgw_fill_path_placeholder "${CGW_LINT_FIX_ARGS:-}")
      # shellcheck disable=SC2086
      _cgw_run_pipeline_tool "${mode}" "LINT AUTO-FIX" "${logfile:-/dev/null}" "${lint_bin}" ${filled_args} ${CGW_LINT_EXCLUDES:-} || fix_failed=1
    fi
  fi
  if [[ -n "${CGW_FORMAT_CMD:-}" ]]; then
    get_python_path 2>/dev/null || true
    local format_bin
    format_bin=$(cgw_resolve_lint_binary "${CGW_FORMAT_CMD}")
    if [[ $# -gt 0 ]]; then
      local stripped_args
      stripped_args=$(cgw_strip_path_arg "${CGW_FORMAT_FIX_ARGS:-}")
      # shellcheck disable=SC2086  # Word splitting intentional: stripped_args/CGW_FORMAT_EXCLUDES contain multiple flags
      _cgw_run_pipeline_tool "${mode}" "FORMAT FIX" "${logfile:-/dev/null}" "${format_bin}" ${stripped_args} "$@" ${CGW_FORMAT_EXCLUDES:-} || fix_failed=1
    else
      local filled_args
      filled_args=$(cgw_fill_path_placeholder "${CGW_FORMAT_FIX_ARGS:-}")
      # shellcheck disable=SC2086
      _cgw_run_pipeline_tool "${mode}" "FORMAT FIX" "${logfile:-/dev/null}" "${format_bin}" ${filled_args} ${CGW_FORMAT_EXCLUDES:-} || fix_failed=1
    fi
  fi
  local status_str="PASSED"
  [[ ${fix_failed} -ne 0 ]] && status_str="FAILED"
  printf -v "${result_var}" '%s:%s:%s' "LintFix" "${status_str}" "0"
  return $fix_failed
}

# cgw_run_markdownlint_check [--mode <logged|plain>] [--result-var <var>] [files...]
#   Runs ${CGW_MARKDOWNLINT_CMD}. Honors CGW_SKIP_MD_LINT=1, CGW_SKIP_LINT=1, and empty
#   CGW_MARKDOWNLINT_CMD (returns 0 silently when unconfigured).
#   Assigns 'Markdown:status:count' into the result variable (default: CGW_RESULT).
#   Returns 0 = clean (or skipped/unconfigured), 1 = errors found, 2 = tool crash.
#   CGW_MARKDOWNLINT_CMD is word-split into an array (not exec'd as a single
#   token) because auto-detection (_config.sh) can resolve it to a multi-word
#   command -- "npx --yes markdownlint-cli2" -- which must reach exec as three
#   argv entries, not one nonexistent binary named with embedded spaces.
cgw_run_markdownlint_check() {
  local mode="logged"
  local result_var="CGW_RESULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --result-var)
        result_var="$2"
        shift 2
        ;;
      --result-var=*)
        result_var="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (markdown lint skipped -- CGW_SKIP_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "Markdown" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  if [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (markdown lint skipped -- CGW_SKIP_MD_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "Markdown" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  if [[ -z "${CGW_MARKDOWNLINT_CMD:-}" ]]; then
    printf -v "${result_var}" '%s:%s:%s' "Markdown" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  # markdownlint-cli2 diagnostics are "file:line[:col] MDxxx/rule ..." -- no
  # trailing colon after the position, so the default file:line:col: pattern
  # counts them as 0 errors.
  # shellcheck disable=SC2034  # read via dynamic scope by run_tool_with_logging
  local CGW_TOOL_ERROR_REGEX='^[^:]+:[0-9]+(:[0-9]+)? [A-Za-z]'
  local -a _md_cmd=()
  read -r -a _md_cmd <<<"${CGW_MARKDOWNLINT_CMD}"
  local _status=0
  if [[ $# -gt 0 ]]; then
    # Scoped: the explicit file list, then flags/exclusions. markdownlint-cli2
    # (globby) resolves glob args in order -- a "!CLAUDE.md" exclusion only
    # removes matches already added by an earlier positive glob, so it MUST
    # come after the target, not before (verified: reversing this order
    # silently stops excluding CLAUDE.md/MEMORY.md from the scan).
    # shellcheck disable=SC2086
    _cgw_run_pipeline_tool "${mode}" "MARKDOWN LINT" "${logfile:-/dev/null}" "${_md_cmd[@]}" "$@" ${CGW_MARKDOWNLINT_ARGS:-} || _status=$?
  else
    # Audit/whole-repo: the default PATHS glob, then flags/exclusions -- same
    # target-before-exclusion ordering as the scoped branch above. PATHS is
    # word-split via read (not left unquoted) so bash's own pathname
    # expansion never touches it -- an unquoted "**/*.md" without globstar
    # silently degrades to "*/*.md" (one directory deep only), passing a
    # partial file list to markdownlint-cli2 instead of its literal glob.
    local -a _md_paths=()
    read -r -a _md_paths <<<"${CGW_MARKDOWNLINT_PATHS:-}"
    # shellcheck disable=SC2086
    _cgw_run_pipeline_tool "${mode}" "MARKDOWN LINT" "${logfile:-/dev/null}" "${_md_cmd[@]}" "${_md_paths[@]}" ${CGW_MARKDOWNLINT_ARGS:-} || _status=$?
  fi
  local ret=0
  local status_str="PASSED"
  if [[ ${_status} -ne 0 ]]; then
    status_str="FAILED"
    if [[ "${TOOL_ERROR_COUNT:-0}" -eq 0 ]]; then
      ret=2
    else
      ret=1
    fi
  fi
  printf -v "${result_var}" '%s:%s:%s' "Markdown" "${status_str}" "${TOOL_ERROR_COUNT:-0}"
  return $ret
}

# cgw_run_markdownlint_fix [--mode <logged|plain>] [--result-var <var>] [files...]
#   Runs ${CGW_MARKDOWNLINT_CMD} ${CGW_MARKDOWNLINT_FIX_ARGS}. Same skip/unset/
#   scoping conventions as cgw_run_markdownlint_check (including the word-split
#   for a multi-word auto-detected command, e.g. the npx fallback).
#   Assigns 'MarkdownFix:status:count' into the result variable (default: CGW_RESULT).
#   Returns 0 = all fixed (or skipped/unconfigured), 1 = unfixable errors remain.
cgw_run_markdownlint_fix() {
  local mode="logged"
  local result_var="CGW_RESULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --result-var)
        result_var="$2"
        shift 2
        ;;
      --result-var=*)
        result_var="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (markdown fix skipped -- CGW_SKIP_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "MarkdownFix" "SKIPPED" "0"
    return 0
  fi
  if [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (markdown fix skipped -- CGW_SKIP_MD_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "MarkdownFix" "SKIPPED" "0"
    return 0
  fi
  [[ -z "${CGW_MARKDOWNLINT_CMD:-}" ]] && {
    printf -v "${result_var}" '%s:%s:%s' "MarkdownFix" "SKIPPED" "0"
    return 0
  }
  # Same diagnostic shape as cgw_run_markdownlint_check -- unfixable errors
  # print as "file:line[:col] MDxxx/rule ..." and must count.
  # shellcheck disable=SC2034  # read via dynamic scope by run_tool_with_logging
  local CGW_TOOL_ERROR_REGEX='^[^:]+:[0-9]+(:[0-9]+)? [A-Za-z]'
  local -a _md_cmd=()
  read -r -a _md_cmd <<<"${CGW_MARKDOWNLINT_CMD}"
  local status=0
  if [[ $# -gt 0 ]]; then
    # --fix is a flag (order-independent); the target file list must still
    # precede the ARGS exclusion globs -- see cgw_run_markdownlint_check.
    # shellcheck disable=SC2086
    _cgw_run_pipeline_tool "${mode}" "MARKDOWN FIX" "${logfile:-/dev/null}" "${_md_cmd[@]}" ${CGW_MARKDOWNLINT_FIX_ARGS:-} "$@" ${CGW_MARKDOWNLINT_ARGS:-} || status=$?
  else
    # PATHS word-split via read, not left unquoted -- see cgw_run_markdownlint_check.
    local -a _md_paths=()
    read -r -a _md_paths <<<"${CGW_MARKDOWNLINT_PATHS:-}"
    # shellcheck disable=SC2086
    _cgw_run_pipeline_tool "${mode}" "MARKDOWN FIX" "${logfile:-/dev/null}" "${_md_cmd[@]}" ${CGW_MARKDOWNLINT_FIX_ARGS:-} "${_md_paths[@]}" ${CGW_MARKDOWNLINT_ARGS:-} || status=$?
  fi
  local status_str="PASSED"
  [[ ${status} -ne 0 ]] && status_str="FAILED"
  printf -v "${result_var}" '%s:%s:%s' "MarkdownFix" "${status_str}" "${TOOL_ERROR_COUNT:-0}"
  return $status
}

# cgw_staged_files_for_md
#   Stdout: newline-separated staged (index) markdown files (added/copied/
#   modified/renamed). Uses --cached because the commit gate lints what is being
#   committed. Outputs nothing when no staged *.md files; caller skips the step.
cgw_staged_files_for_md() {
  git diff --cached --name-only --diff-filter=ACMR -- '*.md'
}

# cgw_modified_files_for_md
#   Stdout: newline-separated markdown files modified/added vs HEAD (working
#   tree, not the index) -- the counterpart to cgw_staged_files_for_md, used by
#   fix_lint.sh --modified-only which operates on disk, not the index. Mirrors
#   cgw_modified_files_for_lint's diff-filter contract (deletions excluded, so
#   a locally deleted file is never re-created by --fix).
cgw_modified_files_for_md() {
  git diff --name-only --diff-filter=ACMR HEAD -- '*.md'
}

# cgw_staged_files_for_lint
#   Stdout: newline-separated staged (index) files matching CGW_LINT_EXTENSIONS
#   (default *.py). The commit gate's code-quality checks must scope to what is
#   being committed — not the whole repo — so an unrelated file's lint error
#   can't block the commit and auto-fix can't rewrite files outside the commit.
cgw_staged_files_for_lint() {
  local -a lint_exts
  read -r -a lint_exts <<<"${CGW_LINT_EXTENSIONS:-*.py}"
  git diff --cached --name-only --diff-filter=ACMR -- "${lint_exts[@]}"
}

# cgw_path_is_diff_blind <path>
#   0 (true) when the index entry for <path> carries assume-unchanged or
#   skip-worktree -- `git diff` / `git status` report such paths clean no
#   matter what's on disk, so their verdict can't be trusted as a second
#   opinion. `git ls-files -v` tags: lowercase letter == assume-unchanged,
#   'S' == skip-worktree (verified empirically; not documented in git-ls-files(1)
#   beyond "lower case letter means assume-unchanged").
cgw_path_is_diff_blind() {
  local _tag
  _tag=$(git ls-files -v -- "$1" 2>/dev/null | head -1 | cut -c1)
  [[ "${_tag}" == [a-z] || "${_tag}" == "S" ]]
}

# cgw_paths_diverging_from_index
#   Stdin: newline-separated staged paths to check. Stdout: the subset whose
#   WORKING-TREE content differs from what is currently staged. Exists
#   because the commit gate's lint/format checks read files from disk
#   (working tree) while `git commit` records the index -- when the two
#   differ, CGW can validate one thing and commit another, silently. Primary
#   detection uses pure git plumbing (tool-agnostic): `git hash-object
#   --path=<f> <f>` computes the blob `git add` would produce from a CLEAN
#   file, and is immune to skip-worktree/assume-unchanged (unlike `git diff`,
#   which reads the index and skips those paths). BUT hash-object never reads
#   the index, while `git add` does: for text=auto/core.autocrlf, git add
#   preserves CRLF verbatim once the index blob already contains CRLF
#   (convert.c: has_crlf_in_index() -- cleared only by an explicit
#   `git add --renormalize`). On such a file hash-object permanently
#   disagrees with a byte-identical, `git add`-clean disk file. So a
#   hash-object mismatch is arbitrated with an index-aware `git diff --quiet`
#   before being reported -- except on diff-blind paths, where hash-object is
#   the only honest signal. Returns 0 if any path diverges, 1 if none do.
#   Fails closed: a staged path that's missing from the working tree, or
#   whose blob can't be hashed, is reported as diverged rather than skipped --
#   nothing validated that path's content, so a stale staged blob must not
#   commit silently.
#   Generalized from a lint-only predicate so every caller (the lint gate,
#   commit_enhanced.sh's partial-stage snapshot, the [3.5] congruence guard)
#   shares one arbitration instead of re-deriving the CRLF landmine handling.
cgw_paths_diverging_from_index() {
  local _f _staged _disk _any=1
  while IFS= read -r _f; do
    [[ -z "${_f}" ]] && continue
    _staged=$(git rev-parse --quiet --verify ":${_f}" 2>/dev/null) || continue
    if [[ ! -f "${_f}" ]]; then
      printf '%s\n' "${_f}"
      _any=0
      continue
    fi
    _disk=$(git hash-object --path="${_f}" -- "${_f}" 2>/dev/null)
    if [[ -z "${_disk}" || "${_staged}" != "${_disk}" ]]; then
      # Second opinion: if the index blob already carries CRLF that `git add`
      # preserves forever, hash-object's renormalized hash will never match --
      # a phantom divergence no re-stage can clear. `git diff --quiet` uses the
      # same index-aware conversion `git add` would, so trust it when it CAN
      # see the path (not diff-blind) and hash-object did produce a hash.
      if [[ -n "${_disk}" ]] && ! cgw_path_is_diff_blind "${_f}" &&
        git diff --quiet -- "${_f}" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "${_f}"
      _any=0
    fi
  done
  return "${_any}"
}

# cgw_lint_files_diverging_from_index
#   Stdout: newline-separated staged lint-eligible files whose WORKING-TREE
#   content differs from what is currently staged. Thin wrapper over
#   cgw_paths_diverging_from_index scoped to cgw_staged_files_for_lint (see
#   that function's header for the divergence-detection rationale). Returns 0
#   if any file diverges, 1 if none do.
cgw_lint_files_diverging_from_index() {
  cgw_staged_files_for_lint | cgw_paths_diverging_from_index
}

# cgw_staged_paths_diverging_from_index
#   Stdout: ALL staged (add/copy/modify/rename) paths whose working-tree
#   content differs from what is staged -- not just lint-eligible ones. Used
#   by commit_enhanced.sh to snapshot which originally-staged files are
#   PARTIALLY staged (the moral equivalent of `git add -p` picking one hunk),
#   so an auto-fix re-stage can skip them instead of promoting the whole
#   working-tree file -- and silently absorbing unstaged content -- into the
#   index. Returns 0 if any path diverges, 1 if none do.
cgw_staged_paths_diverging_from_index() {
  git diff --cached --name-only --diff-filter=ACMR | cgw_paths_diverging_from_index
}

# cgw_validated_path_set [md_skipped]
#   Stdout: newline-separated staged paths this run's code-quality gate
#   actually validated -- staged CGW_LINT_EXTENSIONS files when a code
#   checker is actually configured (CGW_LINT_CMD or CGW_FORMAT_CMD non-empty;
#   extension match alone decides scope, same as cgw_staged_files_for_lint,
#   so this still covers a format-only run with CGW_LINT_CMD unset) plus
#   staged *.md when markdownlint genuinely runs. Markdown is EXCLUDED when
#   any of: the caller passes md_skipped=1, CGW_SKIP_MD_LINT=1, or
#   CGW_MARKDOWNLINT_CMD is empty.
#
#   The argument exists because commit_enhanced.sh's --skip-md-lint /
#   --skip-lint set only a main() local -- an unexported, function-scoped
#   decision this script-level function cannot see. Forwarding it explicitly
#   follows the repo convention (fix_lint.sh's check_lint.sh flag
#   forwarding): a runtime decision is never written back into a CGW_* config
#   var. The CGW_SKIP_MD_LINT clause is load-bearing for callers with no flag
#   parser -- do not drop it as "redundant" with the argument.
#
#   Omitting the argument defaults to 0 ("markdown ran"), deliberately the
#   conservative direction: over-reporting divergence fails a commit closed
#   (noisy but safe), under-reporting would commit unvalidated content
#   silently.
#
#   Returns 0 unconditionally -- both call sites in commit_enhanced.sh pipe
#   this under `set -o pipefail`, where a non-zero status is read as
#   "diverged". Do not "simplify" the md clause to a trailing
#   `[[ cond ]] && cgw_staged_files_for_md`; that returns 1 whenever markdown
#   is skipped and poisons the pipeline.
#
#   Backs the [3.5] congruence guard: divergence outside this set is ordinary
#   partial staging CGW never inspected, not a validation gap, so it must not
#   be re-staged or reported.
cgw_validated_path_set() {
  local _md_skipped="${1:-0}"
  if [[ -n "${CGW_LINT_CMD:-}" ]] || [[ -n "${CGW_FORMAT_CMD:-}" ]]; then
    cgw_staged_files_for_lint
  fi
  if [[ "${_md_skipped}" != "1" ]] &&
    [[ "${CGW_SKIP_MD_LINT:-0}" != "1" ]] &&
    [[ -n "${CGW_MARKDOWNLINT_CMD:-}" ]]; then
    cgw_staged_files_for_md
  fi
}

# cgw_crlf_in_index_files
#   Stdout: tracked paths whose INDEX blob is not in the normalized form the
#   repo's current filters (.gitattributes eol=, core.autocrlf) would produce
#   -- i.e. CRLF retained in the index where conversion is active. `git add`
#   preserves that CRLF forever once it's in the index; only an explicit
#   `git add --renormalize <path>` clears it. This is what makes such files a
#   landmine for cgw_lint_files_diverging_from_index's arbiter above.
#   Pre-filtered to `git ls-files --eol`'s "i/crlf" entries -- normalization
#   only ever strips CR, so nothing else can differ; binary blobs compare
#   equal to themselves and drop out for free. Advisory/read-only: used by
#   repo_health.sh, never by the commit gate.
cgw_crlf_in_index_files() {
  local _rec _f _blob _norm
  while IFS= read -r -d '' _rec; do
    [[ "${_rec}" == i/crlf* ]] || continue
    _f="${_rec#*$'\t'}"
    _blob=$(git rev-parse --quiet --verify ":${_f}" 2>/dev/null) || continue
    _norm=$(git cat-file blob "${_blob}" 2>/dev/null |
      git hash-object --stdin --path="${_f}" 2>/dev/null)
    [[ -n "${_norm}" && "${_norm}" != "${_blob}" ]] && printf '%s\n' "${_f}"
  done < <(git ls-files --eol -z)
}

# cgw_run_typecheck [--mode <logged|plain>] [--result-var <var>] [files...]
#   Runs ${CGW_TYPECHECK_CMD} against the project (no files) or a given file
#   list (strips trailing path token from CGW_TYPECHECK_CHECK_ARGS when files
#   given). Honors CGW_SKIP_TYPECHECK=1, CGW_SKIP_LINT=1, and empty CGW_TYPECHECK_CMD
#   (returns 0, emits skip line).
#   Assigns 'Typecheck:status:count' into the result variable (default: CGW_RESULT).
#   Sets TOOL_ERROR_COUNT for backward compatibility.
#   Returns 0 = clean, 1 = errors found.
#
#   Overrides CGW_TOOL_ERROR_REGEX (see run_tool_with_logging) because the
#   default ruff-shaped `^[^:]+:[0-9]+:[0-9]+:` misses every supported
#   typechecker's real output: mypy omits the column by default
#   (`file.py:10: error:`), pyright indents and uses ` - error:`
#   (`  /p/file.py:10:5 - error:`), and pyrefly's diagnostic line carries no
#   file/line at all -- it prints `ERROR <msg> [<code>]` with the location on
#   the *next* line (` --> file.py:10:8`). Verified against real 1.0.0/1.3.0
#   pyrefly, mypy, and pyright output (2026-09-12); tsc's documented
#   `file.ts(10,5): error TS2322:` form is covered by the first alternative.
# shellcheck disable=SC2120  # all arguments are optional flags
cgw_run_typecheck() {
  local mode="logged"
  local result_var="CGW_RESULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --result-var)
        result_var="$2"
        shift 2
        ;;
      --result-var=*)
        result_var="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (typecheck skipped -- CGW_SKIP_LINT=1)"
    printf -v "${result_var}" '%s:%s:%s' "Typecheck" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  if [[ "${CGW_SKIP_TYPECHECK:-0}" == "1" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (typecheck skipped -- CGW_SKIP_TYPECHECK=1)"
    printf -v "${result_var}" '%s:%s:%s' "Typecheck" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  if [[ -z "${CGW_TYPECHECK_CMD:-}" ]]; then
    [[ "${mode}" != "plain" ]] && echo "  (typecheck skipped -- CGW_TYPECHECK_CMD not set)"
    printf -v "${result_var}" '%s:%s:%s' "Typecheck" "SKIPPED" "0"
    TOOL_ERROR_COUNT=0
    return 0
  fi
  get_python_path 2>/dev/null || true
  local tc_bin
  tc_bin=$(cgw_resolve_lint_binary "${CGW_TYPECHECK_CMD}")
  # shellcheck disable=SC2034  # read via dynamic scope by run_tool_with_logging
  local CGW_TOOL_ERROR_REGEX='^[[:space:]]*[^[:space:]]+[:(][0-9]+[,:)][^[:space:]]*[[:space:]]*(-[[:space:]]+)?error|^ERROR[[:space:]]'
  local status=0
  if [[ $# -gt 0 ]]; then
    local stripped_args
    stripped_args=$(cgw_strip_path_arg "${CGW_TYPECHECK_CHECK_ARGS-check}")
    # shellcheck disable=SC2086  # Word splitting intentional: stripped_args contains multiple flags
    _cgw_run_pipeline_tool "${mode}" "TYPECHECK" "${logfile:-/dev/null}" "${tc_bin}" ${stripped_args} "$@" || status=$?
  else
    local filled_args
    filled_args=$(cgw_fill_path_placeholder "${CGW_TYPECHECK_CHECK_ARGS-check}")
    # shellcheck disable=SC2086  # Word splitting intentional: filled_args/CGW_TYPECHECK_EXCLUDES contain multiple flags
    _cgw_run_pipeline_tool "${mode}" "TYPECHECK" "${logfile:-/dev/null}" "${tc_bin}" ${filled_args} ${CGW_TYPECHECK_EXCLUDES:-} || status=$?
  fi
  local status_str="PASSED"
  [[ ${status} -ne 0 ]] && status_str="FAILED"
  printf -v "${result_var}" '%s:%s:%s' "Typecheck" "${status_str}" "${TOOL_ERROR_COUNT:-0}"
  return $status
}
