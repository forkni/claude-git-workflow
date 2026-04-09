#!/usr/bin/env bash
# changelog_generate.sh - Generate changelog from conventional commits
# Purpose: Parse conventional commit messages (feat/fix/docs/etc.) between two
#          refs and produce a categorized markdown or plain-text changelog.
#          Leverages the commit discipline enforced by commit_enhanced.sh.
#          See Pro Git Ch5 p.156-170 (git shortlog, git describe, release prep).
# Usage: ./scripts/git/changelog_generate.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR          - Directory containing this script
#   PROJECT_ROOT        - Auto-detected git repo root (set by _config.sh)
#   CGW_TARGET_BRANCH   - Default "to" ref if --to not specified
#   CGW_ALL_PREFIXES    - Recognized conventional commit prefixes
# Arguments:
#   --from <ref>     Start ref (exclusive) — default: latest semver tag or first commit
#   --to <ref>       End ref (inclusive) — default: HEAD
#   --format <fmt>   Output format: md (default) or text
#   --output <file>  Write to file instead of stdout
#   --no-merge       Exclude merge commits (default: excluded)
#   -h, --help       Show help
# Returns:
#   0 on success, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

main() {
	local from_ref=""
	local to_ref="HEAD"
	local output_format="md"
	local output_file=""
	local include_merges=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			echo "Usage: ./scripts/git/changelog_generate.sh [OPTIONS]"
			echo ""
			echo "Generate a categorized changelog from conventional commits."
			echo ""
			echo "Options:"
			echo "  --from <ref>     Start ref (exclusive; default: latest semver tag or root)"
			echo "  --to <ref>       End ref inclusive (default: HEAD)"
			echo "  --format <fmt>   Output format: md (default) or text"
			echo "  --output <file>  Write to file (default: stdout)"
			echo "  --include-merges Also include merge commits (default: skipped)"
			echo "  -h, --help       Show this help"
			echo ""
			echo "Commit types recognized (CGW_ALL_PREFIXES):"
			echo "  feat, fix, docs, chore, test, refactor, style, perf"
			echo "  Plus any extras configured via CGW_EXTRA_PREFIXES"
			echo ""
			echo "Examples:"
			echo "  ./scripts/git/changelog_generate.sh"
			echo "  ./scripts/git/changelog_generate.sh --from v1.0.0 --to v1.1.0"
			echo "  ./scripts/git/changelog_generate.sh --from v1.0.0 --output CHANGELOG.md"
			exit 0
			;;
		--from) from_ref="${2:-}"; shift ;;
		--to) to_ref="${2:-}"; shift ;;
		--format) output_format="${2:-md}"; shift ;;
		--output) output_file="${2:-}"; shift ;;
		--include-merges) include_merges=1 ;;
		*)
			echo "[ERROR] Unknown flag: $1" >&2
			exit 1
			;;
		esac
		shift
	done

	cd "${PROJECT_ROOT}" || {
		err "Cannot find project root"
		exit 1
	}

	# Validate output format
	case "${output_format}" in
	md | text) ;;
	*)
		err "Unknown format: ${output_format} (use 'md' or 'text')"
		exit 1
		;;
	esac

	# Auto-detect from_ref: latest semver tag
	if [[ -z "${from_ref}" ]]; then
		from_ref=$(git tag -l "v[0-9]*" | sort -V | tail -1 2>/dev/null || true)
		if [[ -z "${from_ref}" ]]; then
			# No semver tags — use root commit (all history)
			from_ref=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1 || true)
		fi
	fi

	# Validate refs
	if ! git rev-parse "${to_ref}" >/dev/null 2>&1; then
		err "Invalid --to ref: ${to_ref}"
		exit 1
	fi
	if [[ -n "${from_ref}" ]]; then
		if ! git rev-parse "${from_ref}" >/dev/null 2>&1; then
			err "Invalid --from ref: ${from_ref}"
			exit 1
		fi
	fi

	# Determine git log range
	local log_range
	if [[ -n "${from_ref}" ]]; then
		log_range="${from_ref}..${to_ref}"
	else
		log_range="${to_ref}"
	fi

	# Get to_ref description for header
	local to_desc
	to_desc=$(git describe --tags --exact-match "${to_ref}" 2>/dev/null || \
	          git log -1 --format="%h" "${to_ref}" 2>/dev/null || echo "${to_ref}")
	local to_date
	to_date=$(git log -1 --format="%ad" --date=short "${to_ref}" 2>/dev/null || date +%Y-%m-%d)

	# Collect commits in range
	local merge_flag="--no-merges"
	[[ ${include_merges} -eq 1 ]] && merge_flag=""

	# shellcheck disable=SC2086  # merge_flag intentionally word-splits when empty
	local commits
	commits=$(git log ${merge_flag} --format="%H|%s|%b" "${log_range}" 2>/dev/null || true)

	if [[ -z "${commits}" ]]; then
		echo "No commits found in range: ${log_range}" >&2
		exit 0
	fi

	# Categorize commits by conventional type
	# Categories: feat, fix, docs, perf, refactor, style, test, chore, other
	local -a cat_feat=() cat_fix=() cat_docs=() cat_perf=()
	local -a cat_refactor=() cat_style=() cat_test=() cat_chore=() cat_other=()

	while IFS='|' read -r hash subject body; do
		[[ -z "${hash}" ]] && continue

		local prefix rest
		if echo "${subject}" | grep -qE "^[a-zA-Z]+:"; then
			prefix=$(echo "${subject}" | sed 's/:.*//')
			rest=$(echo "${subject}" | sed 's/^[^:]*: *//')
		else
			prefix="other"
			rest="${subject}"
		fi

		# Get short hash and PR reference if any
		local short_hash
		short_hash=$(git log -1 --format="%h" "${hash}" 2>/dev/null || echo "${hash:0:7}")

		local entry="${rest} (${short_hash})"

		case "${prefix}" in
		feat) cat_feat+=("${entry}") ;;
		fix) cat_fix+=("${entry}") ;;
		docs) cat_docs+=("${entry}") ;;
		perf) cat_perf+=("${entry}") ;;
		refactor) cat_refactor+=("${entry}") ;;
		style) cat_style+=("${entry}") ;;
		test) cat_test+=("${entry}") ;;
		chore) cat_chore+=("${entry}") ;;
		*) cat_other+=("${entry}") ;;
		esac
	done <<< "${commits}"

	# Build output
	local output=""
	output=$(_build_changelog \
		"${output_format}" "${to_desc}" "${to_date}" "${from_ref}" \
		"${cat_feat[@]+"${cat_feat[@]}"}" \
		"BREAK_FEAT" \
		"${cat_fix[@]+"${cat_fix[@]}"}" \
		"BREAK_FIX" \
		"${cat_docs[@]+"${cat_docs[@]}"}" \
		"BREAK_DOCS" \
		"${cat_perf[@]+"${cat_perf[@]}"}" \
		"BREAK_PERF" \
		"${cat_refactor[@]+"${cat_refactor[@]}"}" \
		"BREAK_REFACTOR" \
		"${cat_style[@]+"${cat_style[@]}"}" \
		"BREAK_STYLE" \
		"${cat_test[@]+"${cat_test[@]}"}" \
		"BREAK_TEST" \
		"${cat_chore[@]+"${cat_chore[@]}"}" \
		"BREAK_CHORE" \
		"${cat_other[@]+"${cat_other[@]}"}" \
		2>/dev/null || true)

	# Write output
	if [[ -n "${output_file}" ]]; then
		echo "${output}" >"${output_file}"
		echo "✓ Changelog written to: ${output_file}" >&2
	else
		echo "${output}"
	fi
}

