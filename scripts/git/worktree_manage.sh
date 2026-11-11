#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexander Korneev
# SPDX-License-Identifier: MIT
# worktree_manage.sh - Git worktree management wrapper
# Purpose: Add, list, remove, and prune git linked worktrees in a safe, consistent
#          way that matches the CGW toolkit conventions (dry-run default for
#          destructive ops, --non-interactive for CI, confirmation gate).
#          Linked worktrees let you check out multiple branches simultaneously
#          without stashing — useful for parallel feature work or hot-fixes.
# Usage: ./scripts/git/worktree_manage.sh <subcommand> [OPTIONS]
#
# Subcommands:
#   list              List all worktrees (main + linked)
#   list --status [--no-pr]  One row per linked worktree: merged, changed,
#                            untracked, ahead, PR state; counts the safe ones
#   add  <path> [<branch> [<base>]]   Add a linked worktree (creates branch if needed,
#                            from <base> -- default HEAD, with no upstream until first push,
#                            or tracking <remote>/<branch> when only the remote has it
#                            or <base> is that ref)
#   link [<path>]            Link scripts/git and .githooks from the main worktree
#   remove <path>            Remove a linked worktree (dry-run default)
#   remove-merged            Remove every merged, clean linked worktree and
#                            its branch (git branch -d; dry-run default)
#   prune                    Remove stale administrative files (dry-run default)
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
# Returns:
#   0 on success, 1 on failure (remove / remove-merged: also when a folder
#   stays after git unregistered the worktree)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

init_logging "worktree_manage"

# ---------------------------------------------------------------------------
# Worktree-tooling link helpers
# ---------------------------------------------------------------------------
# scripts/git/ and .githooks/ are gitignored, so a linked worktree never gets
# them checked out. These helpers create a real link so both are reachable at
# their normal path from inside the worktree: scripts/git for direct script
# invocation (`./scripts/git/check_lint.sh`), and .githooks so install_hooks.sh
# has a template source to install from without cd-ing back to the main
# worktree. Actual hook execution doesn't depend on this link — hooks/pre-*
# already resolve _common.sh via their own main-worktree fallback regardless
# (see commit 1) — but install_hooks.sh (see below) still needs a source to
# copy from when reinstalling into the shared $GIT_COMMON_DIR/hooks.

# True if $1 is a symlink (POSIX) or an NTFS junction/reparse point (Windows).
# `test -L` alone is not reliable for junctions under Git Bash/MSYS, so fall
# back to `fsutil reparsepoint query`, which is authoritative on Windows.
_cgw_is_link() {
  local p="$1"
  [[ -L "${p}" ]] && return 0
  if [[ -d "${p}" ]] && command -v fsutil >/dev/null 2>&1; then
    fsutil reparsepoint query "${p}" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# True if $1 and $2 resolve to the same directory. Used to recognise a LEGACY
# link at a tooling path (made by older CGW versions) that points at the main
# worktree, so `link` can replace it. `cd && pwd -P` follows an NTFS
# junction's reparse point on Windows/MSYS (unlike `stat`, whose device:inode
# on a junction identifies the reparse point itself, not its target).
_cgw_same_dir() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  [[ "${a}" == "${b}" ]]
}

# Remove a legacy link made by older CGW versions. Refuses to touch anything that
# isn't itself a link/junction — this is the guard from A3: a
# `git worktree remove` recursive delete must never be able to follow a
# junction into the MAIN worktree's scripts/git, so we always unlink first.
# A real (non-link) directory has no reparse point to redirect that delete
# anywhere, so it's not a risk to A3 — leave it alone and return success;
# `git worktree remove`'s own recursive delete handles it normally.
_cgw_unlink_dir() {
  local link_path="$1"
  [[ -e "${link_path}" ]] || return 0
  if ! _cgw_is_link "${link_path}"; then
    echo "  [OK]   ${link_path} is a real (tracked) directory — left for git worktree remove"
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      # A junction is a reparse-point directory; rmdir removes the junction
      # itself without touching its target. Some setups (WSL interop, admin
      # mode) create a real symlink instead — fall back to rm -f for that.
      rmdir "${link_path}" 2>/dev/null || rm -f "${link_path}"
      ;;
    *)
      rm -f "${link_path}"
      ;;
  esac
}

# Marker identifying a scripts/git directory as CGW-generated shims, so `link`
# can refresh it without ever overwriting a real directory.
_CGW_SHIM_MARKER=".cgw-worktree-shims"

# Write one exec shim per public script (no _-prefixed libraries) from main's
# scripts/git ($1) into directory $2, plus the marker file. Each shim resolves
# the main worktree at run time from its own location, then execs the real
# script; the cwd is untouched, so PROJECT_ROOT still resolves to the worktree.
_cgw_write_shims() {
  local main_root="$1" dest="$2" src name tmp
  # Never replace a directory CGW did not generate.
  if [[ -e "${dest}" && ! -f "${dest}/${_CGW_SHIM_MARKER}" ]]; then
    return 1
  fi
  # Build the whole set (marker included) beside the destination, then swap it
  # in: a failed write leaves the old shims instead of a half-built unmarked
  # directory, and shims for scripts removed from main are dropped.
  # mktemp creates it exclusively, so nothing pre-existing (a stale dir or a
  # junction) is ever recursively deleted.
  mkdir -p "$(dirname "${dest}")" || return 1
  tmp="$(mktemp -d "${dest}.cgw-tmp.XXXXXX")" || return 1
  for src in "${main_root}/scripts/git/"*.sh; do
    [[ -f "${src}" ]] || continue
    name="$(basename "${src}")"
    [[ "${name}" == _* ]] && continue
    if ! cat >"${tmp}/${name}" <<EOF
#!/usr/bin/env bash
# CGW worktree shim (generated by worktree_manage.sh link) - do not edit.
_cgw_main="\$(git -C "\$(dirname "\${BASH_SOURCE[0]}")" worktree list --porcelain 2>/dev/null | head -1)"
exec bash "\${_cgw_main#worktree }/scripts/git/${name}" "\$@"
EOF
    then
      rm -rf "${tmp}"
      return 1
    fi
    if ! chmod +x "${tmp}/${name}"; then
      rm -rf "${tmp}"
      return 1
    fi
  done
  if ! echo "Generated by worktree_manage.sh link; safe to delete." >"${tmp}/${_CGW_SHIM_MARKER}"; then
    rm -rf "${tmp}"
    return 1
  fi
  if [[ -e "${dest}" ]] && ! rm -rf "${dest}"; then
    rm -rf "${tmp}"
    return 1
  fi
  if ! mv "${tmp}" "${dest}"; then
    rm -rf "${tmp}"
    return 1
  fi
}

