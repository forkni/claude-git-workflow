#!/usr/bin/env bats
# tests/integration/repo_state.bats - Integration tests for repo_state.sh
# Runs: bats tests/integration/repo_state.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  _g checkout --quiet development
}

teardown() {
  cleanup_test_repo
}

# ── helpers ───────────────────────────────────────────────────────────────────

_g() { git -C "${TEST_REPO_DIR}" "$@"; }

# _val <key>: the value of a key=value line in ${output}
_val() { printf '%s\n' "${output}" | grep -m1 "^$1=" | cut -d= -f2-; }

# _assert_kv <key> <expected>
_assert_kv() {
  local got
  got="$(_val "$1")"
  if [[ "${got}" != "$2" ]]; then
    echo "expected $1='$2', got '${got}'; output was:" >&2
    echo "${output}" >&2
    return 1
  fi
}

# _assert_suggestion <n> <label>
_assert_suggestion() {
  _assert_kv suggestion "$1" && _assert_kv suggestion_label "$2"
}

# _commit_file <file> <content> <message>: write a file and commit it
_commit_file() {
  printf '%s\n' "$2" >"${TEST_REPO_DIR}/$1"
  _g add "$1"
  _g commit --quiet -m "$3"
}

# _push_then_rewind: publish one commit, then drop it locally -> upstream is 1 ahead of us
_push_then_rewind() {
  _commit_file DEV.md "upstream change" "feat: upstream change"
  _g push --quiet origin development
  _g reset --quiet --hard HEAD~1
}

# _conflict_topic: leave 'development' and 'topic' with conflicting edits to DEV.md
_conflict_topic() {
  _g checkout --quiet -b topic development
  _commit_file DEV.md "topic side" "feat: topic"
  _g checkout --quiet development
  _commit_file DEV.md "dev side" "feat: dev side"
  _g push --quiet origin development
}

# _json_ok: ${output} parses as JSON (jq or python); skips when neither works
_json_ok() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -e . >/dev/null
    return $?
  fi
  local py="" cand
  for cand in python python3; do
    if "${cand}" -c 'import sys' >/dev/null 2>&1; then
      py="${cand}"
      break
    fi
  done
  [ -n "${py}" ] || skip "neither jq nor python available to validate JSON"
  printf '%s' "$1" | "${py}" -c 'import json,sys; json.load(sys.stdin)'
}

_state() { run run_script repo_state.sh "$@"; }

# ── usage ─────────────────────────────────────────────────────────────────────

@test "--help exits 0 and documents the keys" {
  _state --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" == *"suggestion_label"* ]]
}

@test "-h exits 0" {
  _state -h
  [ "${status}" -eq 0 ]
}

@test "unknown flag exits 2" {
  _state --foobar
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Unknown flag"* ]]
}

# ── preconditions ─────────────────────────────────────────────────────────────

@test "outside a repository exits 1 with error=not-a-repo" {
  local plain="${TEST_TMPDIR}/plain"
  mkdir -p "${plain}"
  run run_script_at "${plain}" repo_state.sh
  [ "${status}" -eq 1 ]
  _assert_kv inside_repo 0
  _assert_kv error not-a-repo
  [[ "${output}" == *"[ERROR]"* ]]
}

@test "outside a repository --json still reports the error as JSON" {
  local plain="${TEST_TMPDIR}/plain"
  mkdir -p "${plain}"
  run --separate-stderr run_script_at "${plain}" repo_state.sh --json
  [ "${status}" -eq 1 ]
  [[ "${output}" == *'"error":"not-a-repo"'* ]]
  _json_ok "${output}"
}

@test "a repository without commits exits 1 with error=no-commits" {
  local fresh="${TEST_TMPDIR}/fresh"
  git init --quiet "${fresh}"
  run run_script_at "${fresh}" repo_state.sh
  [ "${status}" -eq 1 ]
  _assert_kv inside_repo 1
  _assert_kv error no-commits
}

