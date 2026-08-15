#!/usr/bin/env bats
# tests/integration/cc_guardrail.bats — Tests for cc-block-dangerous-git.sh
# and the configure.sh --skip-cc-guardrail integration.
# Runs: bats tests/integration/cc_guardrail.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

GUARDRAIL_SCRIPT="${CGW_PROJECT_ROOT}/hooks/cc-block-dangerous-git.sh"

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
}

teardown() {
  cleanup_test_repo
}

# Helper: pipe a command string into the guardrail as a fake PreToolUse JSON payload
_run_guardrail() {
  local cmd="$1"
  local json
  printf -v json '{"tool_input":{"command":"%s"}}' "${cmd}"
  bash "${GUARDRAIL_SCRIPT}" <<< "${json}"
}

_run_configure() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/configure.sh' $*
  "
}

# ── Guardrail script: blocked commands ───────────────────────────────────────

@test "blocks raw git commit" {
  _require_jq
  run _run_guardrail "git commit -m 'test'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"BLOCKED"* ]]
  [[ "${output}" == *"commit_enhanced.sh"* ]]
}

@test "blocks git commit with no args" {
  _require_jq
  run _run_guardrail "git commit"
  [ "${status}" -eq 2 ]
}

@test "blocks --no-verify flag" {
  _require_jq
  run _run_guardrail "git push --no-verify origin main"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"BLOCKED"* ]]
}

@test "blocks --no-verify on commit" {
  _require_jq
  run _run_guardrail "git commit --no-verify -m 'skip hooks'"
  [ "${status}" -eq 2 ]
}

@test "blocks git push --force" {
  _require_jq
  run _run_guardrail "git push --force origin main"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"push_validated.sh"* ]]
}

@test "blocks git reset --hard" {
  _require_jq
  run _run_guardrail "git reset --hard HEAD~1"
  [ "${status}" -eq 2 ]
}

@test "blocks git clean -f" {
  _require_jq
  run _run_guardrail "git clean -fd"
  [ "${status}" -eq 2 ]
}

@test "blocks git branch -D" {
  _require_jq
  run _run_guardrail "git branch -D old-feature"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"branch_cleanup.sh"* ]]
}

@test "blocks rm -rf .git" {
  _require_jq
  run _run_guardrail "rm -rf .git"
  [ "${status}" -eq 2 ]
}

@test "blocks rm -rf path/to/.git/" {
  _require_jq
  run _run_guardrail "rm -rf /tmp/repo/.git/"
  [ "${status}" -eq 2 ]
}

@test "blocks git filter-branch" {
  _require_jq
  run _run_guardrail "git filter-branch --tree-filter 'rm -f secrets.txt'"
  [ "${status}" -eq 2 ]
}

@test "blocks git rm -f (working-tree delete)" {
  _require_jq
  run _run_guardrail "git rm -f secrets.toe"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--cached"* ]]
}

@test "blocks git rm -rf" {
  _require_jq
  run _run_guardrail "git rm -rf build/"
  [ "${status}" -eq 2 ]
}

@test "blocks git rm --force" {
  _require_jq
  run _run_guardrail "git rm --force notes.txt"
  [ "${status}" -eq 2 ]
}

# ── Guardrail script: allowed commands ───────────────────────────────────────

@test "allows commit_enhanced.sh" {
  run _run_guardrail "./scripts/git/commit_enhanced.sh 'feat: add feature'"
  [ "${status}" -eq 0 ]
}

@test "allows git push --force-with-lease" {
  run _run_guardrail "git push --force-with-lease origin main"
  [ "${status}" -eq 0 ]
}

@test "allows git status" {
  run _run_guardrail "git status"
  [ "${status}" -eq 0 ]
}

@test "allows rm -rf .gitignore (not the .git dir)" {
  run _run_guardrail "rm -rf .gitignore"
  [ "${status}" -eq 0 ]
}

@test "allows rm -rf /tmp/foo/.github" {
  run _run_guardrail "rm -rf /tmp/foo/.github"
  [ "${status}" -eq 0 ]
}

@test "allows git checkout mybranch (not a dot)" {
  run _run_guardrail "git checkout main"
  [ "${status}" -eq 0 ]
}

@test "allows git commit-graph write" {
  run _run_guardrail "git commit-graph write --reachable"
  [ "${status}" -eq 0 ]
}

@test "allows git rm --cached (index-only, keeps working-tree copy)" {
  run _run_guardrail "git rm --cached CLAUDE.md"
  [ "${status}" -eq 0 ]
}

