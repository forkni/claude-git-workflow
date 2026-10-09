#!/usr/bin/env bats
# tests/integration/rebase_safe.bats - Integration tests for rebase_safe.sh
# Runs: bats tests/integration/rebase_safe.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  # Ensure development has commits not on main, and main has no divergence
  git -C "${TEST_REPO_DIR}" checkout --quiet main
}

teardown() {
  cleanup_test_repo
}

# ── validation ────────────────────────────────────────────────────────────────

@test "no operation flag exits 1 with helpful message" {
  run run_script rebase_safe.sh --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--onto"* ]] || [[ "${output}" == *"Specify"* ]]
}

@test "--onto and --squash-last together exits 1" {
  run run_script rebase_safe.sh --onto main --squash-last 2 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not both"* ]] || [[ "${output}" == *"either"* ]]
}

@test "--abort when no rebase in progress exits 0 with informational message" {
  run run_script rebase_safe.sh --abort
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No rebase"* ]] || [[ "${output}" == *"not in progress"* ]] || [[ "${output}" == *"in progress"* ]]
}

# ── --onto ────────────────────────────────────────────────────────────────────

@test "--onto main when development is already up to date exits 0" {
  # Create a fresh repo where development == main (no extra commits on development)
  local already_repo="${TEST_TMPDIR}/aligned"
  mkdir -p "${already_repo}"
  git -C "${already_repo}" init --quiet
  git -C "${already_repo}" config user.email "test@example.com"
  git -C "${already_repo}" config user.name "Test User"
  git -C "${already_repo}" config core.autocrlf false
  echo "x" > "${already_repo}/x.txt"
  git -C "${already_repo}" add x.txt
  git -C "${already_repo}" commit --quiet -m "chore: init"
  git -C "${already_repo}" checkout --quiet -b main 2>/dev/null || \
    git -C "${already_repo}" branch -m main 2>/dev/null || true
  git -C "${already_repo}" checkout --quiet -b development
  # development has no extra commits beyond main, so rebase is a no-op
  run bash -c "
    cd '${already_repo}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${already_repo}'
    bash '${CGW_PROJECT_ROOT}/scripts/git/rebase_safe.sh' --onto main --non-interactive
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"up to date"* ]] || [[ "${output}" == *"nothing to rebase"* ]]
}

@test "--onto main rebases development commits and creates backup tag" {
  # development has one extra commit over main (from create_test_repo)
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 0 ]

  # Backup tag created
  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-rebase-"
}

@test "--dry-run --onto main shows plan without rebasing" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rebase_safe.sh --onto main --dry-run --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"Would run"* ]]

  # HEAD unchanged
  local head_after
  head_after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${head_before}" = "${head_after}" ]
}

@test "dirty tree without --autostash exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  echo "dirty" >> "${TEST_REPO_DIR}/DEV.md"

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"dirty"* ]] || [[ "${output}" == *"uncommitted"* ]] || [[ "${output}" == *"stash"* ]]
}

@test "invalid --onto ref exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script rebase_safe.sh --onto nonexistent-branch-xyz --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid"* ]] || [[ "${output}" == *"invalid"* ]]
}

# ── Conflict resolution: categorised display ─────────────────────────────────

@test "--autostash stashes dirty changes and restores after successful rebase" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Create a tracked-file modification (diff-index detects this as dirty).
  echo "wip content" >> "${TEST_REPO_DIR}/DEV.md"

  run run_script rebase_safe.sh --onto main --autostash --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"REBASE COMPLETE"* ]] || [[ "${output}" == *"complete"* ]]

  # Stash should have been popped -- dirty content restored.
  grep -q "wip content" "${TEST_REPO_DIR}/DEV.md"

  # Backup tag created.
  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-rebase-"
}

@test "--onto with UU conflict displays categorised conflict summary" {
  # Both main and development independently modify the same line
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'original\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync conflict.txt"
  printf 'dev version\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev modifies conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout main
  printf 'main version\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: main modifies conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"(both modified)"* ]]
}

# ── Regression: the printed restore command must actually restore the branch ──
# rebase_safe.sh used to print "To restore: git checkout <tag>", which only
# detaches HEAD at the tag and leaves the rebased branch untouched. Running the
# advertised command verbatim must put the branch itself back on the backup.

@test "--onto prints a restore command that resets the branch to the backup tag" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse development)

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 0 ]

  local restore_cmd
  restore_cmd=$(printf '%s\n' "${output}" | sed -n 's/^ *To restore: //p' | head -1)
  [ -n "${restore_cmd}" ]
  [[ "${restore_cmd}" == git\ * ]]
  (cd "${TEST_REPO_DIR}" && eval "${restore_cmd}")

  [ "$(git -C "${TEST_REPO_DIR}" symbolic-ref --short HEAD)" = "development" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse development)" = "${before}" ]
}

