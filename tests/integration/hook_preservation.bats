#!/usr/bin/env bats
# tests/integration/hook_preservation.bats
# Regression test: deployment/update must not wipe locally established hooks.

bats_require_minimum_version 1.5.0
load '../helpers/setup'

_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

setup() {
  create_temp_dir
}

teardown() {
  cleanup_temp_dir
}

@test "configure.sh does not overwrite locally established test gate in .githooks/pre-push" {
  PROJ_DIR="${TEST_TMPDIR}/proj"
  mkdir -p "${PROJ_DIR}/.githooks"
  git -C "${PROJ_DIR}" init --quiet
  git -C "${PROJ_DIR}" config user.email "test@example.com"
  git -C "${PROJ_DIR}" config user.name "Test User"
  echo "# proj" > "${PROJ_DIR}/README.md"
  git -C "${PROJ_DIR}" add README.md
  git -C "${PROJ_DIR}" commit --quiet -m "chore: initial commit"

  printf 'CGW_LOCAL_FILES=""\nCGW_LINT_CMD=""\nCGW_MARKDOWNLINT_CMD=""\nCGW_TYPECHECK_CMD=""\n' \
    > "${PROJ_DIR}/.cgw.conf"

  # Create an established local pre-push hook with a local test gate block
  cat << 'EOF' > "${PROJ_DIR}/.githooks/pre-push"
#!/usr/bin/env bash
# local custom hook
if [[ -x "${REPO_ROOT}/scripts/test/run_tests.sh" ]]; then
  "${REPO_ROOT}/scripts/test/run_tests.sh" || exit 1
fi
EOF
  chmod +x "${PROJ_DIR}/.githooks/pre-push"

  pushd "${PROJ_DIR}" >/dev/null
  run bash "${CGW_PROJECT_ROOT}/scripts/git/configure.sh" --template-dir "${CGW_PROJECT_ROOT}" --non-interactive
  popd >/dev/null

  [ "$status" -eq 0 ]
  # Assert that the locally established test gate block was NOT wiped
  grep -qF "scripts/test/run_tests.sh" "${PROJ_DIR}/.githooks/pre-push"
}

@test "cgw-batch-install.cmd does not overwrite locally established test gate in .githooks/pre-push" {
  _is_windows || skip "cmd.exe installer test only runs on Windows"
  command -v cmd >/dev/null 2>&1 || skip "cmd.exe not available"

  PROJ_DIR="${TEST_TMPDIR}/proj"
  mkdir -p "${PROJ_DIR}/.githooks"
  git -C "${PROJ_DIR}" init --quiet
  git -C "${PROJ_DIR}" config user.email "test@example.com"
  git -C "${PROJ_DIR}" config user.name "Test User"
  echo "# proj" > "${PROJ_DIR}/README.md"
  git -C "${PROJ_DIR}" add README.md
  git -C "${PROJ_DIR}" commit --quiet -m "chore: initial commit"

  printf 'CGW_LOCAL_FILES=""\nCGW_LINT_CMD=""\nCGW_MARKDOWNLINT_CMD=""\nCGW_TYPECHECK_CMD=""\n' \
    > "${PROJ_DIR}/.cgw.conf"

  cat << 'EOF' > "${PROJ_DIR}/.githooks/pre-push"
#!/usr/bin/env bash
# local custom hook
if [[ -x "${REPO_ROOT}/scripts/test/run_tests.sh" ]]; then
  "${REPO_ROOT}/scripts/test/run_tests.sh" || exit 1
fi
EOF
  chmod +x "${PROJ_DIR}/.githooks/pre-push"

  BATCH_CONF="${TEST_TMPDIR}/batch.conf"
  printf '%s\r\n' "$(cygpath -w "${PROJ_DIR}")" > "${BATCH_CONF}"

  run env -u NoDefaultCurrentDirectoryInExePath \
    cmd //c "$(cygpath -w "${CGW_PROJECT_ROOT}/cgw-batch-install.cmd")" \
    "$(cygpath -w "${BATCH_CONF}")" --no-pause

  [ "$status" -eq 0 ]
  grep -qF "scripts/test/run_tests.sh" "${PROJ_DIR}/.githooks/pre-push"
}

