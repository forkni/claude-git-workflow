#!/usr/bin/env bats
# tests/integration/commit_enhanced_modes.bats - Integration tests for commit_enhanced.sh (merge conclusion, interactive prompts, index.lock, --only reset, untracked warnings)
# Runs: bats tests/integration/commit_enhanced_modes.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

# Helper: run commit_enhanced.sh with shared env vars
_run_commit() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' $*
  "
}

# Helper: leave TEST_REPO_DIR mid-merge with a genuine UU conflict on
# conflict.txt (development merging main), mirroring the pattern in
# merge_validation.bats. MERGE_HEAD is present and conflict.txt still has
# markers when this returns -- the caller resolves and `git add`s it.
_setup_uu_conflict() {
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  printf 'line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout --quiet development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync conflict.txt"
  printf 'dev-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev edits line1"

  git -C "${TEST_REPO_DIR}" checkout --quiet main
  printf 'main-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: main edits line1"

  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # No -m here: leave git to prepare its own default MERGE_MSG (with the
  # "# Conflicts:" comment block) so the no-message tests exercise the real
  # git-provided message, not a custom one.
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff || true
}

# ── Merge conclusion (git's prepared MERGE_MSG) ──────────────────────────────
# When MERGE_HEAD is present, the message argument is optional: with none,
# commit_enhanced.sh uses git's prepared MERGE_MSG (comments stripped) instead
# of demanding a conventional-format message. See merge_with_validation.sh's
# continue_hint and skill/SKILL.md Rule 1.

@test "merge conclusion with no message uses git's prepared MERGE_MSG" {
  _setup_uu_conflict
  printf 'resolved-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt

  run _run_commit ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]

  # HEAD is a real 2-parent merge commit.
  local parents
  parents="$(git -C "${TEST_REPO_DIR}" rev-list --parents -n1 HEAD)"
  [ "$(echo "${parents}" | wc -w)" -eq 3 ]

  # MERGE_HEAD is cleared.
  run git -C "${TEST_REPO_DIR}" rev-parse -q --verify MERGE_HEAD
  [ "${status}" -ne 0 ]

  # Subject came from git's prepared message, no leftover comment lines.
  local subject body
  subject="$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)"
  body="$(git -C "${TEST_REPO_DIR}" log -1 --format=%B)"
  [[ "${subject}" == Merge* ]]
  [[ "${body}" != *"# Conflicts"* ]]
}

@test "merge conclusion accepts an explicit non-conventional message" {
  _setup_uu_conflict
  printf 'resolved-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt

  run _run_commit "\"Merge main into development\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]

  local parents
  parents="$(git -C "${TEST_REPO_DIR}" rev-list --parents -n1 HEAD)"
  [ "$(echo "${parents}" | wc -w)" -eq 3 ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "Merge main into development" ]
}

@test "merge conclusion accepts an explicit conventional message" {
  _setup_uu_conflict
  printf 'resolved-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt

  run _run_commit "\"chore: merge main into development\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "chore: merge main into development" ]
}

@test "merge conclusion with resolved tree identical to HEAD still commits (allow-empty + MERGE_MSG)" {
  _setup_uu_conflict
  # Resolve toward development's own side -- staged tree ends up byte-identical
  # to development's pre-merge HEAD.
  printf 'dev-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt

  run _run_commit ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]

  local parents
  parents="$(git -C "${TEST_REPO_DIR}" rev-list --parents -n1 HEAD)"
  [ "$(echo "${parents}" | wc -w)" -eq 3 ]
  run git -C "${TEST_REPO_DIR}" rev-parse -q --verify MERGE_HEAD
  [ "${status}" -ne 0 ]
}

@test "non-merge commit with no message is still rejected (regression)" {
  echo "content" > "${TEST_REPO_DIR}/no_message_regress.txt"
  git -C "${TEST_REPO_DIR}" add no_message_regress.txt
  run _run_commit ""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Commit message required"* ]]
}

