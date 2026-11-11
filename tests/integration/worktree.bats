#!/usr/bin/env bats
# tests/integration/worktree.bats - Integration tests for worktree_manage.sh
# and the linked-worktree support it exists to provide.
#
# Bug this whole feature addresses: pushing from a linked worktree failed
# because scripts/git/ and .githooks/ are gitignored, so `git worktree add`
# (which only checks out TRACKED content) never creates them there. All three
# hooks resolve the main worktree as a fallback (commit 1), but the tooling
# was still unreachable for direct script invocation
# (./scripts/git/check_lint.sh) and for install_hooks.sh's own template
# source. worktree_manage.sh's `link` subcommand fixes that by creating a
# real link (symlink / NTFS junction) from the linked worktree back to the
# main worktree's copies.
#
# This is worktree_manage.sh's first test file.
#
# Runs: bats tests/integration/worktree.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo
  create_test_worktree
}

teardown() {
  cleanup_test_repo
}

# Resolves the shared hooks directory for TEST_WORKTREE_DIR the same way
# install_hooks.sh does (git-common-dir, absolutised against the worktree,
# not the main repo -- a relative --git-common-dir is relative to the cwd it
# was resolved from).
_common_hooks_dir() {
  local d
  d="$(git -C "${TEST_WORKTREE_DIR}" rev-parse --git-common-dir)"
  # On Windows/MSYS an already-absolute path from git is drive-letter form
  # ("C:/…"), which a bare "/*" glob does not match -- check both forms or
  # this wrongly re-prefixes it with TEST_WORKTREE_DIR (same fix as
  # install_hooks.sh / ensure_no_stale_index_lock).
  [[ "${d}" != /* && "${d}" != [A-Za-z]:/* ]] && d="${TEST_WORKTREE_DIR}/${d}"
  (cd "${d}" && pwd)
}

# Installs a hook template DIRECTLY into the shared hooks dir, bypassing both
# `link` and install_hooks.sh. Isolates: does the HOOK ITSELF find CGW via its
# own main-worktree fallback (commit 1), independent of the `link` feature?
_install_hook_direct() {
  local hook_name="$1"
  local dir
  dir="$(_common_hooks_dir)/hooks"
  mkdir -p "${dir}"
  cp "${CGW_PROJECT_ROOT}/hooks/${hook_name}" "${dir}/${hook_name}"
  chmod +x "${dir}/${hook_name}"
}

# ── link ─────────────────────────────────────────────────────────────────────

@test "link writes shims for scripts/git (a real directory, not a link)" {
  [ ! -e "${TEST_WORKTREE_DIR}/scripts/git" ]
  [ ! -e "${TEST_WORKTREE_DIR}/.githooks" ]

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK]   scripts/git shims in place"* ]]
  [ -x "${TEST_WORKTREE_DIR}/scripts/git/commit_enhanced.sh" ]
  [ -f "${TEST_WORKTREE_DIR}/scripts/git/.cgw-worktree-shims" ]
  # Libraries stay in main only; hooks/install_hooks fall back to main for them.
  [ ! -e "${TEST_WORKTREE_DIR}/scripts/git/_common.sh" ]
  [ ! -e "${TEST_WORKTREE_DIR}/.githooks" ]
  [ ! -L "${TEST_WORKTREE_DIR}/scripts/git" ]
  run ! fsutil reparsepoint query "$(cygpath -w "${TEST_WORKTREE_DIR}/scripts/git" 2>/dev/null || echo "${TEST_WORKTREE_DIR}/scripts/git")"
}

@test "link shims forward to main's script and keep the worktree as PROJECT_ROOT" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link

  run bash -c "cd '${TEST_WORKTREE_DIR}' && ./scripts/git/worktree_manage.sh list"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Git Worktrees"* ]]
  # Logs land in the worktree, not the main checkout.
  ls "${TEST_WORKTREE_DIR}/logs/"worktree_manage_*.log
}

@test "link is idempotent - re-running succeeds and refreshes the shims" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK]   scripts/git shims in place"* ]]
}

@test "link drops shims for scripts that no longer exist in main" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  echo "stale" >"${TEST_WORKTREE_DIR}/scripts/git/gone_script.sh"

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [ ! -e "${TEST_WORKTREE_DIR}/scripts/git/gone_script.sh" ]
  [ -f "${TEST_WORKTREE_DIR}/scripts/git/.cgw-worktree-shims" ]
  [ -x "${TEST_WORKTREE_DIR}/scripts/git/commit_enhanced.sh" ]
}

@test "link leaves no temp directory and no unmarked dir behind" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  run bash -c "ls -d '${TEST_WORKTREE_DIR}'/scripts/git.cgw-tmp.* 2>/dev/null"
  [ -z "${output}" ]
}

@test "link migrates a legacy junction/symlink to shims without touching main" {
  mkdir -p "${TEST_WORKTREE_DIR}/scripts"
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      cmd //c mklink //J "$(cygpath -w "${TEST_WORKTREE_DIR}/scripts/git")" "$(cygpath -w "${TEST_REPO_DIR}/scripts/git")" >/dev/null
      cmd //c mklink //J "$(cygpath -w "${TEST_WORKTREE_DIR}/.githooks")" "$(cygpath -w "${TEST_REPO_DIR}/.githooks")" >/dev/null
      ;;
    *)
      ln -s "${TEST_REPO_DIR}/scripts/git" "${TEST_WORKTREE_DIR}/scripts/git"
      ln -s "${TEST_REPO_DIR}/.githooks" "${TEST_WORKTREE_DIR}/.githooks"
      ;;
  esac

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"migrated scripts/git"* ]]
  [ -f "${TEST_WORKTREE_DIR}/scripts/git/.cgw-worktree-shims" ]
  [ ! -e "${TEST_WORKTREE_DIR}/.githooks" ]
  [ -f "${TEST_REPO_DIR}/scripts/git/_common.sh" ]
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}


@test "link refuses to overwrite a real (non-linked) directory" {
  mkdir -p "${TEST_WORKTREE_DIR}/scripts/git"
  echo "real" > "${TEST_WORKTREE_DIR}/scripts/git/placeholder.txt"

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"exists as a real directory"* ]]
  # Must not have been touched.
  [ -f "${TEST_WORKTREE_DIR}/scripts/git/placeholder.txt" ]
}

@test "link rejects a stale link that doesn't resolve to the main worktree" {
  # A link exists at the tooling path, but points somewhere other than the
  # main worktree's scripts/git -- must not be accepted as "already linked".
  # Plain `ln -s` on a directory silently falls back to a real directory on
  # Windows/MSYS without admin rights, so create the stale link the same way
  # older CGW versions did (an NTFS junction on MINGW/MSYS/CYGWIN,
  # symlink elsewhere) rather than hardcoding `ln -s`.
  mkdir -p "${TEST_WORKTREE_DIR}/scripts" "${BATS_TEST_TMPDIR}/elsewhere"
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      cmd //c mklink //J "$(cygpath -w "${TEST_WORKTREE_DIR}/scripts/git")" "$(cygpath -w "${BATS_TEST_TMPDIR}/elsewhere")" >/dev/null
      ;;
    *)
      ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${TEST_WORKTREE_DIR}/scripts/git"
      ;;
  esac

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not resolve to the main worktree"* ]]
}

@test "link is a clean no-op from the main worktree itself (F2: path-format mismatch)" {
  # Regression: cgw_main_worktree_root() returns a git-format path
  # ("C:/Users/...") while the caller's `cd && pwd` yielded an MSYS path
  # ("/tmp/..."), so the "target IS the main worktree" check silently missed
  # and the main worktree got an error instead of a clean no-op.
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"is the main worktree — nothing to link."* ]]
}

# ── hooks resolve from a linked worktree ───────────────────────────────────

@test "pre-commit hook resolves CGW via the main-worktree fallback (no link needed)" {
  _install_hook_direct "pre-commit"
  [ ! -e "${TEST_WORKTREE_DIR}/scripts/git" ] # confirm still unlinked

  echo "# Claude" > "${TEST_WORKTREE_DIR}/CLAUDE.md"
  git -C "${TEST_WORKTREE_DIR}" add CLAUDE.md
  run git -C "${TEST_WORKTREE_DIR}" commit -m "docs: leak CLAUDE.md"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"CGW not found"* ]]
  [[ "${output}" != *"No local-only files detected"* ]]
}

@test ".cgw.conf fallback: worktree without its own copy inherits the main worktree's config" {
  # .cgw.conf is gitignored by configure.sh itself, so it's untracked in
  # TEST_REPO_DIR the same way scripts/git and .githooks are -- a linked
  # worktree never gets it checked out either.
  echo 'CGW_LOCAL_FILES="notes.md"' > "${TEST_REPO_DIR}/.cgw.conf"
  _install_hook_direct "pre-commit"
  [ ! -e "${TEST_WORKTREE_DIR}/.cgw.conf" ] # confirm the worktree really lacks its own copy

  echo "scratch" > "${TEST_WORKTREE_DIR}/notes.md"
  git -C "${TEST_WORKTREE_DIR}" add notes.md
  run git -C "${TEST_WORKTREE_DIR}" commit -m "docs: leak notes.md"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.md"* ]] || [[ "${output}" == *"local-only"* ]]
}

@test "pre-commit hook fires and blocks a local-only file once link + install_hooks are run" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  run run_script_at "${TEST_WORKTREE_DIR}" install_hooks.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"HOOKS INSTALLED SUCCESSFULLY"* ]]

  echo "# Claude" > "${TEST_WORKTREE_DIR}/CLAUDE.md"
  git -C "${TEST_WORKTREE_DIR}" add CLAUDE.md
  run git -C "${TEST_WORKTREE_DIR}" commit -m "docs: leak CLAUDE.md"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"CLAUDE.md"* ]] || [[ "${output}" == *"local-only"* ]]
}

# ── remove with no terminal ────────────────────────────────────────────────

@test "remove: no terminal and no --non-interactive exits 1 and keeps the worktree" {
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute "${TEST_WORKTREE_DIR}" </dev/null
  [ "${status}" -eq 1 ]
  [ -d "${TEST_WORKTREE_DIR}" ]
  [[ "${output}" == *"--non-interactive"* ]]
  [[ "${output}" != *"Cancelled"* ]]
}

@test "remove: no terminal with --non-interactive removes the worktree" {
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${TEST_WORKTREE_DIR}" </dev/null
  [ "${status}" -eq 0 ]
  [ ! -d "${TEST_WORKTREE_DIR}" ]
}

# Regression: git can delete every file of a linked worktree and still exit
# non-zero when it cannot remove the directory itself (on Windows a process
# holding it as its cwd does this). The failure report then ran
# `git -C <path> status` in the leftover EMPTY directory, which is no longer a
# worktree, so git walked up to the main checkout and listed ITS untracked
# files as if they were left in the worktree.
_install_git_leaving_empty_dir() {
  local real_git
  real_git="$(command -v git)"
  setup_mock_bin
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == worktree && "$2" == remove ]]; then' \
    "  \"${real_git}\" \"\$@\"" \
    '  mkdir -p "$3"' \
    '  exit "${MOCK_WT_REMOVE_EXIT:-1}"' \
    'fi' \
    "exec \"${real_git}\" \"\$@\"" >"${MOCK_BIN_DIR}/git"
  chmod +x "${MOCK_BIN_DIR}/git"
}

@test "remove: git removes the worktree but fails on the directory -> exit 1, folder named, no files of the main checkout reported" {
  load '../helpers/mocks'
  echo "belongs to the main checkout" >"${TEST_REPO_DIR}/stray-main-file.txt"
  # The worktree lives INSIDE the main checkout (e.g. .claude/worktrees/x), so
  # once its files are gone git walks up from the empty directory into the
  # main checkout. A sibling directory would hide the bug.
  local nested="${TEST_REPO_DIR}/nested-wt"
  git -C "${TEST_REPO_DIR}" worktree add --quiet -b nested-branch "${nested}"
  _install_git_leaving_empty_dir

  _install_no_powershell
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${nested}" </dev/null
  # A folder left behind is not a clean removal: exit 1, not [OK].
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"[OK] Worktree removed"* ]]
  [[ "${output}" != *"Failed to remove worktree"* ]]
  [[ "${output}" != *"stray-main-file.txt"* ]]
  [[ "${output}" != *"Left in it"* ]]
  # The leftover folder is named, with why it stays and that git let go of it.
  [[ "${output}" == *"[ERROR] Folder still exists: ${nested}"* ]]
  [[ "${output}" == *"git no longer registers it as a worktree"* ]]
  [[ "${output}" == *"a process holds it"* ]]
  # git no longer lists it as a worktree.
  local listed
  listed="$(git -C "${TEST_REPO_DIR}" worktree list --porcelain)"
  [[ "${listed}" != *"nested-wt"* ]]
}

@test "remove: git refuses over an untracked file -> that file, and only that file, is listed" {
  echo "belongs to the main checkout" >"${TEST_REPO_DIR}/stray-main-file.txt"
  local nested="${TEST_REPO_DIR}/nested-wt"
  git -C "${TEST_REPO_DIR}" worktree add --quiet -b nested-branch "${nested}"
  echo "left behind" >"${nested}/mine.txt"

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${nested}" </dev/null
  [ "${status}" -eq 1 ]
  [ -d "${nested}" ]
  [[ "${output}" == *"Left in it"* ]]
  [[ "${output}" == *"?? mine.txt"* ]]
  [[ "${output}" != *"stray-main-file.txt"* ]]
}

# ── remove (A3: cannot delete the main worktree's tooling) ─────────────────

@test "remove: unlinks scripts/git and .githooks before removing; main worktree survives" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ -e "${TEST_WORKTREE_DIR}/scripts/git/commit_enhanced.sh" ]

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${TEST_WORKTREE_DIR}"
  [ "${status}" -eq 0 ]
  [ ! -d "${TEST_WORKTREE_DIR}" ]

  # The MAIN worktree's own tooling must be completely untouched.
  [ -f "${TEST_REPO_DIR}/scripts/git/_common.sh" ]
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

@test "remove: a real (non-linked) tooling directory no longer blocks removal" {
  # A REAL directory (not a link) at scripts/git has no reparse point for
  # git worktree remove's recursive delete to follow into the main
  # worktree, so it's not an A3 risk -- _cgw_unlink_dir leaves it alone and
  # git worktree remove's own recursive delete handles it normally.
  mkdir -p "${TEST_WORKTREE_DIR}/scripts/git"
  echo "real" > "${TEST_WORKTREE_DIR}/scripts/git/placeholder.txt"

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${TEST_WORKTREE_DIR}"
  [ "${status}" -eq 0 ]
  [ ! -d "${TEST_WORKTREE_DIR}" ]

  # The MAIN worktree's own tooling must be completely untouched.
  [ -f "${TEST_REPO_DIR}/scripts/git/_common.sh" ]
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

# ── raw removal (bypassing CGW) must not reach the main worktree's tooling ───
# Regression: on Windows `link` made NTFS junctions, and a plain
# `git worktree remove` / `rm -rf` recursed THROUGH them, emptying the main
# checkout's gitignored scripts/git and .githooks (unrecoverable from git).

_skip_unless_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *) skip "junction recursion is Windows-specific" ;;
  esac
}

@test "raw git worktree remove leaves the main worktree's tooling intact" {
  _skip_unless_windows
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link

  git -C "${TEST_REPO_DIR}" worktree remove --force "${TEST_WORKTREE_DIR}"

  [ -f "${TEST_REPO_DIR}/scripts/git/_common.sh" ]
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

@test "recursive delete of a linked worktree leaves the main worktree's tooling intact" {
  _skip_unless_windows
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link

  rm -rf "${TEST_WORKTREE_DIR}"
  git -C "${TEST_REPO_DIR}" worktree prune

  [ -f "${TEST_REPO_DIR}/scripts/git/_common.sh" ]
  [ -f "${TEST_REPO_DIR}/.githooks/pre-commit" ]
}

# ── add <path> <branch> <base> ───────────────────────────────────────────────

@test "add: a new branch starts from an explicit base ref, not HEAD" {
  # HEAD (main) and development differ; base must win.
  local base_sha
  base_sha=$(git -C "${TEST_REPO_DIR}" rev-parse development)
  [ "${base_sha}" != "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" ]

  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-base" topic-from-dev development --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_TMPDIR}/wt-base" rev-parse HEAD)" = "${base_sha}" ]
  [ "$(git -C "${TEST_TMPDIR}/wt-base" symbolic-ref --short HEAD)" = "topic-from-dev" ]
}

@test "add: --base is the flag form of the base positional" {
  local base_sha
  base_sha=$(git -C "${TEST_REPO_DIR}" rev-parse development)

  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-flag" topic-flag --base development --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_TMPDIR}/wt-flag" rev-parse HEAD)" = "${base_sha}" ]
}

@test "add: without a base the new branch still starts from HEAD" {
  local head_sha
  head_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-head" topic-head --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_TMPDIR}/wt-head" rev-parse HEAD)" = "${head_sha}" ]
}

@test "add: a base for an existing branch is refused" {
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-exists" development main --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists"* ]]
  [ ! -d "${TEST_TMPDIR}/wt-exists" ]
}

@test "add: an unknown base ref is refused" {
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-bad" topic-bad no-such-ref --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid base ref"* ]]
  [ ! -d "${TEST_TMPDIR}/wt-bad" ]
  run ! git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/topic-bad
}

@test "add: a base without a branch is refused" {
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-nobranch" --base development --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"needs a branch"* ]]
}

@test "add: --dry-run shows the -b <branch> <path> <base> command and creates nothing" {
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-dry" topic-dry development --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"-b topic-dry ${TEST_TMPDIR}/wt-dry development"* ]]
  [ ! -d "${TEST_TMPDIR}/wt-dry" ]
}

@test "add: a branch only on the remote is checked out tracking it, not created from HEAD" {
  create_bare_remote "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" remote add origin "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" push --quiet origin development:refs/heads/remote-only
  git -C "${TEST_REPO_DIR}" fetch --quiet origin
  run ! git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/remote-only
  local remote_sha
  remote_sha=$(git -C "${TEST_REPO_DIR}" rev-parse refs/remotes/origin/remote-only)
  [ "${remote_sha}" != "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" ]

  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-remote" remote-only --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Branch: remote-only (new, tracking origin/remote-only)"* ]]
  [ "$(git -C "${TEST_TMPDIR}/wt-remote" rev-parse HEAD)" = "${remote_sha}" ]
  [ "$(git -C "${TEST_TMPDIR}/wt-remote" rev-parse --abbrev-ref '@{upstream}')" = "origin/remote-only" ]
}

# A stacked branch is created from its base, but it is not the base: with git's default
# branch.autoSetupMerge a remote-tracking start point made the new branch track the base,
# so a bare `git push`/`git pull` from the stack would have targeted the base's branch.
@test "add: a new branch from a remote-tracking base does not track that base" {
  create_bare_remote "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" remote add origin "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" push --quiet origin development
  git -C "${TEST_REPO_DIR}" fetch --quiet origin
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-stack" stack-tip origin/development --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_TMPDIR}/wt-stack" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse origin/development)" ]
  run ! git -C "${TEST_TMPDIR}/wt-stack" rev-parse --abbrev-ref '@{upstream}'
}

@test "add: a new branch from a local base does not track it, even with autoSetupMerge=always" {
  git -C "${TEST_REPO_DIR}" config branch.autoSetupMerge always
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-local-stack" stack-local development --non-interactive
  [ "${status}" -eq 0 ]
  run ! git -C "${TEST_TMPDIR}/wt-local-stack" rev-parse --abbrev-ref '@{upstream}'
}

@test "add: a new branch from the default HEAD does not track the current branch, even with autoSetupMerge=always" {
  git -C "${TEST_REPO_DIR}" config branch.autoSetupMerge always
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-head-stack" stack-head --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_TMPDIR}/wt-head-stack" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" ]
  run ! git -C "${TEST_TMPDIR}/wt-head-stack" rev-parse --abbrev-ref '@{upstream}'
}

@test "add: a base that is the branch's own remote counterpart still tracks it" {
  create_bare_remote "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" remote add origin "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" push --quiet origin development:refs/heads/feat-x
  git -C "${TEST_REPO_DIR}" fetch --quiet origin
  run run_script worktree_manage.sh add "${TEST_TMPDIR}/wt-own" feat-x origin/feat-x --non-interactive
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tracking origin/feat-x"* ]]
  [ "$(git -C "${TEST_TMPDIR}/wt-own" rev-parse --abbrev-ref '@{upstream}')" = "origin/feat-x" ]
}

# -- remove: folder left although git exits 0 -------------------------------

# A fake powershell.exe for the Win32_Process lookup: prints MOCK_PS_OUTPUT
# (tab-separated "<pid>\t<name>\t<command line>" lines), or nothing.
_install_mock_powershell() {
  setup_mock_bin
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%b" "${MOCK_PS_OUTPUT:-}"' >"${MOCK_BIN_DIR}/powershell.exe"
  chmod +x "${MOCK_BIN_DIR}/powershell.exe"
}

# No holders, and no slow real powershell.exe call on a Windows host.
_install_no_powershell() {
  MOCK_PS_OUTPUT="" _install_mock_powershell
}

# The command line an idle Claude desktop session has, naming <dir> with
# backslashes (the Windows form).
_claude_holding() {
  local dir="$1" win
  win="$(printf '%s' "${dir}" | tr '/' '\\')"
  printf '4242\\tclaude.exe\\t"C:\\\\Claude\\\\claude.exe" --add-dir=%s --resume\\n' "${win//\\/\\\\}"
}

@test "remove: git exits 0 but the folder stays -> exit 1 and the folder is named" {
  load '../helpers/mocks'
  local nested="${TEST_REPO_DIR}/nested-wt"
  git -C "${TEST_REPO_DIR}" worktree add --quiet -b nested-branch "${nested}"
  _install_git_leaving_empty_dir
  _install_no_powershell
  export MOCK_WT_REMOVE_EXIT=0

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${nested}" </dev/null
  [ "${status}" -eq 1 ]
  [ -d "${nested}" ]
  [[ "${output}" == *"[ERROR] Folder still exists: ${nested}"* ]]
  [[ "${output}" == *"git no longer registers it as a worktree"* ]]
  [[ "${output}" != *"[OK] Worktree removed"* ]]
  [[ "${output}" != *"Held by"* ]]
}

@test "remove: a leftover folder names the process whose command line holds it" {
  load '../helpers/mocks'
  local nested="${TEST_REPO_DIR}/nested-wt" top
  git -C "${TEST_REPO_DIR}" worktree add --quiet -b nested-branch "${nested}"
  top="$(git -C "${nested}" rev-parse --show-toplevel)"
  _install_git_leaving_empty_dir
  export MOCK_WT_REMOVE_EXIT=0
  # A sibling folder with a longer name must not count as a holder.
  MOCK_PS_OUTPUT="$(_claude_holding "${top}")7\tcode.exe\tcode --folder ${top}-2\n"
  export MOCK_PS_OUTPUT
  _install_mock_powershell

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove --execute --non-interactive "${nested}" </dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Held by"* ]]
  [[ "${output}" == *"claude.exe (PID 4242)"* ]]
  [[ "${output}" != *"code.exe"* ]]
}

# -- list --status / remove-merged --------------------------------------------

# Adds an origin with main pushed, then one linked worktree per case under
# TEST_TMPDIR. setup() already made TEST_WORKTREE_DIR (worktree-topic, off
# development, so not merged into origin/main).
#   wt-merged     merged-br, clean, no commits of its own        -> safe
#   wt-dirty      dirty-br, a tracked file modified               -> kept
#   wt-untracked  untracked-br, one untracked file                -> kept
#   wt-ahead      ahead-br, one commit not on origin/main         -> kept
#   wt-detached   detached at main                                -> safe
#   wt-det-ahead  detached, one commit not on origin/main         -> kept
#   wt-locked     locked-br, clean but `git worktree lock`-ed     -> kept
_status_fixture() {
  create_bare_remote "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" remote add origin "${TEST_TMPDIR}/remote.git"
  git -C "${TEST_REPO_DIR}" push --quiet -u origin main
  local r="${TEST_REPO_DIR}" t="${TEST_TMPDIR}"
  git -C "${r}" worktree add --quiet -b merged-br "${t}/wt-merged" main
  git -C "${r}" worktree add --quiet -b dirty-br "${t}/wt-dirty" main
  echo "changed" >>"${t}/wt-dirty/README.md"
  git -C "${r}" worktree add --quiet -b untracked-br "${t}/wt-untracked" main
  echo "new" >"${t}/wt-untracked/new.txt"
  git -C "${r}" worktree add --quiet -b ahead-br "${t}/wt-ahead" main
  echo "ahead" >"${t}/wt-ahead/ahead.txt"
  git -C "${t}/wt-ahead" add ahead.txt
  git -C "${t}/wt-ahead" commit --quiet --no-verify -m "feat: ahead"
  git -C "${r}" worktree add --quiet --detach "${t}/wt-detached" main
  git -C "${r}" worktree add --quiet --detach "${t}/wt-det-ahead" main
  echo "det" >"${t}/wt-det-ahead/det.txt"
  git -C "${t}/wt-det-ahead" add det.txt
  git -C "${t}/wt-det-ahead" commit --quiet --no-verify -m "feat: detached ahead"
  git -C "${r}" worktree add --quiet -b locked-br "${t}/wt-locked" main
  git -C "${r}" worktree lock "${t}/wt-locked"
}

# Prints the status row of worktree <name> from $output.
_row() {
  printf '%s\n' "${output}" | grep -E "/$1 " | head -1
}

# Asserts the columns of row <name>: <branch> <merged> <changed> <untracked> <ahead> <reason glob>.
_assert_row() {
  local p b m c u a rest
  read -r p b m c u a rest <<<"$(_row "$1")"
  [ -n "${p}" ] || { echo "no row for $1" >&2; return 1; }
  [ "${b}" = "$2" ] && [ "${m}" = "$3" ] && [ "${c}" = "$4" ] && [ "${u}" = "$5" ] && [ "${a}" = "$6" ] ||
    { echo "row $1: ${b} ${m} ${c} ${u} ${a} ${rest}" >&2; return 1; }
  # shellcheck disable=SC2053  # $7 is a glob on purpose
  [[ "${rest}" == $7 ]] || { echo "row $1 reason: ${rest}" >&2; return 1; }
}

@test "list --status: one row per linked worktree with merged, changed, untracked and ahead" {
  _status_fixture
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh list --status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"compared with origin/main"* ]]
  _assert_row wt-merged merged-br yes 0 0 0 "safe"
  _assert_row wt-dirty dirty-br yes 1 0 0 "1 changed"
  _assert_row wt-untracked untracked-br yes 0 1 0 "1 untracked"
  _assert_row wt-ahead ahead-br no 0 0 1 "not merged, 1 ahead"
  _assert_row wt-detached detached yes 0 0 0 "safe"
  _assert_row wt-det-ahead detached no 0 0 1 "not merged, 1 ahead"
  _assert_row wt-locked locked-br yes 0 0 0 "locked"
  # development's two commits (DEV.md, .gitignore) are not on main.
  _assert_row wt worktree-topic no 0 0 2 "not merged, 2 ahead"
  [[ "${output}" == *"Safe to remove: 2 of 8 linked worktrees"* ]]
  # The main worktree has no row.
  run ! grep -qE '/repo ' <<<"${output}"
}

@test "list --status: no PR column when gh cannot reach a GitHub remote" {
  load '../helpers/mocks'
  _status_fixture
  setup_mock_bin
  hide_gh
  git -C "${TEST_REPO_DIR}" config remote.origin.pushurl "https://github.com/owner/repo.git"
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh list --status
  [ "${status}" -eq 0 ]
  [[ "${output}" != *" PR "* ]]
  _assert_row wt-merged merged-br yes 0 0 0 "safe"
}

@test "list --status: shows the newest PR state per branch when gh answers" {
  load '../helpers/mocks'
  _status_fixture
  setup_mock_bin
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'echo "gh $*" >>"${MOCK_BIN_DIR}/gh.log"' \
    'if [[ "$1" == pr && "$2" == list ]]; then' \
    '  printf "merged-br\tMERGED\t12\nmerged-br\tCLOSED\t9\nahead-br\tOPEN\t15\n"' \
    '  exit 0' \
    'fi' \
    'exit 1' >"${MOCK_BIN_DIR}/gh"
  chmod +x "${MOCK_BIN_DIR}/gh"
  git -C "${TEST_REPO_DIR}" config remote.origin.pushurl "https://github.com/owner/repo.git"

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh list --status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *" PR "* ]]
  [[ "$(_row wt-merged)" == *"MERGED #12"* ]]
  [[ "$(_row wt-ahead)" == *"OPEN #15"* ]]
  grep -q -- "-R owner/repo" "${MOCK_BIN_DIR}/gh.log"

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh list --status --no-pr
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"MERGED #12"* ]]
}

@test "remove-merged: dry-run by default lists what it would remove and removes nothing" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"would remove  "*"/wt-merged  (branch merged-br)"* ]]
  [[ "${output}" == *"would remove  "*"/wt-detached  (detached HEAD)"* ]]
  [[ "${output}" == *"kept     "*"/wt-dirty  (1 changed)"* ]]
  [[ "${output}" == *"kept     "*"/wt-untracked  (1 untracked)"* ]]
  [[ "${output}" == *"kept     "*"/wt-ahead  (not merged, 1 ahead)"* ]]
  [[ "${output}" == *"kept     "*"/wt-locked  (locked)"* ]]
  [[ "${output}" == *"Dry run"* ]]
  [ -d "${TEST_TMPDIR}/wt-merged" ]
  [ -d "${TEST_TMPDIR}/wt-detached" ]
  git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/merged-br
}

@test "remove-merged --execute removes only the safe worktrees and deletes their branches with -d" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed  "*"/wt-merged  (branch merged-br deleted)"* ]]
  [[ "${output}" == *"removed  "*"/wt-detached"* ]]
  [[ "${output}" == *"Removed: 2  Kept: 6  Failed: 0"* ]]
  [ ! -e "${TEST_TMPDIR}/wt-merged" ]
  [ ! -e "${TEST_TMPDIR}/wt-detached" ]
  run ! git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/merged-br
  local d
  for d in wt-dirty wt-untracked wt-ahead wt-det-ahead wt-locked wt; do
    [ -d "${TEST_TMPDIR}/${d}" ]
  done
  [ -f "${TEST_TMPDIR}/wt-untracked/new.txt" ]
  for d in dirty-br untracked-br ahead-br locked-br worktree-topic; do
    git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet "refs/heads/${d}"
  done
}

@test "remove-merged never selects the current worktree" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  run run_script_at "${TEST_TMPDIR}/wt-merged" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"kept     "*"/wt-merged  (current worktree)"* ]]
  [ -d "${TEST_TMPDIR}/wt-merged" ]
  [ ! -e "${TEST_TMPDIR}/wt-detached" ]
}

@test "remove-merged keeps a worktree whose folder a process names on its command line" {
  load '../helpers/mocks'
  _status_fixture
  local top
  top="$(git -C "${TEST_TMPDIR}/wt-merged" rev-parse --show-toplevel)"
  MOCK_PS_OUTPUT="$(_claude_holding "${top}")"
  export MOCK_PS_OUTPUT
  _install_mock_powershell
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"kept     "*"/wt-merged  (in use by claude.exe (PID 4242))"* ]]
  [ -d "${TEST_TMPDIR}/wt-merged" ]
  git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/merged-br
  [ ! -e "${TEST_TMPDIR}/wt-detached" ]
}

@test "remove-merged exits 1 when a selected folder stays after removal" {
  load '../helpers/mocks'
  _status_fixture
  _install_git_leaving_empty_dir
  _install_no_powershell
  export MOCK_WT_REMOVE_EXIT=0
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAILED   "*"/wt-merged  (folder left: a process holds it; branch merged-br deleted)"* ]]
  [[ "${output}" == *"Failed: 2"* ]]
}

@test "remove-merged keeps a branch that git branch -d refuses and never forces it" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  # feat-x is on origin/main but not on the local main that HEAD points at,
  # so `git branch -d` (which checks HEAD) refuses it.
  local t="${TEST_TMPDIR}"
  git -C "${TEST_REPO_DIR}" worktree add --quiet -b feat-x "${t}/wt-feat" main
  echo "x" >"${t}/wt-feat/x.txt"
  git -C "${t}/wt-feat" add x.txt
  git -C "${t}/wt-feat" commit --quiet --no-verify -m "feat: x"
  git -C "${TEST_REPO_DIR}" push --quiet origin feat-x:main
  git -C "${TEST_REPO_DIR}" fetch --quiet origin

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed  "*"/wt-feat  ([WARN] branch feat-x kept:"* ]]
  [ ! -e "${t}/wt-feat" ]
  git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/feat-x
}

@test "remove-merged removes a worktree on a protected branch but never deletes that branch" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  # development is CGW_SOURCE_BRANCH (protected). Bring origin/main up to it so
  # the worktree that has it checked out is merged and clean.
  git -C "${TEST_REPO_DIR}" push --quiet origin development:main
  git -C "${TEST_REPO_DIR}" fetch --quiet origin
  git -C "${TEST_REPO_DIR}" worktree add --quiet "${TEST_TMPDIR}/wt-dev" development

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed  "*"/wt-dev  (branch development kept: protected)"* ]]
  [ ! -e "${TEST_TMPDIR}/wt-dev" ]
  git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/development
}

@test "list --status counts a diverged skip-worktree file as changed, so remove-merged keeps it" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  git -C "${TEST_TMPDIR}/wt-merged" update-index --skip-worktree README.md
  echo "local only" >>"${TEST_TMPDIR}/wt-merged/README.md"

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh list --status
  [ "${status}" -eq 0 ]
  _assert_row wt-merged merged-br yes 1 0 0 "1 changed"

  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute --non-interactive </dev/null
  [ "${status}" -eq 0 ]
  grep -q "local only" "${TEST_TMPDIR}/wt-merged/README.md"
}

@test "remove-merged: no terminal and no --non-interactive exits 1 and removes nothing" {
  load '../helpers/mocks'
  _status_fixture
  _install_no_powershell
  run run_script_at "${TEST_REPO_DIR}" worktree_manage.sh remove-merged --execute </dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--non-interactive"* ]]
  [ -d "${TEST_TMPDIR}/wt-merged" ]
}