# Gives worktree $1 a scripts/git of shims that forward to the main worktree's
# scripts, and cleans up legacy scripts/git / .githooks links. Idempotent and
# refuses to overwrite a real directory. A no-op, non-error, when $1 IS the
# main worktree.
# $2: 1 for dry-run (preview only), 0 (default) to actually link.
# Returns 0 if every entry linked/skipped cleanly, 1 if any entry failed.
_cgw_do_link() {
  local target_path="$1" dry_run="${2:-0}"

  local main_root
  main_root="$(cgw_main_worktree_root "${target_path}")"
  if [[ -z "${main_root}" ]]; then
    echo "[ERROR] '${target_path}' is not part of a git worktree." >&2
    return 1
  fi

  # Normalize target_path through git itself (not caller's `cd && pwd`) before
  # comparing to main_root: on Windows/MSYS, `cd && pwd` yields an MSYS-style
  # path ("/tmp/...") while `git worktree list` emits a git-format path
  # ("C:/Users/..."), so a naive string comparison misses even when the two
  # ARE the same directory.
  local target_norm
  target_norm="$(git -C "${target_path}" rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "${target_norm}" ]] && target_norm="${target_path}"

  if [[ "${target_norm}" == "${main_root}" ]]; then
    echo "  '${target_path}' is the main worktree — nothing to link."
    return 0
  fi

  echo "  Main worktree:   ${main_root}"
  echo "  Target worktree: ${target_path}"

  local status=0

  # scripts/git: a REAL directory of shims, never a link. A junction/symlink
  # back to the main worktree is followed by `git worktree remove`'s recursive
  # delete on Windows, which empties the main checkout's gitignored tooling.
  local rel="scripts/git" dest="${target_path}/scripts/git"
  if [[ ! -d "${main_root}/${rel}" ]]; then
    echo "  [SKIP] ${rel} not found in main worktree"
  elif _cgw_is_link "${dest}"; then
    if _cgw_same_dir "${dest}" "${main_root}/${rel}"; then
      # Legacy link from an older CGW — replace it with shims (rmdir-only unlink).
      if [[ "${dry_run}" -eq 1 ]]; then
        echo "  Would replace legacy link ${rel} with a shim directory"
      elif _cgw_unlink_dir "${dest}" && _cgw_write_shims "${main_root}" "${dest}"; then
        echo "  [OK]   migrated ${rel} from a link to shims"
      else
        echo "  [ERROR] failed to migrate ${rel}" >&2
        status=1
      fi
    else
      echo "  [WARN] ${rel} is a link but does not resolve to the main worktree — not touching it" >&2
      status=1
    fi
  elif [[ -e "${dest}" ]] && [[ ! -f "${dest}/${_CGW_SHIM_MARKER}" ]]; then
    echo "  [WARN] ${rel} exists as a real directory in target — not overwriting" >&2
    status=1
  elif [[ "${dry_run}" -eq 1 ]]; then
    echo "  Would write shims: ${dest} -> ${main_root}/${rel}"
  elif _cgw_write_shims "${main_root}" "${dest}"; then
    echo "  [OK]   ${rel} shims in place"
  else
    echo "  [ERROR] failed to write ${rel} shims" >&2
    status=1
  fi

  # .githooks: no longer linked — install_hooks.sh falls back to the main
  # worktree's copy. Only a legacy link needs cleaning up.
  rel=".githooks"
  dest="${target_path}/.githooks"
  if _cgw_is_link "${dest}"; then
    if ! _cgw_same_dir "${dest}" "${main_root}/${rel}"; then
      echo "  [WARN] ${rel} is a link but does not resolve to the main worktree — not touching it" >&2
      status=1
    elif [[ "${dry_run}" -eq 1 ]]; then
      echo "  Would remove legacy link ${rel}"
    elif _cgw_unlink_dir "${dest}"; then
      echo "  [OK]   removed legacy ${rel} link (hooks resolve via the main worktree)"
    else
      echo "  [ERROR] failed to remove legacy ${rel} link" >&2
      status=1
    fi
  fi
  return "${status}"
}

