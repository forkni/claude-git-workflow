#!/usr/bin/env bash
# md_toc.sh - Generate/insert a Markdown Table of Contents
# Purpose: Offline port of stas00/git-tools' gh-md-toc. Computes GitHub-compatible
#          heading slugs locally instead of POSTing to the GitHub markdown API,
#          so it needs no network access, auth token, or rate limit.
# Usage: ./scripts/git/md_toc.sh <file> [OPTIONS]
#        ./scripts/git/md_toc.sh --all
#
# Globals:
#   SCRIPT_DIR   - Directory containing this script
#   PROJECT_ROOT - Auto-detected git repo root (set by _config.sh)
# Arguments:
#   <file>       Markdown file to read (default action: print TOC to stdout)
#   --insert     Replace/create the <!--ts-->...<!--te--> block in <file> in place
#   --check      Exit 1 if the in-file TOC block is stale (CI-friendly)
#   --all        Apply --insert to every tracked *.md file containing <!--ts-->
#   -h, --help   Show help
# Returns:
#   0 on success (or up-to-date), 1 on error / stale TOC / unknown flag
#
# Notes:
#   Heading levels are indented 2 spaces per level, relative to the shallowest
#   heading level found in the file (e.g. if the file's shallowest heading is
#   h2, h2 entries get 0 indent and h3 entries get 2 spaces). Fenced code blocks
#   (``` or ~~~) are skipped when scanning for headings. Duplicate heading text
#   is de-duplicated as slug, slug-1, slug-2, ... matching GitHub's own scheme.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# _md_toc_extract_headings <file>
#   Stdout: "LEVEL<TAB>TEXT" per ATX heading (# .. ######), one per line.
#   Skips lines inside fenced code blocks (``` or ~~~) and inside any existing
#   <!--ts-->...<!--te--> TOC block (whose own "## Table of Contents" heading
#   and bullet list must never feed back into a subsequent regeneration).
_md_toc_extract_headings() {
  local file="$1"
  local in_fence=0
  local fence_marker=""
  local in_toc_block=0
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == *"<!--ts-->"* ]]; then
      in_toc_block=1
      continue
    fi
    if [[ "${line}" == *"<!--te-->"* ]]; then
      in_toc_block=0
      continue
    fi
    [[ ${in_toc_block} -eq 1 ]] && continue

    if [[ "${line}" =~ ^[[:space:]]*(\`\`\`|~~~) ]]; then
      if [[ ${in_fence} -eq 0 ]]; then
        in_fence=1
        fence_marker="${BASH_REMATCH[1]}"
      elif [[ "${line}" =~ ^[[:space:]]*${fence_marker} ]]; then
        in_fence=0
      fi
      continue
    fi
    [[ ${in_fence} -eq 1 ]] && continue

    if [[ "${line}" =~ ^(#{1,6})[[:space:]]+(.+)$ ]]; then
      local level="${#BASH_REMATCH[1]}"
      local text="${BASH_REMATCH[2]}"
      # Strip optional trailing ATX closing hashes ("## Heading ##")
      text="$(printf '%s' "${text}" | sed -E 's/[[:space:]]+#+[[:space:]]*$//')"
      printf '%s\t%s\n' "${level}" "${text}"
    fi
  done <"${file}"
}

# Reset between files/calls -- tracks slug occurrence counts for de-duplication.
declare -A _MD_TOC_SLUG_SEEN=()
_md_toc_reset_slugs() {
  _MD_TOC_SLUG_SEEN=()
}

# _md_toc_slugify <heading-text>
#   Sets $_MD_TOC_SLUG_RESULT to the GitHub-compatible anchor slug. Strips
#   markdown links/code/emphasis, lowercases, drops punctuation, spaces ->
#   hyphens. De-dupes repeats within the current _md_toc_reset_slugs scope as
#   slug, slug-1, slug-2, ...
#   NOTE: must be called directly (not via `slug=$(_md_toc_slugify ...)`) --
#   command substitution forks a subshell, which would silently discard this
#   function's writes to the shared _MD_TOC_SLUG_SEEN dedup counters.
declare -g _MD_TOC_SLUG_RESULT=""
_md_toc_slugify() {
  local text="$1"
  local slug="${text}"
  slug="$(printf '%s' "${slug}" | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g')" # [text](url) -> text
  # shellcheck disable=SC2016  # single-quoted sed script: backticks are literal regex, not command substitution
  slug="$(printf '%s' "${slug}" | sed -E 's/`+([^`]*)`+/\1/g')"             # `code` -> code
  slug="$(printf '%s' "${slug}" | sed -E 's/(\*\*\*|\*\*|\*|___|__|_)//g')" # emphasis markers
  slug="$(printf '%s' "${slug}" | tr '[:upper:]' '[:lower:]')"
  slug="$(printf '%s' "${slug}" | sed -E 's/[^a-z0-9 _-]//g')"
  slug="$(printf '%s' "${slug}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  slug="${slug// /-}"

  local base="${slug}"
  local n="${_MD_TOC_SLUG_SEEN[${base}]:-0}"
  if ((n > 0)); then
    _MD_TOC_SLUG_SEEN["${base}"]=$((n + 1))
    slug="${base}-${n}"
  else
    _MD_TOC_SLUG_SEEN["${base}"]=1
  fi
  _MD_TOC_SLUG_RESULT="${slug}"
}

# _md_toc_generate <file>
#   Stdout: TOC body ("* [text](#slug)" lines, indented by heading depth).
#   Empty output (no lines) when the file has no headings.
_md_toc_generate() {
  local file="$1"
  _md_toc_reset_slugs
  local headings
  headings="$(_md_toc_extract_headings "${file}")"
  [[ -z "${headings}" ]] && return 0

  local min_level=6
  local level text
  while IFS=$'\t' read -r level text; do
    [[ -z "${level}" ]] && continue
    ((level < min_level)) && min_level=${level}
  done <<<"${headings}"

  while IFS=$'\t' read -r level text; do
    [[ -z "${level}" ]] && continue
    local indent_n=$(((level - min_level) * 2))
    local indent
    indent="$(printf '%*s' "${indent_n}" '')"
    _md_toc_slugify "${text}"
    printf '%s* [%s](#%s)\n' "${indent}" "${text}" "${_MD_TOC_SLUG_RESULT}"
  done <<<"${headings}"
}

# _md_toc_process_file <file> [quiet=0]
#   Inserts/replaces the <!--ts-->...<!--te--> TOC block in <file> in place.
#   Creates the markers (after the first top-level "# " heading, or at the top
#   of the file if none) when they don't already exist. No-op (no write) if
#   the regenerated content is byte-identical to the current file.
#   Returns 0 always (write failures propagate via non-zero mv/awk exit, still
#   surfaced to the caller through the function's own return).
_md_toc_process_file() {
  local file="$1"
  local quiet="${2:-0}"
  local toc
  toc="$(_md_toc_generate "${file}")"

  local tmp
  tmp="$(mktemp)"

  if grep -q '<!--ts-->' "${file}" 2>/dev/null && grep -q '<!--te-->' "${file}" 2>/dev/null; then
    awk -v toc="${toc}" '
      BEGIN { in_block = 0 }
      /<!--ts-->/ {
        print
        print "## Table of Contents"
        print ""
        print toc
        print ""
        in_block = 1
        next
      }
      /<!--te-->/ {
        in_block = 0
        print
        next
      }
      in_block { next }
      { print }
    ' "${file}" >"${tmp}"
  else
    local insert_line
    insert_line="$(grep -n -m1 '^# ' "${file}" 2>/dev/null | cut -d: -f1 || true)"
    {
      if [[ -n "${insert_line}" ]]; then
        head -n "${insert_line}" "${file}"
        echo ""
      fi
      echo "<!--ts-->"
      echo "## Table of Contents"
      echo ""
      echo "${toc}"
      echo ""
      echo "<!--te-->"
      if [[ -n "${insert_line}" ]]; then
        echo ""
        tail -n "+$((insert_line + 1))" "${file}"
      else
        cat "${file}"
      fi
    } >"${tmp}"
  fi

  if ! cmp -s "${file}" "${tmp}"; then
    mv "${tmp}" "${file}"
    [[ "${quiet}" -eq 0 ]] && echo "[OK] Updated TOC in ${file}"
  else
    rm -f "${tmp}"
    [[ "${quiet}" -eq 0 ]] && echo "[OK] TOC already up to date: ${file}"
  fi
  return 0
}

# _md_toc_check_file <file>
#   Returns 0 if the in-file TOC block matches what would be (re)generated,
#   1 (with an error message) if it is missing or stale.
_md_toc_check_file() {
  local file="$1"
  local tmp_copy
  tmp_copy="$(mktemp)"
  cp "${file}" "${tmp_copy}"
  _md_toc_process_file "${tmp_copy}" 1 >/dev/null

  if cmp -s "${file}" "${tmp_copy}"; then
    rm -f "${tmp_copy}"
    echo "[OK] TOC up to date: ${file}"
    return 0
  else
    rm -f "${tmp_copy}"
    err "TOC is stale: ${file} (run: ./scripts/git/md_toc.sh --insert ${file})"
    return 1
  fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local insert=0
  local check=0
  local all=0
  local target_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/md_toc.sh <file> [OPTIONS]"
        echo "       ./scripts/git/md_toc.sh --all"
        echo ""
        echo "Generate or insert a Markdown Table of Contents (offline -- no GitHub API)."
        echo ""
        echo "Options:"
        echo "  --insert     Replace/create the <!--ts-->...<!--te--> block in <file>"
        echo "  --check      Exit 1 if the in-file TOC is stale (CI-friendly)"
        echo "  --all        Apply --insert to every tracked *.md file with a <!--ts--> marker"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/md_toc.sh docs/usage.md              # print TOC to stdout"
        echo "  ./scripts/git/md_toc.sh docs/usage.md --insert      # insert/update in place"
        echo "  ./scripts/git/md_toc.sh docs/usage.md --check       # CI: fail if stale"
        echo "  ./scripts/git/md_toc.sh --all                       # update every marked *.md"
        exit 0
        ;;
      --insert) insert=1 ;;
      --check) check=1 ;;
      --all) all=1 ;;
      -*)
        err "Unknown flag: $1"
        exit 1
        ;;
      *)
        if [[ -z "${target_file}" ]]; then
          target_file="$1"
        else
          err "Unexpected argument: $1"
          exit 1
        fi
        ;;
    esac
    shift
  done

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  if [[ ${all} -eq 1 ]]; then
    if [[ -n "${target_file}" ]]; then
      err "--all cannot be combined with a file argument"
      exit 1
    fi
    local any_fail=0
    local f
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      grep -q '<!--ts-->' "${f}" 2>/dev/null || continue
      _md_toc_process_file "${f}" 0 || any_fail=1
    done < <(git ls-files '*.md')
    exit "${any_fail}"
  fi

  if [[ -z "${target_file}" ]]; then
    err "File argument required (or use --all)"
    exit 1
  fi

  if [[ ! -f "${target_file}" ]]; then
    err "File not found: ${target_file}"
    exit 1
  fi

  if [[ ${check} -eq 1 ]]; then
    _md_toc_check_file "${target_file}"
    exit $?
  fi

  if [[ ${insert} -eq 1 ]]; then
    _md_toc_process_file "${target_file}" 0
    exit $?
  fi

  _md_toc_generate "${target_file}"
}

main "$@"
