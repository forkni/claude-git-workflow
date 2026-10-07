#!/usr/bin/env bash
# sync_cgw_tooling.sh - Refresh this project's vendored CGW tooling from a claude-git-workflow checkout
# Purpose: Replace the hand-copy of scripts/git/ with one reproducible step: bring the branch up to
#          date, copy scripts/git/*.sh from the CGW source, let configure.sh refresh the hooks and
#          the .claude/ + .agents/ skill/command/guardrail twins from the same source, then commit
#          the result as a single "chore: sync CGW git tooling" commit. Never hand-edit a twin --
#          rerun this script instead.
# Usage: ./scripts/git/sync_cgw_tooling.sh --from <claude-git-workflow checkout> [OPTIONS]
#
# Globals:
#   SCRIPT_DIR          - Directory containing this script
#   PROJECT_ROOT        - Auto-detected git repo root (set by _config.sh)
#   logfile             - Set by init_logging
#   CGW_TEMPLATE_DIR    - CGW source checkout, used when --from is not given
# Arguments:
#   --from <dir>              CGW source checkout (has scripts/git/ and skill/)
#   --extra-skill-dst <dir>   Also copy skill/SKILL.md + skill/references/*.md into <dir>
#                             (repeatable; for a forked skill copy outside .claude/ and .agents/)
#   --extra-cmd-dst <file>    Also write command/auto-git-workflow-cmd.md to <file> with its links
#                             rewritten for the skills layout (repeatable; a forked cmd skill)
#   --no-pull                 Skip the sync_branches.sh step (no remote / offline)
#   --non-interactive         Accepted for symmetry; this script never prompts
#   -h, --help                Show help
# Returns:
#   0 on success (or already up to date), 1 on failure or a dirty tree

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

init_logging "sync_cgw_tooling"
ensure_no_stale_index_lock || exit 1

_SYNC_SELF="$(basename "${BASH_SOURCE[0]}")"

_show_help() {
  echo "Usage: ./scripts/git/sync_cgw_tooling.sh --from <claude-git-workflow checkout> [OPTIONS]"
  echo ""
  echo "Refresh the vendored CGW tooling in this project and commit it as one commit."
  echo ""
  echo "Options:"
  echo "  --from <dir>             CGW source checkout (default: \$CGW_TEMPLATE_DIR)"
  echo "  --extra-skill-dst <dir>  Also copy skill/SKILL.md + references/*.md into <dir> (repeatable)"
  echo "  --extra-cmd-dst <file>   Also write the slash-command skill to <file>, links adapted (repeatable)"
  echo "  --no-pull                Skip the sync_branches.sh step"
  echo "  --non-interactive        Accepted for symmetry; this script never prompts"
  echo "  -h, --help               Show this help"
  echo ""
  echo "Refuses to run on a dirty working tree. Exits non-zero if the tree is not clean afterwards."
}

# Porcelain entries that matter: the logs/ dir this very run creates is not "dirty".
_dirty_entries() {
  git status --porcelain --untracked-files=all 2>/dev/null | grep -v -E '^.. logs/' || true
}

# _tool <name>: the project's refreshed copy of a CGW script, else the running one.
_tool() {
  if [[ -f "${PROJECT_ROOT}/scripts/git/$1" ]]; then
    echo "${PROJECT_ROOT}/scripts/git/$1"
  else
    echo "${SCRIPT_DIR}/$1"
  fi
}

