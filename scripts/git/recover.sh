#!/usr/bin/env bash
# recover.sh - Reflog and dangling-commit recovery tool
# Purpose: Surface git's canonical safety nets (reflog + git fsck --full) to
#          help recover commits lost by resets, dropped rebases, or accidental
#          branch deletions.  Complements CGW backup tags with the recovery
#          mechanisms Pro Git frames as "Git's version of shell history"
#          (§"Reflog Shortnames") and the fsck path for when the reflog itself
#          is gone (§"Data Recovery").
# Usage: ./scripts/git/recover.sh <subcommand> [OPTIONS]
#
# Subcommands:
#   reflog   [--limit N] [--ref <ref>]   Show reflog with restore hints
#   show     <entry>                     Show details of a reflog entry or SHA
#   dangling [--limit N]                 List dangling commits via git fsck
#   restore  <sha> --branch <name>       Restore a lost commit as a new branch
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

init_logging "recover"

# ---------------------------------------------------------------------------
# Subcommand: reflog
# ---------------------------------------------------------------------------
_cmd_reflog() {
  local limit=20
  local ref="HEAD"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        limit="${2:-20}"
        shift 2
        ;;
      --ref)
        ref="${2:-HEAD}"
        shift 2
        ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  echo "=== Reflog Recovery ==="
  echo ""
  echo "  Ref:    ${ref}"
  echo "  Limit:  ${limit} entries"
  echo ""
  echo "  Git's reflog records every time a branch tip or HEAD moves — including"
  echo "  resets, rebases, and branch switches.  Use 'recover.sh show <entry>'"
  echo "  to inspect, and 'recover.sh restore <sha>' to recover."
  echo ""

  if ! git rev-parse --verify "${ref}" >/dev/null 2>&1; then
    echo "[ERROR] Ref '${ref}' not found" >&2
    exit 1
  fi

  echo "--- Reflog: ${ref} (most recent first) ---"
  echo ""
  git reflog "${ref}" --date=relative --format="  %C(yellow)%h%C(reset)  %C(blue)%gd%C(reset)  %gs%C(auto)%d%C(reset)  %C(dim)(%cr)%C(reset)" \
    2>/dev/null | head -n "${limit}" ||
    git reflog "${ref}" --date=relative 2>/dev/null | head -n "${limit}" || {
    echo "  (no reflog entries for ${ref})"
    echo ""
    echo "  Tip: run 'recover.sh dangling' to search for unreachable objects"
    echo "       via git fsck when the reflog is empty or unavailable."
  }

  echo ""
  echo "--- Backup tags (CGW safety net) ---"
  local tags
  tags="$(cgw_list_backup_tags 2>/dev/null | tail -5 || true)"
  if [[ -n "${tags}" ]]; then
    echo "${tags}" | while IFS= read -r tag; do
      printf "  %-40s  %s\n" "${tag}" \
        "$(git log -1 --format="%h %s (%ar)" "${tag}" 2>/dev/null || true)"
    done
  else
    echo "  (no CGW backup tags found)"
  fi

  echo ""
  echo "Restore a lost commit:  ./scripts/git/recover.sh restore <sha> --branch <name>"
  echo "Show commit details:    ./scripts/git/recover.sh show <sha-or-entry>"
}

# ---------------------------------------------------------------------------
# Subcommand: show
# ---------------------------------------------------------------------------
_cmd_show() {
  local entry="${1:-}"
  if [[ -z "${entry}" ]]; then
    echo "[ERROR] Usage: recover.sh show <reflog-entry|sha>" >&2
    exit 1
  fi

  echo "=== Show Commit: ${entry} ==="
  echo ""

  if ! git rev-parse --verify "${entry}" >/dev/null 2>&1; then
    echo "[ERROR] '${entry}' is not a valid ref or SHA" >&2
    exit 1
  fi

  git log -1 --stat "${entry}" 2>/dev/null
  echo ""
  echo "To restore as a branch:"
  echo "  ./scripts/git/recover.sh restore ${entry} --branch <name>"
}

# ---------------------------------------------------------------------------
# Subcommand: dangling
# ---------------------------------------------------------------------------
_cmd_dangling() {
  local limit=20

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        limit="${2:-20}"
        shift 2
        ;;
      *)
        echo "[ERROR] Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  echo "=== Dangling Commit Recovery ==="
  echo ""
  echo "  Running git fsck --full --no-reflogs to find unreachable objects."
  echo "  Pro Git: use this when 'the reflog is gone' to find lost commits."
  echo ""
  echo "  This is READ-ONLY: fsck never modifies the repository."
  echo ""

  local fsck_out
  fsck_out="$(git fsck --full --no-reflogs 2>&1 || true)"

  local dangling
  dangling="$(grep "^dangling commit" <<<"${fsck_out}" | while IFS= read -r line; do printf '%s\n' "${line##* }"; done || true)"

  if [[ -z "${dangling}" ]]; then
    echo "  No dangling commits found."
    echo ""
    echo "  Other dangling objects (blobs/trees) were ignored."
    echo "  If your commit is truly lost, check:"
    echo "    - CGW backup tags: ./scripts/git/recover.sh reflog"
    echo "    - git reflog HEAD"
    return 0
  fi

  echo "  Found dangling commits (limited to ${limit}):"
  echo ""
  local count=0
  while IFS= read -r sha; do
    ((count++))
    [[ ${count} -gt ${limit} ]] && {
      echo "  ... (${limit} shown, use --limit N to see more)"
      break
    }
    printf "  %s  %s\n" "${sha:0:10}" \
      "$(git log -1 --format="%s (%ar)" "${sha}" 2>/dev/null || echo '(cannot read)')"
  done <<<"${dangling}"

  echo ""
  echo "Inspect a commit:  ./scripts/git/recover.sh show <sha>"
  echo "Restore a commit:  ./scripts/git/recover.sh restore <sha> --branch <name>"
}

