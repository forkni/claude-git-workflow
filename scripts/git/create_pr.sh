#!/usr/bin/env bash
# create_pr.sh - Create a GitHub pull request from source to target branch
# Purpose: Open a PR to trigger Charlie CI review and GitHub Actions
# Usage: ./scripts/git/create_pr.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR             - Directory containing this script
#   PROJECT_ROOT           - Auto-detected git repo root (set by _config.sh)
#   logfile                - Set by init_logging
#   CGW_SOURCE_BRANCH      - Head branch for the PR (default: development)
#   CGW_TARGET_BRANCH      - Base branch for the PR (default: main)
# Arguments:
#   --title <title>        Override auto-generated PR title
#   --draft                Create PR as draft (not ready for review)
#   --non-interactive      Accept all defaults, no prompts
#   --dry-run              Preview PR details without creating
#   -h, --help             Show help
# Returns:
#   0 on successful PR creation, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

main() {
	local pr_title=""
	local draft=0
	local non_interactive=0
	local dry_run=0

	# Auto-detect non-interactive mode when no TTY
	if [[ ! -t 0 ]]; then
		non_interactive=1
	fi

	[[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			echo "Usage: ./scripts/git/create_pr.sh [OPTIONS]"
			echo ""
			echo "Create a GitHub PR from source to target branch."
			echo "Triggers Charlie CI auto-review and GitHub Actions workflows."
			echo ""
			echo "Options:"
			echo "  --title <title>     Override auto-generated PR title"
			echo "  --draft             Create as draft PR (not ready for review)"
			echo "  --non-interactive   Accept all defaults, no prompts"
			echo "  --dry-run           Preview PR details without creating"
			echo "  -h, --help          Show this help"
			echo ""
			echo "Branches:"
			echo "  Head (from): ${CGW_SOURCE_BRANCH}"
			echo "  Base (into): ${CGW_TARGET_BRANCH}"
			echo ""
			echo "Environment:"
			echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
			echo "  CGW_SOURCE_BRANCH       Override source branch"
			echo "  CGW_TARGET_BRANCH       Override target branch"
			echo ""
			echo "Prerequisites:"
			echo "  gh CLI installed and authenticated (gh auth login)"
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
		--draft)
			draft=1
			shift
			;;
		--non-interactive)
			non_interactive=1
			shift
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		*)
			echo "[ERROR] Unknown flag: $1" >&2
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
		echo "Source: ${CGW_SOURCE_BRANCH} → Target: ${CGW_TARGET_BRANCH}"
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

	if ! command -v gh >/dev/null 2>&1; then
		err "gh CLI not found. Install from https://cli.github.com/"
		log_section_end "PREREQUISITES" "$logfile" "1"
		exit 1
	fi

	if ! gh auth status >/dev/null 2>&1; then
		err "gh CLI not authenticated. Run: gh auth login"
		log_section_end "PREREQUISITES" "$logfile" "1"
		exit 1
	fi

	echo "✓ gh CLI installed and authenticated" | tee -a "$logfile"
	log_section_end "PREREQUISITES" "$logfile" "0"
	echo "" | tee -a "$logfile"

	# [2/4] Validate branch state
	log_section_start "BRANCH VALIDATION" "$logfile"

	local current_branch
	current_branch=$(git branch --show-current)
	echo "Current branch: ${current_branch}" | tee -a "$logfile"
	echo "PR: ${CGW_SOURCE_BRANCH} → ${CGW_TARGET_BRANCH}" | tee -a "$logfile"

	if [[ "${CGW_SOURCE_BRANCH}" == "${CGW_TARGET_BRANCH}" ]]; then
		err "Source and target branch are the same: ${CGW_SOURCE_BRANCH}"
		log_section_end "BRANCH VALIDATION" "$logfile" "1"
		exit 1
	fi

	# Verify source branch exists locally and remotely
	if ! git show-ref --verify "refs/heads/${CGW_SOURCE_BRANCH}" >/dev/null 2>&1; then
		err "Source branch '${CGW_SOURCE_BRANCH}' does not exist locally"
		echo "  Create it with: git checkout -b ${CGW_SOURCE_BRANCH}" >&2
		log_section_end "BRANCH VALIDATION" "$logfile" "1"
		exit 1
	fi

	if ! git ls-remote --exit-code origin "refs/heads/${CGW_SOURCE_BRANCH}" >/dev/null 2>&1; then
		err "Source branch '${CGW_SOURCE_BRANCH}' not pushed to origin"
		echo "  Push it with: ./scripts/git/push_validated.sh" >&2
		log_section_end "BRANCH VALIDATION" "$logfile" "1"
		exit 1
	fi

	# Verify target branch exists on remote
	if ! git ls-remote --exit-code origin "refs/heads/${CGW_TARGET_BRANCH}" >/dev/null 2>&1; then
		err "Target branch '${CGW_TARGET_BRANCH}' does not exist on origin"
		echo "  Create it with: ./scripts/git/push_validated.sh --branch ${CGW_TARGET_BRANCH}" >&2
		log_section_end "BRANCH VALIDATION" "$logfile" "1"
		exit 1
	fi

	# Fetch latest remote refs so comparisons below use current state
	if ! git fetch origin "${CGW_SOURCE_BRANCH}" "${CGW_TARGET_BRANCH}" 2>/dev/null; then
		echo "⚠ WARNING: git fetch failed — comparisons may use stale refs" | tee -a "$logfile"
	fi

	# Warn if local source branch has commits not yet pushed to remote
	local local_sha remote_sha
	local_sha=$(git rev-parse "${CGW_SOURCE_BRANCH}" 2>/dev/null || true)
	remote_sha=$(git rev-parse "origin/${CGW_SOURCE_BRANCH}" 2>/dev/null || true)
	if [[ -n "${local_sha}" ]] && [[ "${local_sha}" != "${remote_sha}" ]]; then
		echo "⚠ WARNING: Local ${CGW_SOURCE_BRANCH} differs from origin/${CGW_SOURCE_BRANCH}" | tee -a "$logfile"
		echo "  Local commits may not appear in the PR. Push first with: ./scripts/git/push_validated.sh" | tee -a "$logfile"
	fi

	# Check for commits ahead of target
	local commits_ahead
	if ! commits_ahead=$(git rev-list --count "origin/${CGW_TARGET_BRANCH}..origin/${CGW_SOURCE_BRANCH}" 2>/dev/null); then
		err "Cannot determine commit distance between origin/${CGW_TARGET_BRANCH} and origin/${CGW_SOURCE_BRANCH}"
		log_section_end "BRANCH VALIDATION" "$logfile" "1"
		exit 1
	fi

	if [[ "${commits_ahead}" == "0" ]]; then
		echo "[!] No commits ahead of ${CGW_TARGET_BRANCH} — nothing to PR" | tee -a "$logfile"
		log_section_end "BRANCH VALIDATION" "$logfile" "1"
		exit 1
	fi

	echo "✓ ${commits_ahead} commit(s) ahead of ${CGW_TARGET_BRANCH}" | tee -a "$logfile"
	log_section_end "BRANCH VALIDATION" "$logfile" "0"
	echo "" | tee -a "$logfile"

	# [3/4] Generate PR title and body
	log_section_start "PR CONTENT" "$logfile"

	local commit_log
	commit_log=$(git log --oneline "origin/${CGW_TARGET_BRANCH}..origin/${CGW_SOURCE_BRANCH}" 2>/dev/null)

	# Auto-generate title if not provided
	if [[ -z "${pr_title}" ]]; then
		if [[ "${commits_ahead}" == "1" ]]; then
			# Single commit: use its subject line
			pr_title=$(git log -1 --format="%s" "origin/${CGW_SOURCE_BRANCH}" 2>/dev/null)
		else
			# Multiple commits: generic merge title
			pr_title="merge: ${CGW_SOURCE_BRANCH} → ${CGW_TARGET_BRANCH}"
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

