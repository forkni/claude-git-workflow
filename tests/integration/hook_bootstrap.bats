#!/usr/bin/env bats
# tests/integration/hook_bootstrap.bats - Regression coverage for the
# worktree-aware, fail-closed hook bootstrap.
#
# Bug: all three hooks resolved CGW via `git rev-parse --show-toplevel` and
# sourced _common.sh from there with no existence check. When scripts/git/ is
# gitignored (so it's absent from a linked worktree, or simply not installed
# yet), the source failed under `set -uo pipefail` (no -e), so execution
# CONTINUED. pre-commit's local-only-file guard then reported a false pass
# ("No local-only files detected") and let the commit through unchecked —
# fail OPEN. pre-push/pre-rebase happened to abort anyway, but only by
# accident, via an unrelated unbound-variable error.
#
# Fix: each hook now falls back to the main worktree for the tooling, and
# refuses to run (exit 1, explicit ERROR message) if _common.sh is still
# unreachable there. This file proves the fail-CLOSED behavior directly —
# no worktree needed, since "no worktree fallback available either" (a plain
# repo where scripts/git/ was never installed) hits the exact same code path.
#
# Runs: bats tests/integration/hook_bootstrap.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

# Installs a hook template into .git/hooks/. Does NOT copy scripts/git/ —
# callers that need the "CGW present" case call _install_cgw_tooling too.
_install_hook() {
  local hook_name="$1"
  cp "${CGW_PROJECT_ROOT}/hooks/${hook_name}" "${TEST_REPO_DIR}/.git/hooks/${hook_name}"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/${hook_name}"
}

_install_cgw_tooling() {
  mkdir -p "${TEST_REPO_DIR}/scripts/git"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
}

# ── pre-commit ───────────────────────────────────────────────────────────────

@test "pre-commit: fails CLOSED when scripts/git/_common.sh is unreachable" {
  _install_hook "pre-commit"
  # scripts/git/ deliberately absent.
  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add feature.txt"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR [pre-commit]: CGW not found"* ]]
  # Regression proof: must NOT show the old false-pass message.
  [[ "${output}" != *"No local-only files detected"* ]]
}

@test "pre-commit: local-only-file guard still blocks once CGW is unreachable (no silent bypass)" {
  # This is the actual hazard the fix closes: before it, a missing _common.sh
  # did not just fail to check — it let a CGW_LOCAL_FILES violation through.
  _install_hook "pre-commit"
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  run git -C "${TEST_REPO_DIR}" commit -m "docs: leak CLAUDE.md"
  [ "${status}" -ne 0 ]
}

@test "pre-commit: guard is inert when CGW is present (normal commit succeeds)" {
  _install_hook "pre-commit"
  _install_cgw_tooling
  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add feature.txt"
  [ "${status}" -eq 0 ]
}

# ── pre-push ─────────────────────────────────────────────────────────────────

@test "pre-push: fails CLOSED when scripts/git/_common.sh is unreachable" {
  _install_hook "pre-push"
  local remote_dir="${TEST_TMPDIR}/bootstrap-remote.git"
  create_bare_remote "${remote_dir}"
  git -C "${TEST_REPO_DIR}" remote add origin "${remote_dir}"
  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"
  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR [pre-push]: CGW not found"* ]]
  # Regression proof: the ORIGINAL failure mode was a raw, unexplained
  # "unbound variable" error, not this clear message.
  [[ "${output}" != *"unbound variable"* ]]
}

@test "pre-push: guard is inert when CGW is present (normal push succeeds)" {
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout development
  _install_hook "pre-push"
  _install_cgw_tooling
  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"
  run git -C "${TEST_REPO_DIR}" push origin development
  [ "${status}" -eq 0 ]
}

# ── pre-rebase ───────────────────────────────────────────────────────────────

# Diverges feature/topic and development so `git rebase development` has real
# commits to replay — a rebase that's already "up to date" never invokes the
# pre-rebase hook at all, which would make these tests pass for the wrong reason.
_diverge_for_rebase() {
  git -C "${TEST_REPO_DIR}" checkout -b feature/topic
  echo "topic" > "${TEST_REPO_DIR}/topic.txt"
  git -C "${TEST_REPO_DIR}" add topic.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add topic.txt"
  git -C "${TEST_REPO_DIR}" checkout development
  echo "upstream" > "${TEST_REPO_DIR}/upstream.txt"
  git -C "${TEST_REPO_DIR}" add upstream.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add upstream.txt"
  git -C "${TEST_REPO_DIR}" checkout feature/topic
}

@test "pre-rebase: fails CLOSED when scripts/git/_common.sh is unreachable" {
  _install_hook "pre-rebase"
  _diverge_for_rebase
  run git -C "${TEST_REPO_DIR}" rebase development
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR [pre-rebase]: CGW not found"* ]]
  [[ "${output}" != *"unbound variable"* ]]
}

@test "pre-rebase: guard is inert when CGW is present (normal rebase succeeds)" {
  _install_hook "pre-rebase"
  _install_cgw_tooling
  _diverge_for_rebase
  run git -C "${TEST_REPO_DIR}" rebase development
  [ "${status}" -eq 0 ]
}