# ── Regression: interactive "yes" to lint auto-fix must re-check ─────────────
# The non-interactive lint path and both markdown paths re-run the check after
# auto-fix and abort if errors remain. The interactive lint "yes" branch used
# to re-stage and fall straight through to the commit, so a fixer that could
# not fix everything still produced a commit. --interactive drives the prompts
# from piped answers (commit_enhanced.sh would otherwise go non-interactive
# without a TTY).

@test "interactive lint auto-fix aborts when errors remain after the fix" {
  install_mock_lint_with_errors
  printf 'x = 1\n' > "${TEST_REPO_DIR}/unfixable.py"
  git -C "${TEST_REPO_DIR}" add unfixable.py
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_SKIP_MD_LINT=1
    unset CGW_NON_INTERACTIVE
    printf 'yes\nyes\nyes\nyes\n' | bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --interactive --no-venv 'feat: unfixable lint'
  "
  [[ "${output}" == *"Code quality errors remain after auto-fix"* ]]
  [[ "${output}" != *"COMMIT SUCCESSFUL"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

# ── Interactive auto-fix branches (characterization) ─────────────────────────
# Pins every interactive answer on both auto-fix prompts before the four
# fix -> re-stage -> re-check copies in main() are consolidated.

# _run_commit_interactive <answers> <message> [KEY=VALUE ...]
#   Runs commit_enhanced.sh --interactive, feeding <answers> (printf format) to
#   its prompts on stdin. (A pty via script(1) was flaky on CI: some script(1)
#   builds hang up the child once piped input hits EOF.) Lint/format/markdown default to
#   off; pass KEY=VALUE pairs to enable what the test needs.
_run_commit_interactive() {
  local answers="$1" msg="$2"
  shift 2
  local exports="" kv
  for kv in "$@"; do exports+="export ${kv}; "; done
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD='' CGW_FORMAT_CMD='' CGW_MARKDOWNLINT_CMD=''
    unset CGW_NON_INTERACTIVE
    ${exports}
    printf '${answers}' | bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --interactive --no-venv '${msg}'
  "
}

@test "interactive lint auto-fix 'yes' commits when the fix clears the errors" {
  install_mock_lint_fixable
  printf 'x = 1\n' > "${TEST_REPO_DIR}/fixable.py"
  git -C "${TEST_REPO_DIR}" add fixable.py
  run _run_commit_interactive 'yes\nyes\nyes\n' 'feat: fixable lint' CGW_LINT_CMD=ruff
  [[ "${output}" == *"Code quality errors detected"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "feat: fixable lint" ]
}

@test "interactive lint auto-fix 'skip' commits with a warning" {
  install_mock_lint_with_errors
  printf 'x = 1\n' > "${TEST_REPO_DIR}/skipped.py"
  git -C "${TEST_REPO_DIR}" add skipped.py
  run _run_commit_interactive 'skip\nyes\nyes\n' 'feat: skip lint' CGW_LINT_CMD=ruff
  [[ "${output}" == *"Proceeding with code quality warnings"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

@test "interactive lint auto-fix 'no' cancels the commit" {
  install_mock_lint_with_errors
  printf 'x = 1\n' > "${TEST_REPO_DIR}/declined.py"
  git -C "${TEST_REPO_DIR}" add declined.py
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  run _run_commit_interactive 'no\n' 'feat: declined lint' CGW_LINT_CMD=ruff
  [[ "${output}" == *"Commit cancelled -- fix code quality errors first"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "interactive markdown auto-fix 'yes' aborts when errors remain after the fix" {
  MOCK_MDLINT_EXIT=1 install_mock_markdownlint
  echo "content" > "${TEST_REPO_DIR}/unfixable.md"
  git -C "${TEST_REPO_DIR}" add unfixable.md
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  run _run_commit_interactive 'yes\nyes\nyes\n' 'docs: unfixable md' CGW_MARKDOWNLINT_CMD=markdownlint-cli2
  [[ "${output}" == *"Markdown lint errors remain after auto-fix"* ]]
  [[ "${output}" != *"COMMIT SUCCESSFUL"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "interactive markdown auto-fix 'skip' commits with a warning" {
  MOCK_MDLINT_EXIT=1 install_mock_markdownlint
  echo "content" > "${TEST_REPO_DIR}/skipped.md"
  git -C "${TEST_REPO_DIR}" add skipped.md
  run _run_commit_interactive 'skip\nyes\nyes\n' 'docs: skip md' CGW_MARKDOWNLINT_CMD=markdownlint-cli2
  [[ "${output}" == *"Proceeding with markdown lint warnings"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
}

# ── Staging-mode decision (pure function, truth table) ──────────────────────

@test "_effective_staged_only truth table" {
  local fn
  fn="$(extract_shell_function "${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh" _effective_staged_only)"
  # staged_only all_flag has_staged has_unstaged -> expected
  local row expected got
  while read -r row expected; do
    got="$(bash -c "${fn}"$'\n'"_effective_staged_only ${row//_/ }")"
    [ "${got}" = "${expected}" ] || { echo "(${row}) -> ${got}, expected ${expected}"; false; }
  done <<'TABLE'
1_0_0_0 1
1_1_1_1 1
0_1_1_1 0
0_1_0_0 0
0_0_1_1 auto
0_0_1_0 0
0_0_0_1 0
0_0_0_0 0
TABLE
}

# ── Regression: --interactive also makes cgw_confirm prompt ────────────────
# Without a TTY, commit_enhanced.sh sets CGW_NON_INTERACTIVE=1. --interactive
# only reset the script's local flag, so its read -p prompts became
# interactive while every cgw_confirm (branch check, proceed, stage-all) kept
# auto-accepting under the non-interactive policy.

@test "--interactive without a TTY makes the branch confirmation prompt too" {
  echo "content" > "${TEST_REPO_DIR}/declined_branch.txt"
  git -C "${TEST_REPO_DIR}" add declined_branch.txt
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD='' CGW_FORMAT_CMD='' CGW_MARKDOWNLINT_CMD=''
    unset CGW_NON_INTERACTIVE
    printf 'no\n' | bash '${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh' --interactive --no-venv 'feat: declined at branch check'
  "
  [[ "${output}" != *"COMMIT SUCCESSFUL"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

# ── Configured prefixes formatting (Obs 1) ────────────────────────────────────

@test "commit_enhanced.sh formats all configured commit prefixes with commas (Obs 1)" {
  echo "change" >> "${TEST_REPO_DIR}/README.md"
  git -C "${TEST_REPO_DIR}" add README.md
  run _run_commit "\"invalid_prefix: some change\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"feat, fix, docs, chore, test, refactor, style, perf"* ]]
  [[ "${output}" != *"fix|docs"* ]]
}

# ── Local-only files excluded exit 0 (Obs 2) ─────────────────────────────────

@test "commit_enhanced.sh exits 0 when all changes are excluded local-only files (Obs 2)" {
  echo "# Claude" > "${TEST_REPO_DIR}/CLAUDE.md"
  git -C "${TEST_REPO_DIR}" add CLAUDE.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: track CLAUDE.md"

  echo "modified" >> "${TEST_REPO_DIR}/CLAUDE.md"
  run _run_commit "\"feat: try to commit local only\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tracked changes were in local-only files and were excluded"* ]]
}

# ── Transient index.lock collision resilience ─────────────────────────────────

@test "commit_enhanced.sh waits for a fresh index.lock to clear and then commits" {
  echo "content" > "${TEST_REPO_DIR}/retry_test.txt"
  git -C "${TEST_REPO_DIR}" add retry_test.txt

  # The lock exists BEFORE the script starts, so the wait path must run: a lock created
  # on a timer could land after the commit and leave that path untested.
  touch "${TEST_REPO_DIR}/.git/index.lock"
  (
    sleep 1
    rm -f "${TEST_REPO_DIR}/.git/index.lock"
  ) 3>&- &
  local bg_pid=$!

  run _run_commit "--staged-only \"feat: commit under transient lock\""
  wait "${bg_pid}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[cgw-lock] index.lock is"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
  [ ! -e "${TEST_REPO_DIR}/.git/index.lock" ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "feat: commit under transient lock" ]
}

@test "commit_enhanced.sh retries git commit after an index.lock collision" {
  echo "content" > "${TEST_REPO_DIR}/retry_test.txt"
  git -C "${TEST_REPO_DIR}" add retry_test.txt

  # Shadow `git` so the FIRST `git commit` fails the way a lost lock race does and every
  # later call reaches the real git. The failure is a mock, so it cannot depend on timing.
  local real_git
  real_git=$(command -v git)
  cat >"${MOCK_BIN_DIR}/git" <<GIT_MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "commit" && ! -f "${MOCK_BIN_DIR}/commit_failed_once" ]]; then
  touch "${MOCK_BIN_DIR}/commit_failed_once"
  echo "fatal: Unable to create '.git/index.lock': File exists." >&2
  exit 128
fi
exec "${real_git}" "\$@"
GIT_MOCK
  chmod +x "${MOCK_BIN_DIR}/git"

  export CGW_LOCK_RETRY_DELAY=0
  run _run_commit "--staged-only \"feat: commit after a lock collision\""

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Index lock collision during 'git commit' (attempt 1/3)"* ]]
  [[ "${output}" == *"COMMIT SUCCESSFUL"* ]]
  [ -f "${MOCK_BIN_DIR}/commit_failed_once" ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "feat: commit after a lock collision" ]
}




# ── --only reset failure / unborn HEAD (D1) ───────────────────────────────────

# Shadow `git` so that exactly `git reset HEAD` fails (simulating a locked index);
# every other invocation goes to the real git.
_install_failing_reset_git() {
  local real_git
  real_git=$(command -v git)
  cat >"${MOCK_BIN_DIR}/git" <<GIT_MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "reset" && "\${2:-}" == "HEAD" && \$# -eq 2 ]]; then
  echo "fatal: Unable to create '.git/index.lock': File exists." >&2
  exit 128
fi
exec "${real_git}" "\$@"
GIT_MOCK
  chmod +x "${MOCK_BIN_DIR}/git"
}

@test "--only aborts when the index reset fails and commits nothing (D1)" {
  echo "file_a v1" >"${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v1" >"${TEST_REPO_DIR}/file_b.txt"
  git -C "${TEST_REPO_DIR}" add file_a.txt file_b.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add files"
  echo "file_a v2" >"${TEST_REPO_DIR}/file_a.txt"
  echo "file_b v2" >"${TEST_REPO_DIR}/file_b.txt"
  git -C "${TEST_REPO_DIR}" add file_a.txt   # pre-staged extra that must not ride along
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  _install_failing_reset_git
  run _run_commit "--skip-lint --only file_b.txt \"feat: only b\""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"failed to reset index"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "--only on an unborn HEAD does not carry pre-staged files along (D1)" {
  rm -rf "${TEST_REPO_DIR}/.git"
  git -C "${TEST_REPO_DIR}" init --quiet -b development
  git -C "${TEST_REPO_DIR}" config user.email "test@example.com"
  git -C "${TEST_REPO_DIR}" config user.name "Test User"
  echo "a" >"${TEST_REPO_DIR}/pre_staged.txt"
  echo "b" >"${TEST_REPO_DIR}/wanted.txt"
  git -C "${TEST_REPO_DIR}" add pre_staged.txt

  run _run_commit "--skip-lint --only wanted.txt \"feat: first commit\""
  [ "${status}" -eq 0 ]

  local committed
  committed=$(git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD | grep -v '^$')
  [[ "${committed}" == *"wanted.txt"* ]]
  [[ "${committed}" != *"pre_staged.txt"* ]]
  # The pre-staged file is untouched on disk, just no longer staged.
  [ -f "${TEST_REPO_DIR}/pre_staged.txt" ]
}

# ── "Configured types" line (Obs 1) ───────────────────────────────────────────

@test "invalid commit message lists configured types comma-separated, with no pipe characters (Obs 1)" {
  echo "x" >"${TEST_REPO_DIR}/obs1.txt"
  git -C "${TEST_REPO_DIR}" add obs1.txt

  run _run_commit "--skip-lint \"not a conventional message\""
  [ "${status}" -ne 0 ]
  local line
  line=$(printf '%s\n' "${output}" | grep "Configured types:")
  [ -n "${line}" ]
  [[ "${line}" == *"feat, fix"* ]]
  [[ "${line}" != *"|"* ]]
}

# ── there is no -m flag ───────────────────────────────────────────────────────

@test "-m is rejected with a clear message, not the --only advice" {
  echo "x" >"${TEST_REPO_DIR}/m.txt"
  git -C "${TEST_REPO_DIR}" add m.txt
  run _run_commit -m '"feat: add m"'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"there is no -m flag"* ]]
  [[ "${output}" != *"--only"* ]]
}

@test "a multi-line positional message commits with its body intact" {
  echo "x" >"${TEST_REPO_DIR}/body.txt"
  git -C "${TEST_REPO_DIR}" add body.txt
  run _run_commit "\"\$(printf 'feat: add body\n\nwhy: the body explains it')\""
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "feat: add body" ]
  [[ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%b)" == *"why: the body explains it"* ]]
}

# ── untracked-file warning / --strict-untracked / --no-untracked-check ────────

# Helper: commit tracked.txt, then modify it so a bulk commit has something to do.
_make_tracked_change() {
  echo "v1" >"${TEST_REPO_DIR}/tracked.txt"
  git -C "${TEST_REPO_DIR}" add tracked.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add tracked"
  echo "v2" >"${TEST_REPO_DIR}/tracked.txt"
}

@test "untracked: a new file left out is warned about on stderr and the commit still succeeds" {
  _make_tracked_change
  echo "new" >"${TEST_REPO_DIR}/new_module.py"
  run --separate-stderr _run_commit "--skip-lint \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"[WARN] 1 untracked file(s) are NOT included in this commit"* ]]
  [[ "${stderr}" == *"?? new_module.py"* ]]
  [[ "${output}" != *"untracked file(s)"* ]]
  git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD | grep -q "^tracked.txt$"
  run git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD
  [[ "${output}" != *"new_module.py"* ]]
}

@test "untracked: --only of one file warns about the other untracked file, not the selected one" {
  echo "a" >"${TEST_REPO_DIR}/file_a.txt"
  echo "b" >"${TEST_REPO_DIR}/file_b.txt"
  run --separate-stderr _run_commit "--skip-lint --only file_a.txt \"feat: only a\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"?? file_b.txt"* ]]
  [[ "${stderr}" != *"file_a.txt"* ]]
  git -C "${TEST_REPO_DIR}" show --name-only --pretty=format: HEAD | grep -q "^file_a.txt$"
}

@test "untracked: --staged-only does not list the staged file, only the untracked one" {
  echo "a" >"${TEST_REPO_DIR}/file_a.txt"
  echo "c" >"${TEST_REPO_DIR}/file_c.txt"
  git -C "${TEST_REPO_DIR}" add file_a.txt
  run --separate-stderr _run_commit "--skip-lint --staged-only \"feat: staged a\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"?? file_c.txt"* ]]
  [[ "${stderr}" != *"file_a.txt"* ]]
}

@test "untracked: gitignored and local-only files are not reported" {
  echo "*.log" >"${TEST_REPO_DIR}/.gitignore"
  git -C "${TEST_REPO_DIR}" add .gitignore
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: ignore logs"
  _make_tracked_change
  echo "x" >"${TEST_REPO_DIR}/debug.log"
  echo "KEY=placeholder" >"${TEST_REPO_DIR}/secret.env"
  mkdir -p "${TEST_REPO_DIR}/scratch"
  echo "x" >"${TEST_REPO_DIR}/scratch/notes.txt"
  export CGW_LOCAL_FILES='secret.env scratch/'
  run --separate-stderr _run_commit "--skip-lint \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" != *"untracked"* ]]
  [[ "${stderr}" != *"debug.log"* ]]
  [[ "${stderr}" != *"secret.env"* ]]
  [[ "${stderr}" != *"scratch"* ]]
}

@test "untracked: lists at most 10 paths and counts the rest" {
  _make_tracked_change
  local i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    echo "x" >"${TEST_REPO_DIR}/new_${i}.txt"
  done
  run --separate-stderr _run_commit "--skip-lint \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"12 untracked file(s) are NOT included"* ]]
  [[ "${stderr}" == *"... and 2 more"* ]]
  [ "$(printf '%s\n' "${stderr}" | grep -c '^  ?? ')" -eq 10 ]
}

@test "untracked: a clean tree prints nothing about untracked files" {
  _make_tracked_change
  run --separate-stderr _run_commit "--skip-lint \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" != *"untracked"* ]]
  [[ "${output}" != *"untracked"* ]]
}

@test "untracked: with no changes to commit, a lone new file is still reported" {
  echo "new" >"${TEST_REPO_DIR}/lonely.txt"
  run --separate-stderr _run_commit "--skip-lint \"feat: nothing\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No changes to commit"* ]]
  [[ "${stderr}" == *"?? lonely.txt"* ]]
}

@test "untracked: --strict-untracked refuses, lists the files and creates no commit" {
  _make_tracked_change
  echo "new" >"${TEST_REPO_DIR}/new_module.py"
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  run --separate-stderr _run_commit "--skip-lint --strict-untracked \"feat: change tracked\""
  [ "${status}" -ne 0 ]
  [[ "${stderr}" == *"?? new_module.py"* ]]
  [[ "${stderr}" == *"git add"* ]]
  [[ "${stderr}" == *".gitignore"* ]]
  [[ "${stderr}" == *"CGW_LOCAL_FILES"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${before}" ]
}

@test "untracked: CGW_STRICT_UNTRACKED=1 refuses the same way" {
  _make_tracked_change
  echo "new" >"${TEST_REPO_DIR}/new_module.py"
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  export CGW_STRICT_UNTRACKED=1
  run --separate-stderr _run_commit "--skip-lint \"feat: change tracked\""
  [ "${status}" -ne 0 ]
  [[ "${stderr}" == *"?? new_module.py"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${before}" ]
}

@test "untracked: --strict-untracked still commits when nothing is left out" {
  _make_tracked_change
  run --separate-stderr _run_commit "--skip-lint --strict-untracked \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "feat: change tracked" ]
}

@test "untracked: --strict-untracked passes once the file is added to CGW_LOCAL_FILES" {
  _make_tracked_change
  echo "new" >"${TEST_REPO_DIR}/new_module.py"
  export CGW_LOCAL_FILES='new_module.py'
  run --separate-stderr _run_commit "--skip-lint --strict-untracked \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" != *"untracked"* ]]
}

@test "untracked: --no-untracked-check prints nothing and commits" {
  _make_tracked_change
  echo "new" >"${TEST_REPO_DIR}/new_module.py"
  run --separate-stderr _run_commit "--skip-lint --no-untracked-check \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" != *"untracked"* ]]
  [[ "${stderr}" != *"new_module.py"* ]]
  [[ "${output}" != *"new_module.py"* ]]
}

@test "untracked: CGW_UNTRACKED_CHECK=0 silences it and overrides strict mode" {
  _make_tracked_change
  echo "new" >"${TEST_REPO_DIR}/new_module.py"
  export CGW_UNTRACKED_CHECK=0
  export CGW_STRICT_UNTRACKED=1
  run --separate-stderr _run_commit "--skip-lint \"feat: change tracked\""
  [ "${status}" -eq 0 ]
  [[ "${stderr}" != *"untracked"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" = "feat: change tracked" ]
}

@test "untracked: --help documents the new flags and variables" {
  run bash "${CGW_PROJECT_ROOT}/scripts/git/commit_enhanced.sh" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--strict-untracked"* ]]
  [[ "${output}" == *"--no-untracked-check"* ]]
  [[ "${output}" == *"CGW_STRICT_UNTRACKED"* ]]
  [[ "${output}" == *"CGW_UNTRACKED_CHECK"* ]]
}
