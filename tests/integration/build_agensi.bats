#!/usr/bin/env bats
# tests/integration/build_agensi.bats - scripts/dev/build_agensi.sh (standalone skill zips)
# Runs: bats tests/integration/build_agensi.bats

bats_require_minimum_version 1.5.0

setup_file() {
  # Git for Windows ships neither; the build is a release-time step run on Linux or macOS.
  command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 || skip "zip/unzip not installed"
  export CGW_ROOT="${BATS_TEST_DIRNAME}/../.."
  export AGENSI_OUT="${BATS_FILE_TMPDIR}/agensi"
  # One build shared by every test: the checks inside the script are what most tests assert.
  bash "${CGW_ROOT}/scripts/dev/build_agensi.sh" --out "${AGENSI_OUT}" >"${BATS_FILE_TMPDIR}/build.log" 2>&1
  echo $? >"${BATS_FILE_TMPDIR}/build.rc"
}

@test "build_agensi: every skill builds and passes its portability checks" {
  run cat "${BATS_FILE_TMPDIR}/build.rc"
  [ "$output" = "0" ] || {
    cat "${BATS_FILE_TMPDIR}/build.log"
    false
  }
  while IFS= read -r name; do
    [ -f "${AGENSI_OUT}/${name}.zip" ]
    [ -f "${AGENSI_OUT}/${name}/SKILL.md" ]
  done < <(bash "${CGW_ROOT}/scripts/dev/build_agensi.sh" --list)
}

@test "build_agensi: each zip holds one folder named after its skill" {
  local zip name
  for zip in "${AGENSI_OUT}"/*.zip; do
    name="$(basename "${zip}" .zip)"
    run bash -c "unzip -Z1 '${zip}' | cut -d/ -f1 | sort -u"
    [ "$output" = "${name}" ]
  done
}

@test "build_agensi: knowledge-only skills ship no scripts" {
  [ ! -e "${AGENSI_OUT}/gitignore-and-local-config/scripts" ]
  [ ! -e "${AGENSI_OUT}/git-merge-conflict-resolution/scripts" ]
}

@test "build_agensi: safe-git-workflow ships executable scripts with skill-relative paths" {
  local dir="${AGENSI_OUT}/safe-git-workflow"
  [ -x "${dir}/scripts/commit_enhanced.sh" ]
  [ -f "${dir}/scripts/_common.sh" ]
  [ -f "${dir}/assets/cgw.conf.example" ]
  run grep -rl './scripts/git/' "${dir}" --include='*.md'
  [ -z "$output" ]
  # Scripts the zip leaves out are not documented as runnable.
  [ ! -e "${dir}/scripts/configure.sh" ]
  run grep -rlE '<skill-dir>/scripts/(configure|create_pr|merge_pr|verify_ci)\.sh' "${dir}"
  [ -z "$output" ]
}

@test "build_agensi: the packaged config disables the npx fallback; the repo's does not" {
  run grep -c '^CGW_MARKDOWNLINT_NPX_FALLBACK|0|' "${AGENSI_OUT}/safe-git-workflow/scripts/_config.sh"
  [ "$output" = "1" ]
  run grep -c '^CGW_MARKDOWNLINT_NPX_FALLBACK|1|' "${CGW_ROOT}/scripts/git/_config.sh"
  [ "$output" = "1" ]
}

@test "build_agensi: packaged commit_enhanced.sh commits from outside the repository tree" {
  local repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  cd "${repo}"
  git config user.email test@example.com
  git config user.name test
  echo a >a.txt
  git add a.txt
  git commit -q -m "chore: init"
  echo b >>a.txt
  run bash "${AGENSI_OUT}/safe-git-workflow/scripts/commit_enhanced.sh" --non-interactive --only a.txt "feat: change a"
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = "feat: change a" ]
}

@test "build_agensi: an unknown skill name fails the build" {
  run bash "${CGW_ROOT}/scripts/dev/build_agensi.sh" --out "${BATS_TEST_TMPDIR}/x" no-such-skill
  [ "$status" -eq 1 ]
}
