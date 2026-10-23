#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexander Korneev
# SPDX-License-Identifier: MIT
# repo_state.sh - Read-only repository state snapshot and next-step suggestion
# Purpose: Check the preconditions every git action depends on (inside a repo, on a branch,
#          has commits) and report the facts the /auto-git-workflow-cmd menu is built from:
#          branch, upstream, ahead/behind, staged/unstaged/untracked counts, in-progress
#          operation, stash count, local-only files, and the first-match suggestion from the
#          command's 11-row table. Never changes anything and never touches the network:
#          ahead/behind uses the remote-tracking refs already on disk (run `git fetch` first
#          for fresh counts). It writes no log file either, so the tree stays untouched.
# Usage: ./scripts/git/repo_state.sh [--json]
#
# Globals:
#   SCRIPT_DIR        - Directory containing this script
#   PROJECT_ROOT      - Auto-detected git repo root (set by _config.sh)
#   CGW_REMOTE        - Remote name for the target-branch lookup (default: origin)
#   CGW_TARGET_BRANCH - Target branch (default: auto-detected)
#   CGW_LOCAL_FILES   - Local-only files, matched by cgw_is_local_file
# Arguments:
#   --json       Print one JSON object instead of key=value lines
#   -h, --help   Show help
# Returns:
#   0 when a report was produced (even on a dirty, conflicted or detached repo),
#   1 when no report is possible (not a repository, no commits yet),
#   2 on a usage error

set -uo pipefail

# Index refreshes are opportunistic writes; this script promises to write nothing.
export GIT_OPTIONAL_LOCKS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_JSON=0

# Ordered result set: key, value, type (n = number, s = string).
declare -a _RS_KEY=() _RS_VAL=() _RS_TYPE=()

_show_help() {
  echo "Usage: ./scripts/git/repo_state.sh [--json]"
  echo ""
  echo "Read-only snapshot of the repository state plus the suggested next step."
  echo "Never fetches or changes anything; ahead/behind uses the remote-tracking refs"
  echo "already on disk (run 'git fetch' first for fresh counts)."
  echo ""
  echo "Options:"
  echo "  --json       Print one JSON object instead of key=value lines"
  echo "  -h, --help   Show this help"
  echo ""
  echo "Output keys (key=value, one per line, in this order):"
  echo "  inside_repo         1 inside a work tree, 0 otherwise"
  echo "  repo_root           Absolute path of the work tree root"
  echo "  branch              Current branch name (empty when detached)"
  echo "  detached            1 when HEAD is detached (includes a stopped rebase)"
  echo "  head                Short commit hash of HEAD"
  echo "  upstream            Upstream ref, e.g. origin/main (empty when none)"
  echo "  upstream_gone       1 when an upstream is configured but its ref is missing"
  echo "  ahead, behind       Commits ahead of / behind the upstream (0 without one)"
  echo "  staged              Paths with changes in the index"
  echo "  unstaged            Paths with working-tree changes not in the index"
  echo "  untracked           Untracked, non-ignored files (git ls-files --others)"
  echo "  conflicted          Paths with unresolved merge conflicts"
  echo "  in_progress         none, or comma list of merge, rebase, cherry-pick, revert, bisect"
  echo "  stash               Number of stash entries"
  echo "  local_only_dirty    Changed/untracked paths that are CGW_LOCAL_FILES"
  echo "  local_only_present  CGW_LOCAL_FILES entries that exist on disk"
  echo "  target              Target branch used for the unmerged check"
  echo "  unmerged_to_target  Commits on HEAD not yet on the target"
  echo "  upstream_overlap    Uncommitted paths the upstream also changed"
  echo "  clean               1 when there is nothing staged, unstaged, untracked or conflicted"
  echo "  suggestion          Row number 1-11 of the command's suggestion table"
  echo "  suggestion_label    Short label of that row"
  echo ""
  echo "On failure the output holds inside_repo, error (not-a-repo or no-commits) and,"
  echo "when known, branch; the message goes to stderr and the exit code is 1."
  echo ""
  echo "Suggestion labels: 1 finish-in-progress, 2 detached-head, 3 reconcile-upstream,"
  echo "  4 commit, 5 push, 6 pull, 7 sync-diverged, 8 publish-branch, 9 merge-or-pr,"
  echo "  10 restore-stash, 11 clean"
  echo ""
  echo "Exit codes: 0 report produced, 1 not a repository / no commits, 2 usage error"
}

# _rs_add <key> <value> <n|s>
_rs_add() {
  _RS_KEY+=("$1")
  _RS_VAL+=("$2")
  _RS_TYPE+=("$3")
}

# _json_escape <string>: JSON string body on stdout (no surrounding quotes, no jq needed).
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Remaining control characters are not valid unescaped in JSON; they cannot occur in the
  # values reported here, so a placeholder is enough.
  s="${s//[[:cntrl:]]/?}"
  printf '%s' "${s}"
}

