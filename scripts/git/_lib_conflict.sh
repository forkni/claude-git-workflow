#!/usr/bin/env bash
# _lib_conflict.sh - Conflict classification and safe auto-resolution for claude-git-workflow scripts
# Usage: sourced automatically by _common.sh -- do not source directly
#
# Functions:
#   cgw_classify_conflicts()       - Parse git status into 8 conflict-category arrays; sets CGW_CONFLICT_TOTAL
#   cgw_conflict_path_is_binary()  - 0 if a conflicted path is binary (gitattributes or NUL in the theirs blob)
#   cgw_resolve_safe_conflicts()   - Auto-resolve DU/DD, emit halt messages; sets CGW_CONFLICT_STATE
#   cgw_print_conflict_summary()   - Print categorised file list from the last classify call
#
# Uses err()/err_tee() and CGW_AUTO_RESOLVE_MODIFY_DELETE from _common.sh / _config.sh at call time.

# ── conflict-policy module ─────────────────────────────────────────────────────
# Single source of truth for git conflict classification and safe auto-resolution.
#
# cgw_classify_conflicts [<porcelain_override>]
#   Parses git status --short (or an optional injected fixture string) into eight
#   category arrays. Returns 0 if any conflicts present, 1 if none.
#
# cgw_resolve_safe_conflicts <op> <original_branch>
#   Owns the policy: auto-resolves DD (propagates failure); DU only when
#   CGW_AUTO_RESOLVE_MODIFY_DELETE=1 and the path is text (see ADR 0005).
#   Re-classifies, emits per-category halt messages with op-specific recovery
#   footer. Sets CGW_CONFLICT_STATE (none|resolved|unresolved). Returns 0 if no
#   manual action needed, 1 if caller should exit 1.
#
# cgw_conflict_path_is_binary <path>
#   Returns 0 if <path> is binary: gitattributes mark it binary / -diff, or the
#   first 8000 bytes of its stage-3 (theirs) blob contain a NUL.

# Conflict-category arrays — reset on every cgw_classify_conflicts call.
declare -g CGW_CONFLICT_DU_FILES=() # modify/delete   (halt by default; opt-in auto-resolve for text: git rm)
declare -g CGW_CONFLICT_DD_FILES=() # both deleted    (auto-resolvable: git rm)
declare -g CGW_CONFLICT_UU_FILES=() # both modified   (halt: content conflict)
declare -g CGW_CONFLICT_AU_FILES=() # add/unmerged    (halt: add-side)
declare -g CGW_CONFLICT_AA_FILES=() # both added      (halt: add-side)
declare -g CGW_CONFLICT_UD_FILES=() # deleted by them (halt: accept deletion vs keep ours)
declare -g CGW_CONFLICT_AD_FILES=() # added by us, deleted by theirs  (halt: keep-ours vs keep-theirs)
declare -g CGW_CONFLICT_DA_FILES=() # deleted by us, added by theirs  (halt: keep-ours vs keep-theirs)
declare -g CGW_CONFLICT_TOTAL=0
# shellcheck disable=SC2034  # CGW_CONFLICT_STATE is read by callers outside _common.sh
declare -g CGW_CONFLICT_STATE="none" # none | resolved | unresolved