@test "configure.sh --overwrite-hooks backs up and replaces modified hook" {
  PROJ_DIR="${TEST_TMPDIR}/proj"
  mkdir -p "${PROJ_DIR}/.githooks"
  git -C "${PROJ_DIR}" init --quiet
  git -C "${PROJ_DIR}" config user.email "test@example.com"
  git -C "${PROJ_DIR}" config user.name "Test User"
  echo "# proj" > "${PROJ_DIR}/README.md"
  git -C "${PROJ_DIR}" add README.md
  git -C "${PROJ_DIR}" commit --quiet -m "chore: initial commit"

  printf 'CGW_LOCAL_FILES=""\nCGW_LINT_CMD=""\nCGW_MARKDOWNLINT_CMD=""\nCGW_TYPECHECK_CMD=""\n' \
    > "${PROJ_DIR}/.cgw.conf"

  cat << 'EOF' > "${PROJ_DIR}/.githooks/pre-push"
#!/usr/bin/env bash
# CUSTOM UNIQUE CONTENT
echo "custom unique hook"
EOF
  chmod +x "${PROJ_DIR}/.githooks/pre-push"

  pushd "${PROJ_DIR}" >/dev/null
  run bash "${CGW_PROJECT_ROOT}/scripts/git/configure.sh" --template-dir "${CGW_PROJECT_ROOT}" --non-interactive --overwrite-hooks
  popd >/dev/null

  [ "$status" -eq 0 ]
  # Backup must exist and contain the original custom content
  [ -f "${PROJ_DIR}/.githooks/pre-push.bak" ]
  grep -qF "CUSTOM UNIQUE CONTENT" "${PROJ_DIR}/.githooks/pre-push.bak"
  # Target must have been updated to upstream template
  grep -qF "cgw_validate_commit_message" "${PROJ_DIR}/.githooks/pre-push"
}

@test "hooks/pre-push natively executes scripts/test/run_tests.sh when present" {
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout development

  # Install CGW tooling and pre-push hook template
  mkdir -p "${TEST_REPO_DIR}/scripts/git" "${TEST_REPO_DIR}/scripts/test"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-push" "${TEST_REPO_DIR}/.git/hooks/pre-push"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-push"

  # Create run_tests.sh that creates a witness file
  cat << 'EOF' > "${TEST_REPO_DIR}/scripts/test/run_tests.sh"
#!/usr/bin/env bash
echo "TESTS_RUN" > "$(git rev-parse --show-toplevel)/test_marker.txt"
exit 0
EOF
  chmod +x "${TEST_REPO_DIR}/scripts/test/run_tests.sh"

  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "$status" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/test_marker.txt" ]
}

@test "hooks/pre-push fails push when scripts/test/run_tests.sh fails" {
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout development

  mkdir -p "${TEST_REPO_DIR}/scripts/git" "${TEST_REPO_DIR}/scripts/test"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-push" "${TEST_REPO_DIR}/.git/hooks/pre-push"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-push"

  cat << 'EOF' > "${TEST_REPO_DIR}/scripts/test/run_tests.sh"
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_REPO_DIR}/scripts/test/run_tests.sh"

  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "$status" -ne 0 ]
  [[ "$output" == *"local test gate failed"* ]]
}

@test "hooks/pre-push executes .githooks/pre-push.local when present" {
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout development

  mkdir -p "${TEST_REPO_DIR}/scripts/git" "${TEST_REPO_DIR}/.githooks"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-push" "${TEST_REPO_DIR}/.git/hooks/pre-push"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-push"

  cat << 'EOF' > "${TEST_REPO_DIR}/.githooks/pre-push.local"
#!/usr/bin/env bash
echo "LOCAL_HOOK_RUN" > "$(git rev-parse --show-toplevel)/local_marker.txt"
exit 0
EOF
  chmod +x "${TEST_REPO_DIR}/.githooks/pre-push.local"

  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "$status" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/local_marker.txt" ]
}