\`${CGW_SOURCE_BRANCH}\` → \`${CGW_TARGET_BRANCH}\`"

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

	log_section_end "PR CONTENT" "$logfile" "0"
	echo "" | tee -a "$logfile"

	# [4/4] Create PR
	if [[ ${dry_run} -eq 1 ]]; then
		echo "=== DRY RUN — PR not created ===" | tee -a "$logfile"
		echo "" | tee -a "$logfile"
		echo "Would create:" | tee -a "$logfile"
		echo "  Title:  ${pr_title}" | tee -a "$logfile"
		echo "  Head:   ${CGW_SOURCE_BRANCH}" | tee -a "$logfile"
		echo "  Base:   ${CGW_TARGET_BRANCH}" | tee -a "$logfile"
		echo "  Draft:  $([[ ${draft} -eq 1 ]] && echo yes || echo no)" | tee -a "$logfile"
		echo "" | tee -a "$logfile"
		echo "Charlie CI will auto-review when PR is opened (non-draft)" | tee -a "$logfile"
		exit 0
	fi

	log_section_start "CREATE PR" "$logfile"

	local gh_flags=()
	gh_flags+=(--base "${CGW_TARGET_BRANCH}")
	gh_flags+=(--head "${CGW_SOURCE_BRANCH}")
	gh_flags+=(--title "${pr_title}")
	gh_flags+=(--body "${pr_body}")
	[[ ${draft} -eq 1 ]] && gh_flags+=(--draft)

	local pr_url gh_output
	if gh_output=$(gh pr create "${gh_flags[@]}" 2>&1 | tee -a "$logfile"); then
		pr_url=$(echo "${gh_output}" | grep -oE 'https://github\.com/[^ ]+' | head -1)
		log_section_end "CREATE PR" "$logfile" "0"
		echo "" | tee -a "$logfile"
		echo "✓ PR created: ${pr_url:-${gh_output}}" | tee -a "$logfile"
		echo "" | tee -a "$logfile"
		if [[ ${draft} -eq 0 ]]; then
			echo "Charlie CI will auto-review this PR." | tee -a "$logfile"
		else
			echo "Draft PR created. Mark as Ready for Review to trigger Charlie CI." | tee -a "$logfile"
		fi
		echo "Full log: $logfile"
	else
		log_section_end "CREATE PR" "$logfile" "1"
		err "PR creation failed — check log: ${logfile}"
		exit 1
	fi
}

main "$@"