# ── Pushed-commit detection ──────────────────────────────────────────────────
# The "already pushed" warning must count the commits being rewritten that are
# reachable from the remote -- not the commits the remote lacks (the inverse).

_add_remote() {
  local remote="${TEST_TMPDIR}/remote.git"
  create_bare_remote "${remote}"
  git -C "${TEST_REPO_DIR}" remote add origin "${remote}"
}

_commit_on() {
  # _commit_on <branch> <file> -- one commit adding <file> on <branch>
  git -C "${TEST_REPO_DIR}" checkout --quiet "$1"
  echo "$2" > "${TEST_REPO_DIR}/$2"
  git -C "${TEST_REPO_DIR}" add "$2"
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: add $2"
}

@test "--onto: a branch never pushed does not trigger the pushed-commits warning" {
  _add_remote
  _commit_on main main-extra.txt
  git -C "${TEST_REPO_DIR}" push --quiet origin main
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"already been pushed"* ]]
  [[ "${output}" == *"REBASE COMPLETE"* ]]
}

@test "--onto: commits already on the remote trigger the warning and abort non-interactively" {
  _add_remote
  _commit_on main main-extra.txt
  git -C "${TEST_REPO_DIR}" push --quiet origin main
  # development is fully pushed (in sync with origin/development): the old
  # "remote..HEAD" count was 0 here, so the warning never fired.
  git -C "${TEST_REPO_DIR}" push --quiet origin development
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rebase_safe.sh --onto main --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"1 commit(s) on this branch have already been pushed"* ]]
  [[ "${output}" == *"requires confirmation"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "--onto: pushed count excludes local-only commits" {
  _add_remote
  _commit_on main main-extra.txt
  git -C "${TEST_REPO_DIR}" push --quiet origin main
  _commit_on development pushed-2.txt
  git -C "${TEST_REPO_DIR}" push --quiet origin development
  _commit_on development local-only.txt

  run run_script rebase_safe.sh --onto main --non-interactive
  # 3 commits would be rewritten, 2 of them (fixture + pushed-2) are on origin
  [[ "${output}" == *"2 commit(s) on this branch have already been pushed"* ]]
}

@test "--squash-last: pushed count covers only the squashed range" {
  _add_remote
  _commit_on development pushed-2.txt
  git -C "${TEST_REPO_DIR}" push --quiet origin development
  _commit_on development local-only.txt

  run run_script rebase_safe.sh --squash-last 3 --non-interactive
  # last 3 = fixture commit + pushed-2 (both on origin) + local-only
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"2 commit(s) on this branch have already been pushed"* ]]
  [[ "${output}" == *"requires confirmation"* ]]
}

# ── 3-argument --onto (--upstream) ───────────────────────────────────────────

_make_server_client() {
  # main -- server (S1) -- client (C1, C2); then main moves on (M1)
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" checkout --quiet -b server
  _commit_on server server.txt
  git -C "${TEST_REPO_DIR}" checkout --quiet -b client
  _commit_on client client1.txt
  _commit_on client client2.txt
  _commit_on main main-moved.txt
  git -C "${TEST_REPO_DIR}" checkout --quiet client
}

@test "--onto <new> --upstream <old> replays only <old>..HEAD (git rebase --onto 3-arg form)" {
  _make_server_client

  run run_script rebase_safe.sh --onto main --upstream server --non-interactive
  [ "${status}" -eq 0 ]

  run git -C "${TEST_REPO_DIR}" ls-files
  grep -q '^client1.txt$' <<< "${output}"
  grep -q '^client2.txt$' <<< "${output}"
  grep -q '^main-moved.txt$' <<< "${output}"
  # server's own commit was NOT carried over
  run ! grep -q '^server.txt$' <<< "${output}"
}

@test "--onto --upstream --dry-run prints the 3-argument command and changes nothing" {
  _make_server_client
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rebase_safe.sh --onto main --upstream server --dry-run --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"git rebase --onto main server"* ]]
  [[ "${output}" == *"Commits to rebase: 2"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "--upstream without --onto exits 1" {
  run run_script rebase_safe.sh --squash-last 2 --upstream main --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--upstream only applies"* ]]
}

@test "--upstream with an unknown ref exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  run run_script rebase_safe.sh --onto main --upstream no-such-ref --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid --upstream ref"* ]]
}