@test "hooks/pre-commit executes .githooks/pre-commit.local when present" {
  create_test_repo
  mkdir -p "${TEST_REPO_DIR}/scripts/git" "${TEST_REPO_DIR}/.githooks"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-commit" "${TEST_REPO_DIR}/.git/hooks/pre-commit"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-commit"

  cat << 'EOF' > "${TEST_REPO_DIR}/.githooks/pre-commit.local"
#!/usr/bin/env bash
echo "PRE_COMMIT_LOCAL_RUN" > "$(git rev-parse --show-toplevel)/local_pc_marker.txt"
exit 0
EOF
  chmod +x "${TEST_REPO_DIR}/.githooks/pre-commit.local"

  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  run git -C "${TEST_REPO_DIR}" commit -m "feat: add feature.txt"
  [ "$status" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/local_pc_marker.txt" ]
}

@test "hooks/pre-rebase executes .githooks/pre-rebase.local when present" {
  create_test_repo
  mkdir -p "${TEST_REPO_DIR}/scripts/git" "${TEST_REPO_DIR}/.githooks"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-rebase" "${TEST_REPO_DIR}/.git/hooks/pre-rebase"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-rebase"

  cat << 'EOF' > "${TEST_REPO_DIR}/.githooks/pre-rebase.local"
#!/usr/bin/env bash
echo "PRE_REBASE_LOCAL_RUN" > "$(git rev-parse --show-toplevel)/local_pr_marker.txt"
exit 0
EOF
  chmod +x "${TEST_REPO_DIR}/.githooks/pre-rebase.local"

  git -C "${TEST_REPO_DIR}" checkout -b feature/test
  echo "topic" > "${TEST_REPO_DIR}/topic.txt"
  git -C "${TEST_REPO_DIR}" add topic.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: topic"
  git -C "${TEST_REPO_DIR}" checkout development
  echo "upstream" > "${TEST_REPO_DIR}/upstream.txt"
  git -C "${TEST_REPO_DIR}" add upstream.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: upstream"
  git -C "${TEST_REPO_DIR}" checkout feature/test

  run git -C "${TEST_REPO_DIR}" rebase development
  [ "$status" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/local_pr_marker.txt" ]
}

# ── code-review follow-ups: configure env policy, stale-hook warning ──────────

_make_hook_project() {
  PROJ_DIR="${TEST_TMPDIR}/proj"
  mkdir -p "${PROJ_DIR}/.githooks"
  git -C "${PROJ_DIR}" init --quiet
  git -C "${PROJ_DIR}" config user.email "test@example.com"
  git -C "${PROJ_DIR}" config user.name "Test User"
  echo "# proj" > "${PROJ_DIR}/README.md"
  git -C "${PROJ_DIR}" add README.md
  git -C "${PROJ_DIR}" commit --quiet -m "chore: initial commit"
  printf 'CGW_LOCAL_FILES=""\nCGW_LINT_CMD=""\nCGW_MARKDOWNLINT_CMD=""\nCGW_TYPECHECK_CMD=""\n' \
    > "${PROJ_DIR}/.cgw.conf"
  cat << 'EOF' > "${PROJ_DIR}/.githooks/pre-push"
#!/usr/bin/env bash
# CUSTOM UNIQUE CONTENT
echo "custom unique hook"
EOF
  chmod +x "${PROJ_DIR}/.githooks/pre-push"
}

@test "configure.sh with CGW_NON_INTERACTIVE=1 (no flag) keeps a differing hook instead of aborting" {
  _make_hook_project

  pushd "${PROJ_DIR}" >/dev/null
  run env CGW_NON_INTERACTIVE=1 bash "${CGW_PROJECT_ROOT}/scripts/git/configure.sh" \
    --template-dir "${CGW_PROJECT_ROOT}" --skip-cc-guardrail --skip-agy-guardrail </dev/null
  popd >/dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"requires confirmation"* ]]
  grep -qF "CUSTOM UNIQUE CONTENT" "${PROJ_DIR}/.githooks/pre-push"
}

@test "configure.sh warns that a preserved hook differs from the template" {
  _make_hook_project

  pushd "${PROJ_DIR}" >/dev/null
  run bash "${CGW_PROJECT_ROOT}/scripts/git/configure.sh" --template-dir "${CGW_PROJECT_ROOT}" --non-interactive
  popd >/dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"Preserved locally established .githooks/pre-push"* ]]
  [[ "$output" == *"--overwrite-hooks"* ]]
  [[ "$output" == *"pre-push.local"* ]]
  grep -qF "CUSTOM UNIQUE CONTENT" "${PROJ_DIR}/.githooks/pre-push"
}

@test "configure.sh --overwrite-hooks never clobbers an existing .bak" {
  _make_hook_project
  echo "FIRST ORIGINAL" > "${PROJ_DIR}/.githooks/pre-push.bak"

  pushd "${PROJ_DIR}" >/dev/null
  run bash "${CGW_PROJECT_ROOT}/scripts/git/configure.sh" --template-dir "${CGW_PROJECT_ROOT}" --non-interactive --overwrite-hooks
  popd >/dev/null

  [ "$status" -eq 0 ]
  grep -qF "FIRST ORIGINAL" "${PROJ_DIR}/.githooks/pre-push.bak"
  local extra
  extra="$(ls "${PROJ_DIR}"/.githooks/pre-push.bak.* 2>/dev/null | head -1)"
  [ -n "${extra}" ]
  grep -qF "CUSTOM UNIQUE CONTENT" "${extra}"
}

