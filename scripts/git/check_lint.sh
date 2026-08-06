#!/usr/bin/env bash
# check_lint.sh - Lint validation (read-only, no modifications)
# Purpose: Check code quality without making changes
# Usage: ./scripts/git/check_lint.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
#   CGW_LINT_CMD   - Lint tool to use (default: ruff; empty = skip)
# Returns:
#   0 on lint pass, 1 on lint errors

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

main() {
  local modified_only=0
  local skip_lint=0
  local skip_md_lint=0
  local md_only=0

  [[ "${CGW_SKIP_LINT:-0}" == "1" ]] && skip_lint=1 && skip_md_lint=1
  [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]] && skip_md_lint=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/check_lint.sh [OPTIONS]"
        echo ""
        echo "Run lint and format checks (read-only, no modifications)."
        echo ""
        echo "Options:"
        echo "  --modified-only   Only check files modified vs HEAD"
        echo "  --no-venv         Use system lint tool instead of .venv"
        echo "  --skip-lint       Skip all lint checks"
        echo "  --skip-md-lint    Skip markdown lint only (CGW_MARKDOWNLINT_CMD step)"
        echo "  --md-only         Only check markdown (skip code lint + format)"
        echo "  -h, --help        Show this help"
        echo ""
        echo "Environment:"
        echo "  CGW_NO_VENV=1          Same as --no-venv"
        echo "  CGW_SKIP_LINT=1        Same as --skip-lint"
        echo "  CGW_SKIP_MD_LINT=1     Same as --skip-md-lint"
        echo "  CGW_LINT_CMD=<tool>    Override lint tool (default: ruff)"
        echo "  (Also: CLAUDE_GIT_NO_VENV)"
        exit 0
        ;;
      --no-venv)
        CGW_NO_VENV=1
        SKIP_VENV=1
        shift
        ;;
      --modified-only)
        modified_only=1
        shift
        ;;
      --skip-lint)
        skip_lint=1
        skip_md_lint=1
        shift
        ;;
      --skip-md-lint)
        skip_md_lint=1
        shift
        ;;
      --md-only)
        md_only=1
        shift
        ;;
      *)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ ${skip_md_lint} -eq 1 ]] && [[ ${md_only} -eq 1 ]]; then
    echo "[ERROR] --skip-md-lint and --md-only are mutually exclusive" >&2
    exit 1
  fi

  if [[ ${modified_only} -eq 1 ]] && [[ ${md_only} -eq 1 ]]; then
    echo "[ERROR] --modified-only and --md-only are not supported together (--modified-only has no markdown-only path)" >&2
    exit 1
  fi

  if [[ ${skip_lint} -eq 1 ]]; then
    echo "[OK] All lint checks skipped (--skip-lint)"
    exit 0
  fi

  if [[ -z "${CGW_LINT_CMD}" ]] && [[ -z "${CGW_FORMAT_CMD}" ]] && [[ -z "${CGW_MARKDOWNLINT_CMD}" ]]; then
    echo "[OK] All lint checks skipped (CGW_LINT_CMD, CGW_FORMAT_CMD, and CGW_MARKDOWNLINT_CMD not set)"
    exit 0
  fi

  if [[ ${md_only} -eq 1 ]] && [[ -z "${CGW_MARKDOWNLINT_CMD}" ]]; then
    echo "[OK] Markdown lint skipped (CGW_MARKDOWNLINT_CMD not set)"
    exit 0
  fi

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # Handle --modified-only mode (direct output, no section logging)
  if [[ "${modified_only}" -eq 1 ]]; then
    if [[ -z "${CGW_LINT_CMD}" ]]; then
      echo "[OK] No code lint tool configured for --modified-only (CGW_LINT_CMD not set)"
      exit 0
    fi
    local modified_files
    modified_files=$(cgw_modified_files_for_lint)
    if [[ -z "$modified_files" ]]; then
      echo "[OK] No modified files to check"
      exit 0
    fi

    echo "=== Modified-Only Lint Check ==="
    echo "Files: $modified_files"
    echo ""

    get_python_path 2>/dev/null || true
    local lint_bin
    lint_bin=$(cgw_resolve_lint_binary "${CGW_LINT_CMD}")

    local EXIT_CODE=0

    echo "[LINT CHECK]"
    local lint_check_cmd_args
    lint_check_cmd_args=$(cgw_strip_path_arg "${CGW_LINT_CHECK_ARGS}")
    # shellcheck disable=SC2086
    "${lint_bin}" ${lint_check_cmd_args} $modified_files || EXIT_CODE=1

    if [[ -n "${CGW_FORMAT_CMD}" ]]; then
      echo ""
      echo "[FORMAT CHECK]"
      local fmt_check_cmd_args
      fmt_check_cmd_args=$(cgw_strip_path_arg "${CGW_FORMAT_CHECK_ARGS}")
      # Non-blocking: mirrors full-mode (overall_status gates on lint+markdown
      # only) and CI's shfmt continue-on-error. A format diff is reported but
      # never gates the exit code -- only the lint step above does.
      # shellcheck disable=SC2086
      if ! "${CGW_FORMAT_CMD}" ${fmt_check_cmd_args} $modified_files; then
        echo "[WARN] Format issues found (non-blocking) -- run fix_lint.sh to auto-format"
      fi
    fi

    exit $EXIT_CODE
  fi

  # Full lint check with logging
  init_logging "check_lint"

  local script_start
  script_start=$(date +%s)

  {
    echo "========================================="
    echo "Lint Validation Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
    echo "Lint tool: ${CGW_LINT_CMD}"
  } >"$logfile"

  local -a results=()
  local lint_status=0 format_status=0 md_lint_status=0

  if [[ ${md_only} -eq 0 ]]; then
    # LINT CHECK
    local lint_start lint_end lint_duration lint_status_str
    lint_start=$(date +%s)
    cgw_run_lint_check || lint_status=1
    lint_end=$(date +%s)
    lint_duration=$((lint_end - lint_start))
    if [[ -n "${CGW_LINT_CMD}" ]]; then
      lint_status_str="PASSED"
      [[ ${lint_status} -ne 0 ]] && lint_status_str="FAILED"
      results+=("Lint:${lint_status_str}:${TOOL_ERROR_COUNT}:${lint_duration}")
    fi

    # FORMAT CHECK
    # Non-blocking: mirrors the CI workflow's `continue-on-error: true` on the
    # shfmt step (.github/workflows/branch-protection.yml), present since that
    # workflow's introduction. A format diff is reported but never gates
    # overall_status or the exit code -- only lint and markdown-lint do.
    local format_start format_end format_duration format_status_str
    format_start=$(date +%s)
    CGW_FORMAT_CHECK_NONBLOCKING=1 cgw_run_format_check || format_status=1
    format_end=$(date +%s)
    format_duration=$((format_end - format_start))
    if [[ -n "${CGW_FORMAT_CMD}" ]]; then
      format_status_str="PASSED"
      [[ ${format_status} -ne 0 ]] && format_status_str="WARN"
      results+=("Format:${format_status_str}:${TOOL_ERROR_COUNT}:${format_duration}")
    fi
  else
    echo "  (code lint + format skipped -- --md-only)" | tee -a "$logfile"
  fi

  # MARKDOWN LINT
  if [[ ${skip_md_lint} -eq 1 ]]; then
    echo "  (markdown lint skipped -- --skip-md-lint)" | tee -a "$logfile"
  else
    local md_start md_end md_duration md_status_str
    md_start=$(date +%s)
    cgw_run_markdownlint_check || md_lint_status=1
    md_end=$(date +%s)
    md_duration=$((md_end - md_start))
    if [[ -n "${CGW_MARKDOWNLINT_CMD}" ]]; then
      md_status_str="PASSED"
      [[ ${md_lint_status} -ne 0 ]] && md_status_str="FAILED"
      results+=("Markdown:${md_status_str}:${TOOL_ERROR_COUNT}:${md_duration}")
    fi
  fi

  log_summary_table "$logfile" "${results[@]}"

  # A FAILED row with 0 parsed errors means the tool exited non-zero without
  # emitting any file:line diagnostics -- a tool/config failure (missing
  # binary, bad flags, crash), not counted lint errors. Name that explicitly
  # instead of leaving "FAILED ... 0 errors" to self-contradict.
  local _row _row_name _row_status _row_errors _row_rest
  for _row in "${results[@]}"; do
    IFS=':' read -r _row_name _row_status _row_errors _row_rest <<<"${_row}"
    if [[ "${_row_status}" == "FAILED" ]] && [[ "${_row_errors}" == "0" ]]; then
      echo "[!] ${_row_name}: tool exited non-zero but no lint diagnostics were parsed -- likely a tool/config failure, not code errors (see log)" | tee -a "$logfile"
    fi
  done

  local script_end total_duration overall_status
  script_end=$(date +%s)
  total_duration=$((script_end - script_start))

  if [[ $lint_status -eq 0 ]] && [[ $md_lint_status -eq 0 ]]; then
    overall_status="PASSED"
  else
    overall_status="FAILED"
  fi

  {
    echo ""
    echo "End Time: $(date)"
    echo "Total Duration: ${total_duration}s"
    echo "STATUS: $overall_status"
  } | tee -a "$logfile"

  echo ""
  echo "Full log: $logfile"

  [[ "$overall_status" == "PASSED" ]] && exit 0 || exit 1
}

main "$@"
