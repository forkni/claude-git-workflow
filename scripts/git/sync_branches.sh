#!/usr/bin/env bash
# sync_branches.sh - Sync local branches with remote via fetch + rebase
# Purpose: Keep branches up-to-date with origin
# Usage: ./scripts/git/sync_branches.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR          - Directory containing this script
#   PROJECT_ROOT        - Auto-detected git repo root (set by _config.sh)
#   logfile             - Set by init_logging
#   CGW_SOURCE_BRANCH   - Source branch name (default: development)
#   CGW_TARGET_BRANCH   - Target branch name (default: main)
# Arguments:
#   --all               Sync both source and target branches (default: current only)
#   --non-interactive   Skip prompts
#   -h, --help          Show help
# Returns:
#   0 on successful sync, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

init_logging "sync_branches"

_sync_original_branch=""

_cleanup_sync() {
	local current
	current=$(git branch --show-current 2>/dev/null || true)
	if [[ -n "${_sync_original_branch}" ]] && [[ "${current}" != "${_sync_original_branch}" ]]; then
		echo "" >&2
		echo "[!] Interrupted -- returning to: ${_sync_original_branch}" >&2
		git rebase --abort 2>/dev/null || true
		git checkout "${_sync_original_branch}" 2>/dev/null || true
	fi
}
trap _cleanup_sync EXIT INT TERM

# sync_one_branch - Fetch and rebase a single branch against origin.
# Arguments:
#   $1 - branch name
# Returns: 0 on success, 1 on failure
sync_one_branch() {
	local branch="$1"
	local current_branch
	current_branch=$(git branch --show-current)

	echo "" | tee -a "$logfile"
	echo "--- Syncing ${branch} ---" | tee -a "$logfile"

	if ! git show-ref --verify --quiet "refs/heads/${branch}"; then
		echo "  [!] Branch '${branch}' does not exist locally -- skipping" | tee -a "$logfile"
		return 0
	fi

	if ! git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
		echo "  [!] No remote tracking branch 'origin/${branch}' -- skipping" | tee -a "$logfile"
		return 0
	fi

	if [[ "${current_branch}" != "${branch}" ]]; then
		if ! git checkout "${branch}" >>"$logfile" 2>&1; then
			echo "  [FAIL] Failed to checkout ${branch}" | tee -a "$logfile"
			return 1
		fi
		echo "  Switched to ${branch}" | tee -a "$logfile"
	fi

	local behind ahead
	behind=$(git rev-list --count "HEAD..origin/${branch}" 2>/dev/null || echo "0")
	ahead=$(git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo "0")

	echo "  Local: ${ahead} ahead, ${behind} behind origin/${branch}" | tee -a "$logfile"

	if [[ "${behind}" -eq 0 ]]; then
		echo "  [OK] Already up-to-date with origin/${branch}" | tee -a "$logfile"
		return 0
	fi

	if [[ "${ahead}" -gt 0 ]]; then
		echo "  [!] Diverged: ${ahead} local commits will be rebased on top of ${behind} remote commits" | tee -a "$logfile"
	fi

	local rebase_args=(pull --rebase origin "${branch}")
	[[ "${_SYNC_AUTOSTASH:-0}" == "1" ]] && rebase_args=(pull --rebase --autostash origin "${branch}")
	if run_git_with_logging "GIT REBASE ${branch}" "$logfile" "${rebase_args[@]}"; then
		echo "  [OK] ${branch} synced successfully" | tee -a "$logfile"
		return 0
	else
		echo "  [FAIL] Rebase failed for ${branch}" | tee -a "$logfile"
		echo "  Aborting rebase..." | tee -a "$logfile"
		git rebase --abort 2>/dev/null || true
		echo "  Manual action needed: git pull --rebase origin ${branch}" | tee -a "$logfile"
		return 1
	fi
}

