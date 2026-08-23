#!/usr/bin/env bash
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
#   add  <path> [<branch>]   Add a linked worktree (creates branch if needed)
#   link [<path>]            Link scripts/git and .githooks from the main worktree
#   remove <path>            Remove a linked worktree (dry-run default)
#   prune                    Remove stale administrative files (dry-run default)
#
# Globals:
#   SCRIPT_DIR     - Directory containing this script
#   PROJECT_ROOT   - Auto-detected git repo root (set by _config.sh)
#   logfile        - Set by init_logging
# Returns:
#   0 on success, 1 on failure

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

# Create a directory link at $1 pointing at existing directory $2.
# POSIX symlink where supported; NTFS directory junction on Windows (`mklink
# /J` needs no admin rights, unlike a symlink or `/D`, and Git Bash reads a
# junction as an ordinary directory).
_cgw_link_dir() {
  local link_path="$1" target_dir="$2"
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      local win_link win_target
      win_link="$(cygpath -w "${link_path}" 2>/dev/null || echo "${link_path}")"
      win_target="$(cygpath -w "${target_dir}" 2>/dev/null || echo "${target_dir}")"
      # Both flags use a doubled leading slash ("//c", "//J"): MSYS's bash
      # auto-converts any bare "/X" argument (single letter after a leading
      # slash) passed to a native Windows binary into a drive-letter path
      # before cmd.exe ever sees it -- an un-doubled "/J" gets silently
      # mangled and mklink fails with "Invalid switch". Doubling the slash is
      # MSYS's own escape convention: it de-mangles "//X" back down to a
      # literal "/X" instead of converting it. (MSYS_NO_PATHCONV=1 is NOT a
      # substitute here -- it disables ALL conversion including that
      # de-mangling step, which breaks "//c" too: cmd.exe doesn't recognize a
      # literal two-slash "//c" as /c and silently drops into an interactive
      # shell instead of running the command, so the whole call becomes a
      # silent no-op that still exits 0.)
      cmd //c mklink //J "${win_link}" "${win_target}" >/dev/null
      ;;
    *)
      ln -s "${target_dir}" "${link_path}"
      ;;
  esac
}

# True if $1 and $2 resolve to the same directory. Used to validate an
# existing link at a tooling path actually points at the main worktree
# before accepting it as "already linked". `cd && pwd -P` follows an NTFS
# junction's reparse point on Windows/MSYS (unlike `stat`, whose device:inode
# on a junction identifies the reparse point itself, not its target).
_cgw_same_dir() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  [[ "${a}" == "${b}" ]]
}

# Remove a link created by _cgw_link_dir. Refuses to touch anything that
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

# Links scripts/git and .githooks from the main worktree into $1. Idempotent
# (skips entries already linked) and refuses to overwrite a real directory. A
# no-op, non-error, when $1 IS the main worktree.
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

  local rel status=0
  for rel in "scripts/git" ".githooks"; do
    if [[ ! -e "${main_root}/${rel}" ]]; then
      echo "  [SKIP] ${rel} not found in main worktree"
      continue
    fi
    if [[ -e "${target_path}/${rel}" ]]; then
      if _cgw_is_link "${target_path}/${rel}"; then
        if _cgw_same_dir "${target_path}/${rel}" "${main_root}/${rel}"; then
          echo "  [OK]   ${rel} already linked"
        else
          echo "  [WARN] ${rel} is a link but does not resolve to the main worktree — not touching it" >&2
          status=1
        fi
      else
        echo "  [WARN] ${rel} exists as a real directory in target — not overwriting" >&2
        status=1
      fi
      continue
    fi
    if [[ "${dry_run}" -eq 1 ]]; then
      echo "  Would link: ${target_path}/${rel} -> ${main_root}/${rel}"
      continue
    fi
    mkdir -p "$(dirname "${target_path}/${rel}")"
    if _cgw_link_dir "${target_path}/${rel}" "${main_root}/${rel}"; then
      echo "  [OK]   linked ${rel}"
    else
      echo "  [ERROR] failed to link ${rel}" >&2
      status=1
    fi
  done
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

# ---------------------------------------------------------------------------
# Subcommand: add
# ---------------------------------------------------------------------------
_cmd_add() {
  local path="" branch="" dry_run=0

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
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [[ -z "${path}" ]]; then
          path="$1"
        elif [[ -z "${branch}" ]]; then
          branch="$1"
        else
          echo "[ERROR] Unexpected argument: $1" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${path}" ]]; then
    echo "[ERROR] Usage: worktree_manage.sh add <path> [<branch>]" >&2
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
    # If the branch doesn't exist, pass -b to create it.
    if ! git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1; then
      echo "  Branch: ${branch} (new — will be created from HEAD)"
      git_args=(-b "${branch}" "${path}")
    else
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
      [[ "${link_status}" -ne 0 ]] && echo "  [WARN] Linking failed — run: ./scripts/git/worktree_manage.sh link ${path}" >&2
    fi
  else
    echo "[ERROR] Failed to add worktree" >&2
    exit 1
  fi
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
    echo "[ERROR] Usage: worktree_manage.sh remove [--execute] <path>" >&2
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
    echo "Note: the working directory at '${path}' and its branch will be preserved."
    echo "      Only the worktree administrative link is removed."
    exit 0
  fi

  if ! cgw_confirm "Remove worktree '${path}'?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

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
    exit 1
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
    err_tee "    ./scripts/git/worktree_manage.sh remove --execute '${path}'"
    exit 1
  fi

  if git worktree remove "${path}" 2>&1 | tee -a "${logfile}"; then
    echo ""
    echo "[OK] Worktree removed: ${path}"
  else
    echo "[ERROR] Failed to remove worktree." >&2
    echo "  If the worktree has uncommitted changes, use: git worktree remove --force '${path}'" >&2
    exit 1
  fi
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
  echo "  add  <path> [<branch>]    Add a linked worktree; creates branch if needed"
  echo "  link [<path>]             Link scripts/git and .githooks from the main worktree"
  echo "  remove [--execute] <path> Remove a linked worktree (dry-run by default)"
  echo "  prune  [--execute]        Remove stale admin files (dry-run by default)"
  echo ""
  echo "Options (add):"
  echo "  --dry-run           Preview without adding"
  echo "  --non-interactive   Skip confirmation prompt"
  echo ""
  echo "Options (link):"
  echo "  --dry-run           Preview without linking"
  echo ""
  echo "Options (remove / prune):"
  echo "  --execute           Actually remove (default is dry-run preview)"
  echo "  --dry-run           Explicit dry-run (the default)"
  echo "  --non-interactive   Skip confirmation (remove only)"
  echo ""
  echo "Examples:"
  echo "  ./scripts/git/worktree_manage.sh list"
  echo "  ./scripts/git/worktree_manage.sh add ../hotfix hotfix/urgent-fix"
  echo "  ./scripts/git/worktree_manage.sh link          # link the current worktree"
  echo "  ./scripts/git/worktree_manage.sh link ../hotfix"
  echo "  ./scripts/git/worktree_manage.sh remove --execute ../hotfix"
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
