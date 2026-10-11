#!/usr/bin/env bash
# tests/lint_doc_snippets.sh
# Lint the ```bash fenced snippets in skill/ and command/ docs, which agents copy
# and run verbatim but which no other check parses:
#   1. bash -n          (syntax)
#   2. shellcheck       (warnings and above, minus codes that are noise for a snippet)
#   3. unbounded loops  (`until`/`while true` with no counter, break or timeout)
#
# Placeholders such as <branch> are replaced with PLACEHOLDER before linting. Preface a
# fence with `<!-- snippet-lint: skip -->` to exempt a block that is pseudo-code.
#
# Convention: usage synopses such as `[--a | --b <x>]` go in ```text fences; ```bash is
# for commands an agent runs verbatim.
#
# Usage: bash tests/lint_doc_snippets.sh [file.md ...]
# Exit: 0 = clean, 1 = one or more findings (printed to stderr).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Noise for a snippet: values consumed by the reader (SC2034), no shebang (SC2148), and
# unquoted expansions of config flag strings, which are split on purpose (SC2086).
# SC2154 (variable used but never assigned) stays on: it is what catches a snippet that
# relies on variables its own block never sets. SC1083 flags git reflog syntax such as
# stash@{0} and HEAD@{u}, and SC2010 flags `ls | grep` over fixed git-internal file names.
SC_EXCLUDE="${CGW_SNIPPET_SC_EXCLUDE:-SC2034,SC2148,SC2086,SC1083,SC2010}"

if (($# > 0)); then
  DOCS=("$@")
else
  mapfile -t DOCS < <(cd "$REPO_ROOT" && find skill command -name '*.md' | sort)
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "[lint_doc_snippets] shellcheck not found" >&2
  exit 1
fi

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

checked=0
fail=0

_fail() {
  printf '  FAIL  %s\n' "$*" >&2
  ((fail++)) || true
}

for doc in "${DOCS[@]}"; do
  [[ -f "${doc}" ]] || doc="${REPO_ROOT}/${doc}"
  rel="${doc#"${REPO_ROOT}"/}"

  # Split the doc into one file per ```bash block, named <index>.<startline>.sh
  rm -f "${_tmp}"/*.sh
  awk -v dir="${_tmp}" '
    /^<!-- snippet-lint: skip -->/ { skip_next = 1; next }
    /^```(bash|sh|shell)[[:space:]]*$/ && !inblock {
      inblock = 1; n++; start = NR + 1
      out = (skip_next ? "/dev/null" : sprintf("%s/%03d.%d.sh", dir, n, start))
      skip_next = 0; next
    }
    /^```/ && inblock { inblock = 0; close(out); next }
    inblock { print > out }
    !/^[[:space:]]*$/ && !inblock { skip_next = 0 }
  ' "${doc}"

  for snippet in "${_tmp}"/*.sh; do
    [[ -f "${snippet}" ]] || continue
    start="${snippet%.sh}"
    start="${start##*.}"
    where="${rel}:${start}"
    sed -i -E -e 's/<[A-Za-z][A-Za-z0-9_-]*>/PLACEHOLDER/g' \
      -e 's/(^|[^$])\{[A-Za-z][A-Za-z0-9_-]*\}/\1PLACEHOLDER/g' "${snippet}"
    ((checked++)) || true

    if ! err="$(bash -n "${snippet}" 2>&1)"; then
      _fail "${where}: bash -n: ${err#"${snippet}: "}"
      continue
    fi

    # Read from stdin so findings are reported as "-:line:col" instead of a temp path.
    if ! sc="$(shellcheck -s bash -S warning -e "${SC_EXCLUDE}" -f gcc - <"${snippet}" 2>&1)"; then
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        _fail "${where}: shellcheck: ${line#-:}"
      done <<<"${sc}"
    fi

    # Unbounded wait loop: `until`/`while true|:` whose body has no counter, break, return or exit.
    if grep -qE '^[[:space:]]*(until[[:space:]]|while[[:space:]]+(true|:)([[:space:];]|$))' "${snippet}" &&
      ! grep -qE '\bbreak\b|\breturn\b|\bexit\b|\bseq\b|\(\(|timeout|SECONDS|deadline' "${snippet}"; then
      _fail "${where}: unbounded wait loop (add an attempt counter or deadline)"
    fi
  done
done

printf '%d snippet(s) checked, %d finding(s)\n' "${checked}" "${fail}"
if ((fail > 0)); then
  echo 'hint: usage synopses belong in a text fence; bash fences are linted as runnable commands' >&2
fi
((fail == 0))