main() {
  local src="${CGW_TEMPLATE_DIR:-}" do_pull=1
  local -a extra_dsts=() cmd_dsts=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        _show_help
        return 0
        ;;
      --from)
        shift
        src="${1:-}"
        ;;
      --from=*) src="${1#*=}" ;;
      --extra-skill-dst)
        shift
        extra_dsts+=("${1:-}")
        ;;
      --extra-skill-dst=*) extra_dsts+=("${1#*=}") ;;
      --extra-cmd-dst)
        shift
        cmd_dsts+=("${1:-}")
        ;;
      --extra-cmd-dst=*) cmd_dsts+=("${1#*=}") ;;
      --no-pull) do_pull=0 ;;
      --non-interactive) CGW_NON_INTERACTIVE=1 ;;
      *)
        echo "[ERROR] Unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  # 1. Source checkout: fail loudly rather than guess.
  if [[ -z "${src}" ]]; then
    echo "[ERROR] No CGW source: pass --from <claude-git-workflow checkout> or set CGW_TEMPLATE_DIR" >&2
    return 1
  fi
  if [[ ! -f "${src}/scripts/git/_common.sh" || ! -f "${src}/skill/SKILL.md" ]]; then
    echo "[ERROR] '${src}' is not a claude-git-workflow checkout (missing scripts/git/_common.sh or skill/SKILL.md)" >&2
    return 1
  fi
  src="$(cd "${src}" && pwd)"
  local d
  for d in "${extra_dsts[@]+"${extra_dsts[@]}"}"; do
    if [[ -z "${d}" ]]; then
      echo "[ERROR] --extra-skill-dst needs a directory" >&2
      return 1
    fi
  done

  for d in "${cmd_dsts[@]+"${cmd_dsts[@]}"}"; do
    if [[ -z "${d}" ]]; then
      echo "[ERROR] --extra-cmd-dst needs a file path" >&2
      return 1
    fi
  done
  if [[ ${#cmd_dsts[@]} -gt 0 && ! -f "${src}/command/auto-git-workflow-cmd.md" ]]; then
    echo "[ERROR] '${src}' has no command/auto-git-workflow-cmd.md for --extra-cmd-dst" >&2
    return 1
  fi

  cd "${PROJECT_ROOT}" || return 1
  if [[ "${src}" == "${PROJECT_ROOT}" ]]; then
    echo "[ERROR] Source and project are the same checkout (${src}); nothing to sync" >&2
    return 1
  fi

  # 2. Refuse on a dirty tree, before touching anything.
  local dirty
  dirty="$(_dirty_entries)"
  if [[ -n "${dirty}" ]]; then
    echo "[ERROR] Working tree is not clean; commit or stash first. Dirty paths:" >&2
    echo "${dirty}" >&2
    return 1
  fi

  # 3. Land on the current upstream first so the sync commit sits on top of it.
  if [[ ${do_pull} -eq 1 ]]; then
    echo "Syncing branch with remote..."
    bash "${SCRIPT_DIR}/sync_branches.sh" --non-interactive || {
      echo "[ERROR] sync_branches.sh failed; resolve that first (or pass --no-pull)" >&2
      return 1
    }
  fi

  # 4. Copy scripts/git/*.sh into the project. Copy only, never delete; this script is
  #    skipped so a running copy is never overwritten from under bash.
  local dst="${PROJECT_ROOT}/scripts/git" f name copied=0
  mkdir -p "${dst}"
  for f in "${src}"/scripts/git/*.sh; do
    name="$(basename "${f}")"
    [[ "${name}" == "${_SYNC_SELF}" ]] && continue
    if ! cmp -s "${f}" "${dst}/${name}"; then
      cp -p "${f}" "${dst}/${name}"
      copied=$((copied + 1))
    fi
  done
  echo "  [OK] scripts/git/*.sh: ${copied} file(s) updated"
  for f in "${dst}"/*.sh; do
    name="$(basename "${f}")"
    [[ "${name}" == "${_SYNC_SELF}" ]] && continue
    [[ -f "${src}/scripts/git/${name}" ]] || echo "  [!] ${name} exists here but not in the CGW source (left in place)"
  done

  # 5. Hooks, skill/command twins and guardrails from the same source. Prefer the copy of
  #    configure.sh that was just refreshed.
  bash "$(_tool configure.sh)" --template-dir "${src}" --non-interactive --overwrite-hooks || {
    echo "[ERROR] configure.sh failed; the working tree is left as-is for inspection" >&2
    return 1
  }

  # 6. Forked skill copies outside .claude/ and .agents/.
  for d in "${extra_dsts[@]+"${extra_dsts[@]}"}"; do
    mkdir -p "${d}/references"
    cp "${src}/skill/SKILL.md" "${d}/SKILL.md"
    cp "${src}/skill/references/"*.md "${d}/references/" 2>/dev/null || true
    echo "  [OK] skill copied to ${d}"
  done

  # 6b. Forked slash-command skill: same link rewrite configure.sh applies for the skills layout.
  for d in "${cmd_dsts[@]+"${cmd_dsts[@]}"}"; do
    mkdir -p "$(dirname "${d}")"
    sed -e 's|\.\./skills/auto-git-workflow/|../auto-git-workflow/|g' \
      -e 's|\.claude/skills/auto-git-workflow/|auto-git-workflow/|g' \
      "${src}/command/auto-git-workflow-cmd.md" >"${d}"
    echo "  [OK] command skill written to ${d}"
  done

  # 7. One commit, listing exactly the changed paths.
  local -a entries=() paths=()
  local e p
  mapfile -d '' -t entries < <(git status --porcelain -z --untracked-files=all 2>/dev/null)
  for e in "${entries[@]+"${entries[@]}"}"; do
    p="${e:3}"
    [[ -z "${p}" || "${p}" == logs/* ]] && continue
    paths+=("${p}")
  done
  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "[OK] CGW tooling already up to date -- nothing to commit"
    return 0
  fi

  local sha msg
  sha="$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  msg="$(printf 'chore: sync CGW git tooling\n\nSyncs upstream %s' "${sha}")"
  local -a only_args=()
  for p in "${paths[@]}"; do
    only_args+=(--only "${p}")
  done
  bash "$(_tool commit_enhanced.sh)" --non-interactive "${only_args[@]}" "${msg}" || {
    echo "[ERROR] commit failed; changes are left in the working tree" >&2
    return 1
  }

  # 8. A clean tree afterwards is the success condition.
  dirty="$(_dirty_entries)"
  if [[ -n "${dirty}" ]]; then
    echo "[ERROR] Working tree is not clean after the sync commit:" >&2
    echo "${dirty}" >&2
    return 1
  fi
  echo "[OK] CGW tooling synced from ${src} (${sha})"
}

# The copy loop skips this file, so bash never reads a half-overwritten script.
main "$@"
exit $?