@test "detached HEAD is reported, exits 0, suggests row 2" {
  _g checkout --quiet --detach
  _state
  [ "${status}" -eq 0 ]
  _assert_kv detached 1
  _assert_kv branch ""
  _assert_suggestion 2 detached-head
}

@test "works from a subdirectory of the repository" {
  mkdir -p "${TEST_REPO_DIR}/sub/dir"
  run run_script_at "${TEST_REPO_DIR}/sub/dir" repo_state.sh
  [ "${status}" -eq 0 ]
  _assert_kv branch development
}

# ── suggestion table: one test per row ────────────────────────────────────────

@test "row 1: merge conflict suggests finishing the operation" {
  _conflict_topic
  _g merge topic >/dev/null 2>&1 || true
  _state
  [ "${status}" -eq 0 ]
  _assert_kv conflicted 1
  _assert_kv in_progress merge
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: stopped rebase is reported as rebase (and as detached)" {
  _conflict_topic
  _g rebase topic >/dev/null 2>&1 || true
  _state
  [ "${status}" -eq 0 ]
  _assert_kv in_progress rebase
  _assert_kv detached 1
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: stopped cherry-pick is reported as cherry-pick" {
  _conflict_topic
  _g cherry-pick topic >/dev/null 2>&1 || true
  _state
  [ "${status}" -eq 0 ]
  _assert_kv in_progress cherry-pick
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: stopped revert is reported as revert" {
  _conflict_topic
  _g revert --no-edit HEAD~1 >/dev/null 2>&1 || true
  _state
  [ "${status}" -eq 0 ]
  _assert_kv in_progress revert
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: a conflict-free paused merge still counts as in progress" {
  _g checkout --quiet -b other development
  _commit_file OTHER.md "other" "feat: other"
  _g checkout --quiet development
  _g merge --no-commit --no-ff other >/dev/null 2>&1
  _state
  [ "${status}" -eq 0 ]
  _assert_kv conflicted 0
  _assert_kv in_progress merge
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: an active bisect is reported as bisect" {
  _g bisect start >/dev/null 2>&1
  _state
  [ "${status}" -eq 0 ]
  _assert_kv in_progress bisect
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: in-progress operation outranks uncommitted work" {
  _conflict_topic
  _g merge topic >/dev/null 2>&1 || true
  echo "extra" >"${TEST_REPO_DIR}/extra.txt"
  _state
  _assert_suggestion 1 finish-in-progress
}

@test "row 1: a merge in a linked worktree is detected" {
  _conflict_topic
  local wt="${TEST_TMPDIR}/linked"
  _g worktree add --quiet -b wtbranch "${wt}" development
  git -C "${wt}" merge topic >/dev/null 2>&1 || true
  run run_script_at "${wt}" repo_state.sh
  [ "${status}" -eq 0 ]
  _assert_kv in_progress merge
  _assert_suggestion 1 finish-in-progress
}

@test "row 2: detached HEAD outranks uncommitted work" {
  _g checkout --quiet --detach
  echo "extra" >"${TEST_REPO_DIR}/extra.txt"
  _state
  _assert_suggestion 2 detached-head
}

@test "row 3: uncommitted path the upstream also changed suggests reconcile" {
  _push_then_rewind
  echo "local edit" >>"${TEST_REPO_DIR}/DEV.md"
  _state
  [ "${status}" -eq 0 ]
  _assert_kv behind 1
  _assert_kv unstaged 1
  _assert_kv upstream_overlap 1
  _assert_suggestion 3 reconcile-upstream
}

@test "row 3: an untracked file the upstream added also counts as overlap" {
  _commit_file NEWFILE.md "from upstream" "feat: add newfile"
  _g push --quiet origin development
  _g reset --quiet --hard HEAD~1
  echo "mine" >"${TEST_REPO_DIR}/NEWFILE.md"
  _state
  _assert_kv upstream_overlap 1
  _assert_suggestion 3 reconcile-upstream
}

