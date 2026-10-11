#!/usr/bin/env bash
# verify_ci.sh - Post-push CI gate: wait for the GitHub Actions runs on a pushed commit and
#                report one verdict
# Purpose: Replaces the manual "watch CI after every push" procedure (skill/references/
#          ci-verification.md) with one command. Branch mode judges the workflow runs that a
#          push to <branch> triggered on the pushed commit; PR mode judges the checks on a
#          pull request's head. Prints machine-readable `CI:` lines on stdout, progress on
#          stderr, and maps the outcome to the exit code.
# Usage: ./scripts/git/verify_ci.sh (--branch <name> | --pr <N>) [OPTIONS]
#
# Globals:
#   SCRIPT_DIR                 - Directory containing this script
#   PROJECT_ROOT               - Auto-detected git repo root (set by _config.sh)
#   CGW_REMOTE                 - Remote whose github.com owner/repo is passed to gh as --repo
#   CGW_CI_VERIFY              - 0 disables the gate (exit 3)
#   CGW_CI_TIMEOUT_SECONDS     - Overall deadline for pending runs/checks (default 900)
#   CGW_CI_POLL_INTERVAL       - Seconds between refreshes while runs are pending (default 15)
#   CGW_CI_REQUIRED_WORKFLOWS  - Comma-separated workflow names that must register and pass;
#                                empty = every workflow the push triggered
#   CGW_PR_HEAD_SYNC_SECONDS, CGW_PR_CHECKS_APPEAR_SECONDS, CGW_PR_CHECKS_POLL_SECONDS
#                              - PR-mode head catch-up / checks-appear waits (as merge_pr.sh)
#   logfile                    - Set by init_logging
# Arguments:
#   --branch <name>    Judge the runs triggered by the push to <name> (its remote tip, or --sha)
#   --pr <N>           Judge the checks on PR #N's head (waits for the head to match the pushed branch)
#   --sha <sha>        Commit to judge instead of the remote tip (40 hex chars; e.g. a tag's commit)
#   --timeout <s>      Override CGW_CI_TIMEOUT_SECONDS
#   --poll <s>         Override CGW_CI_POLL_INTERVAL
#   --non-interactive  Accepted for uniformity; the script never prompts
#   -h, --help         Show help
# Returns:
#   0  green: every judged run/check passed (or was skipped)     -> "CI: green <sha>"
#   1  red: at least one run/check failed, one "CI: red <workflow> <url>" line per failure
#      (also returned for a usage error, which prints [ERROR] and no CI: line)
#   2  unverified: timeout, gh failing mid-watch, PR head lagging or moving, required
#      workflow never registering, no run registering while workflows are active
#      -> "CI: unverified -- <reason>"
#   3  not applicable: CGW_CI_VERIFY=0, no gh/auth, non-GitHub remote, or no active workflow
#      -> "CI: not applicable (<why>)" / "CI: no workflow triggered"
#
# Prerequisites:
#   gh CLI installed and authenticated (gh auth login); otherwise exit 3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

# gh --jq filters (gojq built into gh: no external jq needed). Both print raw TSV rows.
# Runs: newest run per workflow+event (reruns replace their predecessor), oldest first.
readonly _CI_RUNS_JQ='group_by([.workflowName, .event]) | map(max_by(.databaseId)) | sort_by(.databaseId) | .[] | "\(.databaseId)\t\(.workflowName)\t\(.event)\t\(.status)\t\(.conclusion)\t\(.url)"'
# PR checks: one row per check with gh's own bucket (pass|fail|pending|skipping|cancel).
readonly _CI_CHECKS_JQ='.[] | "\(.bucket)\t\(.workflow)\t\(.name)\t\(.link)"'
# Active workflows of the repo (used to tell "no CI here" from "CI did not register").
readonly _CI_WORKFLOWS_JQ='.[] | select(.state == "active") | .name'

# Virtual clock: every wait advances it by the requested seconds, deadlines compare against
# it, and the real sleep can be shortened (CGW_CI_TEST_SLEEP=0 in tests) without changing
# how many polls a deadline allows.
_ci_clock=0