# ---------------------------------------------------------------------------
# Subcommand: link
# ---------------------------------------------------------------------------
_cmd_link() {
  local target_path="" dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [[ -n "${target_path}" ]]; then
          echo "[ERROR] Unexpected argument: $1" >&2
          exit 1
        fi
        target_path="$1"
        shift
        ;;
    esac
  done

  # No argument: link the worktree the caller is standing in.
  if [[ -z "${target_path}" ]]; then
    target_path="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
  if [[ -z "${target_path}" ]]; then
    echo "[ERROR] Not inside a git worktree; pass a path explicitly." >&2
    exit 1
  fi
  local target_path_input="${target_path}"
  target_path="$(cd "${target_path}" 2>/dev/null && pwd)" || {
    echo "[ERROR] Path not found: ${target_path_input}" >&2
    exit 1
  }

  echo "=== Link CGW Tooling ==="
  echo ""

  local link_status=0
  log_section_start "LINK TOOLING" "${logfile}"
  _cgw_do_link "${target_path}" "${dry_run}" | tee -a "${logfile}" || link_status=1
  log_section_end "LINK TOOLING" "${logfile}" "${link_status}"

  if [[ "${link_status}" -eq 0 ]]; then
    echo ""
    if [[ "${dry_run}" -eq 1 ]]; then
      echo "--- Dry run: no changes made ---"
    else
      echo "[OK] Link complete."
    fi
  else
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
_cmd_list() {
  local status_mode=0 want_pr=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        status_mode=1
        shift
        ;;
      --no-pr)
        want_pr=0
        shift
        ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done
  if [[ "${status_mode}" -eq 1 ]]; then
    _cmd_list_status "${want_pr}"
    return
  fi

  echo "=== Git Worktrees ==="
  echo ""

  local raw
  raw="$(git worktree list --porcelain 2>/dev/null)"

  if [[ -z "${raw}" ]]; then
    echo "  (no worktrees found)"
    return 0
  fi

  local path="" head="" branch="" bare=0
  while IFS= read -r line; do
    if [[ "${line}" == worktree* ]]; then
      # Print previous entry if any
      if [[ -n "${path}" ]]; then
        local _br_label="${branch:-<detached>}"
        [[ "${bare}" -eq 1 ]] && _br_label="<bare>"
        printf "  %-40s  %-24s  %s\n" "${path}" "${_br_label}" "${head:0:12}"
        path="" head="" branch="" bare=0
      fi
      path="${line#worktree }"
    elif [[ "${line}" == HEAD\ * ]]; then
      head="${line#HEAD }"
    elif [[ "${line}" == branch\ * ]]; then
      branch="${line#branch refs/heads/}"
    elif [[ "${line}" == "bare" ]]; then
      bare=1
    fi
  done <<<"${raw}"
  # Print last entry
  if [[ -n "${path}" ]]; then
    local _br_label="${branch:-<detached>}"
    [[ "${bare}" -eq 1 ]] && _br_label="<bare>"
    printf "  %-40s  %-24s  %s\n" "${path}" "${_br_label}" "${head:0:12}"
  fi
  echo ""

  # Prune hint if any worktrees have missing paths
  local stale
  stale="$(git worktree prune --dry-run 2>&1 | grep -c "Removing" || true)"
  if [[ "${stale}" -gt 0 ]]; then
    echo "  [!] ${stale} stale administrative file(s) detected."
    echo "      Run: ./scripts/git/worktree_manage.sh prune"
  fi
}

# list --status: one row per linked worktree, then a count of the ones
# remove-merged would select. Read-only.
_cmd_list_status() {
  local want_pr="${1:-1}"
  _cgw_wt_collect "${want_pr}" || exit 1

  echo "=== Linked Worktree Status (compared with ${_WT_DEFAULT_REF}) ==="
  echo ""
  if [[ "${_WT_N}" -eq 0 ]]; then
    echo "  (no linked worktrees)"
    echo ""
    echo "Safe to remove: 0 of 0 linked worktrees."
    return 0
  fi

  local i w_path=4 w_branch=6 safe=0
  for ((i = 0; i < _WT_N; i++)); do
    [[ "${#_WT_PATH[i]}" -gt "${w_path}" ]] && w_path="${#_WT_PATH[i]}"
    [[ "${#_WT_BRANCH[i]}" -gt "${w_branch}" ]] && w_branch="${#_WT_BRANCH[i]}"
  done

  local show_pr="${_WT_PR_OK}"
  if [[ "${show_pr}" -eq 1 ]]; then
    printf "  %-*s  %-*s  %-6s  %7s  %9s  %5s  %-12s  %s\n" "${w_path}" "PATH" "${w_branch}" "BRANCH" \
      "MERGED" "CHANGED" "UNTRACKED" "AHEAD" "PR" "REMOVE-MERGED"
  else
    printf "  %-*s  %-*s  %-6s  %7s  %9s  %5s  %s\n" "${w_path}" "PATH" "${w_branch}" "BRANCH" \
      "MERGED" "CHANGED" "UNTRACKED" "AHEAD" "REMOVE-MERGED"
  fi
  for ((i = 0; i < _WT_N; i++)); do
    [[ "${_WT_SAFE[i]}" -eq 1 ]] && safe=$((safe + 1))
    if [[ "${show_pr}" -eq 1 ]]; then
      printf "  %-*s  %-*s  %-6s  %7s  %9s  %5s  %-12s  %s\n" "${w_path}" "${_WT_PATH[i]}" "${w_branch}" "${_WT_BRANCH[i]}" \
        "${_WT_MERGED[i]}" "${_WT_CHANGED[i]}" "${_WT_UNTRACKED[i]}" "${_WT_AHEAD[i]}" "${_WT_PR[i]}" "${_WT_REASON[i]}"
    else
      printf "  %-*s  %-*s  %-6s  %7s  %9s  %5s  %s\n" "${w_path}" "${_WT_PATH[i]}" "${w_branch}" "${_WT_BRANCH[i]}" \
        "${_WT_MERGED[i]}" "${_WT_CHANGED[i]}" "${_WT_UNTRACKED[i]}" "${_WT_AHEAD[i]}" "${_WT_REASON[i]}"
    fi
  done
  echo ""
  echo "Safe to remove: ${safe} of ${_WT_N} linked worktrees (./scripts/git/worktree_manage.sh remove-merged)."
}