@test "row 4: unstaged edit suggests commit" {
  echo "edit" >>"${TEST_REPO_DIR}/DEV.md"
  _state
  _assert_kv unstaged 1
  _assert_kv clean 0
  _assert_suggestion 4 commit
}

@test "row 4: staged change suggests commit" {
  echo "staged" >"${TEST_REPO_DIR}/staged.txt"
  _g add staged.txt
  _state
  _assert_kv staged 1
  _assert_suggestion 4 commit
}

@test "row 4: untracked file alone suggests commit" {
  echo "new" >"${TEST_REPO_DIR}/new.txt"
  _state
  _assert_kv untracked 1
  _assert_suggestion 4 commit
}

@test "row 4: uncommitted work not touched upstream beats behind (no overlap)" {
  _push_then_rewind
  echo "unrelated" >"${TEST_REPO_DIR}/unrelated.txt"
  _state
  _assert_kv behind 1
  _assert_kv upstream_overlap 0
  _assert_suggestion 4 commit
}

@test "row 5: ahead only suggests push" {
  _commit_file DEV.md "ahead" "feat: ahead"
  _state
  _assert_kv ahead 1
  _assert_kv behind 0
  _assert_suggestion 5 push
}

@test "row 6: behind only suggests pull" {
  _push_then_rewind
  _state
  _assert_kv ahead 0
  _assert_kv behind 1
  _assert_suggestion 6 pull
}

@test "row 7: ahead and behind suggests sync" {
  _push_then_rewind
  _commit_file OTHER.md "local" "feat: local"
  _state
  _assert_kv ahead 1
  _assert_kv behind 1
  _assert_suggestion 7 sync-diverged
}

@test "row 8: no upstream suggests publishing the branch" {
  _g checkout --quiet -b feature development
  _state
  _assert_kv upstream ""
  _assert_kv ahead 0
  _assert_suggestion 8 publish-branch
}

@test "row 9: clean, in sync, commits not on target suggests merge/PR" {
  _state
  _assert_kv upstream origin/development
  _assert_kv target main
  _assert_kv unmerged_to_target 1
  _assert_suggestion 9 merge-or-pr
}

@test "row 9: the target branch itself is never suggested for merging" {
  _g checkout --quiet main
  _commit_file README.md "advanced main" "feat: main moves"
  _g push --quiet origin main
  _state
  _assert_kv branch main
  _assert_suggestion 11 clean
}

@test "row 9: honours CGW_TARGET_BRANCH" {
  CGW_TARGET_BRANCH=development run run_script repo_state.sh
  _assert_kv target development
  _assert_kv unmerged_to_target 0
  _assert_suggestion 11 clean
}

@test "row 9: prefers the remote's HEAD as the target" {
  _g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  _state
  _assert_kv target origin/main
  _assert_kv unmerged_to_target 1
  _assert_suggestion 9 merge-or-pr
}

@test "row 10: clean tree with a stash suggests restoring it" {
  _g checkout --quiet main
  echo "wip" >>"${TEST_REPO_DIR}/README.md"
  _g stash --quiet
  _state
  _assert_kv stash 1
  _assert_kv clean 1
  _assert_suggestion 10 restore-stash
}

@test "row 11: everything clean and in sync suggests nothing" {
  _g checkout --quiet main
  _state
  [ "${status}" -eq 0 ]
  _assert_kv clean 1
  _assert_kv stash 0
  _assert_kv ahead 0
  _assert_kv behind 0
  _assert_suggestion 11 clean
}

# ── report details ────────────────────────────────────────────────────────────

@test "reports branch, upstream and head" {
  _state
  _assert_kv inside_repo 1
  _assert_kv branch development
  _assert_kv detached 0
  _assert_kv upstream origin/development
  _assert_kv in_progress none
  [[ -n "$(_val head)" ]]
  [[ -n "$(_val repo_root)" ]]
}