# _ci_sleep <seconds>
_ci_sleep() {
  local n="${1}" step
  step=$((n > 0 ? n : 1))
  _ci_clock=$((_ci_clock + step))
  local real="${CGW_CI_TEST_SLEEP:-${n}}"
  [[ "${real}" =~ ^[0-9]+$ && ${real} -gt 0 ]] && sleep "${real}"
  return 0
}

# _ci_note <text>  -- progress: stderr + log (stdout is reserved for CI: lines)
_ci_note() {
  echo "$*" | tee -a "${logfile}" >&2
}

# _ci_out <text>   -- a verdict line: stdout + log
_ci_out() {
  echo "$*" | tee -a "${logfile}"
}

# _pr_view <number> <json-field> <jq-expr> -- cgw_pr_view (_common.sh) against this repo
_pr_view() {
  cgw_pr_view "${ci_repo}" "$@"
}

# _ci_list_runs <sha> <branch> -- TSV rows id, workflow, event, status, conclusion, url
_ci_list_runs() {
  gh run list --repo "${ci_repo}" --commit "${1}" --branch "${2}" --limit 50 \
    --json databaseId,workflowName,event,status,conclusion,url --jq "${_CI_RUNS_JQ}" 2>>"${logfile}" | tr -d '\r'
}

# _ci_list_checks <pr> -- TSV rows bucket, workflow, name, link
_ci_list_checks() {
  gh pr checks "${1}" --repo "${ci_repo}" --json bucket,workflow,name,link --jq "${_CI_CHECKS_JQ}" 2>>"${logfile}" | tr -d '\r'
}

# _ci_active_workflows -- names of the repo's active workflows, one per line
_ci_active_workflows() {
  gh workflow list --repo "${ci_repo}" --json name,state --jq "${_CI_WORKFLOWS_JQ}" 2>>"${logfile}" | tr -d '\r'
}

# _ci_no_runs <what> -- nothing registered: exit 3 when the repo has no active workflow,
# else exit 2 (CI exists but nothing ran for this commit).
_ci_no_runs() {
  local what="${1}" active
  active=$(_ci_active_workflows) || active=""
  if [[ -z "${active}" ]]; then
    _ci_out "CI: no workflow triggered (no active workflow in ${ci_repo})"
    return 3
  fi
  _ci_note "Active workflows: $(echo "${active}" | paste -sd ',' -)"
  _ci_out "CI: unverified -- ${what}"
  return 2
}

# _ci_required_missing <runs-tsv> -- echoes the required workflow names absent from the rows
_ci_required_missing() {
  local rows="${1}" name present
  [[ -z "${ci_required}" ]] && return 0
  present=$(printf '%s\n' "${rows}" | awk -F'\t' '{print $2}')
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    grep -qxF -- "${name}" <<<"${present}" || echo "${name}"
  done <<<"${ci_required}"
}

# _ci_judged <runs-tsv> -- the rows to judge: all, or only the required workflows when set
_ci_judged() {
  local rows="${1}" row name
  [[ -z "${ci_required}" ]] && {
    printf '%s\n' "${rows}"
    return 0
  }
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    name=$(printf '%s' "${row}" | awk -F'\t' '{print $2}')
    grep -qxF -- "${name}" <<<"${ci_required}" && printf '%s\n' "${row}"
  done <<<"${rows}"
}

# _ci_run_state <status> <conclusion> -- green | red | pending | unknown
_ci_run_state() {
  local status="${1}" conclusion="${2}"
  if [[ "${status}" != "completed" ]]; then
    echo pending
    return 0
  fi
  case "${conclusion}" in
    success | skipped | neutral) echo green ;;
    failure | cancelled | timed_out | startup_failure | action_required) echo red ;;
    *) echo unknown ;;
  esac
}

# _ci_check_state <bucket> -- green | red | pending | unknown
_ci_check_state() {
  case "${1}" in
    pass | skipping) echo green ;;
    fail | cancel) echo red ;;
    pending) echo pending ;;
    *) echo unknown ;;
  esac
}