_build_changelog() {
	local fmt="$1" version="$2" date_str="$3" from_ref="$4"
	shift 4

	# Parse the positional args back into categories using BREAK_ sentinel tokens
	local current_cat="feat"
	declare -A cats
	cats[feat]="" cats[fix]="" cats[docs]="" cats[perf]=""
	cats[refactor]="" cats[style]="" cats[test]="" cats[chore]="" cats[other]=""

	# Re-collect — simpler: re-run git log with format per category
	# (The sentinel approach doesn't work cleanly with arrays passed through positional args)
	# Instead, recollect directly here.
	local merge_flag="--no-merges"

	local log_range
	if [[ -n "${from_ref}" ]]; then
		log_range="${from_ref}..HEAD"
	else
		log_range="HEAD"
	fi

	# Read commits again (simpler than passing arrays through function args)
	while IFS='|' read -r hash subject; do
		[[ -z "${hash}" ]] && continue
		local prefix rest short_hash
		prefix=$(echo "${subject}" | grep -oE "^[a-zA-Z]+" || echo "other")
		rest=$(echo "${subject}" | sed 's/^[^:]*: *//')
		short_hash=$(git log -1 --format="%h" "${hash}" 2>/dev/null || echo "${hash:0:7}")
		local entry="  - ${rest} (${short_hash})"
		case "${prefix}" in
		feat) cats[feat]+="${entry}"$'\n' ;;
		fix) cats[fix]+="${entry}"$'\n' ;;
		docs) cats[docs]+="${entry}"$'\n' ;;
		perf) cats[perf]+="${entry}"$'\n' ;;
		refactor) cats[refactor]+="${entry}"$'\n' ;;
		style) cats[style]+="${entry}"$'\n' ;;
		test) cats[test]+="${entry}"$'\n' ;;
		chore) cats[chore]+="${entry}"$'\n' ;;
		*) cats[other]+="${entry}"$'\n' ;;
		esac
	done < <(git log --no-merges --format="%H|%s" "${log_range}" 2>/dev/null || true)

	local from_label
	from_label="${from_ref:-root}"

	if [[ "${fmt}" == "md" ]]; then
		echo "## ${version} (${date_str})"
		echo ""
		[[ -n "${from_ref}" ]] && echo "> Changes since \`${from_ref}\`" && echo ""

		local section_map=(
			"feat:New Features"
			"fix:Bug Fixes"
			"perf:Performance Improvements"
			"docs:Documentation"
			"refactor:Refactoring"
			"test:Tests"
			"style:Code Style"
			"chore:Maintenance"
			"other:Other Changes"
		)

		local has_any=0
		for entry in "${section_map[@]}"; do
			local key="${entry%%:*}"
			local title="${entry#*:}"
			if [[ -n "${cats[${key}]}" ]]; then
				echo "### ${title}"
				echo ""
				echo "${cats[${key}]}"
				has_any=1
			fi
		done

		[[ ${has_any} -eq 0 ]] && echo "_No categorized commits found in this range._"
	else
		# Plain text
		echo "${version} (${date_str})"
		echo "$(printf '=%.0s' {1..40})"
		[[ -n "${from_ref}" ]] && echo "Changes since ${from_ref}" && echo ""

		local section_map=(
			"feat:New Features"
			"fix:Bug Fixes"
			"perf:Performance"
			"docs:Documentation"
			"refactor:Refactoring"
			"test:Tests"
			"style:Style"
			"chore:Maintenance"
			"other:Other"
		)

		for entry in "${section_map[@]}"; do
			local key="${entry%%:*}"
			local title="${entry#*:}"
			if [[ -n "${cats[${key}]}" ]]; then
				echo "${title}:"
				echo "${cats[${key}]}"
			fi
		done
	fi
}

main "$@"
