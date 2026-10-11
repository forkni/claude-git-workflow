#!/usr/bin/env bats
# tests/integration/verify_ci.bats - Integration tests for verify_ci.sh (the post-push CI gate)
# Runs: bats tests/integration/verify_ci.bats
#
# gh is mocked (tests/helpers/mocks.bash): `gh run list` / `gh pr checks --json` print the
# post-jq TSV rows the script expects, and CGW_CI_TEST_SLEEP=0 makes every wait instant
# while the script's virtual clock still enforces the deadlines.

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  # verify_ci.sh passes gh an explicit --repo resolved from origin's github.com URL;
  # redirect the fake URL to the local bare remote so git ls-remote still works.
  local fake_url="https://github.com/forkni/claude-git-workflow.git"
  git -C "${TEST_REPO_DIR}" config remote.origin.url "${fake_url}"
  git -C "${TEST_REPO_DIR}" config "url.${TEST_REMOTE_DIR}.insteadOf" "${fake_url}"
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  GH_LOG="${MOCK_BIN_DIR}/gh.log"
  DEV_SHA=$(git -C "${TEST_REPO_DIR}" rev-parse development)
  export CGW_CI_TEST_SLEEP=0
}

teardown() {
  cleanup_test_repo
}

_run_verify_ci() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_NON_INTERACTIVE=1
    bash "${CGW_PROJECT_ROOT}/scripts/git/verify_ci.sh" "$@"
  )
}

# Post-jq rows for `gh run list`: id, workflow, event, status, conclusion, url
RUN_BP_OK='101\tBranch Protection\tpush\tcompleted\tsuccess\thttps://github.com/forkni/claude-git-workflow/actions/runs/101'
RUN_BP_BUSY='101\tBranch Protection\tpush\tin_progress\t\thttps://github.com/forkni/claude-git-workflow/actions/runs/101'
RUN_DOCS_OK='102\tDocs Validation\tpush\tcompleted\tsuccess\thttps://github.com/forkni/claude-git-workflow/actions/runs/102'
RUN_DOCS_FAIL='102\tDocs Validation\tpush\tcompleted\tfailure\thttps://github.com/forkni/claude-git-workflow/actions/runs/102'

# Post-jq rows for `gh pr checks --json`: bucket, workflow, name, link
CHECK_BP_PASS='pass\tBranch Protection\tvalidate\thttps://github.com/forkni/claude-git-workflow/actions/runs/201'
CHECK_BP_FAIL='fail\tBranch Protection\tvalidate\thttps://github.com/forkni/claude-git-workflow/actions/runs/201'
CHECK_BP_PENDING='pending\tBranch Protection\tvalidate\thttps://github.com/forkni/claude-git-workflow/actions/runs/201'
CHECK_DOCS_PASS='pass\tDocs Validation\tlint\thttps://github.com/forkni/claude-git-workflow/actions/runs/202'

# _push_feature_head -- push branch `feature` (the mock's default headRefName) to the bare
# remote with one extra commit; prints its SHA.
_push_feature_head() {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature development
  echo "catch-up" >"${TEST_REPO_DIR}/catchup.txt"
  git -C "${TEST_REPO_DIR}" add catchup.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: catch-up"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature
  git -C "${TEST_REPO_DIR}" rev-parse HEAD
  git -C "${TEST_REPO_DIR}" checkout --quiet development
}

# ── Usage ─────────────────────────────────────────────────────────────────────

@test "neither --branch nor --pr is a usage error: exit 1, no CI: line" {
  install_mock_gh
  run --separate-stderr _run_verify_ci
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"CI:"* ]]
  [[ "${stderr}" == *"[ERROR] One of --branch"* ]]
}

@test "--branch and --pr together is a usage error" {
  install_mock_gh
  run --separate-stderr _run_verify_ci --branch development --pr 42
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"CI:"* ]]
  [[ "${stderr}" == *"mutually exclusive"* ]]
}

