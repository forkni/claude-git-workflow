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
#   --from <ref>     Start ref (exclusive) -- default: latest semver tag or first commit
#   --to <ref>       End ref (inclusive) -- default: HEAD
#   --version <label> Override the section heading (default: exact tag match on --to, else
#                     its short hash). Use when generating a changelog before the release tag
#                     exists, e.g. --version v1.2.0.
#   --format <fmt>   Output format: md (default) or text
#   --output <file>  Write to file instead of stdout
#   --prepend        With --output, stack the new section above the file's existing content
#                     instead of overwriting it (builds a cumulative changelog). Refuses if the
#                     resolved heading is already present in the file.
#   --include-merges Include merge commits (default: excluded)
#   -h, --help       Show help
# Returns:
#   0 on success, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

main() {
  local from_ref=""
  local to_ref="HEAD"
  local version_label=""
  local output_format="md"
  local output_file=""
  local include_merges=0
  local prepend=0

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
        echo "  --version <label> Override the section heading (default: exact tag match on"
        echo "                   --to, else its short hash). Use before the release tag exists."
        echo "  --format <fmt>   Output format: md (default) or text"
        echo "  --output <file>  Write to file (default: stdout)"
        echo "  --prepend        With --output, stack above existing file content instead of"
        echo "                   overwriting it (cumulative changelog). Refuses on a duplicate"
        echo "                   heading."
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
        echo "  ./scripts/git/changelog_generate.sh --from v1.0.0 --version v1.1.0 \\"
        echo "    --output CHANGELOG.md --prepend"
        exit 0
        ;;
      --from)
        from_ref="${2:-}"
        shift
        ;;
      --to)
        to_ref="${2:-}"
        shift
        ;;
      --version)
        version_label="${2:-}"
        shift
        ;;
      --format)
        output_format="${2:-md}"
        shift
        ;;
      --output)
        output_file="${2:-}"
        shift
        ;;
      --prepend) prepend=1 ;;
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
      # No semver tags -- use root commit (all history)
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

  # Get to_ref description for header.  --version overrides the derived value outright --
  # useful when generating a changelog before the release tag exists (git describe would
  # otherwise fall back to a commit hash).
  local to_desc
  if [[ -n "${version_label}" ]]; then
    to_desc="${version_label}"
  else
    to_desc=$(git describe --tags --exact-match "${to_ref}" 2>/dev/null ||
      git log -1 --format="%h" "${to_ref}" 2>/dev/null || echo "${to_ref}")
  fi
  local to_date
  to_date=$(git log -1 --format="%ad" --date=short "${to_ref}" 2>/dev/null || date +%Y-%m-%d)

  # Collect commits in range
  local merge_flag="--no-merges"
  [[ ${include_merges} -eq 1 ]] && merge_flag=""

  # Categorize commits by conventional type
  # Categories: feat, fix, docs, perf, refactor, style, test, chore, other
  local -a cat_feat=() cat_fix=() cat_docs=() cat_perf=()
  local -a cat_refactor=() cat_style=() cat_test=() cat_chore=() cat_other=()

  # Use ASCII unit separator (0x1F) between fields and record separator (0x1E)
  # between commits.  These characters never appear in commit subjects or bodies,
  # unlike '|' which users legitimately put in messages.
  # shellcheck disable=SC2086  # merge_flag intentionally word-splits when empty
  local raw_commits
  raw_commits=$(git log ${merge_flag} --format="%H%x1f%s%x1e" "${log_range}" 2>/dev/null || true)

  if [[ -z "${raw_commits}" ]]; then
    echo "No commits found in range: ${log_range}" >&2
    exit 0
  fi

  local record hash subject
  while IFS=$'\x1e' read -r record; do
    [[ -z "${record}" ]] && continue
    IFS=$'\x1f' read -r hash subject <<<"${record}"
    [[ -z "${hash}" ]] && continue

    local prefix rest
    if echo "${subject}" | grep -qE "^[a-zA-Z]+:"; then
      prefix="${subject%%:*}"
      rest="${subject#*: }"
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
  done <<<"${raw_commits}"

  # Build output directly from the already-categorized arrays
  # (Using individual vars instead of declare -A for Bash 3.2 compat)
  local cats_feat="" cats_fix="" cats_docs="" cats_perf=""
  local cats_refactor="" cats_style="" cats_test="" cats_chore="" cats_other=""

  for item in "${cat_feat[@]+"${cat_feat[@]}"}"; do cats_feat+="  - ${item}"$'\n'; done
  for item in "${cat_fix[@]+"${cat_fix[@]}"}"; do cats_fix+="  - ${item}"$'\n'; done
  for item in "${cat_docs[@]+"${cat_docs[@]}"}"; do cats_docs+="  - ${item}"$'\n'; done
  for item in "${cat_perf[@]+"${cat_perf[@]}"}"; do cats_perf+="  - ${item}"$'\n'; done
  for item in "${cat_refactor[@]+"${cat_refactor[@]}"}"; do cats_refactor+="  - ${item}"$'\n'; done
  for item in "${cat_style[@]+"${cat_style[@]}"}"; do cats_style+="  - ${item}"$'\n'; done
  for item in "${cat_test[@]+"${cat_test[@]}"}"; do cats_test+="  - ${item}"$'\n'; done
  for item in "${cat_chore[@]+"${cat_chore[@]}"}"; do cats_chore+="  - ${item}"$'\n'; done
  for item in "${cat_other[@]+"${cat_other[@]}"}"; do cats_other+="  - ${item}"$'\n'; done

  local section_map_md=(
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
  local section_map_text=(
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

  local output=""
  local heading_line=""
  if [[ "${output_format}" == "md" ]]; then
    heading_line="## ${to_desc} (${to_date})"
    output="${heading_line}"$'\n\n'
    [[ -n "${from_ref}" ]] && output+="> Changes since \`${from_ref}\`"$'\n\n'

    local has_any=0
    for sec in "${section_map_md[@]}"; do
      local key="${sec%%:*}"
      local title="${sec#*:}"
      local cat_val=""
      case "${key}" in
        feat) cat_val="${cats_feat}" ;; fix) cat_val="${cats_fix}" ;;
        docs) cat_val="${cats_docs}" ;; perf) cat_val="${cats_perf}" ;;
        refactor) cat_val="${cats_refactor}" ;; style) cat_val="${cats_style}" ;;
        test) cat_val="${cats_test}" ;; chore) cat_val="${cats_chore}" ;;
        other) cat_val="${cats_other}" ;;
      esac
      if [[ -n "${cat_val}" ]]; then
        output+="### ${title}"$'\n\n'
        output+="${cat_val}"$'\n'
        has_any=1
      fi
    done
    [[ ${has_any} -eq 0 ]] && output+="_No categorized commits found in this range._"$'\n'
  else
    heading_line="${to_desc} (${to_date})"
    output="${heading_line}"$'\n'
    output+="$(printf '=%.0s' {1..40})"$'\n'
    [[ -n "${from_ref}" ]] && output+="Changes since ${from_ref}"$'\n\n'

    for sec in "${section_map_text[@]}"; do
      local key="${sec%%:*}"
      local title="${sec#*:}"
      local cat_val=""
      case "${key}" in
        feat) cat_val="${cats_feat}" ;; fix) cat_val="${cats_fix}" ;;
        docs) cat_val="${cats_docs}" ;; perf) cat_val="${cats_perf}" ;;
        refactor) cat_val="${cats_refactor}" ;; style) cat_val="${cats_style}" ;;
        test) cat_val="${cats_test}" ;; chore) cat_val="${cats_chore}" ;;
        other) cat_val="${cats_other}" ;;
      esac
      if [[ -n "${cat_val}" ]]; then
        output+="${title}:"$'\n'
        output+="${cat_val}"$'\n'
      fi
    done
  fi

  # Write output
  if [[ -n "${output_file}" ]]; then
    if [[ ${prepend} -eq 1 ]] && [[ -f "${output_file}" ]]; then
      if grep -qF "${heading_line}" "${output_file}" 2>/dev/null; then
        err "Section '${heading_line}' already present in ${output_file} -- refusing to duplicate"
        exit 1
      fi
      local existing_content
      existing_content=$(cat "${output_file}")
      {
        echo "${output}"
        echo ""
        echo "${existing_content}"
      } >"${output_file}"
    else
      echo "${output}" >"${output_file}"
    fi
    echo "[OK] Changelog written to: ${output_file}" >&2
  else
    echo "${output}"
  fi
}

main "$@"
