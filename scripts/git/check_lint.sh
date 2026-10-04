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
#   0 on all checks pass
#   1 on lint/markdown errors (interactive callers may still offer an override)
#   2 on typecheck errors specifically (fatal -- push_validated.sh never offers
#     an interactive override for this code, only --skip-typecheck/CGW_SKIP_TYPECHECK=1)
#
# Snapshot mode (--ref <rev>): check the COMMITTED tree of <rev>, extracted into a
# throwaway directory, instead of the working tree -- uncommitted and untracked
# changes cannot affect the result. Typecheck always covers the whole snapshot
# (a type checker needs whole-program context); lint/format/markdown narrow to
# the files a push would publish when --base <rev> or --unpushed is also given.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

# Remove the --ref snapshot directory. Only ever deletes the exact directory
# mktemp created (a cgw-snap.* name), never an arbitrary path.
# shellcheck disable=SC2329 # invoked via trap
_cgw_snapshot_cleanup() {
  local d="${CGW_SNAPSHOT_DIR:-}"
  [[ -n "${d}" && "${d##*/}" == cgw-snap.* && -d "${d}" ]] && rm -rf "${d}"
  return 0
}

main() {
  local modified_only=0
  local md_only=0
  local ref="" base="" unpushed=0
  # The parse loop below consumes "$@"; cgw_lint_plan needs the originals.
  local -a orig_args=("$@")

  while [[ $# -gt 0 ]]; do
    local arg="$1"
    case "$arg" in
      --help | -h)
        echo "Usage: ./scripts/git/check_lint.sh [OPTIONS]"
        echo ""
        echo "Run lint and format checks (read-only, no modifications)."
        echo ""
        echo "Options:"
        echo "  --modified-only   Only check files modified vs HEAD"
        echo "  --ref <rev>       Check the committed tree of <rev> (in a temp dir), not the"
        echo "                    working tree; uncommitted changes are ignored. Typecheck is"
        echo "                    whole-snapshot; incompatible with --modified-only/--md-only"
        echo "  --base <rev>      With --ref: lint/format/markdown only files changed in"
        echo "                    <rev-base>...<ref> (what a push would publish)"
        echo "  --unpushed        With --ref: scope to files in commits no remote-tracking ref"
        echo "                    has yet (new-branch push); alternative to --base"
        echo "  --no-venv         Use system lint tool instead of .venv"
        echo "  --skip-lint       Skip all lint checks (code, markdown, and typecheck)"
        echo "  --skip-md-lint    Skip markdown lint only (CGW_MARKDOWNLINT_CMD step)"
        echo "  --skip-typecheck  Skip typecheck only (CGW_TYPECHECK_CMD step)"
        echo "  --md-only         Only check markdown (skip code lint + format + typecheck)"
        echo "  -h, --help        Show this help"
        echo ""
        echo "Environment:"
        echo "  CGW_NO_VENV=1          Same as --no-venv"
        echo "  CGW_SKIP_LINT=1        Same as --skip-lint"
        echo "  CGW_SKIP_MD_LINT=1     Same as --skip-md-lint"
        echo "  CGW_SKIP_TYPECHECK=1   Same as --skip-typecheck"
        echo "  CGW_LINT_CMD=<tool>    Override lint tool (default: ruff)"
        echo "  CGW_TYPECHECK_CMD=<tool>  Override typecheck tool (empty = skip)"
        echo "  (Also: CLAUDE_GIT_NO_VENV)"
        exit 0
        ;;
      --no-venv)
        CGW_NO_VENV=1
        SKIP_VENV=1
        ;;
      --modified-only)
        modified_only=1
        ;;
      --md-only)
        md_only=1
        ;;
      --ref | --base)
        if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
          echo "[ERROR] ${arg} requires a revision argument" >&2
          exit 1
        fi
        [[ "$arg" == "--ref" ]] && ref="$2" || base="$2"
        shift
        ;;
      --unpushed)
        unpushed=1
        ;;
      --skip-lint | --skip-md-lint | --skip-typecheck) ;;
      *)
        echo "[ERROR] Unknown flag: $arg" >&2
        exit 1
        ;;
    esac
    shift
  done

  # Query the lint pipeline plan
  local plan
  if ! plan=$(cgw_lint_plan check "${orig_args[@]+"${orig_args[@]}"}"); then
    exit 1
  fi

  local lint_act="" lint_reason=""
  local format_act=""
  local tc_act="" tc_reason=""
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
        ;;
      typecheck)
        tc_act="$_act"
        tc_reason="$_rsn"
        ;;
      markdown)
        md_act="$_act"
        md_reason="$_rsn"
        ;;
    esac
  done <<<"${plan}"

  if [[ "$lint_act" == "skip" && "$format_act" == "skip" && "$tc_act" == "skip" && "$md_act" == "skip" ]]; then
    if [[ "$lint_reason" == "--skip-lint" || "$lint_reason" == "CGW_SKIP_LINT=1" ]]; then
      echo "[OK] All lint checks skipped (${lint_reason})"
      exit 0
    elif [[ ${md_only} -eq 1 ]] && [[ "$md_reason" == "CGW_MARKDOWNLINT_CMD not set" ]]; then
      echo "[OK] Markdown lint skipped (CGW_MARKDOWNLINT_CMD not set)"
      exit 0
    elif [[ -z "${CGW_LINT_CMD:-}" && -z "${CGW_FORMAT_CMD:-}" && -z "${CGW_MARKDOWNLINT_CMD:-}" && -z "${CGW_TYPECHECK_CMD:-}" ]]; then
      echo "[OK] All lint checks skipped (CGW_LINT_CMD, CGW_FORMAT_CMD, CGW_MARKDOWNLINT_CMD, and CGW_TYPECHECK_CMD not set)"
      exit 0
    fi
  fi

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # Snapshot mode (--ref): check the committed tree of <ref> in a throwaway
  # directory so uncommitted/untracked work cannot affect the verdict.
  local ref_sha="" scoped=0
  local -a lint_files=() md_files=()
  if [[ -n "${ref}" ]]; then
    if ! ref_sha=$(git rev-parse --verify --quiet "${ref}^{commit}"); then
      err "Cannot resolve --ref '${ref}' to a commit"
      exit 1
    fi
    if [[ -n "${base}" ]] && ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
      err "Cannot resolve --base '${base}' to a commit"
      exit 1
    fi
    if [[ -n "${base}" || ${unpushed} -eq 1 ]]; then
      scoped=1
      local _lf
      while IFS= read -r _lf; do
        [[ -n "${_lf}" ]] && lint_files+=("${_lf}")
      done < <(cgw_pushed_files_for_lint "${ref_sha}" "${base}")
      while IFS= read -r _lf; do
        [[ -n "${_lf}" ]] && md_files+=("${_lf}")
      done < <(cgw_pushed_files_for_lint "${ref_sha}" "${base}" "*.md")
    fi

    CGW_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cgw-snap.XXXXXX")" || {
      err "Cannot create snapshot directory"
      exit 1
    }
    trap _cgw_snapshot_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! cgw_snapshot_tree "${ref_sha}" "${CGW_SNAPSHOT_DIR}"; then
      err "Cannot extract a snapshot of ${ref} (${ref_sha:0:12})"
      exit 1
    fi

    # The snapshot has no .venv (untracked); point the tools at the real one.
    # shellcheck disable=SC2034  # read by get_python_path
    CGW_VENV_ROOT="${PROJECT_ROOT}"
    export CGW_VENV_ROOT
    if [[ "${CGW_NO_VENV:-0}" != "1" ]]; then
      local _vbin=""
      [[ -d "${PROJECT_ROOT}/.venv/Scripts" ]] && _vbin="${PROJECT_ROOT}/.venv/Scripts"
      [[ -z "${_vbin}" && -d "${PROJECT_ROOT}/.venv/bin" ]] && _vbin="${PROJECT_ROOT}/.venv/bin"
      if [[ -n "${_vbin}" ]]; then
        # A drive-letter path would be split on ':' inside PATH under MSYS.
        command -v cygpath >/dev/null 2>&1 && _vbin="$(cygpath -u "${_vbin}")"
        export VIRTUAL_ENV="${PROJECT_ROOT}/.venv"
        export PATH="${_vbin}:${PATH}"
      fi
    fi

    cd "${CGW_SNAPSHOT_DIR}" || {
      err "Cannot enter snapshot directory"
      exit 1
    }
  fi

  # Handle --modified-only mode (lint pipeline scoped to the modified files; console only)
  # Typecheck is deliberately NOT run here: a typechecker needs whole-program
  # context to resolve types across files, so scoping it to a diff's file
  # list (the way lint/format are scoped below) would misreport errors that
  # originate outside the modified set. Use the full mode for typecheck.
  if [[ "${modified_only}" -eq 1 ]]; then
    if [[ -z "${CGW_LINT_CMD:-}" ]] && [[ -z "${CGW_FORMAT_CMD:-}" ]]; then
      echo "[OK] No code lint or format tool configured for --modified-only (CGW_LINT_CMD and CGW_FORMAT_CMD not set)"
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

    local -a files=()
    read -r -a files <<<"${modified_files}"
    local EXIT_CODE=0
    if [[ "$lint_act" == "run" ]]; then
      cgw_run_lint_check "${files[@]}" || EXIT_CODE=1
    fi
    # Non-blocking: mirrors full-mode (overall_status gates on lint+markdown
    # only) and CI's shfmt continue-on-error. A format diff is reported but
    # never gates the exit code -- only the lint step above does.
    if [[ "$format_act" == "run" ]]; then
      if ! CGW_FORMAT_CHECK_NONBLOCKING=1 cgw_run_format_check "${files[@]}"; then
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
    if [[ -n "${ref_sha}" ]]; then
      echo "Checked: ${ref_sha} (committed snapshot of ${ref}; uncommitted changes excluded)"
      if [[ ${scoped} -eq 1 ]]; then
        echo "Scope: ${#lint_files[@]} code file(s), ${#md_files[@]} markdown file(s) from the push; typecheck is whole-snapshot"
      fi
    fi
  } >"$logfile"

  local -a results=()
  local lint_status=0 md_lint_status=0 typecheck_status=0

  if [[ ${md_only} -eq 0 ]]; then
    # LINT CHECK
    if [[ "$lint_act" == "run" ]] && [[ ${scoped} -eq 1 && ${#lint_files[@]} -eq 0 ]]; then
      echo "  (lint check skipped -- no pushed files match ${CGW_LINT_EXTENSIONS:-*.py})" | tee -a "$logfile"
    elif [[ "$lint_act" == "run" ]]; then
      local lint_start lint_end lint_duration lint_res
      lint_start=$(date +%s)
      cgw_run_lint_check --result-var lint_res "${lint_files[@]+"${lint_files[@]}"}" || lint_status=1
      lint_end=$(date +%s)
      lint_duration=$((lint_end - lint_start))
      IFS=':' read -r _l_name _l_status _l_errors <<<"${lint_res}"
      results+=("${_l_name}:${_l_status}:${_l_errors}:${lint_duration}")
    fi

    # FORMAT CHECK
    # Non-blocking: mirrors the CI workflow's `continue-on-error: true` on the
    # shfmt step (.github/workflows/branch-protection.yml), present since that
    # workflow's introduction. A format diff is reported but never gates
    # overall_status or the exit code -- only lint and markdown-lint do.
    if [[ "$format_act" == "run" ]] && [[ ${scoped} -eq 1 && ${#lint_files[@]} -eq 0 ]]; then
      echo "  (format check skipped -- no pushed files match ${CGW_LINT_EXTENSIONS:-*.py})" | tee -a "$logfile"
    elif [[ "$format_act" == "run" ]]; then
      local format_start format_end format_duration format_res
      format_start=$(date +%s)
      CGW_FORMAT_CHECK_NONBLOCKING=1 cgw_run_format_check --result-var format_res "${lint_files[@]+"${lint_files[@]}"}" || true
      format_end=$(date +%s)
      format_duration=$((format_end - format_start))
      IFS=':' read -r _f_name _f_status _f_errors <<<"${format_res}"
      results+=("${_f_name}:${_f_status}:${_f_errors}:${format_duration}")
    fi

    # TYPECHECK
    # Blocking (joins overall_status below), unlike Format. Whole-project --
    # never scoped to a file list, see the --modified-only comment above.
    if [[ "$tc_act" == "skip" ]]; then
      if [[ "$tc_reason" == "--skip-typecheck" || "$tc_reason" == "CGW_SKIP_TYPECHECK=1" ]]; then
        echo "  (typecheck skipped -- ${tc_reason})" | tee -a "$logfile"
      fi
    elif [[ -n "${CGW_TYPECHECK_CMD}" ]] && {
      get_python_path 2>/dev/null || true
      ! command -v "$(cgw_resolve_lint_binary "${CGW_TYPECHECK_CMD}")" >/dev/null 2>&1
    }; then
      # A configured-but-absent checker would exit 127 with no diagnostics,
      # which reads as "FAILED, 0 errors" and would now BLOCK a push. That is
      # an environment gap, not a type error -- warn and skip instead, the
      # same way an unset CGW_MARKDOWNLINT_CMD is treated as opt-out rather
      # than failure.
      echo "[!] Typecheck skipped -- '${CGW_TYPECHECK_CMD}' is configured but not found on PATH or in .venv" | tee -a "$logfile"
    else
      local tc_start tc_end tc_duration tc_res
      tc_start=$(date +%s)
      cgw_run_typecheck --result-var tc_res || typecheck_status=1
      tc_end=$(date +%s)
      tc_duration=$((tc_end - tc_start))
      IFS=':' read -r _tc_name _tc_status _tc_errors <<<"${tc_res}"
      results+=("${_tc_name}:${_tc_status}:${_tc_errors}:${tc_duration}")
    fi
  else
    echo "  (code lint + format + typecheck skipped -- --md-only)" | tee -a "$logfile"
  fi

  # MARKDOWN LINT
  if [[ "$md_act" == "skip" ]]; then
    if [[ "$md_reason" == "--skip-md-lint" ]]; then
      echo "  (markdown lint skipped -- --skip-md-lint)" | tee -a "$logfile"
    fi
  elif [[ ${scoped} -eq 1 && ${#md_files[@]} -eq 0 ]]; then
    echo "  (markdown lint skipped -- no pushed .md files)" | tee -a "$logfile"
  else
    local md_start md_end md_duration md_res
    md_start=$(date +%s)
    cgw_run_markdownlint_check --result-var md_res "${md_files[@]+"${md_files[@]}"}" || md_lint_status=1
    md_end=$(date +%s)
    md_duration=$((md_end - md_start))
    IFS=':' read -r _md_name _md_status _md_errors <<<"${md_res}"
    results+=("${_md_name}:${_md_status}:${_md_errors}:${md_duration}")
  fi

  log_summary_table "$logfile" "${results[@]+"${results[@]}"}"

  # A FAILED row with 0 parsed errors means the tool exited non-zero without
  # emitting any file:line diagnostics -- a tool/config failure (missing
  # binary, bad flags, crash), not counted lint errors. Name that explicitly
  # instead of leaving "FAILED ... 0 errors" to self-contradict.
  local _row _row_name _row_status _row_errors _row_rest
  for _row in "${results[@]+"${results[@]}"}"; do
    IFS=':' read -r _row_name _row_status _row_errors _row_rest <<<"${_row}"
    if [[ "${_row_status}" == "FAILED" ]] && [[ "${_row_errors}" == "0" ]]; then
      echo "[!] ${_row_name}: tool exited non-zero but no diagnostics were parsed -- likely a tool/config failure, not code errors (see log)" | tee -a "$logfile"
    fi
  done

  local script_end total_duration overall_status
  script_end=$(date +%s)
  total_duration=$((script_end - script_start))

  if [[ $lint_status -eq 0 ]] && [[ $md_lint_status -eq 0 ]] && [[ $typecheck_status -eq 0 ]]; then
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

  # Exit 2 (distinct from the generic exit 1) specifically marks a typecheck
  # failure -- callers (push_validated.sh) use this to refuse the interactive
  # "push anyway?" override for type errors while still offering it for
  # lint/markdown failures, matching the blocking-vs-advisory design intent.
  [[ "$overall_status" == "PASSED" ]] && exit 0
  [[ $typecheck_status -ne 0 ]] && exit 2
  exit 1
}

main "$@"