@test "allows git rm -f --cached (cached wins over force)" {
  run _run_guardrail "git rm -f --cached x"
  [ "${status}" -eq 0 ]
}

@test "allows git rm without a force flag (git itself guards dirty/added files)" {
  run _run_guardrail "git rm stale.py"
  [ "${status}" -eq 0 ]
}

@test "allows git rm -f mentioned inside a commit message (quote-stripping)" {
  run _run_guardrail "./scripts/git/commit_enhanced.sh 'docs: prefer git rm --cached over git rm -f'"
  [ "${status}" -eq 0 ]
}

# ── Guardrail script: single-invocation scoping (PR #32 review) ─────────────
# Regression tests for the reported bypass: `--cached` was matched against the
# whole command line, so an exemption belonging to a different command could
# satisfy the check for an earlier `git rm -f`. Same defect class covered flags
# not adjacent to their subcommand (tabs, repeated spaces, split clusters).

@test "blocks git rm -f when --cached belongs to a later command" {
  _require_jq
  run _run_guardrail "git rm -f victim.txt; echo --cached"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--cached"* ]]
}

@test "blocks git rm -f separated by a tab" {
  _require_jq
  # Literal \t (backslash-t), not a real tab byte: the helper embeds this raw
  # into the JSON text, where \t is a valid JSON escape; jq decodes it to an
  # actual tab in COMMAND. A real tab byte here would be invalid JSON (control
  # chars must be escaped) and make jq fail closed-to-open (empty COMMAND).
  run _run_guardrail 'git rm\t-f victim.txt'
  [ "${status}" -eq 2 ]
}

@test "blocks git rm -f separated by repeated spaces" {
  _require_jq
  run _run_guardrail "git rm  -f victim.txt"
  [ "${status}" -eq 2 ]
}

@test "blocks git rm -f as a non-first command in a chain" {
  _require_jq
  run _run_guardrail "echo ok && git rm -f victim.txt"
  [ "${status}" -eq 2 ]
}

@test "blocks git push --force when the flag is not adjacent to push" {
  _require_jq
  run _run_guardrail "git push origin main --force"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"push_validated.sh"* ]]
}

@test "blocks git checkout -- . (split from the discard-all check)" {
  _require_jq
  run _run_guardrail "git checkout -- ."
  [ "${status}" -eq 2 ]
}

@test "blocks git clean -df (reordered flag cluster)" {
  _require_jq
  run _run_guardrail "git clean -df"
  [ "${status}" -eq 2 ]
}

@test "blocks rm -r -f .git (split flags)" {
  _require_jq
  run _run_guardrail "rm -r -f .git"
  [ "${status}" -eq 2 ]
}

@test "blocks git restore --staged --worktree . (worktree still discards)" {
  _require_jq
  run _run_guardrail "git restore --staged --worktree ."
  [ "${status}" -eq 2 ]
}

@test "allows git push --force-with-lease when not adjacent to push" {
  run _run_guardrail "git push origin main --force-with-lease"
  [ "${status}" -eq 0 ]
}

@test "allows rm -rf build && ls .git (segmentation removes the false positive)" {
  run _run_guardrail "rm -rf build && ls .git"
  [ "${status}" -eq 0 ]
}

@test "allows git rm --cached a.txt && echo done (cached still works in a chain)" {
  run _run_guardrail "git rm --cached a.txt && echo done"
  [ "${status}" -eq 0 ]
}

@test "allows git clean -nfd (dry run)" {
  run _run_guardrail "git clean -nfd"
  [ "${status}" -eq 0 ]
}

@test "allows git restore --staged . (index-only, non-destructive)" {
  run _run_guardrail "git restore --staged ."
  [ "${status}" -eq 0 ]
}

# ── Guardrail script: fail-open behavior ─────────────────────────────────────

@test "allows command when input JSON is empty" {
  run bash "${GUARDRAIL_SCRIPT}" <<< ""
  [ "${status}" -eq 0 ]
}

@test "allows command when tool_input.command is missing" {
  run bash "${GUARDRAIL_SCRIPT}" <<< '{"tool_input":{}}'
  [ "${status}" -eq 0 ]
}

@test "degrades gracefully and allows through when jq fails (fail-open)" {
  # Shadow jq with a script that exits 1 — simulates broken jq.
  # The guardrail cannot parse the command, so it must allow through (fail-open).
  local fake_jq="${TEST_TMPDIR}/fake-jq-bin"
  mkdir -p "${fake_jq}"
  cat > "${fake_jq}/jq" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_jq}/jq"
  run env PATH="${fake_jq}:${PATH}" bash "${GUARDRAIL_SCRIPT}" <<< \
    '{"tool_input":{"command":"git commit -m test"}}'
  [ "${status}" -eq 0 ]
}

