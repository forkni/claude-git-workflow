#!/usr/bin/env bash
# agy-block-dangerous-git.sh — Antigravity PreToolUse guardrail (installed by CGW configure.sh)
#
# Blocks dangerous git/shell commands before they reach the shell.
# Antigravity invokes this hook for run_command tool calls (PreToolUse: run_command matcher).
#
# Protocol (Antigravity hook contract):
#   - Tool input arrives as JSON on stdin:
#       {"toolCall":{"name":"run_command","args":{"CommandLine":"..."}}, ...}
#   - Hook returns JSON on stdout:
#       {"decision":"allow"} to permit execution
#       {"decision":"deny","reason":"..."} to block execution immediately
#   - Exit 0 in both cases
#
# Also supports Claude Code hook contract (fallback compatibility):
#   - Input: {"tool_input":{"command":"..."}}
#   - Exit 2 + stderr to block, exit 0 to allow
#
# Fail-open policy: if jq is absent or stdin is unparseable, the guardrail
# degrades gracefully (logs a warning, allows the command through) rather than
# breaking the user's shell.
#
# Heuristic limits (defense-in-depth, not a sandbox): this hook does not evaluate
# `eval`, shell aliases/functions, nested shells (`bash -c '...'`), `git -C <path>
# <subcmd>` / `git --git-dir=... <subcmd>` (the subcommand isn't adjacent to
# `git`), or paths hidden inside quotes -- e.g. `rm -rf "$HOME/.git"` is stripped
# by the quote-stripping heuristic below before pattern matching runs. The git
# pre-commit / pre-push hooks remain the enforcement layer for whatever gets
# through; this guardrail exists to redirect an agent to the CGW wrappers early.
# Mirrors the limits documented in cc-block-dangerous-git.sh.
#
# To uninstall: remove the cgw-git-guardrail entry from .agents/hooks.json and
#   delete this file.
# To temporarily disable: set SKIP_CGW_GUARDRAIL=1 in your environment.
#
# shellcheck disable=SC2034

set -uo pipefail

INPUT=$(cat)

# Fail open helper
_allow_and_exit() {
  if jq -e '.tool_input' <<< "${INPUT}" >/dev/null 2>&1 && ! jq -e '.toolCall' <<< "${INPUT}" >/dev/null 2>&1; then
    exit 0
  fi
  printf '{"decision": "allow"}\n'
  exit 0
}

[[ "${SKIP_CGW_GUARDRAIL:-}" == "1" ]] && _allow_and_exit

# Fail open: if jq is absent, warn and allow through
if ! command -v jq &>/dev/null; then
  printf '[CGW guardrail] WARNING: jq not found — guardrail is degraded; commands are not being inspected\n' >&2
  _allow_and_exit
fi

COMMAND=$(jq -r '(.toolCall.args.CommandLine // .toolCall.args.command // .tool_input.command // empty)' <<< "${INPUT}" 2>/dev/null)
[[ -z "${COMMAND}" ]] && _allow_and_exit

