#!/usr/bin/env bash
# create_pr.sh - Create a GitHub pull request from source to target branch
# Purpose: Open a PR to trigger GitHub Actions
# Usage: ./scripts/git/create_pr.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR             - Directory containing this script
#   PROJECT_ROOT           - Auto-detected git repo root (set by _config.sh)
#   logfile                - Set by init_logging
#   CGW_SOURCE_BRANCH      - Head branch for the PR (no default; --source or .cgw.conf)
#   CGW_TARGET_BRANCH      - Base branch for the PR (default: main)
#
# Passes gh an explicit --repo resolved from CGW_REMOTE's own URL (see
# cgw_remote_owner_repo in _common.sh). Without this, `gh pr create` resolves
# its own target repo and -- when CGW_REMOTE is a fork -- defaults to the
# fork's parent/upstream repo instead of CGW_REMOTE itself. If CGW_REMOTE's
# URL isn't a resolvable github.com URL, this script aborts rather than
# falling back to gh's own (unsafe) resolution.
# Arguments:
#   --title <title>        Override auto-generated PR title
#   --task <id>            Append " [<id>]" to the title (tracker id such as TZ-123,
#                          or no-task); repeatable, one bracket per id
#   --body <text>          Use <text> as the PR body (replaces the commit-log body)
#   --body-file <path>     Read the PR body from <path> (relative to the caller's cwd)
#   --draft                Create PR as draft (not ready for review)
#   --non-interactive      Accept all defaults, no prompts
#   --dry-run              Preview PR details without creating
#   --source <branch>      Override source (head) branch for this invocation
#   --target <branch>      Override target (base) branch for this invocation
#   -h, --help             Show help
# Returns:
#   0 on successful PR creation, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

