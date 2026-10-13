#!/usr/bin/env bats
# tests/integration/sync_cgw_tooling.bats - Integration tests for sync_cgw_tooling.sh
# Verifies: (a) a dirty tree is refused and nothing changes, (b) a clean tree gets exactly
#           one "chore: sync CGW git tooling" commit and stays clean, (c) a second run is a
#           no-op, (d) --extra-skill-dst / --extra-cmd-dst copy the forked skill files,
#           (e) the source must be a CGW checkout.
# Runs: bats tests/integration/sync_cgw_tooling.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # The synced scripts are copied from here, and the sync script itself runs from the
  # real scripts/git; the project only needs a place to receive the copies.
  FAKE_SRC="${TEST_TMPDIR}/cgw-src"
  mkdir -p "${FAKE_SRC}/scripts/git" "${FAKE_SRC}/skill/references" "${FAKE_SRC}/hooks" "${FAKE_SRC}/command"
  printf '# stub\n' >"${FAKE_SRC}/scripts/git/_common.sh"
  printf '#!/usr/bin/env bash\necho new\n' >"${FAKE_SRC}/scripts/git/newtool.sh"
  printf '# skill\n' >"${FAKE_SRC}/skill/SKILL.md"
  printf '# ref\n' >"${FAKE_SRC}/skill/references/r.md"
  printf '# Cmd\n\n[skill](../skills/auto-git-workflow/SKILL.md) and `.claude/skills/auto-git-workflow/`\n' \
    >"${FAKE_SRC}/command/auto-git-workflow-cmd.md"
  local h
  for h in pre-commit pre-push pre-rebase; do
    printf '#!/bin/sh\nexit 0\n' >"${FAKE_SRC}/hooks/${h}"
  done
  git -C "${FAKE_SRC}" init --quiet -b main
  git -C "${FAKE_SRC}" config user.email "test@example.com"
  git -C "${FAKE_SRC}" config user.name "Test User"
  git -C "${FAKE_SRC}" add -A
  git -C "${FAKE_SRC}" commit --quiet -m "chore: src"
}

teardown() {
  cleanup_test_repo
}

@test "dirty tree is refused, names the dirty path and changes nothing" {
  echo "wip" >"${TEST_REPO_DIR}/app.py"
  head_before="$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)"
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"app.py"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
  [ ! -f "${TEST_REPO_DIR}/scripts/git/newtool.sh" ]
}

@test "clean tree gets exactly one sync commit and stays clean" {
  count_before="$(git -C "${TEST_REPO_DIR}" rev-list --count HEAD)"
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull \
    --extra-skill-dst skills/auto-git-workflow \
    --extra-cmd-dst skills/auto-git-workflow-cmd/SKILL.md
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-list --count HEAD)" -eq $((count_before + 1)) ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "chore: sync CGW git tooling" ]
  [[ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%b)" == *"Syncs upstream"* ]]
  files="$(git -C "${TEST_REPO_DIR}" show --name-only --format= HEAD)"
  [[ "${files}" == *"scripts/git/newtool.sh"* ]]
  [[ "${files}" == *"skills/auto-git-workflow/SKILL.md"* ]]
  [[ "${files}" == *"skills/auto-git-workflow/references/r.md"* ]]
  [[ "${files}" == *"skills/auto-git-workflow-cmd/SKILL.md"* ]]
  # configure.sh must not leave anything uncommitted behind.
  [ -z "$(git -C "${TEST_REPO_DIR}" status --porcelain --untracked-files=all | grep -v ' logs/')" ]
}

@test "--extra-cmd-dst adapts the command skill's links to the skills layout" {
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull \
    --extra-cmd-dst skills/auto-git-workflow-cmd/SKILL.md
  [ "${status}" -eq 0 ]
  text="$(cat "${TEST_REPO_DIR}/skills/auto-git-workflow-cmd/SKILL.md")"
  [[ "${text}" == *"(../auto-git-workflow/SKILL.md)"* ]]
  [[ "${text}" == *'`auto-git-workflow/`'* ]]
  [[ "${text}" != *"../skills/"* ]]
  [[ "${text}" != *".claude/skills/"* ]]
}

@test "--extra-cmd-dst needs a command template in the source" {
  rm "${FAKE_SRC}/command/auto-git-workflow-cmd.md"
  git -C "${FAKE_SRC}" add -A
  git -C "${FAKE_SRC}" commit --quiet -m "chore: drop cmd"
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull --extra-cmd-dst x/SKILL.md
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no command/auto-git-workflow-cmd.md"* ]]
}

@test "a second run is a no-op" {
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull
  [ "${status}" -eq 0 ]
  count_before="$(git -C "${TEST_REPO_DIR}" rev-list --count HEAD)"
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already up to date"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-list --count HEAD)" -eq "${count_before}" ]
}

@test "the source must be a CGW checkout and must be given" {
  run run_script sync_cgw_tooling.sh --from "${TEST_TMPDIR}" --no-pull
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a claude-git-workflow checkout"* ]]
  run env -u CGW_TEMPLATE_DIR bash -c "cd '${TEST_REPO_DIR}' && SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git' PROJECT_ROOT='${TEST_REPO_DIR}' bash '${CGW_PROJECT_ROOT}/scripts/git/sync_cgw_tooling.sh' --no-pull"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"No CGW source"* ]]
}