# _ci_settle <section> <green-sha> <noun> <where> -- one verdict round over the rows the
# caller just parsed into red_lines / pending / unknown_line (its locals, visible here
# through bash's dynamic scoping, as are its timeout and poll). On a verdict it prints
# the CI: line, closes the log section and returns 0 green, 1 red or 2 unverified; while
# something is still pending and the deadline holds it notes the wait, sleeps one poll
# interval and returns 10, so the caller re-lists and calls again.
_ci_settle() {
  local section="${1}" green_sha="${2}" noun="${3}" where="${4}" line
  if [[ ${#red_lines[@]} -gt 0 ]]; then
    for line in "${red_lines[@]}"; do _ci_out "${line}"; done
    log_section_end "${section}" "${logfile}" "1" >&2
    return 1
  fi
  if [[ -n "${unknown_line}" ]]; then
    _ci_out "CI: unverified -- ${unknown_line}"
    log_section_end "${section}" "${logfile}" "1" >&2
    return 2
  fi
  if [[ ${pending} -eq 0 ]]; then
    _ci_out "CI: green ${green_sha}"
    log_section_end "${section}" "${logfile}" "0" >&2
    return 0
  fi
  if [[ ${_ci_clock} -ge ${timeout} ]]; then
    _ci_out "CI: unverified -- timed out after ${_ci_clock}s with ${pending} ${noun} still pending on ${where}"
    log_section_end "${section}" "${logfile}" "1" >&2
    return 2
  fi
  _ci_note "${pending} ${noun} pending on ${where} (${_ci_clock}/${timeout}s)"
  _ci_sleep "${poll}"
  return 10
}

# _ci_branch_mode <branch> <sha>
_ci_branch_mode() {
  local branch="${1}" sha="${2}"
  local timeout="${CGW_CI_TIMEOUT_SECONDS:-900}" poll="${CGW_CI_POLL_INTERVAL:-15}"
  local rows waited=0

  # (1) Registration: GitHub needs a few seconds after a push before runs are listable.
  log_section_start "REGISTRATION" "${logfile}" >&2
  rows=$(_ci_list_runs "${sha}" "${branch}") || {
    _ci_out "CI: unverified -- gh run list failed for ${ci_repo} (see ${logfile})"
    return 2
  }
  while [[ -z "${rows}" && ${waited} -lt 30 ]]; do
    _ci_note "No run on ${sha:0:7} yet -- waiting for GitHub to register the push (${waited}/30s)"
    _ci_sleep 3
    waited=$((waited + 3))
    rows=$(_ci_list_runs "${sha}" "${branch}") || {
      _ci_out "CI: unverified -- gh run list failed for ${ci_repo} (see ${logfile})"
      return 2
    }
  done
  if [[ -z "${rows}" ]]; then
    _ci_no_runs "no run registered on ${sha:0:7} (${branch}) within ${waited}s"
    return $?
  fi

  # Settle: several workflows register independently, so wait until the set of run ids is
  # unchanged for 10s and every required workflow is present (cap 60s).
  local ids prev_ids stable=0 settle=0 missing
  prev_ids=$(printf '%s\n' "${rows}" | awk -F'\t' '{print $1}' | sort | paste -sd ',' -)
  missing=$(_ci_required_missing "${rows}")
  while [[ ${stable} -lt 10 || -n "${missing}" ]]; do
    if [[ ${settle} -ge 60 ]]; then
      if [[ -n "${missing}" ]]; then
        _ci_out "CI: unverified -- required workflow(s) not registered on ${sha:0:7}: $(echo "${missing}" | paste -sd ',' -)"
        return 2
      fi
      break
    fi
    _ci_sleep 3
    settle=$((settle + 3))
    rows=$(_ci_list_runs "${sha}" "${branch}") || {
      _ci_out "CI: unverified -- gh run list failed for ${ci_repo} (see ${logfile})"
      return 2
    }
    ids=$(printf '%s\n' "${rows}" | awk -F'\t' '{print $1}' | sort | paste -sd ',' -)
    if [[ "${ids}" == "${prev_ids}" ]]; then
      stable=$((stable + 3))
    else
      stable=0
      prev_ids="${ids}"
    fi
    missing=$(_ci_required_missing "${rows}")
  done
  _ci_note "Runs on ${sha:0:7}:"
  printf '%s\n' "${rows}" | awk -F'\t' '{printf "  #%s %s (%s) %s %s\n", $1, $2, $3, $4, $5}' | tee -a "${logfile}" >&2
  log_section_end "REGISTRATION" "${logfile}" "0" >&2

  # (2) Watch: re-list until every judged run completed; the first red verdict stops.
  log_section_start "WATCH" "${logfile}" >&2
  local judged id name event status conclusion url state rc
  local -a red_lines
  local pending unknown_line
  while :; do
    judged=$(_ci_judged "${rows}")
    if [[ -z "${judged}" ]]; then
      _ci_out "CI: unverified -- runs on ${sha:0:7} disappeared mid-watch"
      log_section_end "WATCH" "${logfile}" "1" >&2
      return 2
    fi
    red_lines=()
    pending=0
    unknown_line=""
    while IFS=$'\t' read -r id name event status conclusion url; do
      [[ -z "${id}" ]] && continue
      state=$(_ci_run_state "${status}" "${conclusion}")
      case "${state}" in
        red) red_lines+=("CI: red ${name} ${url}") ;;
        pending) pending=$((pending + 1)) ;;
        unknown) [[ -z "${unknown_line}" ]] && unknown_line="run #${id} ${name} (${event}) concluded '${conclusion}'" ;;
      esac
    done <<<"${judged}"
    _ci_settle "WATCH" "${sha}" "run(s)" "${sha:0:7}"
    rc=$?
    [[ ${rc} -ne 10 ]] && return "${rc}"
    rows=$(_ci_list_runs "${sha}" "${branch}") || {
      _ci_out "CI: unverified -- gh run list failed for ${ci_repo} (see ${logfile})"
      log_section_end "WATCH" "${logfile}" "1" >&2
      return 2
    }
  done
}

