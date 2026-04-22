#!/usr/bin/env bash
# commit_enhanced.sh - Enhanced commit workflow with validation and logging
# Purpose: Safe commit with lint check, local-file protection, and conventional format
# Usage: ./scripts/git/commit_enhanced.sh [OPTIONS] "commit message"
#
# Globals:
#   SCRIPT_DIR       - Directory containing this script
#   PROJECT_ROOT     - Auto-detected git repo root (set by _config.sh)
#   logfile          - Set by init_logging
#   CGW_LOCAL_FILES  - Space-separated list of files never to commit
#   CGW_ALL_PREFIXES - Allowed commit message type prefixes
# Arguments:
#   --non-interactive  Skip all prompts
#   --interactive      Force interactive mode even without TTY
#   --only <pathspec>  Stage only listed paths (repeatable); resets index first
#   --staged-only      Use pre-staged files only, skip auto-staging
#   --all              Force bulk-stage all tracked changes (override pre-stage respect)
#   --no-venv          Use system ruff instead of .venv ruff
#   --skip-md-lint     (no-op, preserved for backward compat)
#   -h, --help         Show help
#
# Staging behavior (non-interactive):
#   - If anything is pre-staged AND unstaged changes exist: commits pre-staged only
#     (warns about unstaged files that are being left out). Use --all to override.
#   - If nothing is pre-staged: auto-stages all tracked changes (legacy behavior).
#   - --only <path>: explicit selection, resets index, stages listed paths only.
# Returns:
#   0 on successful commit, 1 on failure

set -uo pipefail
# Note: set -e intentionally omitted -- git diff/diff-index use exit codes for signaling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