# ---------------------------------------------------------------------------
# Subcommand: add
# ---------------------------------------------------------------------------
_cmd_add() {
  local path="" branch="" base="" dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --base)
        if [[ -z "${2:-}" ]]; then
          echo "[ERROR] --base requires a ref" >&2
          exit 1
        fi
        base="$2"
        shift 2
        ;;
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [[ -z "${path}" ]]; then
          path="$1"
        elif [[ -z "${branch}" ]]; then
          branch="$1"
        elif [[ -z "${base}" ]]; then
          base="$1"
        else
          echo "[ERROR] Unexpected argument: $1" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${path}" ]]; then
    echo "[ERROR] Usage: worktree_manage.sh add <path> [<branch> [<base>]]" >&2
    exit 1
  fi

  if [[ -n "${base}" ]] && [[ -z "${branch}" ]]; then
    echo "[ERROR] A base ref needs a branch to create from it: add <path> <branch> <base>" >&2
    exit 1
  fi

  echo "=== Add Worktree ==="
  echo ""
  echo "  Path:   ${path}"

  local -a git_args=()
  if [[ -z "${branch}" ]]; then
    # No branch given: git worktree add will create a detached worktree at HEAD.
    # Suggest the user specify one.
    echo "  Branch: (none — detached HEAD)"
    echo "  Tip: provide a branch name to check it out: worktree_manage.sh add ${path} <branch>"
    git_args=("${path}")
  else
    # If the branch doesn't exist, pass -b to create it (from <base>, default HEAD).
    if ! git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1; then
      if [[ -n "${base}" ]]; then
        if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
          echo "[ERROR] Invalid base ref: ${base}" >&2
          exit 1
        fi
        local remote="${CGW_REMOTE:-origin}"
        if [[ "${base}" == "${remote}/${branch}" || "${base}" == "refs/remotes/${remote}/${branch}" ]]; then
          # The base is this branch's own remote counterpart: tracking it is correct.
          echo "  Branch: ${branch} (new, tracking ${remote}/${branch})"
          git_args=(--track -b "${branch}" "${path}" "${base}")
        else
          echo "  Branch: ${branch} (new — will be created from ${base}, no upstream until first push)"
          # --no-track: the base is where the branch starts, not where it pushes. Git would
          # otherwise track a remote-tracking base (or any base, with autoSetupMerge=always),
          # so a bare push/pull from a stacked branch would target its base's branch.
          git_args=(--no-track -b "${branch}" "${path}" "${base}")
        fi
      else
        # No base: if the branch already exists on the remote, check it out tracking it
        # (plain `git worktree add <path> <branch>` would do this too, but -b bypasses it).
        local remote="${CGW_REMOTE:-origin}"
        if git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" >/dev/null 2>&1; then
          echo "  Branch: ${branch} (new, tracking ${remote}/${branch})"
          git_args=(--track -b "${branch}" "${path}" "${remote}/${branch}")
        else
          echo "  Branch: ${branch} (new — will be created from HEAD, no upstream until first push)"
          # --no-track: with autoSetupMerge=always git would otherwise track the current branch.
          git_args=(--no-track -b "${branch}" "${path}")
        fi
      fi
    else
      if [[ -n "${base}" ]]; then
        echo "[ERROR] Branch '${branch}' already exists; a base ref only applies to a new branch" >&2
        exit 1
      fi
      echo "  Branch: ${branch}"
      git_args=("${path}" "${branch}")
    fi
  fi
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would run: git worktree add ${git_args[*]}"
    exit 0
  fi

  if ! cgw_confirm "Add worktree at '${path}'?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  if git worktree add "${git_args[@]}" 2>&1 | tee -a "${logfile}"; then
    echo ""
    echo "[OK] Worktree added: ${path}"
    echo "  cd ${path} to work in this worktree"

    # Link scripts/git and .githooks (best-effort). Both are gitignored, so
    # the new worktree doesn't have them; direct script invocation
    # (./scripts/git/check_lint.sh) and install_hooks.sh need the link. A
    # failure here doesn't fail the add — the worktree is already usable,
    # just re-run `link` later.
    echo ""
    echo "--- Linking CGW tooling ---"
    local abs_path
    abs_path="$(cd "${path}" 2>/dev/null && pwd)"
    if [[ -n "${abs_path}" ]]; then
      local link_status=0
      log_section_start "LINK TOOLING" "${logfile}"
      _cgw_do_link "${abs_path}" 0 | tee -a "${logfile}" || link_status=1
      log_section_end "LINK TOOLING" "${logfile}" "${link_status}"
      if [[ "${link_status}" -ne 0 ]]; then
        echo "  [WARN] Linking failed — run: ./scripts/git/worktree_manage.sh link ${path}" >&2
      fi
    fi
  else
    echo "[ERROR] Failed to add worktree" >&2
    exit 1
  fi
}

# _cgw_is_own_worktree_root <dir>
#   0 when <dir> is itself the root of a git working tree. A directory that
#   git has emptied (or never populated) sits inside an enclosing checkout
#   when the worktree was created under it: `git -C <dir>` then answers for
#   that checkout, with a non-empty --show-prefix. A directory outside any
#   checkout makes rev-parse fail. Both mean "not a worktree root".
_cgw_is_own_worktree_root() {
  local prefix
  prefix="$(git -C "$1" rev-parse --show-prefix 2>/dev/null)" || return 1
  [[ -z "${prefix}" ]]
}

# _cgw_worktree_registered <toplevel>
#   0 when `git worktree list` still has <toplevel> (git-format path, as
#   rev-parse --show-toplevel printed it while the worktree existed).
_cgw_worktree_registered() {
  git worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $1"
}

# ---------------------------------------------------------------------------
# Folder-holder lookup (Windows)
# ---------------------------------------------------------------------------
# Windows refuses to delete a folder that a process uses as its working
# folder: `git worktree remove` then deletes the files and the registration
# but leaves the folder. The usual holder is an idle Claude desktop session
# (`claude.exe ... --add-dir=<folder>`) or an editor. Win32_Process gives no
# working folder, only the command line, so a holder is found only when the
# folder is on its command line. One powershell.exe call per run (cached);
# no powershell.exe (Linux, macOS) means no lookup.
_CGW_PROC_LIST=""
_CGW_PROC_LIST_LOADED=0

_cgw_load_proc_list() {
  [[ "${_CGW_PROC_LIST_LOADED}" -eq 1 ]] && return 0
  _CGW_PROC_LIST_LOADED=1
  command -v powershell.exe >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2016  # PowerShell code: its $ must reach powershell.exe unexpanded
  local ps_cmd='Get-CimInstance Win32_Process | Where-Object { $_.CommandLine } | ForEach-Object { "$($_.ProcessId)`t$($_.Name)`t$($_.CommandLine)" }'
  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout 30)
  _CGW_PROC_LIST="$(${runner[@]+"${runner[@]}"} powershell.exe -NoProfile -NonInteractive -Command "${ps_cmd}" 2>/dev/null | tr -d '\r')" || _CGW_PROC_LIST=""
}