@test "SKIP_CGW_GUARDRAIL=1 bypasses all checks" {
  run env SKIP_CGW_GUARDRAIL=1 bash "${GUARDRAIL_SCRIPT}" <<< \
    '{"tool_input":{"command":"git commit -m test"}}'
  [ "${status}" -eq 0 ]
}

# ── configure.sh integration ─────────────────────────────────────────────────

@test "--skip-cc-guardrail prevents guardrail installation" {
  mkdir -p "${TEST_REPO_DIR}/.claude"
  _run_configure "--non-interactive --skip-cc-guardrail" || true
  # settings.json should either not exist or not contain the guardrail entry
  if [[ -f "${TEST_REPO_DIR}/.claude/settings.json" ]]; then
    ! grep -q "cc-block-dangerous-git" "${TEST_REPO_DIR}/.claude/settings.json"
  fi
}

@test "non-interactive install creates guardrail script in .claude/hooks/" {
  mkdir -p "${TEST_REPO_DIR}/.claude"
  _run_configure "--non-interactive" || true
  [ -f "${TEST_REPO_DIR}/.claude/hooks/cc-block-dangerous-git.sh" ]
}

@test "non-interactive install registers guardrail in .claude/settings.json" {
  mkdir -p "${TEST_REPO_DIR}/.claude"
  _run_configure "--non-interactive" || true
  if [[ -f "${TEST_REPO_DIR}/.claude/settings.json" ]]; then
    grep -q "cc-block-dangerous-git" "${TEST_REPO_DIR}/.claude/settings.json"
  fi
}

@test "settings.json merge preserves existing entries" {
  _require_jq
  mkdir -p "${TEST_REPO_DIR}/.claude"
  # Pre-populate settings.json with an existing entry
  cat > "${TEST_REPO_DIR}/.claude/settings.json" << 'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"existing-hook.sh"}]}]}}
EOF
  _run_configure "--non-interactive" || true
  if [[ -f "${TEST_REPO_DIR}/.claude/settings.json" ]]; then
    grep -q "existing-hook.sh" "${TEST_REPO_DIR}/.claude/settings.json"
    grep -q "cc-block-dangerous-git" "${TEST_REPO_DIR}/.claude/settings.json"
  fi
}

@test "guardrail install is idempotent (no duplicate entries)" {
  mkdir -p "${TEST_REPO_DIR}/.claude"
  _run_configure "--non-interactive" || true
  _run_configure "--non-interactive" || true
  if [[ -f "${TEST_REPO_DIR}/.claude/settings.json" ]]; then
    local count
    count=$(grep -c "cc-block-dangerous-git" "${TEST_REPO_DIR}/.claude/settings.json" || true)
    [ "${count}" -le 1 ]
  fi
}

@test "registered guardrail path resolves to an existing file (regression: MSYS path conversion)" {
  # Catches the bug where Git Bash MSYS converts /.claude/... inside a jq --arg
  # value to C:/Program Files/Git/.claude/... when crossing into jq.exe, producing
  # a non-existent path that the previous string-contains test did not detect.
  mkdir -p "${TEST_REPO_DIR}/.claude"
  _run_configure "--non-interactive" || true
  [ -f "${TEST_REPO_DIR}/.claude/settings.json" ] || skip "settings.json not created"

  local registered resolved
  registered="$(jq -r \
    '[.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("cc-block-dangerous-git")) | .command][0] // empty' \
    "${TEST_REPO_DIR}/.claude/settings.json")"
  [ -n "${registered}" ] || {
    echo "No cc-block-dangerous-git entry in settings.json" >&2
    return 1
  }

  # Substitute $CLAUDE_PROJECT_DIR with the actual test repo root, strip quotes
  resolved="${registered//\"\$CLAUDE_PROJECT_DIR\"/${TEST_REPO_DIR}}"
  resolved="${resolved//\$CLAUDE_PROJECT_DIR/${TEST_REPO_DIR}}"
  resolved="${resolved#\"}"
  resolved="${resolved%\"}"

  [ -f "${resolved}" ] || {
    echo "Registered command: ${registered}" >&2
    echo "Resolved path:      ${resolved}" >&2
    echo "File does not exist — MSYS path conversion likely corrupted the registration." >&2
    return 1
  }
}