# _ci_pr_mode <pr-number> <sha-or-empty>
_ci_pr_mode() {
  local pr="${1}" want_sha="${2}"
  local timeout="${CGW_CI_TIMEOUT_SECONDS:-900}" poll="${CGW_CI_POLL_INTERVAL:-15}"
  local head_poll="${CGW_PR_CHECKS_POLL_SECONDS:-5}"
  local sync_max="${CGW_PR_HEAD_SYNC_SECONDS:-60}"
  local appear_max="${CGW_PR_CHECKS_APPEAR_SECONDS:-90}"

  # (1) Head sync: checks carry no SHA, so the PR head must be the commit that was pushed.
  log_section_start "PR HEAD" "${logfile}" >&2
  local head_branch head_sha is_cross expected_sha=""
  head_branch=$(_pr_view "${pr}" headRefName .headRefName) || head_branch=""
  head_sha=$(_pr_view "${pr}" headRefOid .headRefOid) || head_sha=""
  if [[ -z "${head_branch}" || ! "${head_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    _ci_out "CI: unverified -- could not read PR #${pr} from ${ci_repo} (does it exist?)"
    log_section_end "PR HEAD" "${logfile}" "1" >&2
    return 2
  fi
  if [[ -n "${want_sha}" ]]; then
    expected_sha="${want_sha}"
  else
    is_cross=$(_pr_view "${pr}" isCrossRepository .isCrossRepository) || is_cross=""
    if [[ "${is_cross}" != "true" ]]; then
      expected_sha=$(git ls-remote "${CGW_REMOTE}" "refs/heads/${head_branch}" 2>>"${logfile}" | awk 'NR==1 {print $1}')
      [[ -z "${expected_sha}" ]] && _ci_note "Could not read ${CGW_REMOTE}/${head_branch}'s tip; judging the head GitHub reports (pass --sha to bind it)"
    fi
  fi
  local waited=0
  while [[ -n "${expected_sha}" && "${head_sha}" != "${expected_sha}" ]]; do
    if [[ ${waited} -ge ${sync_max} ]]; then
      _ci_out "CI: unverified -- PR #${pr} head ${head_sha:0:7} has not caught up with pushed ${expected_sha:0:7} after ${waited}s; rerun in a moment"
      log_section_end "PR HEAD" "${logfile}" "1" >&2
      return 2
    fi
    _ci_note "PR #${pr} head ${head_sha:0:7} != pushed ${expected_sha:0:7} -- waiting for GitHub (${waited}/${sync_max}s)"
    _ci_sleep "${head_poll}"
    waited=$((waited + (head_poll > 0 ? head_poll : 1)))
    head_sha=$(_pr_view "${pr}" headRefOid .headRefOid) || head_sha=""
    if [[ ! "${head_sha}" =~ ^[0-9a-f]{40}$ ]]; then
      _ci_out "CI: unverified -- could not re-read PR #${pr}'s head commit"
      log_section_end "PR HEAD" "${logfile}" "1" >&2
      return 2
    fi
  done
  _ci_note "PR #${pr} (${head_branch}) head ${head_sha}"
  log_section_end "PR HEAD" "${logfile}" "0" >&2

  # (2) Checks must appear on that head.
  log_section_start "PR CHECKS" "${logfile}" >&2
  local rows
  rows=$(_ci_list_checks "${pr}") || {
    _ci_out "CI: unverified -- gh pr checks failed for PR #${pr} (see ${logfile})"
    log_section_end "PR CHECKS" "${logfile}" "1" >&2
    return 2
  }
  waited=0
  while [[ -z "${rows}" && ${waited} -lt ${appear_max} ]]; do
    _ci_note "No checks on PR #${pr} head ${head_sha:0:7} yet -- waiting for CI to register (${waited}/${appear_max}s)"
    _ci_sleep "${head_poll}"
    waited=$((waited + (head_poll > 0 ? head_poll : 1)))
    rows=$(_ci_list_checks "${pr}") || {
      _ci_out "CI: unverified -- gh pr checks failed for PR #${pr} (see ${logfile})"
      log_section_end "PR CHECKS" "${logfile}" "1" >&2
      return 2
    }
  done
  if [[ -z "${rows}" ]]; then
    _ci_no_runs "no check registered on PR #${pr} head ${head_sha:0:7} within ${waited}s"
    local rc=$?
    log_section_end "PR CHECKS" "${logfile}" "$((rc == 3 ? 0 : 1))" >&2
    return "${rc}"
  fi

  # (3) Poll until nothing is pending, re-reading the head each round (a push mid-wait
  # invalidates the verdict).
  local bucket workflow name link state pending head_now rc
  local -a red_lines
  local unknown_line
  while :; do
    red_lines=()
    pending=0
    unknown_line=""
    while IFS=$'\t' read -r bucket workflow name link; do
      [[ -z "${bucket}" ]] && continue
      state=$(_ci_check_state "${bucket}")
      case "${state}" in
        red) red_lines+=("CI: red ${workflow:-${name}} ${link}") ;;
        pending) pending=$((pending + 1)) ;;
        unknown) [[ -z "${unknown_line}" ]] && unknown_line="check '${name}' is in bucket '${bucket}'" ;;
      esac
    done <<<"${rows}"
    _ci_settle "PR CHECKS" "${head_sha}" "check(s)" "PR #${pr}"
    rc=$?
    [[ ${rc} -ne 10 ]] && return "${rc}"
    head_now=$(_pr_view "${pr}" headRefOid .headRefOid) || head_now=""
    if [[ "${head_now}" != "${head_sha}" ]]; then
      _ci_out "CI: unverified -- PR #${pr} head moved to ${head_now}; rerun with --sha ${head_now}"
      log_section_end "PR CHECKS" "${logfile}" "1" >&2
      return 2
    fi
    rows=$(_ci_list_checks "${pr}") || {
      _ci_out "CI: unverified -- gh pr checks failed for PR #${pr} (see ${logfile})"
      log_section_end "PR CHECKS" "${logfile}" "1" >&2
      return 2
    }
  done
}

