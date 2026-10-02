#!/usr/bin/env bash
# fix_lint.sh - Auto-fix lint issues
# Purpose: Run lint auto-fix and formatting
# Usage: ./scripts/git/fix_lint.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
#   CGW_LINT_CMD   - Lint tool to use (default: ruff; empty = skip)
#   CGW_MARKDOWNLINT_CMD - Markdown lint tool; auto-detected if unset (see _config.sh)
# Returns:
#   0 on success, 1 if issues remain after fix

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

main() {
  local non_interactive=0
  local modified_only=0
  local skip_md_lint=0
  local md_only=0

  for arg in "$@"; do
    case "$arg" in
      --help | -h)
        echo "Usage: ./scripts/git/fix_lint.sh [OPTIONS]"
        echo ""
        echo "Auto-fix lint issues using configured lint tool(s)."
        echo ""
        echo "Options:"
        echo "  --modified-only     Only fix files modified vs HEAD"
        echo "  --skip-md-lint      Skip markdown auto-fix"
        echo "  --md-only           Only run markdown auto-fix (skip code lint)"
        echo "  --non-interactive   Skip prompts"
        echo "  --no-venv           Use system lint tool instead of .venv"
        echo "  -h, --help          Show this help"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
        echo "  CGW_NO_VENV=1           Same as --no-venv"
        echo "  CGW_SKIP_MD_LINT=1      Same as --skip-md-lint"
        echo "  CGW_MARKDOWNLINT_CMD    Markdown tool; auto-detected if unset"
        echo "  (Also: CLAUDE_GIT_NON_INTERACTIVE, CLAUDE_GIT_NO_VENV)"
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      --no-venv)
        CGW_NO_VENV=1
        SKIP_VENV=1
        ;;
      --modified-only)
        modified_only=1
        ;;
      --skip-md-lint)
        skip_md_lint=1
        ;;
      --md-only)
        md_only=1
        ;;
      *)
        echo "[ERROR] Unknown flag: $arg" >&2
        exit 1
        ;;
    esac
  done

  # Query the lint pipeline plan
  local plan
  if ! plan=$(cgw_lint_plan fix "$@"); then
    exit 1
  fi

  local lint_act="" lint_reason=""
  local format_act="" format_reason=""
  local md_act="" md_reason=""
  local _step _act _rsn
  while IFS=: read -r _step _act _rsn; do
    case "$_step" in
      lint)
        lint_act="$_act"
        lint_reason="$_rsn"
        ;;
      format)
        format_act="$_act"
        format_reason="$_rsn"
        ;;
      typecheck) ;; # shared plan format; fix_lint has no typecheck step
      markdown)
        md_act="$_act"
        md_reason="$_rsn"
        ;;
    esac
  done <<<"${plan}"

  if [[ "$lint_act" == "skip" && "$format_act" == "skip" && "$md_act" == "skip" ]]; then
    if [[ "$lint_reason" == "CGW_LINT_CMD not set" && "$format_reason" == "CGW_FORMAT_CMD not set" && "$md_reason" == "CGW_MARKDOWNLINT_CMD not set" ]]; then
      echo "[OK] Lint fix skipped (CGW_LINT_CMD, CGW_FORMAT_CMD, and CGW_MARKDOWNLINT_CMD not set)"
      exit 0
    elif [[ "$lint_reason" == "--skip-lint" || "$lint_reason" == "CGW_SKIP_LINT=1" ]]; then
      echo "[OK] Lint fix skipped (${lint_reason})"
      exit 0
    fi
  fi

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  get_lint_exclusions

  # Handle --modified-only mode (lint pipeline scoped to the modified files; console only)
  if [[ "${modified_only}" -eq 1 ]]; then
    local EXIT_CODE=0
    local ran_something=0

    if [[ "$lint_act" == "run" || "$format_act" == "run" ]]; then
      local modified_files
      modified_files=$(cgw_modified_files_for_lint)
      if [[ -n "$modified_files" ]]; then
        ran_something=1
        echo "=== Modified-Only Lint Fix ==="
        echo "Files: $modified_files"
        echo ""

        local -a files=()
        read -r -a files <<<"${modified_files}"
        # Same lint pipeline as full mode, scoped to the modified files:
        # lint --fix then format --fix, each skipped when its tool is unset.
        # Section output goes to the console only (no log file in this mode).
        cgw_run_lint_fix "${files[@]}" || EXIT_CODE=1
      fi
    fi

    if [[ "$md_act" == "run" ]]; then
      local modified_md
      modified_md=$(cgw_modified_files_for_md)
      if [[ -n "$modified_md" ]]; then
        ran_something=1
        local -a modified_md_arr=()
        local md_f
        while IFS= read -r md_f; do
          [[ -n "${md_f}" ]] && modified_md_arr+=("${md_f}")
        done <<<"$modified_md"

        echo ""
        echo "=== Modified-Only Markdown Fix ==="
        echo "Files: $modified_md"
        echo ""
        echo "[MARKDOWN FIX]"
        cgw_run_markdownlint_fix "${modified_md_arr[@]}" || EXIT_CODE=1
      fi
    fi

    if [[ "${ran_something}" -eq 0 ]]; then
      echo "[OK] No modified files to fix"
    fi

    exit $EXIT_CODE
  fi

  # Full fix with logging
  init_logging "fix_lint"

  local script_start
  script_start=$(date +%s)

  {
    echo "========================================="
    echo "Lint Auto-Fix Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
    echo "Lint tool: ${CGW_LINT_CMD}"
    echo "Markdown tool: ${CGW_MARKDOWNLINT_CMD}"
    echo "Mode: $([[ ${non_interactive} -eq 1 ]] && echo 'Non-interactive' || echo 'Interactive')"
  } >"$logfile"

  local fix_failed=0

  if [[ "$lint_act" == "run" || "$format_act" == "run" ]]; then
    cgw_run_lint_fix || {
      echo "[!] Lint tool: some issues may not be auto-fixable" | tee -a "$logfile"
      fix_failed=1
    }
  fi

  if [[ "$md_act" == "run" ]]; then
    cgw_run_markdownlint_fix || {
      echo "[!] Markdown lint: some issues may not be auto-fixable" | tee -a "$logfile"
      fix_failed=1
    }
  fi

  {
    echo ""
    echo "========================================"
    echo "[FIX SUMMARY]"
    echo "========================================"
  } | tee -a "$logfile"

  if ((fix_failed == 0)); then
    echo "[OK] All lint fixes applied successfully!" | tee -a "$logfile"
  else
    echo "[!] Some issues remain -- check output above" | tee -a "$logfile"
  fi

  # Run final verification
  echo "" | tee -a "$logfile"
  echo "Running final verification..." | tee -a "$logfile"

  # check_lint.sh runs in a separate process; this shell's CGW_NO_VENV/SKIP_VENV
  # and skip choices are unexported assignments and do not cross that boundary.
  # Forward them as explicit flags (same pattern as push_validated.sh).
  local -a verify_args=()
  if [[ "${CGW_NO_VENV:-0}" == "1" ]] || [[ "${SKIP_VENV:-0}" == "1" ]]; then
    verify_args+=("--no-venv")
  fi
  [[ ${skip_md_lint} -eq 1 ]] && verify_args+=("--skip-md-lint")
  [[ ${md_only} -eq 1 ]] && verify_args+=("--md-only")

  local verify_output verify_status
  verify_output=$(bash "${SCRIPT_DIR}/check_lint.sh" "${verify_args[@]+"${verify_args[@]}"}" 2>&1)
  verify_status=$?
  printf '%s\n' "${verify_output}" | tee -a "$logfile"

  if [[ ${verify_status} -eq 0 ]]; then
    echo "[OK] All lint checks pass!" | tee -a "$logfile"
  else
    echo "[!] Some issues remain -- manual fixes may be required" | tee -a "$logfile"
    # Surface the unfixable diagnostics (file:line[:col] rule) as a distilled
    # list so the next manual step is visible without digging through the
    # full log -- "cannot auto-fix" with no target list is a dead end.
    local remaining
    remaining=$(printf '%s\n' "${verify_output}" | grep -E "^[^:]+:[0-9]+(:[0-9]+)?[: ]" | head -20)
    if [[ -n "${remaining}" ]]; then
      {
        echo ""
        echo "Remaining issues needing manual fixes:"
        printf '%s\n' "${remaining}" | sed 's/^/  /'
      } | tee -a "$logfile"
    fi
  fi

  local script_end total_duration
  script_end=$(date +%s)
  total_duration=$((script_end - script_start))

  {
    echo ""
    echo "End Time: $(date)"
    echo "Total Duration: ${total_duration}s"
  } | tee -a "$logfile"

  echo ""
  echo "Full log: $logfile"
}

main "$@"
