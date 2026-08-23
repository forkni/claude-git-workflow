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

@test "link copies scripts/git and .githooks into a linked worktree" {
  [ ! -e "${TEST_WORKTREE_DIR}/scripts/git" ]
  [ ! -e "${TEST_WORKTREE_DIR}/.githooks" ]

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK]   linked scripts/git"* ]]
  [[ "${output}" == *"[OK]   linked .githooks"* ]]
  [ -e "${TEST_WORKTREE_DIR}/scripts/git/_common.sh" ]
  [ -e "${TEST_WORKTREE_DIR}/.githooks/pre-commit" ]
}

@test "link is idempotent — re-running reports already linked, doesn't fail" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link

  run run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[OK]   scripts/git already linked"* ]]
  [[ "${output}" == *"[OK]   .githooks already linked"* ]]
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
  # production code does (_cgw_link_dir: NTFS junction on MINGW/MSYS/CYGWIN,
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

# ── remove (A3: cannot delete the main worktree's tooling) ─────────────────

@test "remove: unlinks scripts/git and .githooks before removing; main worktree survives" {
  run_script_at "${TEST_WORKTREE_DIR}" worktree_manage.sh link
  [ -e "${TEST_WORKTREE_DIR}/scripts/git/_common.sh" ]

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