# Strip quoted-string contents before pattern matching so that blocked keywords
# appearing inside commit messages or other string arguments do not cause false
# positives. For example, commit_enhanced.sh "docs: explain git commit workflow"
# should not match the 'git commit' block.
COMMAND_UNQUOTED=$(sed 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g' <<< "${COMMAND}")

# Split into individual shell invocations before pattern matching, so a flag or
# exemption belonging to one command cannot satisfy a check for a different command.
COMMAND_JOINED="${COMMAND_UNQUOTED//\\$'\n'/ }"
COMMAND_SEGMENTED="${COMMAND_JOINED//[;|&$'\n']/$'\n'}"

# ── Block helper ──────────────────────────────────────────────────────────────

_block() {
  local pattern="$1"
  local redirect="$2"
  local reason="BLOCKED: Command matched dangerous pattern \"${pattern}\".
${redirect}
The user has prevented you from doing this."

  # Claude Code compatibility mode
  if jq -e '.tool_input' <<< "${INPUT}" >/dev/null 2>&1 && ! jq -e '.toolCall' <<< "${INPUT}" >/dev/null 2>&1; then
    printf 'BLOCKED: Command matched dangerous pattern "%s".\n%s\nThe user has prevented you from doing this.\n' \
      "${pattern}" "${redirect}" >&2
    exit 2
  fi

  # Antigravity protocol: emit JSON on stdout
  jq -n --arg r "${reason}" '{"decision": "deny", "reason": $r}'
  exit 0
}

# ── Pattern checks ────────────────────────────────────────────────────────────

_check_invocation() {
  local padded=" $1 "

  # Reusable flag fragments
  local _force='[[:space:]](-[A-Za-z]*f[A-Za-z]*|--force)[[:space:]]'
  local _cached='[[:space:]]--cached([[:space:]]|=)'
  local _dryrun='[[:space:]](-[A-Za-z]*n[A-Za-z]*|--dry-run)[[:space:]]'
  local _dot='[[:space:]][.][[:space:]]'
  local _staged='[[:space:]]--staged([[:space:]]|=)'
  local _worktree='[[:space:]]--worktree([[:space:]]|=)'

  # Raw git commit — bypasses lint, local-file protection, conventional commit enforcement
  if [[ ${padded} =~ git[[:space:]]+commit[[:space:]] ]]; then
    _block 'git commit' \
      'Use ./scripts/git/commit_enhanced.sh "<type>: <msg>" instead — it runs lint, protects local-only files, and enforces conventional commit format.'
  fi

  # --no-verify — bypasses pre-commit and pre-push hooks entirely
  if [[ ${padded} =~ [[:space:]]--no-verify([[:space:]]|=) ]]; then
    _block '--no-verify' \
      'CGW pre-commit/pre-push hooks cannot be bypassed with --no-verify. Fix the underlying issue (run ./scripts/git/fix_lint.sh for lint errors, or inspect the hook output).'
  fi

  # Force-push without lease — overwrites others work and bypasses protection
  if [[ ${padded} =~ git[[:space:]]+push[[:space:]] ]] && [[ ${padded} =~ ${_force} ]]; then
    _block 'git push --force' \
      'Use ./scripts/git/push_validated.sh instead — it uses --force-with-lease and requires confirmation on protected branches. Note: --force-with-lease is allowed.'
  fi

  # Hard reset — irreversibly discards uncommitted work and index changes
  if [[ ${padded} =~ git[[:space:]]+reset[[:space:]] ]] && [[ ${padded} =~ [[:space:]]--hard([[:space:]]|=) ]]; then
    _block 'git reset --hard' \
      'Confirm with the user before running git reset --hard. This irreversibly discards uncommitted work and index changes.'
  fi

  # git clean -f — permanently deletes untracked files
  if [[ ${padded} =~ git[[:space:]]+clean[[:space:]] ]] \
     && [[ ${padded} =~ ${_force} ]] \
     && ! [[ ${padded} =~ ${_dryrun} ]]; then
    _block 'git clean -f' \
      'Confirm with the user before running git clean. This permanently deletes untracked files from the working tree.'
  fi

  # git rm -f — deletes files from the working tree
  if [[ ${padded} =~ git[[:space:]]+rm[[:space:]] ]] \
     && ! [[ ${padded} =~ ${_cached} ]] \
     && [[ ${padded} =~ ${_force} ]]; then
    _block 'git rm -f' \
      'git rm -f deletes files from the working tree — for git-ignored or untracked files this is UNRECOVERABLE. To untrack a file while keeping it on disk, use git rm --cached <path>. To force-delete a tracked file, confirm with the user first.'
  fi

  # Force-delete branch — may lose commits on an unmerged branch (-D, not -d)
  if [[ ${padded} =~ git[[:space:]]+branch[[:space:]] ]] \
     && [[ ${padded} =~ [[:space:]]-[A-Za-z]*D[A-Za-z]*[[:space:]] ]]; then
    _block 'git branch -D' \
      'Use ./scripts/git/branch_cleanup.sh --execute to prune merged branches, or confirm with the user before force-deleting an unmerged branch.'
  fi

  # Discard all working-tree changes (. = current directory = everything)
  if [[ ${padded} =~ git[[:space:]]+checkout[[:space:]] ]] && [[ ${padded} =~ ${_dot} ]]; then
    _block 'git checkout .' \
      'Confirm with the user — git checkout . irreversibly discards all working-tree changes.'
  fi

  if [[ ${padded} =~ git[[:space:]]+restore[[:space:]] ]] && [[ ${padded} =~ ${_dot} ]]; then
    if ! { [[ ${padded} =~ ${_staged} ]] && ! [[ ${padded} =~ ${_worktree} ]]; }; then
      _block 'git restore .' \
        'Confirm with the user — git restore . irreversibly discards all working-tree changes.'
    fi
  fi

  # History rewrites — permanently alter commit history; extremely destructive
  if [[ ${padded} =~ git[[:space:]]+filter-branch[[:space:]] ]]; then
    _block 'git filter-branch' \
      'Destructive history rewrite — confirm with the user before proceeding.'
  fi

  if [[ ${padded} =~ git[[:space:]]+filter-repo[[:space:]] ]]; then
    _block 'git filter-repo' \
      'Destructive history rewrite — confirm with the user before proceeding.'
  fi

  # Recovery ref destruction — eliminates the ability to recover lost commits
  if [[ ${padded} =~ git[[:space:]]+reflog[[:space:]]+expire[[:space:]] ]]; then
    _block 'git reflog expire' \
      'This destroys reflog recovery references — confirm with the user.'
  fi

  if [[ ${padded} =~ git[[:space:]]+gc[[:space:]] ]] && [[ ${padded} =~ [[:space:]]--prune=now[[:space:]] ]]; then
    _block 'git gc --prune=now' \
      'This destroys unreachable objects needed for recovery — confirm with the user.'
  fi

  if [[ ${padded} =~ git[[:space:]]+update-ref[[:space:]] ]] \
     && [[ ${padded} =~ [[:space:]]-[A-Za-z]*d[A-Za-z]*[[:space:]] ]]; then
    _block 'git update-ref -d' \
      'Destructive ref operation — confirm with the user.'
  fi

  # .git directory destruction
  if [[ ${padded} =~ [[:space:]]rm[[:space:]] ]] \
     && [[ ${padded} =~ [[:space:]]-[A-Za-z]*r[A-Za-z]*[[:space:]] ]] \
     && [[ ${padded} =~ ${_force} ]] \
     && [[ ${padded} =~ [.]git(/|[[:space:]]) ]]; then
    _block 'rm -rf .git' \
      'This would destroy the git repository — confirm with the user first.'
  fi
}

while IFS= read -r _invocation; do
  _check_invocation "${_invocation}"
done <<< "${COMMAND_SEGMENTED}"

_allow_and_exit