# _cgw_folder_holders <path>
#   Prints "<name> (PID <n>)" for each process whose command line names
#   <path> (or a folder inside it), one per line. Case-insensitive, and both
#   slash styles match. A longer sibling name (<path>-2) does not match. This
#   script's own processes and powershell.exe are skipped.
_cgw_folder_holders() {
  local p="$1" win=""
  _cgw_load_proc_list
  [[ -z "${_CGW_PROC_LIST}" ]] && return 0
  command -v cygpath >/dev/null 2>&1 && win="$(cygpath -m "${p}" 2>/dev/null)"
  [[ -z "${win}" ]] && win="${p}"
  win="${win%/}"
  printf '%s\n' "${_CGW_PROC_LIST}" | awk -F'\t' -v fwd="${win}" '
    BEGIN {
      fwd = tolower(fwd)
      back = fwd
      gsub("/", "\\", back)
    }
    function hit(s, n,    i, c) {
      while ((i = index(s, n)) > 0) {
        c = substr(s, i + length(n), 1)
        if (c == "" || c !~ /[A-Za-z0-9._-]/) return 1
        s = substr(s, i + 1)
      }
      return 0
    }
    {
      name = $2
      cl = tolower($0)
      if (tolower(name) ~ /^powershell/ || cl ~ /worktree_manage/) next
      if (hit(cl, fwd) || hit(cl, back)) print name " (PID " $1 ")"
    }'
}

# ---------------------------------------------------------------------------
# Worktree classification (list --status, remove-merged)
# ---------------------------------------------------------------------------

# _cgw_wt_default_ref
#   Echoes the ref merged-ness is judged against: <remote>/<default branch>,
#   or the local default branch when the remote-tracking ref is missing.
_cgw_wt_default_ref() {
  local def
  def="$(cgw_default_branch)"
  [[ -z "${def}" ]] && return 1
  if git rev-parse --verify --quiet "refs/remotes/${CGW_REMOTE}/${def}" >/dev/null 2>&1; then
    echo "${CGW_REMOTE}/${def}"
  elif git rev-parse --verify --quiet "refs/heads/${def}" >/dev/null 2>&1; then
    echo "${def}"
  else
    return 1
  fi
}

# _cgw_wt_load_prs
#   Fills _WT_PR_DATA with "<head branch>\t<STATE>\t<number>" lines (newest PR
#   first) from one `gh pr list` call. Quietly leaves it empty when gh is
#   missing, the remote is not on GitHub, or the call fails.
_WT_PR_DATA=""
_WT_PR_OK=0
_cgw_wt_load_prs() {
  _WT_PR_DATA=""
  _WT_PR_OK=0
  command -v gh >/dev/null 2>&1 || return 0
  local slug
  slug="$(cgw_remote_owner_repo "${CGW_REMOTE}" 2>/dev/null)" || return 0
  [[ -z "${slug}" ]] && return 0
  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout 60)
  local data
  if data="$(${runner[@]+"${runner[@]}"} gh pr list -R "${slug}" --state all --limit 1000 \
    --json number,state,headRefName \
    --jq '.[] | [.headRefName, .state, (.number | tostring)] | @tsv' 2>/dev/null)"; then
    _WT_PR_DATA="$(printf '%s' "${data}" | tr -d '\r')"
    _WT_PR_OK=1
  fi
}

# _cgw_wt_pr_for <branch>  -> "STATE #N" for the newest PR from <branch>, or "-".
_cgw_wt_pr_for() {
  local b="$1" hit=""
  if [[ -n "${b}" && -n "${_WT_PR_DATA}" ]]; then
    hit="$(printf '%s\n' "${_WT_PR_DATA}" | awk -F'\t' -v b="${b}" '$1 == b { print $2 " #" $3; exit }')"
  fi
  echo "${hit:--}"
}

# _cgw_wt_collect [<want_pr>]
#   Classifies every LINKED worktree (the main worktree is skipped) into the
#   parallel arrays below. _WT_SAFE[i]=1 when remove-merged may select it:
#   merged into _WT_DEFAULT_REF, 0 changed, 0 untracked, 0 ahead, folder
#   present, not locked, not the current worktree. _WT_REASON[i] says why not.
_cgw_wt_collect() {
  local want_pr="${1:-0}"
  _WT_N=0
  _WT_PATH=()
  _WT_BRANCH=()
  _WT_MERGED=()
  _WT_CHANGED=()
  _WT_UNTRACKED=()
  _WT_AHEAD=()
  _WT_SAFE=()
  _WT_REASON=()
  _WT_PR=()

  _WT_DEFAULT_REF="$(_cgw_wt_default_ref)" || {
    err "Cannot resolve the default branch (${CGW_REMOTE}/$(cgw_default_branch) or a local copy) to compare with."
    return 1
  }
  [[ "${want_pr}" -eq 1 ]] && _cgw_wt_load_prs

  local current raw
  current="$(git rev-parse --show-toplevel 2>/dev/null)"
  raw="$(git worktree list --porcelain 2>/dev/null)" || return 1

  local line first=1 path="" head="" branch="" locked=0 prunable=0 bare=0
  while IFS= read -r line; do
    case "${line}" in
      "worktree "*) path="${line#worktree }" ;;
      "HEAD "*) head="${line#HEAD }" ;;
      "branch "*) branch="${line#branch refs/heads/}" ;;
      bare) bare=1 ;;
      locked | "locked "*) locked=1 ;;
      prunable | "prunable "*) prunable=1 ;;
      "")
        if [[ -n "${path}" ]]; then
          if [[ "${first}" -eq 1 ]]; then
            first=0 # the main worktree: never listed, never removed
          elif [[ "${bare}" -eq 0 ]]; then
            _cgw_wt_add_row "${path}" "${head}" "${branch}" "${locked}" "${prunable}" "${current}"
          fi
        fi
        path="" head="" branch="" locked=0 prunable=0 bare=0
        ;;
    esac
  done <<<"${raw}"$'\n'
}

