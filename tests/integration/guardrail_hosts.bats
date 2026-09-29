#!/usr/bin/env bats
# tests/integration/guardrail_hosts.bats — Cross-host characterization of the
# dangerous-git guardrails (cc-block-dangerous-git.sh, agy-block-dangerous-git.sh).
#
# cc_guardrail.bats drives its classifier edge cases through the Claude Code
# payload shape only, and agy_guardrail.bats repeats a subset through the
# Antigravity shape. This file runs ONE verdict table through BOTH scripts
# with BOTH payload shapes, and pins each host's protocol, so the two scripts
# are held to the same classifier behaviour however they are structured.
#
# Protocol, per payload shape (identical for both scripts):
#   tool_input (Claude Code): block -> exit 2 + "BLOCKED" on stderr; allow -> exit 0, no output
#   toolCall  (Antigravity):  block -> exit 0 + {"decision": "deny", ...};  allow -> {"decision": "allow"}
#
# Runs: bats tests/integration/guardrail_hosts.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

CC_SCRIPT="${CGW_PROJECT_ROOT}/hooks/cc-block-dangerous-git.sh"
AGY_SCRIPT="${CGW_PROJECT_ROOT}/hooks/agy-block-dangerous-git.sh"

# Verdict table: "B<TAB>command" = blocked, "A<TAB>command" = allowed.
# Mirrors every classifier case in cc_guardrail.bats.
_verdict_table() {
  cat <<'TABLE'
B	git commit -m 'test'
B	git commit
B	git push --no-verify origin main
B	git commit --no-verify -m 'skip hooks'
B	git push --force origin main
B	git reset --hard HEAD~1
B	git clean -fd
B	git branch -D old-feature
B	rm -rf .git
B	rm -rf /tmp/repo/.git/
B	git filter-branch --tree-filter 'rm -f secrets.txt'
B	git filter-repo --path secrets.txt --invert-paths
B	git reflog expire --expire=now --all
B	git gc --prune=now
B	git update-ref -d refs/heads/x
B	git rm -f secrets.toe
B	git rm -rf build/
B	git rm --force notes.txt
B	git rm -f victim.txt; echo --cached
B	git rm  -f victim.txt
B	echo ok && git rm -f victim.txt
B	git push origin main --force
B	git checkout -- .
B	git clean -df
B	rm -r -f .git
B	git restore --staged --worktree .
B	git restore .
A	./scripts/git/commit_enhanced.sh 'feat: add feature'
A	git push --force-with-lease origin main
A	git status
A	rm -rf .gitignore
A	rm -rf /tmp/foo/.github
A	git checkout main
A	git commit-graph write --reachable
A	git rm --cached CLAUDE.md
A	git rm -f --cached x
A	git rm stale.py
A	./scripts/git/commit_enhanced.sh 'docs: prefer git rm --cached over git rm -f'
A	git push origin main --force-with-lease
A	rm -rf build && ls .git
A	git rm --cached a.txt && echo done
A	git clean -nfd
A	git restore --staged .
A	git branch -d merged-feature
TABLE
  # Tab-separated flag (JSON "\t" in the original cc test) — kept out of the
  # heredoc so the literal tab inside the command survives.
  printf 'B\tgit rm\t-f victim.txt\n'
}

_payload() { # <shape> <command>
  if [[ "$1" == "tool_input" ]]; then
    jq -cn --arg c "$2" '{tool_input: {command: $c}}'
  else
    jq -cn --arg c "$2" '{toolCall: {name: "run_command", args: {CommandLine: $c}}}'
  fi
}

# Runs the whole table through <script> with payload <shape>; prints every
# mismatch and fails if there is any.
_check_table() {
  local script="$1" shape="$2"
  local verdict cmd out rc failures=""
  while IFS=$'\t' read -r verdict cmd; do
    [[ -z "${verdict}" ]] && continue
    # bats runs under errexit: capture the exit status without aborting.
    out=$(_payload "${shape}" "${cmd}" | bash "${script}" 2>&1) && rc=0 || rc=$?
    case "${shape}:${verdict}" in
      tool_input:B) [[ ${rc} -eq 2 && "${out}" == *BLOCKED* ]] ;;
      tool_input:A) [[ ${rc} -eq 0 && -z "${out}" ]] ;;
      toolCall:B) [[ ${rc} -eq 0 && "${out}" =~ \"decision\":[[:space:]]*\"deny\" ]] ;;
      toolCall:A) [[ ${rc} -eq 0 && "${out}" =~ \"decision\":[[:space:]]*\"allow\" ]] ;;
    esac || failures+="  [${verdict}] ${cmd}  (rc=${rc}, out=${out:0:80})"$'\n'
  done < <(_verdict_table)
  if [[ -n "${failures}" ]]; then
    printf '%s via %s:\n%s' "${script##*/}" "${shape}" "${failures}"
    return 1
  fi
}

@test "verdict table: cc guardrail, Claude Code payload" {
  _require_jq
  _check_table "${CC_SCRIPT}" tool_input
}

@test "verdict table: cc guardrail, Antigravity payload" {
  _require_jq
  _check_table "${CC_SCRIPT}" toolCall
}

@test "verdict table: agy guardrail, Claude Code payload" {
  _require_jq
  _check_table "${AGY_SCRIPT}" tool_input
}

@test "verdict table: agy guardrail, Antigravity payload" {
  _require_jq
  _check_table "${AGY_SCRIPT}" toolCall
}

# ── Host-specific protocol differences (pinned as they are today) ────────────

@test "unrecognized payload shape: cc stays silent, agy emits decision allow" {
  _require_jq
  run bash "${CC_SCRIPT}" <<<'{"other":{"command":"git commit"}}'
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  run bash "${AGY_SCRIPT}" <<<'{"other":{"command":"git commit"}}'
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\":[[:space:]]*\"allow\" ]]
}

@test "payload carrying both shapes: cc reads tool_input, agy reads toolCall" {
  _require_jq
  local both='{"tool_input":{"command":"git commit -m x"},"toolCall":{"args":{"CommandLine":"git status"}}}'
  run bash "${CC_SCRIPT}" <<<"${both}"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\":[[:space:]]*\"deny\" ]]
  run bash "${AGY_SCRIPT}" <<<"${both}"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\":[[:space:]]*\"allow\" ]]
}

@test "toolCall.args.command is accepted as well as CommandLine (both hosts)" {
  _require_jq
  local s
  for s in "${CC_SCRIPT}" "${AGY_SCRIPT}"; do
    run bash "${s}" <<<'{"toolCall":{"args":{"command":"git reset --hard"}}}'
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ \"decision\":[[:space:]]*\"deny\" ]]
  done
}

@test "SKIP_CGW_GUARDRAIL=1 allows under each host's protocol (both scripts)" {
  _require_jq
  local s
  for s in "${CC_SCRIPT}" "${AGY_SCRIPT}"; do
    run env SKIP_CGW_GUARDRAIL=1 bash "${s}" <<<'{"tool_input":{"command":"git commit"}}'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run env SKIP_CGW_GUARDRAIL=1 bash "${s}" <<<'{"toolCall":{"args":{"CommandLine":"git commit"}}}'
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ \"decision\":[[:space:]]*\"allow\" ]]
  done
}