# _emit: print the collected result set as key=value lines or one JSON object.
_emit() {
  local i n="${#_RS_KEY[@]}" v
  if ((OUTPUT_JSON == 1)); then
    local out="{" sep=""
    for ((i = 0; i < n; i++)); do
      if [[ "${_RS_TYPE[i]}" == "n" ]]; then
        out+="${sep}\"${_RS_KEY[i]}\":${_RS_VAL[i]}"
      else
        v="$(_json_escape "${_RS_VAL[i]}")"
        out+="${sep}\"${_RS_KEY[i]}\":\"${v}\""
      fi
      sep=","
    done
    printf '%s}\n' "${out}"
  else
    for ((i = 0; i < n; i++)); do
      v="${_RS_VAL[i]//$'\n'/ }"
      printf '%s=%s\n' "${_RS_KEY[i]}" "${v//$'\r'/ }"
    done
  fi
}

# _fail_report <error-code> <message> [branch]: report a precondition failure and exit 1.
_fail_report() {
  _rs_add inside_repo "$([[ "$1" == "not-a-repo" ]] && echo 0 || echo 1)" n
  _rs_add error "$1" s
  [[ -n "${3:-}" ]] && _rs_add branch "$3" s
  _emit
  echo "[ERROR] $2" >&2
  exit 1
}

# _strip_fields <record> <n>: set _PATH to the record minus its first <n> space-separated fields.
_strip_fields() {
  _PATH="$1"
  local i
  for ((i = 0; i < $2; i++)); do
    _PATH="${_PATH#* }"
  done
}

# _in_progress: comma list of the operations git has paused, or "none". Uses --git-path so a
# linked worktree reads its own state files.
_in_progress() {
  local -a found=()
  [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]] && found+=("rebase")
  [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]] && found+=("merge")
  [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]] && found+=("cherry-pick")
  [[ -f "$(git rev-parse --git-path REVERT_HEAD)" ]] && found+=("revert")
  [[ -f "$(git rev-parse --git-path BISECT_LOG)" ]] && found+=("bisect")
  if ((${#found[@]} == 0)); then
    echo "none"
  else
    local IFS=","
    echo "${found[*]}"
  fi
}

# _suggest: set SUGGESTION / SUGGESTION_LABEL from the state variables, first match wins.
# Mirrors the table in command/auto-git-workflow-cmd.md (Step 1) row for row.
_suggest() {
  if ((conflicted > 0)) || [[ "${in_progress}" != "none" ]]; then
    SUGGESTION=1 SUGGESTION_LABEL="finish-in-progress"
  elif ((detached == 1)); then
    SUGGESTION=2 SUGGESTION_LABEL="detached-head"
  elif ((dirty > 0 && upstream_overlap > 0)); then
    SUGGESTION=3 SUGGESTION_LABEL="reconcile-upstream"
  elif ((dirty > 0)); then
    SUGGESTION=4 SUGGESTION_LABEL="commit"
  elif ((ahead > 0 && behind > 0)); then
    SUGGESTION=7 SUGGESTION_LABEL="sync-diverged"
  elif ((ahead > 0)); then
    SUGGESTION=5 SUGGESTION_LABEL="push"
  elif ((behind > 0)); then
    SUGGESTION=6 SUGGESTION_LABEL="pull"
  elif [[ -z "${upstream}" ]]; then
    SUGGESTION=8 SUGGESTION_LABEL="publish-branch"
  elif ((unmerged_to_target > 0)) && [[ "${branch}" != "${target_short}" ]]; then
    SUGGESTION=9 SUGGESTION_LABEL="merge-or-pr"
  elif ((stash > 0)); then
    SUGGESTION=10 SUGGESTION_LABEL="restore-stash"
  else
    SUGGESTION=11 SUGGESTION_LABEL="clean"
  fi
}

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      _show_help
      exit 0
      ;;
    --json) OUTPUT_JSON=1 ;;
    *)
      echo "[ERROR] Unknown flag: $1 (see --help)" >&2
      exit 2
      ;;
  esac
  shift
done

# ── preconditions ─────────────────────────────────────────────────────────────
# Checked against the current directory before _config.sh runs: its fallback walks up from
# SCRIPT_DIR, which would silently report on the toolkit's own checkout when the caller is
# not inside a repository.

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]]; then
  _fail_report "not-a-repo" "Not inside a git work tree: ${PWD}"
fi
if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  _fail_report "no-commits" "Repository has no commits yet" "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi

# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