_cgw_wt_add_row() {
  local path="$1" head="$2" branch="$3" locked="$4" prunable="$5" current="$6"
  local merged="-" changed="-" untracked="-" ahead="-" st
  local -a reasons=()

  if [[ "${prunable}" -eq 1 ]] || [[ ! -d "${path}" ]]; then
    reasons+=("folder missing (run prune)")
  else
    if git merge-base --is-ancestor "${head}" "${_WT_DEFAULT_REF}" 2>/dev/null; then
      merged="yes"
    else
      merged="no"
    fi
    ahead="$(git rev-list --count "${_WT_DEFAULT_REF}..${head}" 2>/dev/null)" || ahead="?"
    if st="$(git -C "${path}" status --porcelain --untracked-files=all 2>/dev/null)"; then
      untracked="$(printf '%s' "${st}" | grep -c '^??' || true)"
      changed="$(printf '%s' "${st}" | grep -vc '^??' || true)"
    else
      changed="?" untracked="?"
      reasons+=("git status failed")
    fi
    [[ "${merged}" == "no" ]] && reasons+=("not merged")
    [[ "${changed}" != "0" && "${changed}" != "?" ]] && reasons+=("${changed} changed")
    [[ "${untracked}" != "0" && "${untracked}" != "?" ]] && reasons+=("${untracked} untracked")
    [[ "${ahead}" != "0" ]] && reasons+=("${ahead} ahead")
  fi
  [[ "${locked}" -eq 1 ]] && reasons+=("locked")
  [[ -n "${current}" && "${path}" == "${current}" ]] && reasons+=("current worktree")

  local i="${_WT_N}"
  _WT_PATH[i]="${path}"
  _WT_BRANCH[i]="${branch:-detached}"
  _WT_MERGED[i]="${merged}"
  _WT_CHANGED[i]="${changed}"
  _WT_UNTRACKED[i]="${untracked}"
  _WT_AHEAD[i]="${ahead}"
  _WT_PR[i]="$(_cgw_wt_pr_for "${branch}")"
  if [[ "${#reasons[@]}" -eq 0 ]]; then
    _WT_SAFE[i]=1
    _WT_REASON[i]="safe"
  else
    _WT_SAFE[i]=0
    local joined="${reasons[0]}" r
    for r in "${reasons[@]:1}"; do joined+=", ${r}"; done
    _WT_REASON[i]="${joined}"
  fi
  _WT_N=$((i + 1))
}

# ---------------------------------------------------------------------------
# Subcommand: remove
# ---------------------------------------------------------------------------
_cmd_remove() {
  local path="" dry_run=1 # default dry-run like branch_cleanup.sh

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute)
        dry_run=0
        shift
        ;;
      --non-interactive)
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        path="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${path}" ]]; then
    echo "[ERROR] Usage: worktree_manage.sh remove [--execute [--non-interactive]] <path>" >&2
    exit 1
  fi

  echo "=== Remove Worktree ==="
  echo ""
  echo "  Path: ${path}"
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made (use --execute to proceed) ---"
    echo "Would run: git worktree remove '${path}'"
    echo ""
    echo "Note: the worktree directory at '${path}' is deleted; its branch is preserved."
    echo "      (git refuses if it has uncommitted changes.)"
    exit 0
  fi

  # With no terminal to answer, the prompt below would read EOF and report
  # "Cancelled" with exit 0, which a caller (an agent, a script) takes for a
  # successful remove. Refuse loudly instead.
  if [[ "${CGW_NON_INTERACTIVE:-0}" != "1" ]] && [[ ! -t 0 ]]; then
    err_tee "[ERROR] worktree_manage.sh remove: needs confirmation and stdin is not a terminal; rerun with --non-interactive"
    err_tee "  ./scripts/git/worktree_manage.sh remove --execute --non-interactive '${path}'"
    exit 1
  fi

  if ! cgw_confirm "Remove worktree '${path}'?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  _cgw_remove_worktree "${path}" || exit 1
}

# _cgw_remove_worktree <path>
#   The removal itself, shared by `remove --execute` and `remove-merged
#   --execute` (no prompt here: callers confirm first). Returns:
#     0  removed, folder gone
#     1  not removed (git refused, or the tooling links could not be checked)
#     2  git removed the files and the registration, but the folder is still
#        there (on Windows: a process uses it as its working folder)
_cgw_remove_worktree() {
  local path="$1"

  # Unlink CGW tooling first (A3). scripts/git and .githooks may be NTFS
  # junctions; `git worktree remove`'s recursive delete stats reparse points
  # as ordinary directories, so an unremoved junction could be walked into
  # and delete the MAIN worktree's scripts/git or .githooks. Unlinking first
  # removes that possibility — _cgw_unlink_dir refuses to touch anything
  # that isn't itself a link, so this is a no-op for worktrees that were
  # never linked.
  #
  # Fail CLOSED: if a link can't be verified/removed, ABORT the worktree
  # removal rather than proceeding. The asymmetry is decisive — a refused
  # removal is a one-line manual fix, whereas git following a junction into
  # the main checkout deletes scripts/git or .githooks, which are gitignored
  # and therefore not recoverable from git.
  local abs_path
  abs_path="$(cd "${path}" 2>/dev/null && pwd)"
  if [[ -z "${abs_path}" ]]; then
    err_tee "[ERROR] Could not resolve worktree path '${path}' — refusing to remove without verifying CGW tooling links."
    err_tee "  If the worktree directory is already gone, use: ./scripts/git/worktree_manage.sh prune --execute"
    return 1
  fi
  local rel unlink_failed=0
  for rel in "scripts/git" ".githooks"; do
    _cgw_unlink_dir "${abs_path}/${rel}" || unlink_failed=1
  done
  if [[ "${unlink_failed}" -eq 1 ]]; then
    err_tee "[ERROR] Could not verify/unlink CGW tooling under '${abs_path}' — refusing to remove."
    err_tee "  git worktree remove's recursive delete could otherwise follow a stray junction"
    err_tee "  into the MAIN worktree's scripts/git or .githooks and delete it."
    err_tee "  Resolve manually (remove the offending link/directory), then retry:"
    err_tee "    ./scripts/git/worktree_manage.sh remove --execute --non-interactive '${path}'"
    return 1
  fi

  # The worktree root as git spells it, taken now while it still is one: after
  # a partial removal the directory can no longer be asked, and `git worktree
  # list` writes git-format paths that `cd && pwd` does not match on Windows.
  local wt_toplevel
  wt_toplevel="$(git -C "${abs_path}" rev-parse --show-toplevel 2>/dev/null)"

  local git_ok=0
  git worktree remove "${path}" 2>&1 | tee -a "${logfile}" && git_ok=1
  if [[ "${git_ok}" -eq 0 ]] && { [[ -z "${wt_toplevel}" ]] || _cgw_worktree_registered "${wt_toplevel}"; }; then
    err_tee "[ERROR] Failed to remove worktree: ${path}"
    if [[ ! -d "${path}" ]]; then
      :
    elif _cgw_is_own_worktree_root "${path}"; then
      err_tee "  git refuses while the worktree holds modified or untracked files. Left in it:"
      git -C "${path}" status --porcelain --untracked-files=all 2>/dev/null | sed 's/^/    /' | tee -a "${logfile}" >&2
      err_tee "  Commit, move or delete them by name (an untracked file is often a copy of the main"
      err_tee "  worktree's: compare with git diff --no-index), then retry. --force would discard them."
    else
      # Still registered, but no longer a worktree root: `git -C` here would
      # resolve to an enclosing checkout and list ITS files. Say only what is
      # known.
      err_tee "  The directory is no longer a git worktree root, so its contents are not listed."
      err_tee "  Check: git worktree list, then git worktree prune --dry-run."
    fi
    return 1
  fi

  # git deleted the files and the registration. On Windows the folder itself
  # can stay (git may still exit 0): a process that uses it as its working
  # folder blocks the delete. That is not a clean removal, so say so and fail;
  # never `git -C` in the leftover folder (it resolves to an enclosing checkout
  # and lists ITS files).
  if [[ -e "${path}" ]]; then
    echo ""
    err_tee "[ERROR] Folder still exists: ${path}"
    err_tee "  git no longer registers it as a worktree (its files are removed), but the folder could"
    err_tee "  not be deleted: a process holds it, for example an idle Claude session or an editor"
    err_tee "  that uses it as its working folder."
    local holders line
    holders="$(_cgw_folder_holders "${wt_toplevel:-${abs_path}}")"
    if [[ -n "${holders}" ]]; then
      err_tee "  Held by (command line names the folder):"
      while IFS= read -r line; do
        err_tee "    ${line}"
      done <<<"${holders}"
    fi
    err_tee "  Close that process, then delete the folder by hand (nothing of value is left in it)."
    return 2
  fi

  echo ""
  echo "[OK] Worktree removed: ${path}"
  return 0
}