@test "install_hooks.sh keeps the user's original .bak across a later update" {
  _make_hook_project
  cp "${CGW_PROJECT_ROOT}/hooks/pre-commit" "${PROJ_DIR}/.githooks/pre-commit"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-push" "${PROJ_DIR}/.githooks/pre-push"
  mkdir -p "${PROJ_DIR}/scripts"
  cp -r "${CGW_PROJECT_ROOT}/scripts/git" "${PROJ_DIR}/scripts/git"
  printf '#!/bin/sh\n# ORIGINAL USER HOOK\n' > "${PROJ_DIR}/.git/hooks/pre-commit"

  pushd "${PROJ_DIR}" >/dev/null
  run bash scripts/git/install_hooks.sh
  [ "$status" -eq 0 ]
  grep -qF "ORIGINAL USER HOOK" "${PROJ_DIR}/.git/hooks/pre-commit.bak"

  # A later update: the installed hook differs again from the source.
  printf '#!/bin/sh\n# SECOND COPY\n' > "${PROJ_DIR}/.git/hooks/pre-commit"
  run bash scripts/git/install_hooks.sh
  popd >/dev/null

  [ "$status" -eq 0 ]
  grep -qF "ORIGINAL USER HOOK" "${PROJ_DIR}/.git/hooks/pre-commit.bak"
  local extra
  extra="$(ls "${PROJ_DIR}"/.git/hooks/pre-commit.bak.* 2>/dev/null | head -1)"
  [ -n "${extra}" ]
  grep -qF "SECOND COPY" "${extra}"
}

# ── pre-push local test gate scope ────────────────────────────────────────────

_gate_repo() {
  create_test_repo_with_remote
  git -C "${TEST_REPO_DIR}" checkout development
  mkdir -p "${TEST_REPO_DIR}/scripts/git" "${TEST_REPO_DIR}/scripts/test"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_common.sh" "${TEST_REPO_DIR}/scripts/git/_common.sh"
  cp "${CGW_PROJECT_ROOT}/scripts/git/_config.sh" "${TEST_REPO_DIR}/scripts/git/_config.sh"
  cp "${CGW_PROJECT_ROOT}/hooks/pre-push" "${TEST_REPO_DIR}/.git/hooks/pre-push"
  chmod +x "${TEST_REPO_DIR}/.git/hooks/pre-push"
  cat << 'EOF' > "${TEST_REPO_DIR}/scripts/test/run_tests.sh"
#!/usr/bin/env bash
echo "TESTS_RUN" > "$(git rev-parse --show-toplevel)/gate_marker.txt"
exit 1
EOF
  chmod +x "${TEST_REPO_DIR}/scripts/test/run_tests.sh"
}

@test "hooks/pre-push SKIP_TESTS=1 bypasses a failing test gate" {
  _gate_repo
  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"

  run env SKIP_TESTS=1 git -C "${TEST_REPO_DIR}" push origin development
  [ "$status" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/gate_marker.txt" ]
  [[ "$output" == *"SKIP_TESTS=1"* ]]
}

@test "hooks/pre-push does not run the test gate for a tag push" {
  _gate_repo
  git -C "${TEST_REPO_DIR}" tag v9.9.9

  run git -C "${TEST_REPO_DIR}" push origin v9.9.9
  [ "$status" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/gate_marker.txt" ]
}

@test "hooks/pre-push does not run the test gate for a branch deletion" {
  _gate_repo
  git -C "${TEST_REPO_DIR}" branch old-branch
  git -C "${TEST_REPO_DIR}" push --no-verify origin old-branch

  run git -C "${TEST_REPO_DIR}" push origin --delete old-branch
  [ "$status" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/gate_marker.txt" ]
}

@test "hooks/pre-push still runs the test gate for a branch update" {
  _gate_repo
  echo "content" > "${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --no-verify -m "feat: add feature.txt"

  run git -C "${TEST_REPO_DIR}" push origin development
  [ "$status" -ne 0 ]
  [ -f "${TEST_REPO_DIR}/gate_marker.txt" ]
}