main() {
  local pr_title=""
  local task_ids=()
  local body_text="" body_file="" body_source=""
  local draft=0
  local non_interactive=0
  local dry_run=0
  local src_branch="${CGW_SOURCE_BRANCH}"
  local tgt_branch="${CGW_TARGET_BRANCH}"

  # Auto-detect non-interactive mode when no TTY
  if [[ ! -t 0 ]]; then
    non_interactive=1
    CGW_NON_INTERACTIVE=1
  fi

  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/create_pr.sh [OPTIONS]"
        echo ""
        echo "Create a GitHub PR from source to target branch."
        echo "Triggers GitHub Actions workflows."
        echo ""
        echo "Options:"
        echo "  --title <title>     Override auto-generated PR title"
        echo "  --task <id>         Append ' [<id>]' to the title: a tracker id such as TZ-123,"
        echo "                      or no-task. Repeatable; an id already in the title is not added again"
        echo "  --body <text>       Use <text> as the PR body (replaces the commit-log body)"
        echo "  --body-file <path>  Read the PR body from <path> (not '-'; stdin is the title prompt)"
        echo "  --draft             Create as draft PR (not ready for review)"
        echo "  --non-interactive   Accept all defaults, no prompts"
        echo "  --dry-run           Preview PR details without creating"
        echo "  --source <branch>   Override source (head) branch for this invocation"
        echo "  --target <branch>   Override target (base) branch for this invocation"
        echo "  -h, --help          Show this help"
        echo ""
        echo "Branches:"
        echo "  Head (from): ${src_branch}"
        echo "  Base (into): ${tgt_branch}"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
        echo "  CGW_SOURCE_BRANCH       Default source branch"
        echo "  CGW_TARGET_BRANCH       Default target branch"
        echo "  CGW_REMOTE              Remote name (default: origin)"
        echo ""
        echo "Prerequisites:"
        echo "  gh CLI installed and authenticated (gh auth login)"
        echo ""
        echo "Note:"
        echo "  Passes gh an explicit --repo resolved from \${CGW_REMOTE}'s URL, so a fork"
        echo "  remote targets itself instead of gh's default (the fork's parent repo)."
        exit 0
        ;;
      --title)
        if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
          err "--title requires a non-empty value"
          exit 1
        fi
        pr_title="${2}"
        shift 2
        ;;
      --task)
        # PROJECT-123 style (letters/digits, a dash, a number), or the explicit no-task marker.
        if [[ $# -lt 2 ]] || ! [[ "${2:-}" =~ ^([A-Za-z][A-Za-z0-9]*-[0-9]+|no-task)$ ]]; then
          err "--task requires an id like TZ-123, or no-task"
          exit 1
        fi
        task_ids+=("${2}")
        shift 2
        ;;
      --body)
        if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
          err "--body requires a non-empty value"
          exit 1
        fi
        if [[ -n "${body_source}" ]]; then
          err "--body and --body-file are mutually exclusive"
          exit 1
        fi
        body_text="${2}"
        body_source="--body"
        shift 2
        ;;
      --body-file)
        if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
          err "--body-file requires a path"
          exit 1
        fi
        if [[ -n "${body_source}" ]]; then
          err "--body and --body-file are mutually exclusive"
          exit 1
        fi
        if [[ "${2}" == "-" ]]; then
          err "--body-file does not accept '-' (stdin is used for the title prompt)"
          exit 1
        fi
        # Read now, before the cd to PROJECT_ROOT below, so a relative path
        # resolves against the caller's cwd.
        if [[ ! -r "${2}" ]] || [[ -d "${2}" ]]; then
          err "--body-file: cannot read '${2}'"
          exit 1
        fi
        body_text=$(cat "${2}")
        if [[ -z "${body_text//[[:space:]]/}" ]]; then
          err "--body-file: '${2}' is empty"
          exit 1
        fi
        body_file="${2}"
        body_source="--body-file"
        shift 2
        ;;
      --draft)
        draft=1
        shift
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --source)
        src_branch="${2:-}"
        if [[ -z "${src_branch}" ]]; then
          err "--source requires a branch name"
          exit 1
        fi
        shift 2
        ;;
      --target)
        tgt_branch="${2:-}"
        if [[ -z "${tgt_branch}" ]]; then
          err "--target requires a branch name"
          exit 1
        fi
        shift 2
        ;;
      *)
        err "Unknown flag: $1"
        exit 1
        ;;
    esac
  done

  init_logging "create_pr"

  {
    echo "========================================="
    echo "Create PR Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Source: ${src_branch} -> Target: ${tgt_branch}"
    echo ""
  } >"$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  echo "=== Create Pull Request ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  # [1/4] Validate prerequisites
  log_section_start "PREREQUISITES" "$logfile"

  if ! cgw_require_gh; then
    log_section_end "PREREQUISITES" "$logfile" "1"
    exit 1
  fi

  echo "[OK] gh CLI installed and authenticated" | tee -a "$logfile"
  log_section_end "PREREQUISITES" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [2/4] Validate branch state
  log_section_start "BRANCH VALIDATION" "$logfile"

  local current_branch
  current_branch=$(git branch --show-current)
  echo "Current branch: ${current_branch}" | tee -a "$logfile"
  echo "PR: ${src_branch} -> ${tgt_branch}" | tee -a "$logfile"

  # CGW_SOURCE_BRANCH has no default (see _config.sh); same message as validate_branch_pair.
  if [[ -z "${src_branch}" ]]; then
    err "No source branch configured. Pass --source <branch>, or set CGW_SOURCE_BRANCH in .cgw.conf."
    [[ -n "${current_branch}" ]] && echo "  The current branch is '${current_branch}': pass --source ${current_branch}" >&2
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  if [[ "${src_branch}" == "${tgt_branch}" ]]; then
    err "Source and target branch are the same: ${src_branch}"
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  # Verify source branch exists locally and remotely
  if ! git show-ref --verify "refs/heads/${src_branch}" >/dev/null 2>&1; then
    err "Source branch '${src_branch}' does not exist locally"
    echo "  Create it with: git checkout -b ${src_branch}" >&2
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  if ! cgw_remote_branch_exists "${CGW_REMOTE}" "${src_branch}"; then
    err "Source branch '${src_branch}' not pushed to ${CGW_REMOTE}"
    echo "  Push it with: ./scripts/git/push_validated.sh" >&2
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  # Verify target branch exists on remote
  if ! cgw_remote_branch_exists "${CGW_REMOTE}" "${tgt_branch}"; then
    err "Target branch '${tgt_branch}' does not exist on ${CGW_REMOTE}"
    echo "  Create it with: ./scripts/git/push_validated.sh --branch ${tgt_branch}" >&2
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  # Fetch latest remote refs so comparisons below use current state
  if ! cgw_net_git fetch "${CGW_REMOTE}" "${src_branch}" "${tgt_branch}" 2>/dev/null; then
    echo "[!] WARNING: git fetch failed -- comparisons may use stale refs" | tee -a "$logfile"
  fi

  # Warn if local source branch has commits not yet pushed to remote
  local local_sha remote_sha
  local_sha=$(git rev-parse "${src_branch}" 2>/dev/null || true)
  remote_sha=$(git rev-parse "${CGW_REMOTE}/${src_branch}" 2>/dev/null || true)
  if [[ -n "${local_sha}" ]] && [[ "${local_sha}" != "${remote_sha}" ]]; then
    echo "[!] WARNING: Local ${src_branch} differs from ${CGW_REMOTE}/${src_branch}" | tee -a "$logfile"
    echo "  Local commits may not appear in the PR. Push first with: ./scripts/git/push_validated.sh" | tee -a "$logfile"
  fi

  # Check for commits ahead of target
  local commits_ahead
  if ! commits_ahead=$(cgw_rev_count "${CGW_REMOTE}/${tgt_branch}" "${CGW_REMOTE}/${src_branch}"); then
    err "Cannot determine commit distance between ${CGW_REMOTE}/${tgt_branch} and ${CGW_REMOTE}/${src_branch}"
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  if [[ "${commits_ahead}" == "0" ]]; then
    echo "[!] No commits ahead of ${tgt_branch} -- nothing to PR" | tee -a "$logfile"
    log_section_end "BRANCH VALIDATION" "$logfile" "1"
    exit 1
  fi

  echo "[OK] ${commits_ahead} commit(s) ahead of ${tgt_branch}" | tee -a "$logfile"
  log_section_end "BRANCH VALIDATION" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [3/4] Generate PR title and body
  log_section_start "PR CONTENT" "$logfile"

  local commit_log
  commit_log=$(git log --oneline "${CGW_REMOTE}/${tgt_branch}..${CGW_REMOTE}/${src_branch}" 2>/dev/null)

  # Auto-generate title if not provided
  if [[ -z "${pr_title}" ]]; then
    if [[ "${commits_ahead}" == "1" ]]; then
      # Single commit: use its subject line
      pr_title=$(git log -1 --format="%s" "${CGW_REMOTE}/${src_branch}" 2>/dev/null)
    else
      # Multiple commits: generic merge title
      pr_title="merge: ${src_branch} -> ${tgt_branch}"
    fi
  fi

  # Build PR body from commit log
  local pr_body
  local formatted_log
  # shellcheck disable=SC2001  # sed required: prepend '- ' to every line; no bash equivalent
  formatted_log=$(echo "${commit_log}" | sed 's/^/- /')

  pr_body="## Changes