# ---------------------------------------------------------------------------
# Subcommand: remove-merged
# ---------------------------------------------------------------------------
# Selects the linked worktrees that hold nothing of their own: merged into
# <remote>/<default>, 0 changed, 0 untracked, 0 ahead (list --status's "safe"
# rows), never the main or the current worktree. A selected folder that a
# process names on its command line is kept (removing it would leave the folder
# behind). Dry-run by default; --execute removes each through
# _cgw_remove_worktree (the `remove` code path) and deletes its branch with
# `git branch -d` (never -D). Exit 1 when any selected removal failed.
_cmd_remove_merged() {
  local dry_run=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute)
        dry_run=0
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --non-interactive)
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  _cgw_wt_collect 0 || exit 1

  echo "=== Remove Merged Worktrees (compared with ${_WT_DEFAULT_REF}) ==="
  echo ""

  local i holders kept=0
  local -a sel=()
  for ((i = 0; i < _WT_N; i++)); do
    if [[ "${_WT_SAFE[i]}" -ne 1 ]]; then
      printf "  kept     %s  (%s)\n" "${_WT_PATH[i]}" "${_WT_REASON[i]}"
      kept=$((kept + 1))
      continue
    fi
    holders="$(_cgw_folder_holders "${_WT_PATH[i]}")"
    if [[ -n "${holders}" ]]; then
      printf "  kept     %s  (in use by %s)\n" "${_WT_PATH[i]}" "$(printf '%s\n' "${holders}" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
      kept=$((kept + 1))
      continue
    fi
    sel+=("${i}")
  done

  if [[ "${#sel[@]}" -eq 0 ]]; then
    [[ "${_WT_N}" -gt 0 ]] && echo ""
    echo "Nothing to remove (${kept} kept)."
    exit 0
  fi

  if [[ "${dry_run}" -eq 1 ]]; then
    for i in "${sel[@]}"; do
      if [[ "${_WT_BRANCH[i]}" == "detached" ]]; then
        printf "  would remove  %s  (detached HEAD)\n" "${_WT_PATH[i]}"
      else
        printf "  would remove  %s  (branch %s)\n" "${_WT_PATH[i]}" "${_WT_BRANCH[i]}"
      fi
    done
    echo ""
    echo "--- Dry run: no changes made (use --execute to proceed) ---"
    echo "Would remove ${#sel[@]} worktree(s) and delete their branches with git branch -d; ${kept} kept."
    exit 0
  fi

  if [[ "${CGW_NON_INTERACTIVE:-0}" != "1" ]] && [[ ! -t 0 ]]; then
    err_tee "[ERROR] worktree_manage.sh remove-merged: needs confirmation and stdin is not a terminal; rerun with --non-interactive"
    err_tee "  ./scripts/git/worktree_manage.sh remove-merged --execute --non-interactive"
    exit 1
  fi
  if ! cgw_confirm "Remove ${#sel[@]} merged worktree(s) and delete their branches?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  log_section_start "REMOVE MERGED" "${logfile}"
  local out rc b bout removed=0 failed=0
  for i in "${sel[@]}"; do
    b="${_WT_BRANCH[i]}"
    out="$(_cgw_remove_worktree "${_WT_PATH[i]}" 2>&1)"
    rc=$?
    if [[ "${rc}" -eq 1 ]]; then
      printf "  FAILED   %s  (not removed)\n" "${_WT_PATH[i]}" | tee -a "${logfile}"
      printf '%s\n' "${out}" | grep -v '^$' | sed 's/^/      /'
      failed=$((failed + 1))
      continue
    fi
    # The registration is gone in both remaining cases, so the branch is
    # free to delete.
    local note=""
    if [[ "${b}" != "detached" ]]; then
      if bout="$(git branch -d "${b}" 2>&1)"; then
        note="branch ${b} deleted"
      else
        note="[WARN] branch ${b} kept: $(printf '%s' "${bout}" | head -1)"
      fi
    fi
    if [[ "${rc}" -eq 2 ]]; then
      printf "  FAILED   %s  (folder left: a process holds it%s)\n" "${_WT_PATH[i]}" "${note:+; ${note}}" | tee -a "${logfile}"
      printf '%s\n' "${out}" | grep '^  Held by\|^    ' | sed 's/^/    /'
      failed=$((failed + 1))
    else
      printf "  removed  %s%s\n" "${_WT_PATH[i]}" "${note:+  (${note})}" | tee -a "${logfile}"
      removed=$((removed + 1))
    fi
  done
  log_section_end "REMOVE MERGED" "${logfile}" "$([[ "${failed}" -eq 0 ]] && echo 0 || echo 1)"

  echo ""
  echo "Removed: ${removed}  Kept: ${kept}  Failed: ${failed}"
  [[ "${failed}" -eq 0 ]] || exit 1
}

