#!/usr/bin/env bats
# tests/integration/bisect_helper.bats - Integration tests for bisect_helper.sh
# Runs: bats tests/integration/bisect_helper.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Add several commits to make a meaningful bisect range
  for i in 1 2 3 4 5; do
    echo "v${i}" > "${TEST_REPO_DIR}/v${i}.txt"
    git -C "${TEST_REPO_DIR}" add "v${i}.txt"
    git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: commit ${i}"
  done
  # Tag the first commit in the range as a known good baseline
  git -C "${TEST_REPO_DIR}" tag "v0.1.0" HEAD~5
}

teardown() {
  cleanup_test_repo
}

# ── validation ────────────────────────────────────────────────────────────────

@test "--non-interactive without --run exits 1" {
  run run_script bisect_helper.sh --good HEAD~3 --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--run"* ]] || [[ "${output}" == *"requires"* ]]
}

@test "invalid --good ref exits 1" {
  run run_script bisect_helper.sh --good nonexistent-ref-xyz --non-interactive --run "true"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid"* ]] || [[ "${output}" == *"invalid"* ]]
}

# ── --abort ───────────────────────────────────────────────────────────────────

@test "--abort when no bisect in progress exits 0" {
  run run_script bisect_helper.sh --abort
  [ "${status}" -eq 0 ]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run shows plan without starting bisect" {
  run run_script bisect_helper.sh --good v0.1.0 --dry-run --non-interactive --run "true"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"Would run"* ]]
  # No bisect session started
  run ! git -C "${TEST_REPO_DIR}" bisect log
}

# ── auto-detect good ref ──────────────────────────────────────────────────────

@test "auto-detects semver tag as good ref when --good omitted" {
  run run_script bisect_helper.sh --dry-run --non-interactive --run "true"
  [ "${status}" -eq 0 ]
  # The auto-detected ref (v0.1.0) should appear in output
  [[ "${output}" == *"v0.1.0"* ]] || [[ "${output}" == *"Auto-detected"* ]]
}

# ── backup tag ────────────────────────────────────────────────────────────────

@test "automated bisect with --run creates backup tag" {
  # Use 'true' as run command so bisect immediately finds no "bad" commit
  # and terminates (all commits "pass" the test)
  run run_script bisect_helper.sh --good v0.1.0 --non-interactive --run "true"
  # The script may exit 0 or non-zero depending on bisect result, but backup tag must exist
  git -C "${TEST_REPO_DIR}" tag | grep -q "^pre-bisect-"
}

# ── --continue ────────────────────────────────────────────────────────────────

@test "--continue when no bisect in progress shows status and exits 0" {
  run run_script bisect_helper.sh --continue
  [ "${status}" -eq 0 ]
}

# ── --run command is a shell command line (ST4) ───────────────────────────────

@test "--run honours quoted arguments containing spaces" {
  echo "x" > "${TEST_REPO_DIR}/bad file.txt"
  git -C "${TEST_REPO_DIR}" add "bad file.txt"
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: introduce bad file"
  echo "y" > "${TEST_REPO_DIR}/after.txt"
  git -C "${TEST_REPO_DIR}" add after.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: after bad file"

  run run_script bisect_helper.sh --good v0.1.0 --non-interactive --run 'test ! -e "bad file.txt"'
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"feat: introduce bad file"* ]]
}

@test "--run uses the running bash, not a PATH-first bash shim" {
  local shim_dir="${TEST_TMPDIR}/shimbin"
  mkdir -p "${shim_dir}"
  # Delegate script runs (run_script uses bash from PATH); only `bash -c` -- how
  # bisect's --run command is launched -- counts as shim use and fails.
  printf '#!/bin/sh\nif [ "$1" = "-c" ]; then echo SHIM_USED > "%s/shim_marker"; exit 1; fi\nexec "%s" "$@"\n' \
    "${TEST_TMPDIR}" "${BASH}" > "${shim_dir}/bash"
  chmod +x "${shim_dir}/bash"

  echo "x" > "${TEST_REPO_DIR}/bad.txt"
  git -C "${TEST_REPO_DIR}" add bad.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: introduce bad"
  echo "y" > "${TEST_REPO_DIR}/after.txt"
  git -C "${TEST_REPO_DIR}" add after.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: after bad"

  PATH="${shim_dir}:${PATH}" run run_script bisect_helper.sh --good v0.1.0 --non-interactive --run 'test ! -e bad.txt'
  [ ! -f "${TEST_TMPDIR}/shim_marker" ]
  [[ "${output}" == *"feat: introduce bad"* ]]
}