@test "counts staged, unstaged and untracked paths separately" {
  echo "s" >"${TEST_REPO_DIR}/staged.txt"
  _g add staged.txt
  echo "u" >>"${TEST_REPO_DIR}/DEV.md"
  echo "t1" >"${TEST_REPO_DIR}/untracked1.txt"
  echo "t2" >"${TEST_REPO_DIR}/untracked2.txt"
  _state
  _assert_kv staged 1
  _assert_kv unstaged 1
  _assert_kv untracked 2
}

@test "a path both staged and modified again counts in both" {
  echo "v1" >>"${TEST_REPO_DIR}/DEV.md"
  _g add DEV.md
  echo "v2" >>"${TEST_REPO_DIR}/DEV.md"
  _state
  _assert_kv staged 1
  _assert_kv unstaged 1
}

@test "gitignored files are not counted as untracked" {
  echo "ignored.txt" >"${TEST_REPO_DIR}/.gitignore"
  _g add .gitignore
  _g commit --quiet -m "chore: ignore"
  echo "x" >"${TEST_REPO_DIR}/ignored.txt"
  _state
  _assert_kv untracked 0
  _assert_kv clean 1
}

@test "untracked files with spaces in the name are counted once" {
  echo "x" >"${TEST_REPO_DIR}/has space.txt"
  _state
  _assert_kv untracked 1
}

@test "a staged rename counts as one staged path" {
  _g mv DEV.md RENAMED.md
  _state
  _assert_kv staged 1
  _assert_kv unstaged 0
}

@test "local-only files are counted via CGW_LOCAL_FILES" {
  echo "notes" >"${TEST_REPO_DIR}/LOCAL.md"
  mkdir -p "${TEST_REPO_DIR}/scratch"
  echo "x" >"${TEST_REPO_DIR}/scratch/a.txt"
  echo "y" >"${TEST_REPO_DIR}/shared.txt"
  CGW_LOCAL_FILES="LOCAL.md scratch/ missing.txt" run run_script repo_state.sh
  _assert_kv untracked 3
  _assert_kv local_only_dirty 2
  _assert_kv local_only_present 2
}

@test "CGW_LOCAL_FILES_EXEMPT removes a path from the local-only count" {
  echo "notes" >"${TEST_REPO_DIR}/LOCAL.md"
  CGW_LOCAL_FILES="LOCAL.md" CGW_LOCAL_FILES_EXEMPT="LOCAL.md" run run_script repo_state.sh
  _assert_kv local_only_dirty 0
}

@test "an upstream whose ref is gone is flagged and does not suggest publishing" {
  _g checkout --quiet -b gone development
  _g push --quiet -u origin gone
  _g update-ref -d refs/remotes/origin/gone
  _state
  [ "${status}" -eq 0 ]
  _assert_kv upstream_gone 1
  _assert_kv ahead 0
}

@test "stash entries are counted" {
  echo "one" >>"${TEST_REPO_DIR}/DEV.md"
  _g stash --quiet
  echo "two" >>"${TEST_REPO_DIR}/DEV.md"
  _g stash --quiet
  _state
  _assert_kv stash 2
}

# ── output formats ────────────────────────────────────────────────────────────

@test "default output is key=value lines in a stable order" {
  _state
  [ "${status}" -eq 0 ]
  local keys
  keys="$(printf '%s\n' "${output}" | cut -d= -f1 | tr '\n' ' ')"
  [ "${keys}" = "inside_repo repo_root branch detached head upstream upstream_gone ahead behind staged unstaged untracked conflicted in_progress stash local_only_dirty local_only_present target unmerged_to_target upstream_overlap clean suggestion suggestion_label " ]
}

@test "--json prints one valid JSON object" {
  echo "edit" >>"${TEST_REPO_DIR}/DEV.md"
  _state --json
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "${output}" == "{"*"}" ]]
  [[ "${output}" == *'"suggestion":4'* ]]
  [[ "${output}" == *'"suggestion_label":"commit"'* ]]
  [[ "${output}" == *'"unstaged":1'* ]]
  _json_ok "${output}"
}