main() {
  local branch="" pr="" sha="" timeout="" poll=""

  while [[ ${#} -gt 0 ]]; do
    case "${1}" in
      --help | -h)
        echo "Usage: ./scripts/git/verify_ci.sh (--branch <name> | --pr <N>) [OPTIONS]"
        echo ""
        echo "Post-push CI gate: wait for the GitHub Actions runs on a pushed commit and report"
        echo "one verdict. stdout carries only 'CI:' lines; progress goes to stderr."
        echo ""
        echo "Options:"
        echo "  --branch <name>    Judge the runs triggered by the push to <name> (its remote tip)"
        echo "  --pr <N>           Judge the checks on PR #N's head (waits for the head to match"
        echo "                     the pushed branch, then for checks to appear and settle)"
        echo "  --sha <sha>        Commit to judge instead of the remote tip (40 hex; e.g. the commit"
        echo "                     a release tag points at)"
        echo "  --timeout <s>      Override CGW_CI_TIMEOUT_SECONDS (default 900)"
        echo "  --poll <s>         Override CGW_CI_POLL_INTERVAL (default 15)"
        echo "  --non-interactive  Accepted for uniformity (the script never prompts)"
        echo "  -h, --help         Show this help"
        echo ""
        echo "Exit codes:"
        echo "  0  green           every judged run/check passed      -> CI: green <sha>"
        echo "  1  red             at least one failed                 -> CI: red <workflow> <url> (per failure)"
        echo "  2  unverified      timeout, gh failing, PR head lagging/moved, required workflow"
        echo "                     missing, nothing ran while workflows are active -> CI: unverified -- <reason>"
        echo "  3  not applicable  CGW_CI_VERIFY=0, no gh/auth, non-GitHub remote, no active workflow"
        echo "                     -> CI: not applicable (<why>)"
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/verify_ci.sh --branch development"
        echo "  ./scripts/git/verify_ci.sh --pr 42"
        echo "  ./scripts/git/verify_ci.sh --branch main --sha \$(git rev-parse v1.2.0^{commit})"
        echo ""
        echo "Notes:"
        echo "  Config: CGW_CI_VERIFY, CGW_CI_TIMEOUT_SECONDS, CGW_CI_POLL_INTERVAL,"
        echo "  CGW_CI_REQUIRED_WORKFLOWS (comma-separated names: only these are judged and all must"
        echo "  register). PR mode also honours CGW_PR_HEAD_SYNC_SECONDS, CGW_PR_CHECKS_APPEAR_SECONDS"
        echo "  and CGW_PR_CHECKS_POLL_SECONDS (as merge_pr.sh)."
        echo "  The default timeout exceeds a 10-minute tool cap: run it in the background when driven"
        echo "  by an agent, or pass --timeout."
        echo ""
        echo "Prerequisites:"
        echo "  gh CLI installed and authenticated (gh auth login); otherwise exit 3"
        exit 0
        ;;
      --branch)
        branch="${2:-}"
        if [[ -z "${branch}" ]]; then
          err "--branch requires a branch name"
          exit 1
        fi
        shift
        ;;
      --pr)
        pr="${2:-}"
        if [[ -z "${pr}" ]] || ! [[ "${pr}" =~ ^[0-9]+$ ]]; then
          err "--pr requires a PR number"
          exit 1
        fi
        shift
        ;;
      --sha)
        sha="${2:-}"
        if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
          err "--sha requires a full 40-hex commit SHA"
          exit 1
        fi
        shift
        ;;
      --timeout)
        timeout="${2:-}"
        if [[ ! "${timeout}" =~ ^[0-9]+$ ]]; then
          err "--timeout requires a number of seconds"
          exit 1
        fi
        shift
        ;;
      --poll)
        poll="${2:-}"
        if [[ ! "${poll}" =~ ^[0-9]+$ ]]; then
          err "--poll requires a number of seconds"
          exit 1
        fi
        shift
        ;;
      --non-interactive) CGW_NON_INTERACTIVE=1 ;;
      -*)
        err "Unknown flag: ${1}"
        exit 1
        ;;
      *)
        err "Unexpected argument: ${1}"
        exit 1
        ;;
    esac
    shift
  done

  if [[ -n "${branch}" && -n "${pr}" ]]; then
    err "--branch and --pr are mutually exclusive"
    exit 1
  fi
  if [[ -z "${branch}" && -z "${pr}" ]]; then
    err "One of --branch <name> or --pr <N> is required"
    exit 1
  fi
  [[ -n "${timeout}" ]] && CGW_CI_TIMEOUT_SECONDS="${timeout}"
  [[ -n "${poll}" ]] && CGW_CI_POLL_INTERVAL="${poll}"

  init_logging "verify_ci"
  {
    echo "========================================="
    echo "CI Verification Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Mode: ${branch:+branch ${branch}}${pr:+PR #${pr}}${sha:+ (sha ${sha})}"
  } >"${logfile}"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # gh must never block on a prompt or decorate its output.
  export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1

  # Comma-separated allow-list, normalised to one trimmed name per line.
  ci_required=""
  if [[ -n "${CGW_CI_REQUIRED_WORKFLOWS:-}" ]]; then
    ci_required=$(printf '%s' "${CGW_CI_REQUIRED_WORKFLOWS}" | tr ',' '\n' |
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')
  fi

  # [1] Applicability probe: anything missing here is "not CI's problem" (exit 3).
  log_section_start "PROBE" "${logfile}" >&2
  if [[ "${CGW_CI_VERIFY:-1}" != "1" ]]; then
    _ci_out "CI: not applicable (CGW_CI_VERIFY=${CGW_CI_VERIFY:-})"
    log_section_end "PROBE" "${logfile}" "0" >&2
    exit 3
  fi
  if ! cgw_require_gh 2>>"${logfile}"; then
    if command -v gh >/dev/null 2>&1; then
      _ci_out "CI: not applicable (gh CLI not authenticated; run gh auth login)"
    else
      _ci_out "CI: not applicable (gh CLI not installed)"
    fi
    log_section_end "PROBE" "${logfile}" "0" >&2
    exit 3
  fi
  ci_repo=""
  if ! ci_repo=$(cgw_remote_owner_repo "${CGW_REMOTE}"); then
    _ci_out "CI: not applicable (${CGW_REMOTE} is not a github.com remote)"
    log_section_end "PROBE" "${logfile}" "0" >&2
    exit 3
  fi
  _ci_note "Repo: ${ci_repo}"
  [[ -n "${ci_required}" ]] && _ci_note "Required workflows: $(echo "${ci_required}" | paste -sd ',' -)"
  log_section_end "PROBE" "${logfile}" "0" >&2

  local rc
  if [[ -n "${pr}" ]]; then
    _ci_pr_mode "${pr}" "${sha}"
    rc=$?
  else
    # Resolve the commit the push landed: --sha, else the remote tip of the branch (or the
    # commit a tag of that name points at).
    if [[ -z "${sha}" ]]; then
      sha=$(git ls-remote "${CGW_REMOTE}" "refs/heads/${branch}" 2>>"${logfile}" | awk 'NR==1 {print $1}')
      if [[ -z "${sha}" ]]; then
        # ls-remote lists the tag object first and its peeled ^{} commit second (annotated
        # tags only); the run is on the commit, so prefer the peeled line.
        sha=$(git ls-remote "${CGW_REMOTE}" "refs/tags/${branch}^{}" "refs/tags/${branch}" 2>>"${logfile}" |
          awk '$2 ~ /\^\{\}$/ {p = $1} $2 !~ /\^\{\}$/ {t = $1} END {print (p != "" ? p : t)}')
      fi
      if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
        _ci_out "CI: unverified -- could not resolve ${CGW_REMOTE}/${branch} to a commit (pushed?)"
        exit 2
      fi
    fi
    _ci_note "Judging ${branch} @ ${sha}"
    _ci_branch_mode "${branch}" "${sha}"
    rc=$?
  fi
  _ci_note "Full log: ${logfile}"
  exit "${rc}"
}

main "${@}"
