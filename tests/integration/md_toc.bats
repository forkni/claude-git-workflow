#!/usr/bin/env bats
# tests/integration/md_toc.bats - Integration tests for md_toc.sh
# Runs: bats tests/integration/md_toc.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

setup() {
  create_test_repo
}

teardown() {
  cleanup_test_repo
}

_run_md_toc() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    bash "${CGW_PROJECT_ROOT}/scripts/git/md_toc.sh" "$@"
  ) 2>&1
}

_write_fixture() {
  local name="$1"
  cat >"${TEST_REPO_DIR}/${name}"
}

# ── Basic generation ───────────────────────────────────────────────────────────

@test "generates a bullet per heading with correct anchors" {
  _write_fixture doc.md <<'EOF'
# My Title

## Section One

### Sub Section
EOF
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[My Title](#my-title)"* ]]
  [[ "${output}" == *"[Section One](#section-one)"* ]]
  [[ "${output}" == *"[Sub Section](#sub-section)"* ]]
}

@test "indents nested headings by level relative to the shallowest heading" {
  _write_fixture doc.md <<'EOF'
## Top

### Child
EOF
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  # Top (h2, shallowest) gets 0 indent; Child (h3) gets 2 spaces
  [[ "${output}" == *$'\n''  * [Child]'* ]] || [[ "${output}" == '  * [Child]'* ]]
  [[ "${output}" == "* [Top]"* ]]
}

@test "no headings produces empty output and exit 0" {
  _write_fixture doc.md <<'EOF'
Just a paragraph.
EOF
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "missing file exits 1" {
  run _run_md_toc nonexistent.md
  [ "${status}" -eq 1 ]
}

@test "no file argument and no --all exits 1" {
  run _run_md_toc
  [ "${status}" -eq 1 ]
}

# ── Duplicate heading de-duplication ──────────────────────────────────────────

@test "duplicate heading text gets slug, slug-1, slug-2 suffixes" {
  _write_fixture doc.md <<'EOF'
## Section One

## Section One

## Section One
EOF
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(#section-one)"* ]]
  [[ "${output}" == *"(#section-one-1)"* ]]
  [[ "${output}" == *"(#section-one-2)"* ]]
}

# ── Fenced code blocks are skipped ────────────────────────────────────────────

@test "heading-like lines inside fenced code blocks are ignored" {
  _write_fixture doc.md <<'EOF'
## Real Heading

```bash
# Not A Heading
```

~~~
## Also Not A Heading
~~~
EOF
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Real Heading"* ]]
  [[ "${output}" != *"Not A Heading"* ]]
  [[ "${output}" != *"Also Not A Heading"* ]]
}

# ── Markdown stripped from slugs only, not display text ───────────────────────

@test "emphasis and inline code in heading text are stripped only from the slug" {
  _write_fixture doc.md <<'EOF'
## **Bold** and `code`
EOF
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[**Bold** and \`code\`](#bold-and-code)"* ]]
}

# ── --insert ───────────────────────────────────────────────────────────────

@test "--insert creates markers when none exist, after the first H1" {
  _write_fixture doc.md <<'EOF'
# Title

Intro text.

## Overview
EOF
  run _run_md_toc doc.md --insert
  [ "${status}" -eq 0 ]
  run cat "${TEST_REPO_DIR}/doc.md"
  [[ "${output}" == "# Title"* ]]
  [[ "${output}" == *"<!--ts-->"* ]]
  [[ "${output}" == *"<!--te-->"* ]]
  [[ "${output}" == *"Intro text."* ]]
}

@test "--insert creates markers at the top when there is no H1" {
  _write_fixture doc.md <<'EOF'
## Overview

Some content.
EOF
  run _run_md_toc doc.md --insert
  [ "${status}" -eq 0 ]
  first_line="$(head -n1 "${TEST_REPO_DIR}/doc.md")"
  [ "${first_line}" = "<!--ts-->" ]
}

@test "--insert is idempotent: second run reports up to date and makes no further changes" {
  _write_fixture doc.md <<'EOF'
# Title

## Overview
EOF
  _run_md_toc doc.md --insert
  run bash -c "md5sum '${TEST_REPO_DIR}/doc.md' 2>/dev/null || sha1sum '${TEST_REPO_DIR}/doc.md'"
  first_hash="${output}"
  run _run_md_toc doc.md --insert
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"up to date"* ]]
  run bash -c "md5sum '${TEST_REPO_DIR}/doc.md' 2>/dev/null || sha1sum '${TEST_REPO_DIR}/doc.md'"
  [ "${output}" = "${first_hash}" ]
}

@test "--insert regenerates without duplicating a prior TOC's own heading" {
  # Regression guard: the TOC block's own "## Table of Contents" heading must
  # never feed back into a subsequent regeneration.
  _write_fixture doc.md <<'EOF'
# Title

## Overview
EOF
  _run_md_toc doc.md --insert
  _run_md_toc doc.md --insert
  run _run_md_toc doc.md
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Table of Contents"* ]]
}

@test "--insert updates an existing TOC block when headings change" {
  _write_fixture doc.md <<'EOF'
# Title

## Overview
EOF
  _run_md_toc doc.md --insert
  printf '\n## New Section\n' >>"${TEST_REPO_DIR}/doc.md"
  run _run_md_toc doc.md --insert
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Updated TOC"* ]]
  run cat "${TEST_REPO_DIR}/doc.md"
  [[ "${output}" == *"New Section"* ]]
}

# ── --check ────────────────────────────────────────────────────────────────

@test "--check exits 0 when the TOC is up to date" {
  _write_fixture doc.md <<'EOF'
# Title

## Overview
EOF
  _run_md_toc doc.md --insert
  run _run_md_toc doc.md --check
  [ "${status}" -eq 0 ]
}

@test "--check exits 1 when the file has no TOC block at all" {
  _write_fixture doc.md <<'EOF'
# Title

## Overview
EOF
  run _run_md_toc doc.md --check
  [ "${status}" -eq 1 ]
}

@test "--check exits 1 when a heading was added after the last insert" {
  _write_fixture doc.md <<'EOF'
# Title

## Overview
EOF
  _run_md_toc doc.md --insert
  printf '\n## New Section\n' >>"${TEST_REPO_DIR}/doc.md"
  run _run_md_toc doc.md --check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"stale"* ]]
}

# ── --all ────────────────────────────────────────────────────────────────────

@test "--all updates only tracked files containing the <!--ts--> marker" {
  _write_fixture marked.md <<'EOF'
<!--ts-->
<!--te-->

## Marked File Heading
EOF
  _write_fixture unmarked.md <<'EOF'
## Unmarked File Heading
EOF
  git -C "${TEST_REPO_DIR}" add marked.md unmarked.md
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add fixtures"

  run _run_md_toc --all
  [ "${status}" -eq 0 ]

  run cat "${TEST_REPO_DIR}/marked.md"
  [[ "${output}" == *"Marked File Heading"* ]]

  run cat "${TEST_REPO_DIR}/unmarked.md"
  [[ "${output}" == "## Unmarked File Heading" ]]
}

@test "--all combined with a file argument exits 1" {
  run _run_md_toc doc.md --all
  [ "${status}" -eq 1 ]
}

# ── --help / unknown flag ─────────────────────────────────────────────────────

@test "--help exits 0 and prints Usage:" {
  run _run_md_toc --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "unknown flag exits 1" {
  run _run_md_toc doc.md --bogus-flag
  [ "${status}" -eq 1 ]
}