# ---------------------------------------------------------------------------
# Subcommand: prune
# ---------------------------------------------------------------------------
_cmd_prune() {
  local dry_run=1 # default dry-run

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute)
        dry_run=0
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  echo "=== Prune Stale Worktree Admin Files ==="
  echo ""
  echo "  This removes stale worktree administrative files for worktrees whose"
  echo "  working-directory paths no longer exist (e.g., manually deleted)."
  echo ""

  local prune_dry
  prune_dry="$(git worktree prune --dry-run 2>&1 || true)"

  if [[ -z "${prune_dry}" ]] || ! echo "${prune_dry}" | grep -q "Removing"; then
    echo "  Nothing to prune."
    exit 0
  fi

  echo "  Would prune:"
  while IFS= read -r _prune_line; do
    printf '    %s\n' "${_prune_line}"
  done <<<"${prune_dry}"
  echo ""

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made (use --execute to proceed) ---"
    exit 0
  fi

  if git worktree prune --verbose 2>&1 | tee -a "${logfile}"; then
    echo ""
    echo "[OK] Pruned stale worktree administrative files."
  else
    echo "[ERROR] Prune failed" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
_show_help() {
  echo "Usage: ./scripts/git/worktree_manage.sh <subcommand> [OPTIONS]"
  echo ""
  echo "Git linked-worktree management."
  echo "Allows multiple branches to be checked out simultaneously in separate directories."
  echo ""
  echo "Subcommands:"
  echo "  list                      List all worktrees (main + linked)"
  echo "  list --status [--no-pr]   One row per linked worktree: branch (or detached), merged into"
  echo "                            <remote>/<default branch>, changed files, untracked files,"
  echo "                            commits ahead, PR state (when gh can reach the GitHub remote;"
  echo "                            --no-pr skips it), and why remove-merged would keep it."
  echo "                            Ends with the count of worktrees that are safe to remove"
  echo "  add  <path> [<branch> [<base>]]"
  echo "                            Add a linked worktree; creates the branch if needed,"
  echo "                            starting from <base> (default HEAD) with no upstream"
  echo "                            until first push; tracks <remote>/<branch> when only"
  echo "                            the remote has it or <base> is that ref"
  echo "  link [<path>]             Link scripts/git and .githooks from the main worktree"
  echo "  remove [--execute] <path> Remove a linked worktree (dry-run by default). Exits 1 when"
  echo "                            the folder stays after git unregistered the worktree (a process"
  echo "                            holds it; on Windows the holder is named when its command line"
  echo "                            names the folder)"
  echo "  remove-merged [--execute] Remove every linked worktree that is merged, has 0 changed,"
  echo "                            0 untracked and 0 ahead (a detached one when its HEAD is in the"
  echo "                            default branch), then git branch -d its branch (never -D)."
  echo "                            Never the main or current worktree, nor a locked one or one a"
  echo "                            process names on its command line. Dry-run by default; one line"
  echo "                            per worktree; exits 1 if any selected removal failed"
  echo "  prune  [--execute]        Remove stale admin files (dry-run by default)"
  echo ""
  echo "Options (add):"
  echo "  --base <ref>        Start a new branch from <ref> (same as the 3rd positional)"
  echo "  --dry-run           Preview without adding"
  echo "  --non-interactive   Skip confirmation prompt"
  echo ""
  echo "Options (link):"
  echo "  --dry-run           Preview without linking"
  echo ""
  echo "Options (list):"
  echo "  --status            Show the status table instead of the plain list"
  echo "  --no-pr             With --status: do not ask gh for PR states"
  echo ""
  echo "Options (remove / remove-merged / prune):"
  echo "  --execute           Actually remove (default is dry-run preview)"
  echo "  --dry-run           Explicit dry-run (the default)"
  echo "  --non-interactive   Skip confirmation (remove and remove-merged)"
  echo ""
  echo "Examples:"
  echo "  ./scripts/git/worktree_manage.sh list"
  echo "  ./scripts/git/worktree_manage.sh list --status"
  echo "  ./scripts/git/worktree_manage.sh add ../hotfix hotfix/urgent-fix"
  echo "  ./scripts/git/worktree_manage.sh add ../pr2 feat/part-2 feat/part-1   # branch off another branch"
  echo "  ./scripts/git/worktree_manage.sh link          # link the current worktree"
  echo "  ./scripts/git/worktree_manage.sh link ../hotfix"
  echo "  ./scripts/git/worktree_manage.sh remove --execute ../hotfix"
  echo "  ./scripts/git/worktree_manage.sh remove --execute --non-interactive ../hotfix   # no terminal (agent, CI)"
  echo "  ./scripts/git/worktree_manage.sh remove-merged                               # preview"
  echo "  ./scripts/git/worktree_manage.sh remove-merged --execute --non-interactive    # no terminal (agent, CI)"
  echo "  ./scripts/git/worktree_manage.sh prune --execute"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local subcmd="${1:-}"
  shift || true

  case "${subcmd}" in
    list) _cmd_list "$@" ;;
    add) _cmd_add "$@" ;;
    link) _cmd_link "$@" ;;
    remove) _cmd_remove "$@" ;;
    remove-merged) _cmd_remove_merged "$@" ;;
    prune) _cmd_prune "$@" ;;
    --help | -h | help | "") _show_help ;;
    *)
      echo "[ERROR] Unknown subcommand: ${subcmd}" >&2
      echo ""
      _show_help
      exit 1
      ;;
  esac
}

main "$@"