main() {
  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  local branch="" detached=0 upstream="" ab_seen=0 ahead=0 behind=0
  local n_staged=0 n_unstaged=0 untracked=0 conflicted=0
  local rec xy path a b
  local -A dirty_paths=()

  # One status call, NUL-delimited so odd paths survive. Entry shapes (path after N fields):
  #   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>              ordinary, 8 fields
  #   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <score> <path> NUL <orig>   rename, 9 fields
  #   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>    unmerged, 10 fields
  while IFS= read -r -d '' rec; do
    case "${rec}" in
      "# branch.head "*)
        branch="${rec#"# branch.head "}"
        if [[ "${branch}" == "(detached)" ]]; then
          branch=""
          detached=1
        fi
        ;;
      "# branch.upstream "*) upstream="${rec#"# branch.upstream "}" ;;
      "# branch.ab "*)
        read -r _ _ a b <<<"${rec}"
        ahead="${a#+}"
        behind="${b#-}"
        ab_seen=1
        ;;
      "1 "*)
        xy="${rec:2:2}"
        [[ "${xy:0:1}" != "." ]] && ((n_staged++))
        [[ "${xy:1:1}" != "." ]] && ((n_unstaged++))
        _strip_fields "${rec}" 8
        dirty_paths["${_PATH}"]=1
        ;;
      "2 "*)
        xy="${rec:2:2}"
        [[ "${xy:0:1}" != "." ]] && ((n_staged++))
        [[ "${xy:1:1}" != "." ]] && ((n_unstaged++))
        _strip_fields "${rec}" 9
        dirty_paths["${_PATH}"]=1
        IFS= read -r -d '' _ # the rename's original path
        ;;
      "u "*)
        ((conflicted++))
        _strip_fields "${rec}" 10
        dirty_paths["${_PATH}"]=1
        ;;
    esac
  done < <(git status --porcelain=v2 --branch --untracked-files=no -z 2>/dev/null)

  while IFS= read -r -d '' path; do
    ((untracked++))
    dirty_paths["${path}"]=1
  done < <(git ls-files --others --exclude-standard -z 2>/dev/null)

  local dirty=$((n_staged + n_unstaged + untracked))
  local upstream_gone=0
  if [[ -n "${upstream}" && ${ab_seen} -eq 0 ]]; then
    upstream_gone=1
  fi

  # Paths changed locally AND by the upstream since the merge base.
  local upstream_overlap=0
  if ((dirty > 0 && ab_seen == 1)); then
    while IFS= read -r -d '' path; do
      [[ -n "${dirty_paths[${path}]+x}" ]] && ((upstream_overlap++))
    done < <(git diff --name-only -z "HEAD...@{u}" 2>/dev/null)
  fi

  local in_progress
  in_progress="$(_in_progress)"

  local stash
  stash="$(git stash list 2>/dev/null | wc -l | tr -d '[:space:]')"
  stash="${stash:-0}"

  # Local-only files: dirty paths that match, and configured entries that exist on disk.
  local local_only_dirty=0 local_only_present=0 entry
  for path in "${!dirty_paths[@]}"; do
    cgw_is_local_file "${path}" && ((local_only_dirty++))
  done
  local -a _local_arr=()
  read -r -a _local_arr <<<"${CGW_LOCAL_FILES:-}" || true
  for entry in "${_local_arr[@]+"${_local_arr[@]}"}"; do
    [[ -e "${entry%/}" ]] && ((local_only_present++))
  done

  # Target branch: the remote's HEAD when known, else the configured/auto-detected target.
  local remote="${CGW_REMOTE:-origin}" target target_short unmerged_to_target=0
  target="$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null)" || target=""
  target="${target:-${CGW_TARGET_BRANCH:-main}}"
  target_short="${target#"${remote}"/}"
  unmerged_to_target="$(git rev-list --count "${target}..HEAD" 2>/dev/null)" || unmerged_to_target=0
  unmerged_to_target="${unmerged_to_target:-0}"

  local clean=0
  ((dirty == 0 && conflicted == 0)) && clean=1

  SUGGESTION=11 SUGGESTION_LABEL="clean"
  _suggest

  _rs_add inside_repo 1 n
  _rs_add repo_root "${PROJECT_ROOT}" s
  _rs_add branch "${branch}" s
  _rs_add detached "${detached}" n
  _rs_add head "$(git rev-parse --short HEAD 2>/dev/null)" s
  _rs_add upstream "${upstream}" s
  _rs_add upstream_gone "${upstream_gone}" n
  _rs_add ahead "${ahead}" n
  _rs_add behind "${behind}" n
  _rs_add staged "${n_staged}" n
  _rs_add unstaged "${n_unstaged}" n
  _rs_add untracked "${untracked}" n
  _rs_add conflicted "${conflicted}" n
  _rs_add in_progress "${in_progress}" s
  _rs_add stash "${stash}" n
  _rs_add local_only_dirty "${local_only_dirty}" n
  _rs_add local_only_present "${local_only_present}" n
  _rs_add target "${target}" s
  _rs_add unmerged_to_target "${unmerged_to_target}" n
  _rs_add upstream_overlap "${upstream_overlap}" n
  _rs_add clean "${clean}" n
  _rs_add suggestion "${SUGGESTION}" n
  _rs_add suggestion_label "${SUGGESTION_LABEL}" s
  _emit
  exit 0
}

main