@test "--pr, --sha, --timeout and --poll validate their values" {
  install_mock_gh
  run --separate-stderr _run_verify_ci --pr abc
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"--pr requires a PR number"* ]]
  run --separate-stderr _run_verify_ci --branch development --sha abc123
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"--sha requires a full 40-hex"* ]]
  run --separate-stderr _run_verify_ci --branch development --timeout soon
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"--timeout requires"* ]]
  run --separate-stderr _run_verify_ci --branch development --poll x
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"--poll requires"* ]]
}

# ── Applicability probe (exit 3) ──────────────────────────────────────────────

@test "CGW_CI_VERIFY=0 is not applicable: exit 3 without calling gh" {
  install_mock_gh
  export CGW_CI_VERIFY=0
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 3 ]
  [ "${output}" == "CI: not applicable (CGW_CI_VERIFY=0)" ]
  [ ! -f "${GH_LOG}" ]
}

@test "an unusable gh CLI is not applicable: exit 3" {
  hide_gh # a gh that fails every call (command -v still finds it, so this is the auth path)
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 3 ]
  [[ "${output}" == "CI: not applicable (gh CLI not "* ]]
}

@test "gh present but not authenticated is not applicable: exit 3" {
  install_mock_gh_no_auth
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"CI: not applicable (gh CLI not authenticated"* ]]
}

@test "a non-github.com remote is not applicable: exit 3" {
  install_mock_gh
  git -C "${TEST_REPO_DIR}" config remote.origin.url "${TEST_REMOTE_DIR}"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"CI: not applicable (origin is not a github.com remote)"* ]]
}

# ── Branch mode ───────────────────────────────────────────────────────────────

@test "branch mode: all runs green exits 0 with CI: green <remote tip>" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_OK}\n${RUN_DOCS_OK}"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${DEV_SHA}" ]
  grep -q -- "run list --repo forkni/claude-git-workflow --commit ${DEV_SHA} --branch development" "${GH_LOG}"
}

@test "branch mode: --sha judges that commit instead of the remote tip" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_OK}"
  local sha=3333333333333333333333333333333333333333
  run --separate-stderr _run_verify_ci --branch development --sha "${sha}"
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${sha}" ]
  grep -q -- "--commit ${sha} --branch development" "${GH_LOG}"
}

@test "branch mode: a failed run exits 1 with one CI: red line per failure" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_OK}\n${RUN_DOCS_FAIL}"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 1 ]
  [ "${output}" == "CI: red Docs Validation https://github.com/forkni/claude-git-workflow/actions/runs/102" ]
}

@test "branch mode: pending runs are re-listed until they complete" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_BUSY}\n${RUN_DOCS_OK}"
  export MOCK_GH_RUNS_AFTER=2
  export MOCK_GH_RUNS_LATER="${RUN_BP_OK}\n${RUN_DOCS_OK}"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${DEV_SHA}" ]
  [ "$(grep -c 'run list' "${GH_LOG}")" -ge 3 ]
}

@test "branch mode: a run still pending at the deadline is unverified: exit 2" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_BUSY}"
  export CGW_CI_TIMEOUT_SECONDS=30
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- timed out after "*"s with 1 run(s) still pending"* ]]
}

@test "branch mode: --timeout overrides CGW_CI_TIMEOUT_SECONDS" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_BUSY}"
  run --separate-stderr _run_verify_ci --branch development --timeout 20 --poll 10
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- timed out after "* ]]
}

@test "branch mode: nothing registers while workflows are active is unverified: exit 2" {
  install_mock_gh
  export MOCK_GH_WORKFLOWS="Branch Protection\nDocs Validation"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- no run registered on ${DEV_SHA:0:7} (development) within 30s" ]]
  grep -q 'workflow list --repo forkni/claude-git-workflow' "${GH_LOG}"
}

@test "branch mode: nothing registers and no active workflow is not applicable: exit 3" {
  install_mock_gh
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 3 ]
  [ "${output}" == "CI: no workflow triggered (no active workflow in forkni/claude-git-workflow)" ]
}

