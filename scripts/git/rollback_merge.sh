#!/usr/bin/env bash
# rollback_merge.sh - Emergency rollback for merge operations
# Purpose: Revert target branch to pre-merge state safely
# Usage: ./scripts/git/rollback_merge.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR          - Directory containing this script
#   PROJECT_ROOT        - Auto-detected git repo root (set by _config.sh)
#   logfile             - Set by init_logging
#   CGW_TARGET_BRANCH   - Branch to roll back (default: main)
# Arguments:
#   --non-interactive   Skip prompts; without --target, auto-selects the latest pre-merge
#                       backup tag only if it equals HEAD^1 (--revert: HEAD, only if a merge)
#   --target <ref>      Reset point (hard) or merge commit to undo (--revert)
#   --dry-run           Show rollback target without resetting
#   --revert            Undo the merge with 'git revert -m 1' (history-preserving)
#   -h, --help          Show help
# Returns:
#   0 on successful rollback, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

init_logging "rollback_merge"
ensure_no_stale_index_lock || exit 1

_rollback_done=0

_cleanup_rollback() {
  [[ ${_rollback_done} -eq 1 ]] && return 0
  echo "" >&2
  echo "[!] Rollback interrupted. Verify repository state before proceeding:" >&2
  echo "  git log --oneline -5" >&2
  echo "  git status" >&2
}
trap _cleanup_rollback EXIT INT TERM

