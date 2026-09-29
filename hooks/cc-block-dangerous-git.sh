#!/usr/bin/env bash
# cc-block-dangerous-git.sh — Claude Code PreToolUse guardrail (installed by CGW configure.sh)
#
# Blocks dangerous git/shell commands before they reach the shell.
# Claude Code invokes this hook for every Bash tool call (PreToolUse: Bash matcher).
#
# Protocol (Claude Code hook contract):
#   - Tool input arrives as JSON on stdin
#   - Exit 2 + stderr content → Claude Code blocks the call; stderr is shown to the model
#   - Exit 0 → command is allowed through
#
# Fail-open policy: if jq is absent or stdin is unparseable, the guardrail
# degrades gracefully (logs a warning, allows the command through) rather than
# breaking the user's shell.
#
# The classifier itself (which commands are blocked, and its heuristic limits)
# lives in _guardrail_core.sh next to this file, shared with the Antigravity
# guardrail; this adapter owns only stdin parsing and the Claude Code protocol.
#
# To uninstall: remove the PreToolUse entry from .claude/settings.json and
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
  if jq -e '.toolCall' <<< "${INPUT}" >/dev/null 2>&1; then
    printf '{"decision": "allow"}\n'
  fi
  exit 0
}

[[ "${SKIP_CGW_GUARDRAIL:-}" == "1" ]] && _allow_and_exit

# Fail open: if jq is absent, warn and allow through
if ! command -v jq &>/dev/null; then
  printf '[CGW guardrail] WARNING: jq not found — guardrail is degraded; commands are not being inspected\n' >&2
  _allow_and_exit
fi

# Shared classifier. Fail open (loudly) if it is missing, same as a missing jq:
# without it no command can be classified, and blocking every call would stop
# the agent's whole shell, not just git.
_CGW_GUARDRAIL_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_guardrail_core.sh"
# shellcheck source=_guardrail_core.sh
if ! source "${_CGW_GUARDRAIL_CORE}" 2>/dev/null; then
  printf '[CGW guardrail] WARNING: %s not found — guardrail is degraded; commands are not being inspected\n' "${_CGW_GUARDRAIL_CORE}" >&2
  _allow_and_exit
fi

COMMAND=$(jq -r '(.tool_input.command // .toolCall.args.CommandLine // .toolCall.args.command // empty)' <<< "${INPUT}" 2>/dev/null)
[[ -z "${COMMAND}" ]] && _allow_and_exit

# ── Block helper ──────────────────────────────────────────────────────────────

_block() {
  local pattern="$1"
  local redirect="$2"
  local reason="BLOCKED: Command matched dangerous pattern \"${pattern}\".
${redirect}
The user has prevented you from doing this."

  if jq -e '.tool_input' <<< "${INPUT}" >/dev/null 2>&1 && ! jq -e '.toolCall' <<< "${INPUT}" >/dev/null 2>&1; then
    printf 'BLOCKED: Command matched dangerous pattern "%s".\n%s\nThe user has prevented you from doing this.\n' \
      "${pattern}" "${redirect}" >&2
    exit 2
  fi

  if jq -e '.toolCall' <<< "${INPUT}" >/dev/null 2>&1; then
    jq -n --arg r "${reason}" '{"decision": "deny", "reason": $r}'
    exit 0
  fi

  printf 'BLOCKED: Command matched dangerous pattern "%s".\n%s\nThe user has prevented you from doing this.\n' \
    "${pattern}" "${redirect}" >&2
  exit 2
}

if ! _verdict=$(cgw_guardrail_classify "${COMMAND}"); then
  _block "${_verdict%%$'\n'*}" "${_verdict#*$'\n'}"
fi

_allow_and_exit