main() {
	local sync_all=0
	local non_interactive=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--help | -h)
			echo "Usage: ./scripts/git/sync_branches.sh [OPTIONS]"
			echo ""
			echo "Sync local branches with remote origin via fetch + rebase."
			echo ""
			echo "Options:"
			echo "  --all               Sync both source and target branches (default: current only)"
			echo "  --non-interactive   Abort (instead of prompt) if uncommitted changes found"
			echo "  -h, --help          Show this help"
			echo ""
			echo "Behavior:"
			echo "  - Runs git fetch origin first to update remote refs"
			echo "  - Uses git pull --rebase (preserves clean linear history)"
			echo "  - With --all: switches between branches, returns to starting branch"
			echo "  - Warns if local diverges from remote before rebasing"
			echo ""
			echo "Configuration:"
			echo "  CGW_SOURCE_BRANCH   Source branch (default: development)"
			echo "  CGW_TARGET_BRANCH   Target branch (default: main)"
			echo ""
			echo "Environment:"
			echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
			exit 0
			;;
		--all) sync_all=1 ;;
		--non-interactive) non_interactive=1 ;;
		*)
			echo "[ERROR] Unknown flag: $1" >&2
			exit 1
			;;
		esac
		shift
	done

	[[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

	{
		echo "========================================="
		echo "Sync Branches Log"
		echo "========================================="
		echo "Start Time: $(date)"
		echo "Working Directory: ${PROJECT_ROOT}"
	} >"$logfile"

	echo "=== Branch Sync ===" | tee -a "$logfile"
	echo "" | tee -a "$logfile"
	echo "Workflow Log: ${logfile}" | tee -a "$logfile"
	echo "" | tee -a "$logfile"

	cd "${PROJECT_ROOT}" || {
		err "Cannot find project root"
		exit 1
	}

	_sync_original_branch=$(git branch --show-current)

	if ! git diff-index --quiet HEAD -- 2>/dev/null; then
		echo "[!] Uncommitted changes detected -- will auto-stash during rebase" | tee -a "$logfile"
		git status --short | tee -a "$logfile"
		echo "" | tee -a "$logfile"
		if [[ ${non_interactive} -eq 1 ]]; then
			echo "[Non-interactive] Auto-stash enabled (--autostash)" | tee -a "$logfile"
		else
			read -r -p "Auto-stash changes and sync? (yes/no): " uncommitted_choice
			if [[ "${uncommitted_choice}" != "yes" ]]; then
				echo "Aborted -- commit or stash manually before syncing" | tee -a "$logfile"
				exit 0
			fi
		fi
		# Pass --autostash to pull --rebase to handle dirty working tree cleanly
		export _SYNC_AUTOSTASH=1
	else
		export _SYNC_AUTOSTASH=0
	fi

	# [1] Fetch all remotes
	log_section_start "GIT FETCH" "$logfile"
	echo "Fetching from origin..." | tee -a "$logfile"
	if git fetch origin >>"$logfile" 2>&1; then
		echo "[OK] Fetch complete" | tee -a "$logfile"
		log_section_end "GIT FETCH" "$logfile" "0"
	else
		echo "[FAIL] Fetch failed -- check network/auth" | tee -a "$logfile"
		log_section_end "GIT FETCH" "$logfile" "1"
		exit 1
	fi
	echo "" | tee -a "$logfile"

	# [2] Sync branches
	log_section_start "SYNC BRANCHES" "$logfile"

	local sync_failed=0

	if [[ ${sync_all} -eq 1 ]]; then
		sync_one_branch "${CGW_SOURCE_BRANCH}" || sync_failed=1
		sync_one_branch "${CGW_TARGET_BRANCH}" || sync_failed=1
	else
		sync_one_branch "${_sync_original_branch}" || sync_failed=1
	fi

	log_section_end "SYNC BRANCHES" "$logfile" "${sync_failed}"
	echo "" | tee -a "$logfile"

	# Return to original branch if we moved
	local current_after
	current_after=$(git branch --show-current)
	if [[ "${current_after}" != "${_sync_original_branch}" ]]; then
		git checkout "${_sync_original_branch}" >>"$logfile" 2>&1
		echo "Returned to: ${_sync_original_branch}" | tee -a "$logfile"
		echo "" | tee -a "$logfile"
	fi

	{
		echo "========================================"
		echo "[SYNC SUMMARY]"
		echo "========================================"
	} | tee -a "$logfile"

	if [[ ${sync_failed} -eq 0 ]]; then
		echo "[OK] SYNC SUCCESSFUL" | tee -a "$logfile"
	else
		echo "[!] SYNC COMPLETED WITH ERRORS" | tee -a "$logfile"
		echo "  Check log for details: ${logfile}" | tee -a "$logfile"
	fi

	{
		echo ""
		echo "End Time: $(date)"
	} | tee -a "$logfile"

	echo "Full log: $logfile"

	return ${sync_failed}
}

main "$@"