@test "branch mode: a required workflow that never registers is unverified: exit 2" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_OK}"
  export CGW_CI_REQUIRED_WORKFLOWS="Branch Protection, Docs Validation"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- required workflow(s) not registered on ${DEV_SHA:0:7}: Docs Validation" ]]
}

@test "branch mode: CGW_CI_REQUIRED_WORKFLOWS judges only the listed workflows" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_OK}\n${RUN_DOCS_FAIL}"
  export CGW_CI_REQUIRED_WORKFLOWS="Branch Protection"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${DEV_SHA}" ]
}

@test "branch mode: gh run list failing is unverified: exit 2" {
  install_mock_gh
  export MOCK_GH_RUN_LIST_EXIT=1
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- gh run list failed"* ]]
}

@test "branch mode: an unpushed branch is unverified: exit 2" {
  install_mock_gh
  run --separate-stderr _run_verify_ci --branch no-such-branch
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- could not resolve origin/no-such-branch"* ]]
}

@test "branch mode: stdout carries only CI: lines, progress goes to stderr" {
  install_mock_gh
  export MOCK_GH_RUNS="${RUN_BP_OK}"
  run --separate-stderr _run_verify_ci --branch development
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | grep -vc '^CI: ')" -eq 0 ]
  [[ "${stderr}" == *"[REGISTRATION]"* ]]
  [[ "${stderr}" == *"Repo: forkni/claude-git-workflow"* ]]
}

# ── PR mode ───────────────────────────────────────────────────────────────────

@test "PR mode: a head that never catches up with the pushed branch is unverified: exit 2" {
  install_mock_gh
  _push_feature_head >/dev/null
  export MOCK_GH_PR_42_HEADREFOID=2222222222222222222222222222222222222222
  export CGW_PR_HEAD_SYNC_SECONDS=2
  run --separate-stderr _run_verify_ci --pr 42
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- PR #42 head 2222222 has not caught up with pushed "* ]]
  ! grep -q 'pr checks' "${GH_LOG}"
}

@test "PR mode: all checks green exits 0 with CI: green <head>" {
  install_mock_gh
  local pushed
  pushed=$(_push_feature_head)
  export MOCK_GH_PR_42_HEADREFOID="${pushed}"
  export MOCK_GH_CHECKS_JSON="${CHECK_BP_PASS}\n${CHECK_DOCS_PASS}"
  run --separate-stderr _run_verify_ci --pr 42
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${pushed}" ]
  grep -q -- "pr checks 42 --repo forkni/claude-git-workflow --json bucket,workflow,name,link" "${GH_LOG}"
}

@test "PR mode: a failed check exits 1 with a CI: red line" {
  install_mock_gh
  local pushed
  pushed=$(_push_feature_head)
  export MOCK_GH_PR_42_HEADREFOID="${pushed}"
  export MOCK_GH_CHECKS_JSON="${CHECK_BP_FAIL}\n${CHECK_DOCS_PASS}"
  run --separate-stderr _run_verify_ci --pr 42
  [ "${status}" -eq 1 ]
  [ "${output}" == "CI: red Branch Protection https://github.com/forkni/claude-git-workflow/actions/runs/201" ]
}

@test "PR mode: pending checks are polled until they settle" {
  install_mock_gh
  local pushed
  pushed=$(_push_feature_head)
  export MOCK_GH_PR_42_HEADREFOID="${pushed}"
  export MOCK_GH_CHECKS_JSON="${CHECK_BP_PENDING}\n${CHECK_DOCS_PASS}"
  export MOCK_GH_CHECKS_JSON_AFTER=2
  export MOCK_GH_CHECKS_JSON_LATER="${CHECK_BP_PASS}\n${CHECK_DOCS_PASS}"
  run --separate-stderr _run_verify_ci --pr 42
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${pushed}" ]
}