@test "--json is valid for a branch name with quotes and unicode" {
  _g checkout --quiet -b "feat/it's-caf$(printf '\303\251')" development
  _state --json
  [ "${status}" -eq 0 ]
  _json_ok "${output}"
}

@test "--json key set matches the key=value key set" {
  _state
  local kv_keys
  kv_keys="$(printf '%s\n' "${output}" | cut -d= -f1 | tr '\n' ' ')"
  _state --json
  local json_keys
  json_keys="$(printf '%s' "${output}" | grep -o '"[a-z_]*":' | tr -d '":' | tr '\n' ' ')"
  [ "${kv_keys}" = "${json_keys}" ]
}

@test "_json_escape escapes quotes, backslashes and control characters" {
  local fn py="" cand
  fn="$(extract_shell_function "${CGW_PROJECT_ROOT}/scripts/git/repo_state.sh" _json_escape)"
  local escaped
  escaped="$(bash -c "${fn}"$'\n''_json_escape "$1"' _ $'a"b\\c\td\ne')"
  [ "${escaped}" = 'a\"b\\c\td\ne' ]
  for cand in python python3; do
    if "${cand}" -c 'import sys' >/dev/null 2>&1; then
      py="${cand}"
      break
    fi
  done
  [ -n "${py}" ] || skip "python not available for the round-trip check"
  local back
  back="$(printf '"%s"' "${escaped}" | "${py}" -c 'import json,sys; sys.stdout.buffer.write(json.load(sys.stdin).encode())')"
  [ "${back}" = $'a"b\\c\td\ne' ]
}

# ── read-only guarantees ──────────────────────────────────────────────────────

# _fingerprint: everything a state probe could disturb
_fingerprint() {
  {
    GIT_OPTIONAL_LOCKS=0 git -C "${TEST_REPO_DIR}" status --porcelain=v2 --branch --untracked-files=all
    git -C "${TEST_REPO_DIR}" for-each-ref
    git -C "${TEST_REPO_DIR}" stash list
    cksum "${TEST_REPO_DIR}/.git/index"
    stat -c %Y "${TEST_REPO_DIR}/.git/index" 2>/dev/null || stat -f %m "${TEST_REPO_DIR}/.git/index"
    (cd "${TEST_REPO_DIR}/.git" && find . -type f | sort)
    (cd "${TEST_REPO_DIR}" && find . -path ./.git -prune -o -type f -print | sort)
  } 2>&1
}

@test "makes no changes: status, refs, index, .git tree and worktree are untouched" {
  # Without this, git status may rewrite a stale index; the script must stop that itself.
  unset GIT_OPTIONAL_LOCKS
  echo "staged" >"${TEST_REPO_DIR}/staged.txt"
  _g add staged.txt
  echo "edit" >>"${TEST_REPO_DIR}/DEV.md"
  echo "new" >"${TEST_REPO_DIR}/new.txt"
  _g stash list >/dev/null
  # Make every tracked file's stat data stale so an index refresh would be tempting.
  sleep 1
  touch "${TEST_REPO_DIR}/README.md"
  local before after
  before="$(_fingerprint)"
  _state
  [ "${status}" -eq 0 ]
  _state --json
  [ "${status}" -eq 0 ]
  after="$(_fingerprint)"
  [ "${before}" = "${after}" ]
  [ ! -d "${TEST_REPO_DIR}/logs" ]
}

@test "makes no changes during a paused merge" {
  unset GIT_OPTIONAL_LOCKS
  _conflict_topic
  _g merge topic >/dev/null 2>&1 || true
  local before after
  before="$(_fingerprint)"
  _state
  [ "${status}" -eq 0 ]
  after="$(_fingerprint)"
  [ "${before}" = "${after}" ]
}

@test "needs no network: works with an unreachable remote" {
  _g remote set-url origin "${TEST_TMPDIR}/does-not-exist.git"
  _commit_file DEV.md "ahead" "feat: ahead"
  _state
  [ "${status}" -eq 0 ]
  _assert_kv ahead 1
  _assert_suggestion 5 push
}