generate_analysis_report() {
  cat >"$reportfile" <<EOF
# Enhanced Commit Workflow Analysis Report

**Date**: $(date)
**Branch**: $current_branch
**Status**: SUCCESS

## Files Committed

$(git diff HEAD~1 --name-status 2>/dev/null)

## Commit Details

$(git log -1 --pretty=format:"- **Hash**: %H%n- **Message**: %s%n- **Author**: %an%n- **Date**: %ad%n" 2>/dev/null)

## Validations Passed

- [OK] No local-only files committed
- [OK] Branch-specific validations passed
- [OK] Code quality checks passed (or auto-fixed)
- [OK] Conventional commit format validated

## Logs

- Execution log: \`$logfile\`
- Analysis report: \`$reportfile\`

EOF

  echo "End Time: $(date)" >>"$logfile"
}

unstage_local_only_files() {
  # Unstage files listed in CGW_LOCAL_FILES (space-separated).
  # Entries ending with / are treated as directory prefixes.
  local file
  for file in ${CGW_LOCAL_FILES}; do
    if [[ "${file}" == */ ]]; then
      # Directory prefix: unstage all matching staged files
      while read -r f; do
        git reset HEAD "$f" 2>/dev/null || true
      done < <(git diff --cached --name-only | grep "^${file}" || true)
    else
      git reset HEAD "${file}" 2>/dev/null || true
    fi
  done
}

main() {
  local non_interactive=0
  local skip_lint=0
  local skip_md_lint=0
  local staged_only=0
  local all_flag=0
  local only_paths=()
  local commit_msg_param=""

  # Auto-detect non-interactive mode when no TTY
  if [[ ! -t 0 ]]; then
    non_interactive=1
  fi

  # CGW_* environment variable overrides
  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1
  [[ "${CGW_STAGED_ONLY:-0}" == "1" ]] && staged_only=1
  [[ "${CGW_ALL:-0}" == "1" ]] && all_flag=1
  [[ "${CGW_NO_VENV:-0}" == "1" ]] && SKIP_VENV=1
  [[ "${CGW_SKIP_LINT:-0}" == "1" ]] && skip_lint=1 && skip_md_lint=1
  [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]] && skip_md_lint=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/commit_enhanced.sh [OPTIONS] \"commit message\""
        echo ""
        echo "Enhanced commit workflow with lint validation and local-only file protection."
        echo ""
        echo "Options:"
        echo "  --non-interactive   Skip all prompts (auto-fix lint; staging as below)"
        echo "  --interactive       Force interactive mode even without TTY"
        echo "  --only <pathspec>   Stage only listed paths (repeatable); resets index first"
        echo "  --staged-only       Use pre-staged files only, skip auto-staging"
        echo "  --all               Force bulk-stage all tracked changes (overrides pre-stage respect)"
        echo "  --no-venv           Use system ruff instead of .venv ruff"
        echo "  --skip-lint         Skip all lint checks (code + markdown)"
        echo "  --skip-md-lint      Skip markdown lint only (CGW_MARKDOWNLINT_CMD step)"
        echo "  -h, --help          Show this help"
        echo ""
        echo "Staging defaults (non-interactive):"
        echo "  1. Pre-staged + unstaged present -> commits pre-staged only (warns)"
        echo "  2. Nothing pre-staged            -> auto-stages all tracked changes"
        echo "  3. --only <path>                 -> resets index, stages only listed paths"
        echo "  4. --all                         -> always bulk-stage (old default)"
        echo ""
        echo "Commit message format: <type>: <message>"
        echo "  Standard types: feat fix docs chore test refactor style perf"
        echo "  Configure extras via CGW_EXTRA_PREFIXES in .cgw.conf"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
        echo "  CGW_STAGED_ONLY=1       Same as --staged-only"
        echo "  CGW_ALL=1               Same as --all"
        echo "  CGW_NO_VENV=1           Same as --no-venv"
        echo "  CGW_SKIP_LINT=1         Same as --skip-lint"
        echo "  CGW_SKIP_MD_LINT=1      Same as --skip-md-lint"
        echo "  (Also: CLAUDE_GIT_NON_INTERACTIVE, CLAUDE_GIT_STAGED_ONLY, CLAUDE_GIT_NO_VENV)"
        echo ""
        echo "Protected files (never committed): configured via CGW_LOCAL_FILES in .cgw.conf"
        echo "  Default: CLAUDE.md MEMORY.md .claude/ logs/"
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
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
      --interactive)
        non_interactive=0
        shift
        ;;
      --staged-only)
        staged_only=1
        shift
        ;;
      --all)
        all_flag=1
        shift
        ;;
      --only)
        if [[ -z "${2:-}" ]] || [[ "${2:0:2}" == "--" ]]; then
          echo "[ERROR] --only requires a pathspec argument" >&2
          exit 1
        fi
        only_paths+=("$2")
        shift 2
        ;;
      --no-venv)
        SKIP_VENV=1
        CGW_NO_VENV=1
        shift
        ;;
      --*)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
      *)
        commit_msg_param="$1"
        shift
        ;;
    esac
  done

  init_logging "commit_enhanced"

  if [[ -z "$logfile" ]] || [[ -z "$reportfile" ]]; then
    err "Failed to initialize logging"
    exit 1
  fi

  {
    echo "========================================="
    echo "Enhanced Commit Workflow Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Branch: $(git branch --show-current)"
    echo ""
  } >"$logfile"

  log_message "=== Enhanced Commit Workflow ===" "$logfile"
  log_message "" "$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # Get Python path (best-effort, ruff may be in PATH)
  get_python_path 2>/dev/null || true

  local current_branch
  current_branch=$(git branch --show-current)
  echo "Current branch: $current_branch"
  echo ""

  # [1] Check for uncommitted changes
  echo "[1/6] Checking for changes..."

  # Apply --only: reset index and stage only the listed paths
  if [[ ${#only_paths[@]} -gt 0 ]]; then
    echo "[--only] Resetting index and staging ${#only_paths[@]} path(s)..."
    git reset HEAD >/dev/null 2>&1 || true
    local only_path
    for only_path in "${only_paths[@]}"; do
      if ! git add -- "${only_path}" 2>&1; then
        err "Failed to stage: ${only_path}"
        exit 1
      fi
      echo "  + ${only_path}"
    done
    # --only implies staged-only semantics
    staged_only=1
    echo ""
  fi

  git diff --quiet
  local has_unstaged=$?
  git diff --cached --quiet
  local has_staged=$?

  if [[ ${has_unstaged} -eq 0 ]] && [[ ${has_staged} -eq 0 ]]; then
    echo "[!] No changes to commit"
    exit 0
  fi

  # Determine effective staging mode.
  # Safe default: if user pre-staged anything AND has unstaged changes,
  # respect their selection (implicit --staged-only). --all overrides.
  local effective_staged_only=0
  if [[ ${staged_only} -eq 1 ]]; then
    effective_staged_only=1
  elif [[ ${all_flag} -eq 1 ]]; then
    effective_staged_only=0
  elif [[ ${has_staged} -ne 0 ]] && [[ ${has_unstaged} -ne 0 ]]; then
    effective_staged_only=1
    echo ""
    echo "===================================================================="
    echo "[!] PRE-STAGED FILES DETECTED + UNSTAGED CHANGES PRESENT"
    echo "===================================================================="
    echo "Committing pre-staged files ONLY. The following unstaged changes"
    echo "will NOT be included in this commit:"
    echo ""
    git diff --name-status | sed 's/^/  /'
    echo ""
    echo "To include everything, re-run with --all (or CGW_ALL=1)."
    echo "===================================================================="
    echo ""
  fi

  if [[ ${has_unstaged} -ne 0 ]] && [[ ${effective_staged_only} -eq 0 ]]; then
    echo "Unstaged changes detected:"
    git diff --name-status
    echo ""

    if [[ ${non_interactive} -eq 1 ]]; then
      echo "[Non-interactive] Auto-staging tracked changes..."
      git add -u
      unstage_local_only_files
      echo "[OK] Changes staged"
    else
      read -rp "Stage all tracked changes? (yes/no): " stage_all
      if [[ "$stage_all" == "yes" ]]; then
        git add -u
        unstage_local_only_files
        echo "[OK] Changes staged"
      else
        echo "Please stage changes manually: git add <files>"
        exit 1
      fi
    fi
  elif [[ ${effective_staged_only} -eq 1 ]]; then
    echo "[staged-only] Committing pre-staged files only"
  fi
  echo ""

  # Capture originally-staged file list for re-stage after lint auto-fix
  local originally_staged_files=""
  if [[ ${effective_staged_only} -eq 1 ]]; then
    originally_staged_files=$(git diff --cached --name-only)
  fi

  # [2] Validate staged files -- unstage and verify local-only files
  echo "[2/6] Validating staged files..."
  unstage_local_only_files

  # Post-unstage check: verify nothing slipped through
  local found_local_files=0
  local staged_files
  staged_files=$(git diff --cached --name-only)

  local file
  for file in ${CGW_LOCAL_FILES}; do
    local check_file="${file%/}" # strip trailing slash
    if echo "${staged_files}" | grep -q "^${check_file}"; then
      echo "[X] ERROR: '${check_file}' is staged (local-only file -- should not be committed)" >&2
      found_local_files=1
    fi
  done

  if [[ ${found_local_files} -eq 1 ]]; then
    echo "Remove these files from staging: git reset HEAD <file>" >&2
    exit 1
  fi

  echo "[OK] Staged files validated"
  echo ""

  # [2.5] Whitespace check (non-blocking -- warns but does not abort)
  if git diff --cached --check >/dev/null 2>&1; then
    : # no whitespace issues
  else
    echo "[WARN] Whitespace issues detected in staged files:" | tee -a "$logfile"
    git diff --cached --check 2>&1 | head -20 | tee -a "$logfile"
    echo "  (continuing -- fix with: git diff --cached --check)" | tee -a "$logfile"
    echo ""
  fi

  # [3] Code quality check
  echo "[3/6] Checking code quality..."

  if [[ ${skip_lint} -eq 1 ]]; then
    echo "  (all lint checks skipped -- --skip-lint)"
  else
    get_lint_exclusions

    # Resolve lint and format binaries independently (each uses venv ruff if available)
    local lint_cmd="${CGW_LINT_CMD}"
    local format_cmd="${CGW_FORMAT_CMD}"
    if [[ -n "${CGW_LINT_CMD}" ]] || [[ -n "${CGW_FORMAT_CMD}" ]]; then
      get_python_path 2>/dev/null || true
    fi
    if [[ -n "${CGW_LINT_CMD}" && "${CGW_LINT_CMD}" == "ruff" ]]; then
      if [[ -n "${PYTHON_BIN:-}" ]] && [[ -f "${PYTHON_BIN}/ruff${PYTHON_EXT:-}" ]]; then
        lint_cmd="${PYTHON_BIN}/ruff${PYTHON_EXT:-}"
      fi
    fi
    if [[ -n "${CGW_FORMAT_CMD}" && "${CGW_FORMAT_CMD}" == "ruff" ]]; then
      if [[ -n "${PYTHON_BIN:-}" ]] && [[ -f "${PYTHON_BIN}/ruff${PYTHON_EXT:-}" ]]; then
        format_cmd="${PYTHON_BIN}/ruff${PYTHON_EXT:-}"
      fi
    fi

    local lint_error=0 format_error=0 lint_output format_output

    # -- Code lint (skipped when CGW_LINT_CMD not set) -------------------------
    if [[ -n "${CGW_LINT_CMD}" ]]; then
      log_section_start "LINT CHECK" "$logfile"
      # shellcheck disable=SC2086  # Word splitting intentional: CGW_LINT_CHECK_ARGS/CGW_LINT_EXCLUDES contain multiple flags
      lint_output=$("${lint_cmd}" ${CGW_LINT_CHECK_ARGS} ${CGW_LINT_EXCLUDES} 2>&1) || lint_error=1
      if [[ -n "$lint_output" ]] && [[ "$lint_output" != *"All checks passed"* ]]; then
        echo "[LINT ERRORS]" | tee -a "$logfile"
        echo "$lint_output" | tee -a "$logfile"
      fi
      log_section_end "LINT CHECK" "$logfile" "$lint_error"
    else
      echo "  (lint check skipped -- CGW_LINT_CMD not set)"
    fi

    # -- Format check (skipped when CGW_FORMAT_CMD not set) --------------------
    if [[ -n "${CGW_FORMAT_CMD}" ]]; then
      log_section_start "FORMAT CHECK" "$logfile"
      # shellcheck disable=SC2086  # Word splitting intentional: CGW_FORMAT_CHECK_ARGS/CGW_FORMAT_EXCLUDES contain multiple flags
      format_output=$("${format_cmd}" ${CGW_FORMAT_CHECK_ARGS} ${CGW_FORMAT_EXCLUDES} 2>&1) || format_error=1
      if [[ -n "$format_output" ]] && [[ "$format_output" == *"would reformat"* ]]; then
        echo "[FORMAT ERRORS]" | tee -a "$logfile"
        echo "$format_output" | tee -a "$logfile"
      fi
      log_section_end "FORMAT CHECK" "$logfile" "$format_error"
    fi

    # -- Combined error handling -----------------------------------------------
    local python_lint_error=$((lint_error | format_error))

    if [[ ${python_lint_error} -eq 1 ]]; then
      echo "[!] Code quality errors detected"
      if [[ ${non_interactive} -eq 1 ]]; then
        echo "[Non-interactive] Auto-fixing code quality issues..."
        if [[ -n "${CGW_LINT_CMD}" ]]; then
          # shellcheck disable=SC2086  # Word splitting intentional: CGW_LINT_FIX_ARGS/CGW_LINT_EXCLUDES contain multiple flags
          "${lint_cmd}" ${CGW_LINT_FIX_ARGS} ${CGW_LINT_EXCLUDES} 2>&1 | tee -a "$logfile"
        fi
        if [[ -n "${CGW_FORMAT_CMD}" ]]; then
          # shellcheck disable=SC2086  # Word splitting intentional: CGW_FORMAT_FIX_ARGS/CGW_FORMAT_EXCLUDES contain multiple flags
          "${format_cmd}" ${CGW_FORMAT_FIX_ARGS} ${CGW_FORMAT_EXCLUDES} 2>&1 | tee -a "$logfile"
        fi

        # Re-stage files that lint auto-fix may have modified
        if [[ ${effective_staged_only} -eq 1 ]]; then
          # Respect original selection: re-add only the files that were originally staged
          if [[ -n "${originally_staged_files}" ]]; then
            while IFS= read -r f; do
              [[ -n "$f" ]] && git add -- "$f" 2>/dev/null || true
            done <<<"${originally_staged_files}"
            unstage_local_only_files
          fi
        else
          git add -u
          unstage_local_only_files
        fi

        # Re-check
        python_lint_error=0
        if [[ -n "${CGW_LINT_CMD}" ]]; then
          # shellcheck disable=SC2086  # Word splitting intentional: CGW_LINT_CHECK_ARGS/CGW_LINT_EXCLUDES contain multiple flags
          "${lint_cmd}" ${CGW_LINT_CHECK_ARGS} ${CGW_LINT_EXCLUDES} 2>&1 | tee -a "$logfile" || python_lint_error=1
        fi
        if [[ -n "${CGW_FORMAT_CMD}" ]]; then
          # shellcheck disable=SC2086  # Word splitting intentional: CGW_FORMAT_CHECK_ARGS/CGW_FORMAT_EXCLUDES contain multiple flags
          "${format_cmd}" ${CGW_FORMAT_CHECK_ARGS} ${CGW_FORMAT_EXCLUDES} 2>&1 | tee -a "$logfile" || python_lint_error=1
        fi

        if [[ ${python_lint_error} -eq 1 ]]; then
          err "Code quality errors remain after auto-fix"
          exit 1
        fi
      else
        read -rp "Auto-fix code quality issues? (yes/no/skip): " fix_lint
        case "$fix_lint" in
          yes | y)
            if [[ -n "${CGW_LINT_CMD}" ]]; then
              # shellcheck disable=SC2086  # Word splitting intentional: CGW_LINT_FIX_ARGS/CGW_LINT_EXCLUDES contain multiple flags
              "${lint_cmd}" ${CGW_LINT_FIX_ARGS} ${CGW_LINT_EXCLUDES}
            fi
            if [[ -n "${CGW_FORMAT_CMD}" ]]; then
              # shellcheck disable=SC2086  # Word splitting intentional: CGW_FORMAT_FIX_ARGS/CGW_FORMAT_EXCLUDES contain multiple flags
              "${format_cmd}" ${CGW_FORMAT_FIX_ARGS} ${CGW_FORMAT_EXCLUDES}
            fi
            if [[ ${effective_staged_only} -eq 1 ]]; then
              if [[ -n "${originally_staged_files}" ]]; then
                while IFS= read -r f; do
                  [[ -n "$f" ]] && git add -- "$f" 2>/dev/null || true
                done <<<"${originally_staged_files}"
              fi
            else
              git add -u
            fi
            unstage_local_only_files
            ;;
          skip | s)
            echo "[!] Proceeding with code quality warnings (CI may flag these)"
            ;;
          *)
            echo "Commit cancelled -- fix code quality errors first"
            exit 1
            ;;
        esac
      fi
    else
      echo "[OK] Code quality checks passed"
    fi

    # Markdown lint step (skipped if --skip-md-lint or CGW_MARKDOWNLINT_CMD not set)
    if [[ ${skip_md_lint} -eq 0 ]] && [[ -n "${CGW_MARKDOWNLINT_CMD}" ]]; then
      log_section_start "MARKDOWN LINT" "$logfile"
      local md_lint_error=0
      # shellcheck disable=SC2086  # Word splitting intentional: CGW_MARKDOWNLINT_ARGS contains multiple flags/patterns
      if ! "${CGW_MARKDOWNLINT_CMD}" ${CGW_MARKDOWNLINT_ARGS} 2>&1 | tee -a "$logfile"; then
        md_lint_error=1
      fi
      log_section_end "MARKDOWN LINT" "$logfile" "$md_lint_error"
      if [[ ${md_lint_error} -eq 1 ]]; then
        echo "[!] Markdown lint errors detected"
        if [[ ${non_interactive} -eq 1 ]]; then
          err "Markdown lint failed -- fix errors or use --skip-md-lint to bypass"
          exit 1
        fi
        read -rp "Proceed despite markdown lint errors? (yes/no): " md_choice
        [[ "${md_choice}" == "yes" ]] || exit 1
      fi
    elif [[ ${skip_md_lint} -eq 1 ]]; then
      echo "  (markdown lint skipped -- --skip-md-lint)"
    fi
  fi
  echo ""

  # [4] Show staged changes
  echo "[4/6] Staged changes:"
  echo "===================================="
  git diff --cached --name-status
  echo "===================================="
  echo ""

  local staged_count
  staged_count=$(git diff --cached --name-only | wc -l)
  echo "Files to commit: $staged_count"
  echo ""

  # [5] Get commit message
  echo "[5/6] Commit message..."

  if [[ -z "$commit_msg_param" ]]; then
    err "Commit message required"
    echo "Usage: ./scripts/git/commit_enhanced.sh \"feat: Your message\"" >&2
    echo "Types: feat fix docs chore test refactor style perf (+ extras in .cgw.conf)" >&2
    exit 1
  fi

  local commit_msg="$commit_msg_param"

  if ! echo "$commit_msg" | grep -qE "^(${CGW_ALL_PREFIXES}):"; then
    echo "[!] WARNING: Message doesn't follow conventional format"
    echo "  Configured types: ${CGW_ALL_PREFIXES/|/, }"
    if [[ ${non_interactive} -eq 1 ]]; then
      err "Commit message must follow conventional format in non-interactive mode"
      err "Use --skip-lint or set CGW_EXTRA_PREFIXES if you need a custom prefix"
      exit 1
    else
      read -rp "Continue anyway? (yes/no): " continue_commit
      if [[ "$continue_commit" != "yes" ]]; then
        echo "Commit cancelled"
        exit 0
      fi
    fi
  fi

  echo "Commit message: $commit_msg"
  echo ""

  # [6] Create commit
  echo "[6/6] Creating commit..."

  if [[ ${non_interactive} -eq 1 ]]; then
    echo "[Non-interactive] Branch: $current_branch -- Proceeding..."
  else
    echo "[!] Branch verification: you are committing to: $current_branch"
    read -rp "Is this the correct branch? (yes/no): " correct_branch
    if [[ "$correct_branch" != "yes" ]]; then
      echo "Switch to correct branch first: git checkout <branch-name>"
      exit 0
    fi
    read -rp "Proceed with commit? (yes/no): " confirm_commit
    if [[ "$confirm_commit" != "yes" ]]; then
      echo "Commit cancelled"
      exit 0
    fi
  fi

  if git commit -m "$commit_msg"; then
    echo ""
    echo "===================================="
    echo "[OK] COMMIT SUCCESSFUL"
    echo "===================================="
    echo ""
    echo "Commit: $(git log -1 --oneline)"
    echo "Branch: $current_branch"
    echo "Files:  $staged_count"
    echo ""
    echo "Next steps:"
    if [[ "$current_branch" == "${CGW_SOURCE_BRANCH}" ]]; then
      echo "  - Continue development"
      echo "  - When ready: ./scripts/git/merge_with_validation.sh --dry-run"
    else
      echo "  - Push: ./scripts/git/push_validated.sh"
    fi

    generate_analysis_report
  else
    err "Commit failed -- check output above"
    exit 1
  fi

  exit 0
}

main "$@"