# shellcheck disable=SC2120  # optional arg used by unit tests; callers inside file omit it
cgw_classify_conflicts() {
  CGW_CONFLICT_DU_FILES=()
  CGW_CONFLICT_DD_FILES=()
  CGW_CONFLICT_UU_FILES=()
  CGW_CONFLICT_AU_FILES=()
  CGW_CONFLICT_AA_FILES=()
  CGW_CONFLICT_UD_FILES=()
  CGW_CONFLICT_AD_FILES=()
  CGW_CONFLICT_DA_FILES=()
  CGW_CONFLICT_TOTAL=0

  # Inner classifier shared by both paths.  Receives XY<space>path per call.
  _cgw_classify_one() {
    local code="${1:0:2}"
    local path="${1:3}"
    [[ -z "${path}" ]] && return
    case "${code}" in
      DU)
        CGW_CONFLICT_DU_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      DD)
        CGW_CONFLICT_DD_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      UU)
        CGW_CONFLICT_UU_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      AU)
        CGW_CONFLICT_AU_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      AA)
        CGW_CONFLICT_AA_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      UD)
        CGW_CONFLICT_UD_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      AD)
        CGW_CONFLICT_AD_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
      DA)
        CGW_CONFLICT_DA_FILES+=("${path}")
        CGW_CONFLICT_TOTAL=$((CGW_CONFLICT_TOTAL + 1))
        ;;
    esac
  }

  if [[ $# -gt 0 ]]; then
    # Test-injection path: caller passes newline-delimited porcelain text.
    # Kept for unit-test compatibility (tests/unit/common.bats injects text directly).
    local line
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      _cgw_classify_one "${line}"
    done <<<"$1"
  else
    # Production path: NUL-delimited --porcelain -z never C-quotes paths,
    # so paths with spaces, Unicode, and special characters are preserved exactly.
    # This is the documented-stable format contract (unlike --short which is human output).
    local record
    while IFS= read -r -d $'\0' record; do
      [[ -z "${record}" ]] && continue
      _cgw_classify_one "${record}"
    done < <(git status --porcelain -z 2>/dev/null || true)
  fi

  unset -f _cgw_classify_one
  [[ "${CGW_CONFLICT_TOTAL}" -gt 0 ]]
}

cgw_conflict_path_is_binary() {
  local path="$1" attrs total text
  attrs=$(git check-attr binary diff -- "${path}" 2>/dev/null)
  if [[ "${attrs}" == *"binary: set"* ]] || [[ "${attrs}" == *"diff: unset"* ]]; then
    return 0
  fi
  total=$(git cat-file blob ":3:${path}" 2>/dev/null | head -c 8000 | wc -c)
  text=$(git cat-file blob ":3:${path}" 2>/dev/null | head -c 8000 | LC_ALL=C tr -d '\000' | wc -c)
  [[ "${total//[[:space:]]/}" != "${text//[[:space:]]/}" ]]
}

# shellcheck disable=SC2034  # CGW_CONFLICT_STATE is read by callers outside _common.sh
cgw_resolve_safe_conflicts() {
  local op="$1" original_branch="$2"
  local _log="${logfile:-/dev/null}"
  CGW_CONFLICT_STATE="none"

  cgw_classify_conflicts
  if [[ "${CGW_CONFLICT_TOTAL}" -eq 0 ]]; then
    return 0
  fi

  # DU (modify/delete): our side deleted the file, theirs modified it. Accepting the
  # deletion silently discards the other side's work, so it halts by default (ADR 0005).
  # Opt-in CGW_AUTO_RESOLVE_MODIFY_DELETE=1 accepts the deletion for text files only;
  # binary paths always halt.
  local f resolution_failed=0 auto_resolved=0
  if [[ "${CGW_AUTO_RESOLVE_MODIFY_DELETE:-0}" == "1" ]]; then
    for f in "${CGW_CONFLICT_DU_FILES[@]}"; do
      echo "  Found modify/delete conflict: ${f}"
      if cgw_conflict_path_is_binary "${f}"; then
        echo "  [SKIP] Binary file -- needs a manual decision: ${f}"
        continue
      fi
      if git rm "${f}" >/dev/null 2>&1; then
        echo "  [OK] Removed: ${f}"
        auto_resolved=$((auto_resolved + 1))
      else
        echo "  [FAIL] Failed to remove ${f}" >&2
        resolution_failed=1
      fi
    done
  fi

  # Auto-resolve DD (both deleted): nothing to lose — propagate failure.
  for f in "${CGW_CONFLICT_DD_FILES[@]}"; do
    echo "  Found both-deleted conflict: ${f}"
    if git rm "${f}" >/dev/null 2>&1; then
      echo "  [OK] Removed (both deleted): ${f}"
      auto_resolved=$((auto_resolved + 1))
    else
      echo "  [FAIL] Failed to remove ${f}" >&2
      resolution_failed=1
    fi
  done

  if [[ "${resolution_failed}" -eq 1 ]]; then
    err_tee "[FAIL] Auto-resolution failed for some files"
    CGW_CONFLICT_STATE="unresolved"
    return 1
  fi

  # Re-classify so halt checks see the post-rm state (fixes stale-snapshot bug).
  cgw_classify_conflicts
  if [[ "${CGW_CONFLICT_TOTAL}" -eq 0 ]]; then
    if [[ "${auto_resolved}" -gt 0 ]]; then
      echo "[OK] Auto-resolved both-deleted conflicts (and modify/delete, opted in)" | tee -a "${_log}"
    fi
    CGW_CONFLICT_STATE="resolved"
    return 0
  fi

  if [[ "${auto_resolved}" -gt 0 ]]; then
    echo "[OK] Auto-resolved both-deleted conflicts (and modify/delete, opted in)" | tee -a "${_log}"
  fi

  # Op-specific recovery footer.
  local continue_hint abort_hint
  case "${op}" in
    merge)
      continue_hint="  1. Edit conflicted files
  2. git add <resolved files>
  3. ./scripts/git/commit_enhanced.sh   (no message needed -- uses git's prepared merge message; do NOT pass --only)"
      abort_hint="Or abort: git merge --abort && git checkout ${original_branch}"
      ;;
    cherry-pick)
      continue_hint="  1. Edit conflicted files
  2. git add <resolved files>
  3. git cherry-pick --continue"
      abort_hint="Or abort: git cherry-pick --abort && git checkout ${original_branch}"
      ;;
    *)
      continue_hint="  1. Edit conflicted files
  2. git add <resolved files>"
      abort_hint="Or restore: git checkout ${original_branch}"
      ;;
  esac

  local any_halt=0

  # DU — modify/delete: we deleted, they modified (their version is in the work tree)
  if [[ "${#CGW_CONFLICT_DU_FILES[@]}" -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Modify/delete conflicts require manual resolution (deleted by us, modified by them):"
    printf '  %s\n' "${CGW_CONFLICT_DU_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually (for each file):"
    echo "  Accept deletion:    git rm <file>"
    echo "  Keep their version: git add <file>"
    echo "(CGW_AUTO_RESOLVE_MODIFY_DELETE=1 accepts the deletion automatically for text files.)"
    echo ""
    printf '%s\n' "${continue_hint}"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # UU — both modified (content conflict)
  if [[ "${#CGW_CONFLICT_UU_FILES[@]}" -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Content conflicts require manual resolution:"
    printf '  %s\n' "${CGW_CONFLICT_UU_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually:"
    printf '%s\n' "${continue_hint}"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # AU/AA — add-side conflicts
  if [[ $((${#CGW_CONFLICT_AU_FILES[@]} + ${#CGW_CONFLICT_AA_FILES[@]})) -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Add/add or add/unmerged conflicts require manual resolution:"
    [[ "${#CGW_CONFLICT_AU_FILES[@]}" -gt 0 ]] &&
      printf '  %s\n' "${CGW_CONFLICT_AU_FILES[@]}" | tee -a "${_log}"
    [[ "${#CGW_CONFLICT_AA_FILES[@]}" -gt 0 ]] &&
      printf '  %s\n' "${CGW_CONFLICT_AA_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually:"
    printf '%s\n' "${continue_hint}"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # UD — updated by us, deleted by them
  if [[ "${#CGW_CONFLICT_UD_FILES[@]}" -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Deleted-by-them conflicts require manual resolution:"
    printf '  %s\n' "${CGW_CONFLICT_UD_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually (for each file):"
    echo "  Accept deletion: git rm <file>"
    echo "  Keep ours:       git add <file>"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # AD/DA — add/delete conflicts
  if [[ $((${#CGW_CONFLICT_AD_FILES[@]} + ${#CGW_CONFLICT_DA_FILES[@]})) -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Add/delete conflicts require manual resolution:"
    [[ "${#CGW_CONFLICT_AD_FILES[@]}" -gt 0 ]] &&
      printf '  %s\n' "${CGW_CONFLICT_AD_FILES[@]}" | tee -a "${_log}"
    [[ "${#CGW_CONFLICT_DA_FILES[@]}" -gt 0 ]] &&
      printf '  %s\n' "${CGW_CONFLICT_DA_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually (for each file):"
    echo "  Keep ours:   git checkout --ours <file> && git add <file>"
    echo "  Keep theirs: git checkout --theirs <file> && git add <file>"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  if [[ "${any_halt}" -eq 1 ]]; then
    CGW_CONFLICT_STATE="unresolved"
    return 1
  fi

  CGW_CONFLICT_STATE="resolved"
  return 0
}

# Print a categorised conflict file list from the most recent cgw_classify_conflicts call.
# Does nothing if CGW_CONFLICT_TOTAL == 0.
cgw_print_conflict_summary() {
  [[ "${CGW_CONFLICT_TOTAL}" -eq 0 ]] && return 0
  local _f
  echo "  Conflicting files:"
  for _f in "${CGW_CONFLICT_UU_FILES[@]}"; do echo "    ${_f} (both modified)"; done
  for _f in "${CGW_CONFLICT_DU_FILES[@]}"; do echo "    ${_f} (modify/delete)"; done
  for _f in "${CGW_CONFLICT_UD_FILES[@]}"; do echo "    ${_f} (deleted by them)"; done
  for _f in "${CGW_CONFLICT_AA_FILES[@]}"; do echo "    ${_f} (both added)"; done
  for _f in "${CGW_CONFLICT_AU_FILES[@]}"; do echo "    ${_f} (add/unmerged)"; done
  for _f in "${CGW_CONFLICT_AD_FILES[@]}"; do echo "    ${_f} (added by us, deleted by theirs)"; done
  for _f in "${CGW_CONFLICT_DA_FILES[@]}"; do echo "    ${_f} (deleted by us, added by theirs)"; done
  for _f in "${CGW_CONFLICT_DD_FILES[@]}"; do echo "    ${_f} (both deleted)"; done
}