@test "sync replaces its own, running copy and still finishes and commits" {
  # The project's copy is the one executing. The source's version is longer and different, so a
  # bash that resumed reading at a stale offset would execute garbage or stop early.
  mkdir -p "${TEST_REPO_DIR}/scripts/git"
  cp "${CGW_PROJECT_ROOT}"/scripts/git/*.sh "${TEST_REPO_DIR}/scripts/git/"
  git -C "${TEST_REPO_DIR}" add -f scripts/git
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "chore: vendor scripts"
  cp "${CGW_PROJECT_ROOT}"/scripts/git/*.sh "${FAKE_SRC}/scripts/git/"
  # Padding goes right after the shebang so every later byte offset shifts.
  { head -n 1 "${CGW_PROJECT_ROOT}/scripts/git/sync_cgw_tooling.sh"
    for i in $(seq 1 7); do echo "# padding line ${i} so the new copy is longer and its offsets shift"; done
    tail -n +2 "${CGW_PROJECT_ROOT}/scripts/git/sync_cgw_tooling.sh"; } >"${FAKE_SRC}/scripts/git/sync_cgw_tooling.sh"
  git -C "${FAKE_SRC}" add -A
  git -C "${FAKE_SRC}" commit --quiet -m "chore: newer sync script"
  run bash -c "cd '${TEST_REPO_DIR}' && PROJECT_ROOT='${TEST_REPO_DIR}' bash scripts/git/sync_cgw_tooling.sh --from '${FAKE_SRC}' --no-pull"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CGW tooling synced"* ]]
  cmp "${FAKE_SRC}/scripts/git/sync_cgw_tooling.sh" "${TEST_REPO_DIR}/scripts/git/sync_cgw_tooling.sh"
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "chore: sync CGW git tooling" ]
  [[ "$(git -C "${TEST_REPO_DIR}" show --name-only --format= HEAD)" == *"scripts/git/sync_cgw_tooling.sh"* ]]
}

# ── --check: read-only drift report over the tracked copies ─────────────────────

_seed_copies() {
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull \
    --extra-skill-dst skills/auto-git-workflow \
    --extra-cmd-dst skills/auto-git-workflow-cmd/SKILL.md
  [ "${status}" -eq 0 ]
}

@test "--check passes on freshly synced copies and needs no CGW source" {
  _seed_copies
  run env -u CGW_TEMPLATE_DIR bash -c "cd '${TEST_REPO_DIR}' && SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git' PROJECT_ROOT='${TEST_REPO_DIR}' bash '${CGW_PROJECT_ROOT}/scripts/git/sync_cgw_tooling.sh' --check"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"in sync"* ]]
}

@test "--check discovers a tracked copy that no flag named, and exits 1 on drift" {
  _seed_copies
  printf '# hand edit\n' >>"${TEST_REPO_DIR}/skills/auto-git-workflow/references/r.md"
  git -C "${TEST_REPO_DIR}" add skills/auto-git-workflow/references/r.md
  head_before="$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)"
  run run_script sync_cgw_tooling.sh --check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"skills/auto-git-workflow/references/r.md"* ]]
  # Read-only: nothing committed, nothing rewritten.
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
  grep -q 'hand edit' "${TEST_REPO_DIR}/skills/auto-git-workflow/references/r.md"
}

@test "--check treats a skill-layout and a file-layout command copy as the same text" {
  _seed_copies
  mkdir -p "${TEST_REPO_DIR}/.claude/commands"
  cp "${FAKE_SRC}/command/auto-git-workflow-cmd.md" "${TEST_REPO_DIR}/.claude/commands/auto-git-workflow-cmd.md"
  git -C "${TEST_REPO_DIR}" add -f .claude/commands/auto-git-workflow-cmd.md
  run run_script sync_cgw_tooling.sh --check
  [ "${status}" -eq 0 ]
}

@test "--check --from also reports a copy that is stale against the source" {
  _seed_copies
  printf '# skill v2\n' >"${FAKE_SRC}/skill/SKILL.md"
  run run_script sync_cgw_tooling.sh --check --from "${FAKE_SRC}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"skills/auto-git-workflow/SKILL.md"* ]]
  # Without --from the copies still agree with each other.
  run run_script sync_cgw_tooling.sh --check
  [ "${status}" -eq 0 ]
}

@test "sync refreshes a tracked copy found by discovery, without any flag" {
  _seed_copies
  printf '# skill v2\n' >"${FAKE_SRC}/skill/SKILL.md"
  git -C "${FAKE_SRC}" add -A
  git -C "${FAKE_SRC}" commit --quiet -m "chore: v2"
  run run_script sync_cgw_tooling.sh --from "${FAKE_SRC}" --no-pull
  [ "${status}" -eq 0 ]
  [ "$(cat "${TEST_REPO_DIR}/skills/auto-git-workflow/SKILL.md")" = "# skill v2" ]
  run run_script sync_cgw_tooling.sh --check --from "${FAKE_SRC}"
  [ "${status}" -eq 0 ]
}