${formatted_log}

## Branch

\`${src_branch}\` -> \`${tgt_branch}\`"

  # A caller-supplied body replaces the generated one verbatim.
  [[ -n "${body_source}" ]] && pr_body="${body_text}"

  echo "Title: ${pr_title}" | tee -a "$logfile"
  echo "" | tee -a "$logfile"
  echo "Commits:" | tee -a "$logfile"
  echo "${commit_log}" | tee -a "$logfile"

  # In interactive mode, allow title override
  if [[ ${non_interactive} -eq 0 ]] && [[ ${dry_run} -eq 0 ]]; then
    echo ""
    read -rp "PR title [${pr_title}]: " title_input
    if [[ -n "${title_input}" ]]; then
      pr_title="${title_input}"
    fi
  fi

  # Task ids go on last, so they survive both the auto-title and the prompt above.
  local task_id
  for task_id in "${task_ids[@]+"${task_ids[@]}"}"; do
    [[ "${pr_title}" == *"[${task_id}]"* ]] || pr_title="${pr_title} [${task_id}]"
  done
  [[ ${#task_ids[@]} -gt 0 ]] && echo "Title with task id(s): ${pr_title}" | tee -a "$logfile"

  log_section_end "PR CONTENT" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # Resolve an explicit --repo for gh from ${CGW_REMOTE}'s own URL. Without
  # it, `gh pr create` resolves the target repo itself and -- when the remote
  # is a fork -- defaults to the fork's parent/upstream repo, opening (or
  # failing to open) the PR against the wrong repository.
  local pr_repo=""
  if pr_repo=$(cgw_remote_owner_repo "${CGW_REMOTE}"); then
    echo "Repo: ${pr_repo} (explicit -- avoids gh defaulting to a parent repo if ${CGW_REMOTE} is a fork)" | tee -a "$logfile"
  else
    err_tee "[ERROR] Could not determine ${CGW_REMOTE}'s owner/repo from its configured URL (checked pushurl, then url)."
    err_tee "[ERROR] Refusing to run 'gh pr create' without an explicit --repo -- gh's own"
    err_tee "[ERROR] resolution defaults to the parent/upstream repo when ${CGW_REMOTE} is a fork."
    err_tee "[ERROR] Fix: run 'git remote -v' and confirm ${CGW_REMOTE} is a github.com SSH/HTTPS URL."
    exit 1
  fi

  # [4/4] Create PR
  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- PR not created ===" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Would create:" | tee -a "$logfile"
    [[ -n "${pr_repo}" ]] && echo "  Repo:   ${pr_repo}" | tee -a "$logfile"
    echo "  Title:  ${pr_title}" | tee -a "$logfile"
    echo "  Head:   ${src_branch}" | tee -a "$logfile"
    echo "  Base:   ${tgt_branch}" | tee -a "$logfile"
    echo "  Draft:  $([[ ${draft} -eq 1 ]] && echo yes || echo no)" | tee -a "$logfile"
    case "${body_source}" in
      --body) echo "  Body:   (from --body)" | tee -a "$logfile" ;;
      --body-file) echo "  Body:   (from file ${body_file})" | tee -a "$logfile" ;;
      *) echo "  Body:   (auto-generated from commit log)" | tee -a "$logfile" ;;
    esac
    echo "${pr_body}" | sed 's/^/    /' | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    exit 0
  fi

  log_section_start "CREATE PR" "$logfile"

  local gh_flags=()
  [[ -n "${pr_repo}" ]] && gh_flags+=(--repo "${pr_repo}")
  gh_flags+=(--base "${tgt_branch}")
  gh_flags+=(--head "${src_branch}")
  gh_flags+=(--title "${pr_title}")
  # Body goes on stdin: no command-line length limit, and no MSYS path
  # conversion of a file argument handed to a native gh.exe.
  gh_flags+=(--body-file -)
  [[ ${draft} -eq 1 ]] && gh_flags+=(--draft)

  local pr_url gh_output
  if gh_output=$(gh pr create "${gh_flags[@]}" <<<"${pr_body}" 2>&1 | tee -a "$logfile"); then
    pr_url=$(echo "${gh_output}" | tr -d '\r' | grep -oE 'https://github\.com/[^ ]+' | head -1)
    log_section_end "CREATE PR" "$logfile" "0"
    echo "" | tee -a "$logfile"
    echo "[OK] PR created: ${pr_url:-${gh_output}}" | tee -a "$logfile"
    # Handed to the CI gate (skill/references/ci-verification.md): the PR number avoids guessing it
    # from the current branch, and the head SHA is what the PR's checks must be reported against.
    # A missing line must be loud -- the gate has nothing else to bind to.
    local pr_num="" pushed_sha
    [[ "${pr_url}" =~ /pull/([0-9]+) ]] && pr_num="${BASH_REMATCH[1]}"
    if [[ -n "${pr_num}" ]]; then
      echo "PR number: ${pr_num}" | tee -a "$logfile"
    else
      err_tee "[WARN] Could not parse the PR number from gh's output -- find it with: gh pr list --repo ${pr_repo} --head ${src_branch}"
    fi
    pushed_sha=$(cgw_net_git ls-remote "${CGW_REMOTE}" "refs/heads/${src_branch}" 2>>"$logfile" | awk 'NR==1 {print $1}')
    if [[ -n "${pushed_sha}" ]]; then
      echo "Head SHA: ${pushed_sha}" | tee -a "$logfile"
    else
      err_tee "[WARN] Could not read ${CGW_REMOTE}/${src_branch}'s SHA via git ls-remote -- the CI gate must resolve it itself"
    fi
    echo "" | tee -a "$logfile"
    if [[ ${draft} -eq 0 ]]; then
      echo "PR created and ready for review." | tee -a "$logfile"
    else
      echo "Draft PR created. Mark as Ready for Review when it is ready." | tee -a "$logfile"
    fi
    echo "Full log: $logfile"
  else
    log_section_end "CREATE PR" "$logfile" "1"
    err "PR creation failed -- check log: ${logfile}"
    exit 1
  fi
}

main "$@"