# _rb_parent_count <ref> - number of parents of the commit <ref> peels to (0 if invalid)
_rb_parent_count() {
  local line
  line=$(git rev-list --parents -n 1 "${1}^{commit}" 2>/dev/null) || {
    echo 0
    return 0
  }
  # "<sha> <parent>..." -> word count minus the commit itself
  # shellcheck disable=SC2086 # intentional word splitting
  set -- ${line}
  echo $(($# > 0 ? $# - 1 : 0))
}

# _rb_classify_tag <tag> - how a backup tag relates to HEAD:
#   first-parent  tag == HEAD^1 (the state just before HEAD's merge) -- safe auto-pick
#   same          tag == HEAD (nothing to roll back)
#   ancestor      tag is older than HEAD^1; a reset would discard more than one merge
#   unrelated     tag is not an ancestor of HEAD (e.g. from another history)
_rb_classify_tag() {
  local tag_sha head_sha first_parent
  tag_sha=$(git rev-parse --verify -q "${1}^{commit}") || {
    echo "unrelated"
    return 0
  }
  head_sha=$(git rev-parse HEAD)
  if [[ "${tag_sha}" == "${head_sha}" ]]; then
    echo "same"
  elif first_parent=$(git rev-parse --verify -q "HEAD^1") && [[ "${tag_sha}" == "${first_parent}" ]]; then
    echo "first-parent"
  elif git merge-base --is-ancestor "${tag_sha}" "${head_sha}"; then
    echo "ancestor"
  else
    echo "unrelated"
  fi
}

main() {
  local non_interactive=0
  local dry_run=0
  local rollback_target_flag=""
  local use_revert=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help | -h)
        echo "Usage: ./scripts/git/rollback_merge.sh [OPTIONS]"
        echo ""
        echo "Emergency rollback: resets target branch to a pre-merge state,"
        echo "or (--revert) adds a commit that undoes a merge."
        echo "Must be run from the target branch (default: ${CGW_TARGET_BRANCH})."
        echo ""
        echo "Options:"
        echo "  --non-interactive   Skip prompts. Without --target: hard mode auto-selects the latest"
        echo "                      pre-merge backup tag only if it is HEAD^1 (else refuses);"
        echo "                      --revert uses HEAD only if HEAD is a merge (else refuses)"
        echo "  --target <ref>      Hard mode: commit/tag to reset to. --revert: the merge commit to undo"
        echo "  --dry-run           Show rollback target without resetting"
        echo "  --revert            Safe mode: use 'git revert -m 1' instead of 'git reset --hard'"
        echo "                      Preserves history -- safe for shared repos where commits are pushed"
        echo "  -h, --help          Show this help"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
        echo "  CGW_REMOTE              Remote name (default: origin)"
        echo ""
        echo "CAUTION: Without --revert, this rewrites branch history. Force-push required after."
        echo "         With --revert, history is preserved -- no force-push needed."
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      --dry-run) dry_run=1 ;;
      --revert) use_revert=1 ;;
      --target)
        rollback_target_flag="${2:-}"
        shift
        ;;
      *)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  {
    echo "========================================="
    echo "Rollback Merge Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
  } >"$logfile"

  echo "=== Emergency Merge Rollback ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # [1/5] Verify current branch
  log_section_start "BRANCH VERIFICATION" "$logfile"

  local current_branch
  current_branch=$(git branch --show-current 2>&1)
  echo "Current branch: ${current_branch}" | tee -a "$logfile"

  if [[ "${current_branch}" != "${CGW_TARGET_BRANCH}" ]]; then
    echo "" | tee -a "$logfile"
    err_tee "[FAIL] ERROR: Not on target branch (${CGW_TARGET_BRANCH})"
    echo "This script should only be run from the target branch" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Current branch: ${current_branch}" | tee -a "$logfile"
    echo "Expected: ${CGW_TARGET_BRANCH}" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Please checkout target branch first: git checkout ${CGW_TARGET_BRANCH}"
    log_section_end "BRANCH VERIFICATION" "$logfile" "1"
    exit 1
  fi
  echo "[OK] On target branch (${CGW_TARGET_BRANCH})" | tee -a "$logfile"
  log_section_end "BRANCH VERIFICATION" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [2/5] Check for uncommitted changes
  log_section_start "UNCOMMITTED CHANGES CHECK" "$logfile"

  if cgw_is_tree_clean; then
    echo "[OK] No uncommitted changes" | tee -a "$logfile"
  else
    if ! cgw_require_clean_tree --on-dirty confirm-abort --reason "rollback"; then
      log_section_end "UNCOMMITTED CHANGES CHECK" "$logfile" "1"
      exit 1
    fi
  fi
  log_section_end "UNCOMMITTED CHANGES CHECK" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [3/5] Find rollback target
  log_section_start "FIND ROLLBACK TARGET" "$logfile"

  local backup_tags
  backup_tags=$(cgw_list_backup_tags merge | sort -r | head -5)
  if [[ -n "${backup_tags}" ]]; then
    echo "Available backup tags:" | tee -a "$logfile"
    echo "${backup_tags}" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
  else
    echo "No backup tags found (pre-merge-*)" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
  fi

  echo "Recent commits:" | tee -a "$logfile"
  git log --oneline -5 | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  local latest_merge
  latest_merge=$(git log --merges --oneline -1)
  if [[ -n "${latest_merge}" ]]; then
    echo "Latest merge commit: ${latest_merge}" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
  fi

  log_section_end "FIND ROLLBACK TARGET" "$logfile" "0"

  # [4/5] Choose the rollback target. Its meaning depends on the mode:
  #   hard   (default) -> the *reset point*: the commit the branch is reset to
  #   --revert         -> the *merge under revert*: a merge commit, never a backup tag
  # A backup tag is only ever a reset point; reverting needs the merge itself, and
  # HEAD~1 of a --no-ff history is the *previous* merge, not the one being undone.
  local rollback_target=""
  local target_sha=""

  if [[ -n "${rollback_target_flag}" ]]; then
    if ! target_sha=$(git rev-parse --verify -q "${rollback_target_flag}^{commit}"); then
      err "Invalid --target ref: ${rollback_target_flag}"
      exit 1
    fi
    rollback_target="${rollback_target_flag}"
    echo "Rollback target (from --target): ${rollback_target}" | tee -a "$logfile"
  elif [[ ${use_revert} -eq 1 ]]; then
    if [[ ${non_interactive} -eq 1 ]]; then
      if [[ "$(_rb_parent_count HEAD)" -lt 2 ]]; then
        err "[Non-interactive] Refusing --revert: HEAD is not a merge commit and no --target was given."
        err "Specify --target <merge-commit> (find it with: git log --merges --oneline)."
        _rollback_done=1
        exit 1
      fi
      rollback_target="HEAD"
      echo "[Non-interactive] Reverting the merge at HEAD" | tee -a "$logfile"
    else
      echo "[4/5] Choose the merge to revert:"
      echo ""
      echo "Available options:"
      if [[ "$(_rb_parent_count HEAD)" -ge 2 ]]; then
        echo "  1. Revert the merge at HEAD (recommended)"
      else
        echo "  1. Revert the merge at HEAD (unavailable: HEAD is not a merge commit)"
      fi
      echo "  2. Revert a specific merge commit hash"
      echo "  3. Cancel rollback"
      echo ""

      read -r -p "Select option (1-3): " rollback_choice

      case "${rollback_choice}" in
        1)
          rollback_target="HEAD"
          echo "Merge to revert: HEAD"
          ;;
        2)
          echo ""
          read -r -p "Enter merge commit hash: " rollback_target
          echo ""
          echo "Merge to revert: ${rollback_target}"
          ;;
        3)
          echo "" | tee -a "$logfile"
          echo "Rollback cancelled" | tee -a "$logfile"
          _rollback_done=1
          exit 0
          ;;
        *)
          err "Invalid choice: ${rollback_choice}"
          exit 1
          ;;
      esac
      if ! target_sha=$(git rev-parse --verify -q "${rollback_target}^{commit}"); then
        err "Invalid commit hash: ${rollback_target}"
        exit 1
      fi
    fi
    [[ -z "${target_sha}" ]] && target_sha=$(git rev-parse HEAD)
  elif [[ ${non_interactive} -eq 1 ]]; then
    # Hard mode without --target: only auto-pick the backup tag that is exactly the
    # state before HEAD's merge. Any other tag could discard unrelated later work.
    local latest_tag tag_kind
    latest_tag=$(cgw_list_backup_tags merge | sort -r | head -1)
    if [[ -z "${latest_tag}" ]]; then
      err "[Non-interactive] Refusing hard rollback: no --target specified and no pre-merge backup tag found."
      err "Specify --target <ref> or use --revert mode."
      _rollback_done=1
      exit 1
    fi
    tag_kind=$(_rb_classify_tag "${latest_tag}")
    if [[ "${tag_kind}" != "first-parent" ]]; then
      err "[Non-interactive] Refusing hard rollback: latest backup tag ${latest_tag} is not the state just before HEAD's merge (${tag_kind})."
      err "Specify --target <ref> explicitly, or use --revert."
      _rollback_done=1
      exit 1
    fi
    rollback_target="${latest_tag}"
    target_sha=$(git rev-parse "${latest_tag}^{commit}")
    echo "[Non-interactive] Using latest backup tag: ${rollback_target}" | tee -a "$logfile"
  else
    echo "[4/5] Choose rollback method:"
    echo ""
    echo "Available options:"
    echo "  1. Reset to the latest pre-merge backup tag (recommended)"
    echo "  2. Reset to the commit before HEAD (HEAD~1)"
    echo "  3. Reset to a specific commit hash"
    echo "  4. Cancel rollback"
    echo ""

    read -r -p "Select option (1-4): " rollback_choice

    case "${rollback_choice}" in
      1)
        rollback_target=$(cgw_list_backup_tags merge | sort -r | head -1)
        if [[ -z "${rollback_target}" ]]; then
          err "No backup tags found"
          echo "Please use option 2 or 3"
          exit 1
        fi
        case "$(_rb_classify_tag "${rollback_target}")" in
          same | unrelated)
            err "Backup tag ${rollback_target} is not a rollback point for ${CGW_TARGET_BRANCH}"
            echo "Please use option 2 or 3"
            exit 1
            ;;
          ancestor)
            echo "[!] Backup tag ${rollback_target} is older than HEAD's latest merge --"
            echo "    more than the latest merge will be discarded."
            ;;
        esac
        echo "Rollback target: ${rollback_target}"
        ;;
      2)
        rollback_target="HEAD~1"
        echo "Rollback target: HEAD~1 (previous commit)"
        ;;
      3)
        echo ""
        read -r -p "Enter commit hash: " rollback_target
        echo ""
        echo "Rollback target: ${rollback_target}"
        ;;
      4)
        echo "" | tee -a "$logfile"
        echo "Rollback cancelled" | tee -a "$logfile"
        _rollback_done=1
        exit 0
        ;;
      *)
        err "Invalid choice: ${rollback_choice}"
        exit 1
        ;;
    esac
    if ! target_sha=$(git rev-parse --verify -q "${rollback_target}^{commit}"); then
      err "Invalid rollback target: ${rollback_target}"
      exit 1
    fi
  fi

  # Revert mode needs a merge commit (git revert -m 1); check before any warning,
  # dry-run output or confirmation. Uses the peeled commit, not the ref/tag object.
  if [[ ${use_revert} -eq 1 ]]; then
    local parent_count
    parent_count=$(_rb_parent_count "${target_sha}")
    if [[ "${parent_count}" -lt 2 ]]; then
      err "--revert requires a merge commit (2+ parents), but ${rollback_target} has ${parent_count} parent(s)"
      err "Use plain rollback (omit --revert) or provide a merge commit hash with --target"
      exit 1
    fi
  fi

  # [5/5] Execute rollback
  echo "" | tee -a "$logfile"
  if [[ ${use_revert} -eq 1 ]]; then
    echo "[!] This will add a commit to ${CGW_TARGET_BRANCH} that reverts the merge:" | tee -a "$logfile"
    git log "${target_sha}" --oneline -1 | tee -a "$logfile"
  else
    echo "[!] WARNING: This will permanently reset ${CGW_TARGET_BRANCH} branch to:" | tee -a "$logfile"
    git log "${target_sha}" --oneline -1 | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "$(git rev-list --count "${target_sha}..HEAD" 2>/dev/null || echo "?") commit(s) after this point will be discarded" | tee -a "$logfile"
    echo "(recoverable from the pre-rollback-* backup tag created before the reset)." | tee -a "$logfile"
  fi
  echo "" | tee -a "$logfile"

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- no changes made ===" | tee -a "$logfile"
    if [[ ${use_revert} -eq 1 ]]; then
      echo "Would revert merge: ${rollback_target} (${target_sha})" | tee -a "$logfile"
    else
      echo "Would reset ${CGW_TARGET_BRANCH} to: ${rollback_target}" | tee -a "$logfile"
    fi
    _rollback_done=1
    exit 0
  fi

  # Non-interactive runs reach here with an explicit --target or an auto-selected
  # target validated above (revert: HEAD is a merge; hard: tag == HEAD^1).
  if ! cgw_confirm "Type 'ROLLBACK' to confirm" --literal-token ROLLBACK --non-interactive accept; then
    echo "" | tee -a "$logfile"
    echo "Rollback cancelled" | tee -a "$logfile"
    _rollback_done=1
    exit 0
  fi

  if [[ ${use_revert} -eq 1 ]]; then
    # Safe revert mode: creates a new commit that undoes the merge.
    # Preserves history -- no force-push needed (Pro Git p.288-289).
    log_section_start "GIT REVERT" "$logfile"
    if run_git_with_logging "GIT REVERT MERGE" "$logfile" revert -m 1 --no-edit "${target_sha}"; then
      log_section_end "GIT REVERT" "$logfile" "0"
      echo "" | tee -a "$logfile"
      {
        echo "========================================"
        echo "[ROLLBACK SUMMARY -- REVERT MODE]"
        echo "========================================"
      } | tee -a "$logfile"
      echo "[OK] REVERT SUCCESSFUL" | tee -a "$logfile"
      echo "" | tee -a "$logfile"
      echo "Summary:" | tee -a "$logfile"
      line="$(git log --oneline -1)"
      echo "  Current HEAD: ${line}" | tee -a "${logfile}"
      local revert_sha
      revert_sha=$(git rev-parse --short HEAD)
      echo "" | tee -a "$logfile"
      echo "Next steps:" | tee -a "$logfile"
      echo "  1. Verify revert: git log --oneline -5" | tee -a "$logfile"
      echo "  2. Push normally: ./scripts/git/push_validated.sh" | tee -a "$logfile"
      echo "     (no force-push needed -- history is preserved)" | tee -a "$logfile"
      echo "" | tee -a "$logfile"
      echo "  [!] Before re-merging this work later, revert the revert first:" | tee -a "$logfile"
      echo "        git revert ${revert_sha}" | tee -a "$logfile"
      echo "      Otherwise git treats the reverted commits as already merged and" | tee -a "$logfile"
      echo "      the re-merge silently brings in none of their changes (Pro Git," | tee -a "$logfile"
      echo "      'Undoing Merges')." | tee -a "$logfile"
      {
        echo ""
        echo "End Time: $(date)"
      } | tee -a "$logfile"
      echo "" | tee -a "$logfile"
      _rollback_done=1
      echo "Full log: $logfile"
    else
      log_section_end "GIT REVERT" "$logfile" "1"
      echo "" | tee -a "$logfile"
      err_tee "[FAIL] Revert failed"
      echo "Please manually revert: git revert -m 1 ${target_sha}"
      exit 1
    fi
  else
    log_section_start "GIT RESET" "$logfile"

    # Tag current HEAD before the destructive hard reset so the discarded state
    # is recoverable (matches rebase_safe.sh / undo_last.sh). Critical for the
    # --non-interactive path, which auto-accepts the confirmation token.
    cgw_create_backup_tag rollback

    if run_git_with_logging "GIT RESET HARD" "$logfile" reset --hard "${target_sha}"; then
      log_section_end "GIT RESET" "$logfile" "0"
      echo "" | tee -a "$logfile"
      {
        echo "========================================"
        echo "[ROLLBACK SUMMARY]"
        echo "========================================"
      } | tee -a "$logfile"
      echo "[OK] ROLLBACK SUCCESSFUL" | tee -a "$logfile"
      echo "" | tee -a "$logfile"
      echo "Summary:" | tee -a "$logfile"
      line="$(git log --oneline -1)"
      echo "  Current HEAD: ${line}" | tee -a "${logfile}"
      echo "" | tee -a "$logfile"
      echo "Next steps:" | tee -a "$logfile"
      echo "  1. Verify rollback: git log --oneline -5" | tee -a "$logfile"
      echo "  2. If correct, force push: git push ${CGW_REMOTE} ${CGW_TARGET_BRANCH} --force-with-lease" | tee -a "$logfile"
      echo "  3. If issues, contact maintainer" | tee -a "$logfile"
      echo "" | tee -a "$logfile"
      echo "  [!] WARNING: Force push will rewrite remote history!" | tee -a "$logfile"
      {
        echo ""
        echo "End Time: $(date)"
      } | tee -a "$logfile"
      echo "" | tee -a "$logfile"
      _rollback_done=1
      echo "Full log: $logfile"
    else
      log_section_end "GIT RESET" "$logfile" "1"
      echo "" | tee -a "$logfile"
      err_tee "[FAIL] Rollback failed"
      echo "Please manually reset: git reset --hard ${target_sha}"
      exit 1
    fi
  fi
}

main "$@"
