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
#   --skip-lint        Skip all lint checks
#   --skip-md-lint     Skip markdown lint only (CGW_MARKDOWNLINT_CMD step)
#   -h, --help         Show help
#
# Staging behavior (non-interactive):
#   - If anything is pre-staged AND unstaged changes exist: commits pre-staged only
#     (warns about unstaged files that are being left out). Use --all to override.
#   - If nothing is pre-staged: auto-stages all tracked changes (legacy behavior).
#   - --only <path>: explicit selection, resets index, stages listed paths only.
#     Force-stages (git add -f) paths already tracked, so a path that became
#     gitignored after it was first committed can still be selected explicitly.
# Returns:
#   0 on successful commit, 1 on failure

set -uo pipefail
# Note: set -e intentionally omitted -- git diff/diff-index use exit codes for signaling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

generate_analysis_report() {
  cat >"${reportfile}" <<EOF
# Enhanced Commit Workflow Analysis Report

**Date**: $(date)
**Branch**: ${current_branch}
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

- Execution log: \`${logfile}\`
- Analysis report: \`${reportfile}\`

EOF

  echo "End Time: $(date)" >>"${logfile}"
}

unstage_local_only_files() {
  local f
  # Only target add/modify entries — staged deletions of local-only files are the
  # documented `git rm --cached` untrack workflow and must not be unstaged.
  # Matches the --diff-filter=AM contract in hooks/pre-commit.
  while read -r f; do
    git reset HEAD "${f}" 2>/dev/null || true
  done < <(git diff --cached --name-only --diff-filter=AM | cgw_filter_local_files)
}

# Re-stage files after lint/markdown auto-fix, then remove any local-only
# files the fixer may have touched. Takes explicit params because main()
# locals are not visible to script-level functions in bash.
#
# Re-stages every originally-staged path EXCEPT ones already flagged
# partially staged (index differs from working tree at snapshot time --
# the moral equivalent of `git add -p` picking one hunk). Whole-file
# re-staging one of those would silently promote unstaged content into the
# index, defeating the user's selection. This applies uniformly in bulk and
# staged-only mode: bulk mode's originally_staged_files already reflects the
# post `git add -u` index (see the snapshot site in main()), so replaying it
# here -- rather than issuing a second `git add -u` -- also avoids sweeping
# in any file a concurrent process modified in the gap since that snapshot.
_restage_after_fix() {
  local originally_staged_files="$1"
  local partially_staged_files="$2"

  local -A _partial=()
  local _pf
  while IFS= read -r _pf; do
    [[ -n "${_pf}" ]] && _partial["${_pf}"]=1
  done <<<"${partially_staged_files}"

  local f
  local -a _skipped=()
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    if [[ -n "${_partial[${f}]:-}" ]]; then
      _skipped+=("${f}")
      continue
    fi
    # -f: these paths came from a prior `git diff --cached` snapshot, so
    # they're already tracked/staged -- force-add survives a .gitignore
    # added between staging and this re-stage (see --only loop above).
    git add -f -- "${f}" 2>/dev/null || true
  done <<<"${originally_staged_files}"

  if [[ ${#_skipped[@]} -gt 0 ]]; then
    echo "[!] Auto-fix touched a partially-staged file; leaving it as-is to preserve your staged hunks: ${_skipped[*]}"
  fi

  unstage_local_only_files
}

main() {
  local non_interactive=0
  local skip_lint=0
  local skip_md_lint=0
  local staged_only=0
  local all_flag=0
  local only_paths=()
  local commit_msg_param=""
  # Signing: -1 = unset (use CGW_SIGN_COMMITS), 0 = off, 1 = on
  local sign_flag=-1

  # Auto-detect non-interactive mode when no TTY
  if [[ ! -t 0 ]]; then
    non_interactive=1
    CGW_NON_INTERACTIVE=1
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
        echo "  --sign              GPG/SSH-sign the commit (git commit -S)"
        echo "  --no-sign           Disable signing even if CGW_SIGN_COMMITS=1"
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
        echo "  CGW_SIGN_COMMITS=1      Same as --sign (sign all commits by default)"
        echo "  (Also: CLAUDE_GIT_NON_INTERACTIVE, CLAUDE_GIT_STAGED_ONLY, CLAUDE_GIT_NO_VENV)"
        echo ""
        echo "Protected files (never committed): configured via CGW_LOCAL_FILES in .cgw.conf"
        echo "  Default: CLAUDE.md MEMORY.md .claude/ logs/"
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
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
      --sign)
        sign_flag=1
        shift
        ;;
      --no-sign)
        sign_flag=0
        shift
        ;;
      --*)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
      *)
        # A second bare positional used to silently overwrite the first --
        # the classic victim being `--only path1 path2 "msg"`, where path2
        # became a briefly held "commit message" and was then dropped without
        # any warning. Fail loudly instead.
        if [[ -n "${commit_msg_param}" ]]; then
          echo "[ERROR] Unexpected extra positional argument: $1" >&2
          echo "  Already have a commit message: \"${commit_msg_param}\"" >&2
          echo "  The commit message must be ONE quoted argument. To stage several paths," >&2
          echo "  repeat --only per path:" >&2
          echo "    ./scripts/git/commit_enhanced.sh --only path1 --only path2 \"feat: msg\"" >&2
          exit 1
        fi
        commit_msg_param="$1"
        shift
        ;;
    esac
  done

  init_logging "commit_enhanced"
  ensure_no_stale_index_lock || exit 1

  if [[ -z "${logfile}" ]] || [[ -z "${reportfile}" ]]; then
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
  } >"${logfile}"

  log_message "=== Enhanced Commit Workflow ===" "${logfile}"
  log_message "" "${logfile}"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # Get Python path (best-effort, ruff may be in PATH)
  get_python_path 2>/dev/null || true

  local current_branch
  current_branch=$(git branch --show-current)
  echo "Current branch: ${current_branch}"
  echo ""

  # [1] Check for uncommitted changes
  echo "[1/6] Checking for changes..."

  # Apply --only: reset index and stage only the listed paths
  if [[ ${#only_paths[@]} -gt 0 ]]; then
    echo "[--only] Resetting index and staging ${#only_paths[@]} path(s)..."
    # Show what the reset below is about to discard from the index. --only's
    # contract is "reset, then stage exactly these paths", which silently
    # unstages anything pre-staged outside them -- the second half of the
    # incident this guard exists for (a prior session's staged files had to
    # be manually reconstructed because the wipe gave no warning).
    local -a _only_discard_pathspec=(".")
    local _only_p
    for _only_p in "${only_paths[@]}"; do
      _only_discard_pathspec+=(":(exclude)${_only_p}")
    done
    local -a _will_unstage=()
    local _wu_f
    while IFS= read -r _wu_f; do
      [[ -n "${_wu_f}" ]] && _will_unstage+=("${_wu_f}")
    done < <(git diff --cached --name-only -- "${_only_discard_pathspec[@]}" 2>/dev/null)
    if [[ ${#_will_unstage[@]} -gt 0 ]]; then
      echo "[--only] Currently staged but not matched by --only (will be unstaged): ${_will_unstage[*]}"
    fi
    # Reset only when HEAD exists. An unborn HEAD (fresh repo, no commits) has
    # nothing to reset, so skip. A real reset failure (e.g. stale index.lock)
    # must abort — swallowing it would let pre-staged extras ride along, breaking
    # the --only contract of "reset, then stage exactly these paths".
    if git rev-parse --verify -q HEAD >/dev/null; then
      if ! git reset HEAD >/dev/null 2>&1; then
        err "--only: failed to reset index (stale index.lock?); aborting to avoid committing unintended files"
        exit 1
      fi
    fi
    local only_path
    for only_path in "${only_paths[@]}"; do
      local staged_any=0
      # (a) Force-stage TRACKED files matching the pathspec. These are already
      # committed, so -f only matters when the path later became gitignored.
      # Scoping -f to concrete tracked paths (never the raw pathspec) means an
      # ignored *untracked* artifact under a dir/glob pathspec can never be
      # force-added alongside it -- .gitignore still protects new files.
      local tracked_match
      while IFS= read -r -d '' tracked_match; do
        if ! git add -f -- "${tracked_match}"; then
          err "Failed to stage: ${tracked_match}"
          exit 1
        fi
        staged_any=1
      done < <(git ls-files -z -- "${only_path}")
      # (b) Stage untracked, non-ignored files matching the pathspec with a
      # PLAIN add (no -f), so .gitignore still blocks new artifacts. Capture
      # combined output so a genuine failure (e.g. a pathspec that matched
      # nothing) still surfaces git's actionable message; when (a) already
      # staged the tracked part, staged_any stays set and this output is
      # harmlessly discarded.
      local add_out=""
      if add_out=$(git add -- "${only_path}" 2>&1); then
        staged_any=1
      fi
      if [[ ${staged_any} -eq 0 ]]; then
        err "Failed to stage: ${only_path}"
        [[ -n "${add_out}" ]] && err "${add_out}"
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

  # A merge in progress (MERGE_HEAD present) must still be concluded even when
  # the resolved index happens to be byte-identical to HEAD -- e.g. conflict
  # resolution that kept "our" side on every conflicting hunk. The commit
  # below still needs to run: it records a real two-parent merge commit and
  # clears MERGE_HEAD, regardless of whether the tree itself changed.
  local merge_head_path merge_in_progress=0
  merge_head_path="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)"
  [[ -n "${merge_head_path}" && -f "${merge_head_path}" ]] && merge_in_progress=1

  if [[ ${has_unstaged} -eq 0 ]] && [[ ${has_staged} -eq 0 ]]; then
    if [[ ${merge_in_progress} -eq 1 ]]; then
      echo "[!] Merge in progress; resolved tree matches HEAD -- concluding merge commit"
    else
      echo "[!] No changes to commit"
      exit 0
    fi
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
    git diff --name-status | while IFS= read -r line; do printf '  %s\n' "${line}"; done
    echo ""
    echo "To include everything, re-run with --all (or CGW_ALL=1)."
    echo "===================================================================="
    echo ""
  fi

  if [[ ${has_unstaged} -ne 0 ]] && [[ ${effective_staged_only} -eq 0 ]]; then
    echo "Unstaged changes detected:"
    git diff --name-status
    echo ""

    if cgw_confirm "Stage all tracked changes?" --non-interactive accept; then
      git add -u
      unstage_local_only_files
      echo "[OK] Changes staged"
    else
      echo "Please stage changes manually: git add <files>"
      exit 1
    fi
  elif [[ ${effective_staged_only} -eq 1 ]]; then
    echo "[staged-only] Committing pre-staged files only"
  fi
  echo ""

  # Snapshot the staged-file set now that staging is final for this run (the
  # bulk `git add -u` above, or the user's own pre-staging in staged-only /
  # --only mode). _restage_after_fix replays THIS list rather than issuing a
  # fresh `git add -u` -- a fresh sweep would also pick up any file a
  # concurrent process modified in the gap between here and the auto-fix.
  local originally_staged_files
  originally_staged_files=$(git diff --cached --name-only)

  # Snapshot which of those are PARTIALLY staged -- index differs from the
  # working tree, the moral equivalent of `git add -p` picking one hunk.
  # _restage_after_fix must never promote these whole; see
  # cgw_staged_paths_diverging_from_index.
  local partially_staged_files
  partially_staged_files=$(cgw_staged_paths_diverging_from_index)

  # [2] Validate staged files -- unstage and verify local-only files
  echo "[2/6] Validating staged files..."
  unstage_local_only_files

  # Post-unstage check: verify nothing slipped through (add/modify only — deletions are allowed)
  local found_local_files=0
  local staged_files
  staged_files=$(git diff --cached --name-only --diff-filter=AM)

  local f
  while read -r f; do
    echo "[X] ERROR: '${f}' is staged (local-only file -- should not be committed)" >&2
    found_local_files=1
  done < <(echo "${staged_files}" | cgw_filter_local_files)

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
    echo "[WARN] Whitespace issues detected in staged files:" | tee -a "${logfile}"
    git diff --cached --check 2>&1 | head -20 | tee -a "${logfile}"
    echo "  (continuing -- fix with: git diff --cached --check)" | tee -a "${logfile}"
    echo ""
  fi

  # [3] Code quality check
  echo "[3/6] Checking code quality..."

  if [[ ${skip_lint} -eq 1 ]]; then
    echo "[skip-lint] Lint gate BYPASSED for this commit -- code + markdown checks not run"
    echo "  (the gate exists to keep CI green; prefer fixing lint over skipping it)"
  else
    # Scope code-quality checks to the staged files being committed. A bare call
    # scans the whole repo, so an unrelated file's lint error blocks the commit
    # and (worse) non-interactive auto-fix rewrites files outside the commit.
    local -a staged_lint=()
    local lint_f
    while IFS= read -r lint_f; do
      [[ -n "${lint_f}" ]] && staged_lint+=("${lint_f}")
    done < <(cgw_staged_files_for_lint)

    local lint_error=0 format_error=0
    if [[ ${#staged_lint[@]} -eq 0 ]]; then
      echo "  (code quality checks skipped -- no staged files matching ${CGW_LINT_EXTENSIONS:-*.py})"
    else
      cgw_run_lint_check "${staged_lint[@]}" || lint_error=1
      cgw_run_format_check "${staged_lint[@]}" || format_error=1
    fi

    local python_lint_error=$((lint_error | format_error))

    if [[ ${python_lint_error} -eq 1 ]]; then
      echo "[!] Code quality errors detected"
      if [[ ${non_interactive} -eq 1 ]]; then
        echo "[Non-interactive] Auto-fixing code quality issues..."
        cgw_run_lint_fix "${staged_lint[@]}"
        _restage_after_fix "${originally_staged_files}" "${partially_staged_files}"

        # Re-check after fix (same staged scope)
        python_lint_error=0
        cgw_run_lint_check "${staged_lint[@]}" || python_lint_error=1
        cgw_run_format_check "${staged_lint[@]}" || python_lint_error=1

        if [[ ${python_lint_error} -eq 1 ]]; then
          err "Code quality errors remain after auto-fix"
          exit 1
        fi
      else
        read -rp "Auto-fix code quality issues? (yes/no/skip): " fix_lint
        case "${fix_lint}" in
          yes | y)
            cgw_run_lint_fix "${staged_lint[@]}"
            _restage_after_fix "${originally_staged_files}" "${partially_staged_files}"
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

    # Markdown lint step (skipped if --skip-md-lint or CGW_MARKDOWNLINT_CMD not set).
    # Scope to staged *.md only — a code-only commit must not be blocked by a
    # markdown violation in an unrelated file elsewhere in the repo. Local-only
    # files (CLAUDE.md/MEMORY.md) are already unstaged above, so they won't appear.
    if [[ ${skip_md_lint} -eq 0 ]]; then
      local -a staged_md=()
      local md_f
      while IFS= read -r md_f; do
        [[ -n "${md_f}" ]] && staged_md+=("${md_f}")
      done < <(cgw_staged_files_for_md)

      if [[ ${#staged_md[@]} -eq 0 ]]; then
        echo "  (markdown lint skipped -- no staged .md files)"
      else
        local md_lint_error=0
        cgw_run_markdownlint_check "${staged_md[@]}" || md_lint_error=1

        if [[ ${md_lint_error} -eq 1 ]]; then
          echo "[!] Markdown lint errors detected"
          if [[ ${non_interactive} -eq 1 ]]; then
            echo "[Non-interactive] Auto-fixing markdown lint issues..."
            cgw_run_markdownlint_fix "${staged_md[@]}"
            _restage_after_fix "${originally_staged_files}" "${partially_staged_files}"

            # Re-check after fix (same staged scope)
            md_lint_error=0
            cgw_run_markdownlint_check "${staged_md[@]}" || md_lint_error=1

            if [[ ${md_lint_error} -eq 1 ]]; then
              err "Markdown lint errors remain after auto-fix"
              exit 1
            fi
          else
            read -rp "Auto-fix markdown lint issues? (yes/no/skip): " fix_md_lint
            case "${fix_md_lint}" in
              yes | y)
                cgw_run_markdownlint_fix "${staged_md[@]}"
                _restage_after_fix "${originally_staged_files}" "${partially_staged_files}"

                # Re-check after fix (same staged scope)
                md_lint_error=0
                cgw_run_markdownlint_check "${staged_md[@]}" || md_lint_error=1

                if [[ ${md_lint_error} -eq 1 ]]; then
                  err "Markdown lint errors remain after auto-fix"
                  exit 1
                fi
                ;;
              skip | s)
                echo "[!] Proceeding with markdown lint warnings (CI may flag these)"
                ;;
              *)
                echo "Commit cancelled -- fix markdown lint errors first"
                exit 1
                ;;
            esac
          fi
        else
          echo "[OK] Markdown lint checks passed"
        fi
      fi
    else
      echo "  (markdown lint skipped -- --skip-md-lint)"
    fi

    # [3.5] Congruence guard: the checks above validated the WORKING TREE, but
    # `git commit` records the INDEX. If a staged file CGW actually validated
    # (a lint-eligible file when a code checker is configured, or a *.md file
    # when markdownlint genuinely ran) has a blob that differs from what's on
    # disk, CGW would commit content it never validated -- silently. Covers
    # both the gate-skip case (working tree already clean, stale staged
    # blob) and a re-stage that silently failed to update the index. Runs
    # once here, after both the lint/format auto-fix above and the markdown
    # auto-fix just above, so one check covers both paths -- see
    # cgw_validated_path_set.
    #
    # skip_md_lint is a main() local, invisible to a script-level function --
    # forward it explicitly rather than exporting it into CGW_SKIP_MD_LINT
    # (see cgw_validated_path_set's header for why). It must be forwarded
    # identically at BOTH call sites below (detection and re-verify): if they
    # drift, the re-verify sees a different validated set than detection did,
    # and can abort after a re-stage that actually succeeded.
    local -a _diverged_validated_files=()
    local _div_f
    while IFS= read -r _div_f; do
      [[ -n "${_div_f}" ]] && _diverged_validated_files+=("${_div_f}")
    done < <(cgw_validated_path_set "${skip_md_lint}" | cgw_paths_diverging_from_index)

    if [[ ${#_diverged_validated_files[@]} -gt 0 ]]; then
      # Re-staging the whole file is safe only when staging intent is
      # whole-file: bulk/--all (effective_staged_only==0) or --only <paths>
      # (only_paths non-empty; --only forces staged_only=1 above). Genuine
      # partial staging (--staged-only, or auto-detected pre-stage+unstaged,
      # with no --only) may intentionally leave index != working tree --
      # never silently re-stage there.
      if [[ ${effective_staged_only} -eq 0 || ${#only_paths[@]} -gt 0 ]]; then
        echo "[!] Validated working tree diverges from staged blob; re-staging: ${_diverged_validated_files[*]}"
        local _div_rf
        for _div_rf in "${_diverged_validated_files[@]}"; do
          git add -f -- "${_div_rf}"
        done
        unstage_local_only_files
        # Re-verify: a path that still can't be re-staged (e.g. assume-unchanged/
        # skip-worktree) stays divergent -- fail closed rather than commit
        # unvalidated content.
        if cgw_validated_path_set "${skip_md_lint}" | cgw_paths_diverging_from_index >/dev/null; then
          err "Staged content still diverges from the validated working tree; aborting."
          exit 1
        fi
      elif [[ "${CGW_ALLOW_STAGED_DIVERGENCE:-0}" == "1" ]]; then
        echo "[!] staged-only: committing staged blob that differs from the validated working tree (CGW_ALLOW_STAGED_DIVERGENCE=1)"
      else
        err "Staged content differs from the validated working tree for: ${_diverged_validated_files[*]}"
        err "CGW validated the working tree but would commit a different staged blob."
        err "  - To commit exactly your staged hunks:  CGW_ALLOW_STAGED_DIVERGENCE=1"
        err "  - To bypass the checks entirely:        --skip-lint"
        err "  - To commit the full working-tree file: git add ${_diverged_validated_files[*]}  (DISCARDS your hunk selection)"
        exit 1
      fi
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
  echo "Files to commit: ${staged_count}"
  echo ""

  # [5] Get commit message
  echo "[5/6] Commit message..."

  if [[ -z "${commit_msg_param}" ]]; then
    err "Commit message required"
    echo "Usage: ./scripts/git/commit_enhanced.sh \"feat: Your message\"" >&2
    echo "Types: feat fix docs chore test refactor style perf (+ extras in .cgw.conf)" >&2
    exit 1
  fi

  local commit_msg="${commit_msg_param}"

  if ! cgw_validate_commit_message "${commit_msg}"; then
    echo "[!] WARNING: Message doesn't follow conventional format"
    echo "  Configured types: ${CGW_ALL_PREFIXES/|/, }"
    if ! cgw_confirm "Continue anyway?" --non-interactive abort; then
      echo "Commit cancelled"
      exit 0
    fi
  fi

  # Commit subject length (Pro Git §"Commit Guidelines" recommends ~50 chars
  # for the summary line after the prefix; git log --oneline / GitHub UI
  # commonly truncate around 72). Soft threshold: advisory tip, non-blocking.
  # Hard threshold: blocks via cgw_confirm (non-interactive: abort) unless
  # CGW_ENFORCE_SUBJECT_LENGTH=0.
  # NOTE: measure the first line only -- commit_msg is the full multi-line
  # message (subject + body + trailers); stripping "*: " against the whole
  # string would swallow the body into the "summary" and false-positive on
  # any commit with a normal-length body.
  # NOTE: cgw_validate_commit_message only requires "type:" (colon, no
  # mandatory space) -- strip on the bare colon, then trim one optional
  # leading space, so "type:subject" (no space) isn't measured with the
  # prefix still attached.
  local _subject_line="${commit_msg%%$'\n'*}"
  local _summary_part="${_subject_line#*:}"
  _summary_part="${_summary_part# }"
  local _summary_len=${#_summary_part}
  if [[ ${_summary_len} -gt ${CGW_COMMIT_SUBJECT_SOFT_LEN} ]]; then
    if [[ ${_summary_len} -gt ${CGW_COMMIT_SUBJECT_HARD_LEN} ]]; then
      echo "[!] Subject after prefix is ${_summary_len} chars, over the ${CGW_COMMIT_SUBJECT_HARD_LEN}-char hard cap (Pro Git recommends ~${CGW_COMMIT_SUBJECT_SOFT_LEN})"
      echo "  Move detail into the commit body instead of a long summary line."
      if [[ "${CGW_ENFORCE_SUBJECT_LENGTH}" == "1" ]]; then
        if ! cgw_confirm "Commit with an oversized subject line anyway?" --non-interactive abort; then
          echo "Commit cancelled"
          exit 0
        fi
      fi
    else
      echo "[!] Tip: subject after prefix is ${_summary_len} chars (Pro Git recommends ≤${CGW_COMMIT_SUBJECT_SOFT_LEN})"
    fi
  fi
  unset _subject_line _summary_part _summary_len

  echo "Commit message: ${commit_msg}"
  echo ""

  # [6] Create commit
  echo "[6/6] Creating commit..."

  echo "[!] Branch verification: you are committing to: ${current_branch}"
  if ! cgw_confirm "Is this the correct branch?" --non-interactive accept; then
    echo "Switch to correct branch first: git checkout <branch-name>"
    exit 0
  fi
  if ! cgw_confirm "Proceed with commit?" --non-interactive accept; then
    echo "Commit cancelled"
    exit 0
  fi

  # Resolve signing: --sign/--no-sign override; else fall back to CGW_SIGN_COMMITS.
  # We only ADD -S; we never pass --no-gpg-sign (respect git's commit.gpgsign config).
  local _do_sign=0
  if [[ "${sign_flag}" -eq 1 ]]; then
    _do_sign=1
  elif [[ "${sign_flag}" -lt 0 ]] && [[ "${CGW_SIGN_COMMITS:-0}" == "1" ]]; then
    _do_sign=1
  fi

  local -a _commit_cmd=(git commit -m "${commit_msg}")
  [[ "${_do_sign}" -eq 1 ]] && _commit_cmd=(git commit -S -m "${commit_msg}")
  # A merge conclusion whose STAGED tree is byte-identical to HEAD (every
  # conflict resolved toward "ours") has nothing for plain `git commit` to
  # see -- it would refuse with "nothing to commit" and, worse, silently
  # drop MERGE_HEAD without ever recording the merge. --allow-empty forces
  # the two-parent merge commit through in that case. Only has_staged (not
  # has_unstaged) matters here: this commit only ever records the index, so
  # unrelated dirty working-tree files elsewhere are irrelevant to whether
  # *this* commit would be empty.
  if [[ ${merge_in_progress} -eq 1 ]] && [[ ${has_staged} -eq 0 ]]; then
    _commit_cmd+=(--allow-empty)
  fi

  if "${_commit_cmd[@]}"; then
    echo ""
    echo "===================================="
    echo "[OK] COMMIT SUCCESSFUL"
    echo "===================================="
    echo ""
    echo "Commit: $(git log -1 --oneline)"
    echo "Branch: ${current_branch}"
    echo "Files:  ${staged_count}"
    if [[ ${skip_lint} -eq 1 ]]; then
      echo ""
      echo "[skip-lint] Lint gate was bypassed for this commit -- CI may still flag it"
    fi
    echo ""
    echo "Next steps:"
    if [[ "${current_branch}" == "${CGW_SOURCE_BRANCH}" ]]; then
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