@test "PR mode: a head that moves mid-watch is unverified with a --sha hint: exit 2" {
  install_mock_gh
  local pushed moved=2222222222222222222222222222222222222222
  pushed=$(_push_feature_head)
  export MOCK_GH_PR_42_HEADREFOID="${pushed}"
  export MOCK_GH_HEAD_CATCHUP_AFTER=1
  export MOCK_GH_HEAD_CATCHUP_SHA="${moved}"
  export MOCK_GH_CHECKS_JSON="${CHECK_BP_PENDING}"
  run --separate-stderr _run_verify_ci --pr 42
  [ "${status}" -eq 2 ]
  [ "${output}" == "CI: unverified -- PR #42 head moved to ${moved}; rerun with --sha ${moved}" ]
}

@test "PR mode: --sha pins the expected head (cross-repo PRs have no readable branch tip)" {
  install_mock_gh
  export MOCK_GH_PR_42_ISCROSSREPOSITORY=true
  local sha=1111111111111111111111111111111111111111 # the mock's default headRefOid
  export MOCK_GH_CHECKS_JSON="${CHECK_BP_PASS}"
  run --separate-stderr _run_verify_ci --pr 42 --sha "${sha}"
  [ "${status}" -eq 0 ]
  [ "${output}" == "CI: green ${sha}" ]
}

@test "PR mode: no checks appearing while workflows are active is unverified: exit 2" {
  install_mock_gh
  local pushed
  pushed=$(_push_feature_head)
  export MOCK_GH_PR_42_HEADREFOID="${pushed}"
  export MOCK_GH_WORKFLOWS="Branch Protection"
  export CGW_PR_CHECKS_APPEAR_SECONDS=10
  run --separate-stderr _run_verify_ci --pr 42
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- no check registered on PR #42 head ${pushed:0:7} within 10s" ]]
}

@test "PR mode: an unknown PR is unverified: exit 2" {
  install_mock_gh
  export MOCK_GH_PR_99_HEADREFOID=nope
  run --separate-stderr _run_verify_ci --pr 99
  [ "${status}" -eq 2 ]
  [[ "${output}" == "CI: unverified -- could not read PR #99"* ]]
}

# ── jq filters ────────────────────────────────────────────────────────────────

@test "_CI_RUNS_JQ keeps the newest run per workflow+event, oldest id first" {
  _require_jq
  local filter
  filter=$(sed -n "s/^readonly _CI_RUNS_JQ='\(.*\)'$/\1/p" "${CGW_PROJECT_ROOT}/scripts/git/verify_ci.sh")
  [ -n "${filter}" ]
  # jq on Windows emits CRLF; the script strips  from every gh result, so do the same here.
  run bash -c "jq -r '${filter}' '${CGW_PROJECT_ROOT}/tests/fixtures/gh_run_list.json' | tr -d '\r'"
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" == $'102\tDocs Validation\tpush\tin_progress\t\thttps://github.com/forkni/claude-git-workflow/actions/runs/102' ]
  [ "${lines[1]}" == $'103\tBranch Protection\tpull_request\tcompleted\tsuccess\thttps://github.com/forkni/claude-git-workflow/actions/runs/103' ]
  [ "${lines[2]}" == $'105\tBranch Protection\tpush\tcompleted\tsuccess\thttps://github.com/forkni/claude-git-workflow/actions/runs/105' ]
  [[ "${output}" != *"runs/101"* ]]
}

@test "_CI_CHECKS_JQ flattens gh pr checks JSON to bucket/workflow/name/link rows" {
  _require_jq
  local filter
  filter=$(sed -n "s/^readonly _CI_CHECKS_JQ='\(.*\)'$/\1/p" "${CGW_PROJECT_ROOT}/scripts/git/verify_ci.sh")
  [ -n "${filter}" ]
  run bash -c "jq -r '${filter}' <<<'[{\"bucket\":\"pass\",\"workflow\":\"Branch Protection\",\"name\":\"validate\",\"link\":\"https://x/1\",\"state\":\"SUCCESS\"}]' | tr -d '\r'"
  [ "${status}" -eq 0 ]
  [ "${output}" == $'pass\tBranch Protection\tvalidate\thttps://x/1' ]
}