# ---------------------------------------------------------------------------
# Subcommand: restore
# ---------------------------------------------------------------------------
_cmd_restore() {
  local sha=""
  local branch_name=""
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        branch_name="${2:-}"
        [[ -z "${branch_name}" ]] && {
          echo "[ERROR] --branch requires a name" >&2
          exit 1
        }
        shift 2
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
        sha="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${sha}" ]]; then
    echo "[ERROR] Usage: recover.sh restore <sha> --branch <name>" >&2
    exit 1
  fi
  if [[ -z "${branch_name}" ]]; then
    echo "[ERROR] --branch <name> is required" >&2
    exit 1
  fi

  # Validate the SHA
  if ! git rev-parse --verify "${sha}" >/dev/null 2>&1; then
    echo "[ERROR] '${sha}' is not a valid ref or SHA" >&2
    exit 1
  fi

  local full_sha
  full_sha="$(git rev-parse "${sha}")"

  echo "=== Restore Lost Commit ==="
  echo ""
  echo "  Commit:  ${full_sha:0:12}"
  echo "  Subject: $(git log -1 --format='%s' "${full_sha}")"
  echo "  Author:  $(git log -1 --format='%an <%ae>' "${full_sha}")"
  echo "  Date:    $(git log -1 --format='%cd' --date=short "${full_sha}")"
  echo "  Branch:  ${branch_name} (will be created)"
  echo ""

  # Check the branch name doesn't already exist
  if git rev-parse --verify --quiet "refs/heads/${branch_name}" >/dev/null 2>&1; then
    echo "[ERROR] Branch '${branch_name}' already exists." >&2
    echo "  Choose a different name, or delete it first: git branch -D ${branch_name}" >&2
    exit 1
  fi

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "--- Dry run: no changes made ---"
    echo "Would create backup tag at HEAD, then: git branch ${branch_name} ${full_sha}"
    exit 0
  fi

  if ! cgw_confirm "Create branch '${branch_name}' at ${full_sha:0:12}?" --non-interactive accept; then
    echo "Cancelled"
    exit 0
  fi

  # Create a backup tag at the current HEAD before any mutation.
  cgw_create_backup_tag recover 2>/dev/null || true

  # Create the recovery branch pointing at the lost commit.
  if git branch "${branch_name}" "${full_sha}"; then
    echo ""
    echo "[OK] Recovered commit as branch: ${branch_name}"
    echo "  $(git log -1 --oneline "${branch_name}")"
    echo ""
    echo "  To inspect:       git log ${branch_name}"
    echo "  To switch to it:  git checkout ${branch_name}"
  else
    echo "[ERROR] Failed to create branch" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
_show_help() {
  echo "Usage: ./scripts/git/recover.sh <subcommand> [OPTIONS]"
  echo ""
  echo "Reflog and dangling-commit recovery tool."
  echo "Surfaces git's canonical safety nets (Pro Git §'Reflog' + §'Data Recovery')."
  echo ""
  echo "Subcommands:"
  echo "  reflog   [--limit N] [--ref <ref>]   Pretty-print reflog with restore hints"
  echo "  show     <entry>                     Show log + stat for a reflog entry or SHA"
  echo "  dangling [--limit N]                 List unreachable commits via git fsck --full"
  echo "  restore  <sha> --branch <name>       Recover lost commit as a new branch"
  echo ""
  echo "All subcommands except 'restore' are read-only."
  echo "'restore' creates a backup tag before touching any ref."
  echo ""
  echo "Options (restore):"
  echo "  --branch <name>     Name for the recovery branch (required)"
  echo "  --dry-run           Preview without making changes"
  echo "  --non-interactive   Skip confirmation prompt"
  echo ""
  echo "CGW backup tags are also shown in 'reflog' output."
  echo "Use 'recover.sh restore <tag> --branch <name>' to restore from a CGW tag."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local subcmd="${1:-}"
  shift || true

  case "${subcmd}" in
    reflog) _cmd_reflog "$@" ;;
    show) _cmd_show "$@" ;;
    dangling) _cmd_dangling "$@" ;;
    restore) _cmd_restore "$@" ;;
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
