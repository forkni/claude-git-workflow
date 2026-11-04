#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexander Korneev
# SPDX-License-Identifier: MIT
# scripts/dev/build_agensi.sh — assemble the standalone Agent Skills zips listed on Agensi
#
# Usage:
#   bash scripts/dev/build_agensi.sh                    # build every skill into dist/agensi/
#   bash scripts/dev/build_agensi.sh --out <dir>        # build somewhere else
#   bash scripts/dev/build_agensi.sh <skill> [...]      # build only the named skills
#   bash scripts/dev/build_agensi.sh --list             # print the skill names and exit
#
# Each skill becomes <out>/<name>/ (the unpacked tree, for review) and <out>/<name>.zip.
# Sources:
#   agensi/<name>/          hand-maintained portable files (SKILL.md, references/ overlays)
#   skill/references/       canonical references, copied with paths rewritten (safe-git-workflow)
#   scripts/git/            canonical scripts, copied as-is except the two packaging defaults below
#
# Packaging-only changes (the repo's own copies are untouched):
#   - ./scripts/git/<x>.sh in shipped Markdown becomes <skill-dir>/scripts/<x>.sh
#   - links to references that a zip does not ship point at the GitHub copy instead
#   - CGW_MARKDOWNLINT_NPX_FALLBACK defaults to 0, so no zip downloads an npm package on its own
#
# Every build runs the portability checks below and exits 1 when one fails; nothing is uploaded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_URL="https://github.com/forkni/claude-git-workflow/blob/main"

ALL_SKILLS=(gitignore-and-local-config git-merge-conflict-resolution safe-git-workflow)

# Always sourced by _common.sh, so every script-bearing skill ships all of them.
BASE_SCRIPTS=(_common.sh _config.sh _lib_conflict.sh _lib_lint.sh _lib_lock.sh _lib_remote.sh)

SAFE_SCRIPTS=(commit_enhanced.sh check_lint.sh fix_lint.sh check_local_files.sh push_validated.sh
  validate_branches.sh merge_with_validation.sh rollback_merge.sh rebase_safe.sh
  cherry_pick_commits.sh stash_work.sh undo_last.sh recover.sh sync_branches.sh
  branch_cleanup.sh branch_diff.sh repo_state.sh bisect_helper.sh)
SAFE_REFERENCES=(wrapper-recipes.md script-reference.md branch-and-merge-rules.md
  error-recovery.md resolving-merge-conflicts.md)
# H2 sections dropped from the shipped references: operations whose scripts are not in the zip,
# and the Claude Code / git-hook specific parts.
SAFE_DROP_SECTIONS=("Creating a PR" "Merging a PR" "Merging docs only" "Generating a changelog"
  "Creating a release" "Worktree management" "Project setup & hygiene" "Reviewing a PR locally"
  "Generating or updating a Markdown Table of Contents" "PreToolUse Guardrail" "CI Failures"
  "CGW Not Found (Linked Worktree)")

# Terms that only make sense inside Claude Code or a vendored install.
PORTABILITY_PATTERN='AskUserQuestion|run_in_background|PreToolUse|\.claude/skills|\.claude/commands|/auto-git-workflow-cmd|\./scripts/git/'
# Patterns marketplace scanners commonly flag. Reported for review, never fatal.
SCAN_PATTERN='rm -rf|reset --hard|push --force|--force-with-lease|filter-branch|filter-repo|curl |wget |\beval\b|base64|npx |chmod |sudo '

out_dir="${REPO_ROOT}/dist/agensi"
selected=()

_usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      _usage
      exit 0
      ;;
    --list)
      printf '%s\n' "${ALL_SKILLS[@]}"
      exit 0
      ;;
    --out)
      [[ -n "${2:-}" ]] || {
        echo "[ERROR] --out needs a directory" >&2
        exit 1
      }
      out_dir="$2"
      shift
      ;;
    -*)
      echo "[ERROR] Unknown flag: $1" >&2
      exit 1
      ;;
    *) selected+=("$1") ;;
  esac
  shift
done
[[ ${#selected[@]} -gt 0 ]] || selected=("${ALL_SKILLS[@]}")

for tool in zip awk sed; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "[ERROR] ${tool} is required" >&2
    exit 1
  }
done

failures=0
_fail() {
  echo "  [FAIL] $*" >&2
  failures=$((failures + 1))
}

# _drop_sections <file> <heading>... — remove each "## <heading>" section (up to the next H2)
# and its "- <heading>" line in a Contents list.
_drop_sections() {
  local file="$1" tmp
  shift
  tmp="$(mktemp)"
  printf '%s\n' "$@" | awk '
    NR == FNR { drop[$0] = 1; next }
    /^## / { h = substr($0, 4); skipping = (h in drop) }
    skipping { next }
    /^- / && (substr($0, 3) in drop) { next }
    { print }
  ' - "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

# _drop_script_blocks <file> <script>... — remove each "**`<script>`** — ..." block
# (up to the next script block, H2 or horizontal rule).
_drop_script_blocks() {
  local file="$1" tmp
  shift
  tmp="$(mktemp)"
  printf '%s\n' "$@" | awk '
    NR == FNR { drop[$0] = 1; next }
    /^\*\*`[a-z_]+\.sh`\*\*/ {
      name = $0; sub(/^\*\*`/, "", name); sub(/`.*/, "", name)
      skipping = (name in drop)
    }
    /^## / || /^---$/ { skipping = 0 }
    skipping { next }
    { print }
  ' - "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

# _rewrite_markdown <file> <shipped-reference>... — skill-relative script paths, and links to
# references this zip does not ship pointed at the GitHub copy.
_rewrite_markdown() {
  local file="$1" tmp
  shift
  tmp="$(mktemp)"
  sed -i.bak -e 's#\./scripts/git/#<skill-dir>/scripts/#g' \
    -e 's#\([( `]\)scripts/git/#\1<skill-dir>/scripts/#g' "${file}"
  rm -f "${file}.bak"
  printf '%s\n' "$@" | awk -v url="${REPO_URL}/skill/references/" '
    NR == FNR { keep[$0] = 1; next }
    {
      line = $0; out = ""
      while (match(line, /\]\([a-z0-9-]+\.md[)#]/)) {
        target = substr(line, RSTART + 2, RLENGTH - 3)
        out = out substr(line, 1, RSTART + 1)
        if (!(target in keep)) out = out url
        line = substr(line, RSTART + 2)
      }
      print out line
    }
  ' - "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

# _package_edits <file> — the few canonical sentences that only hold in a vendored install with
# the Claude Code guardrail or the PR scripts. If one stops matching, the portability check fails.
_package_edits() {
  local file="$1"
  # shellcheck disable=SC2016 # the backticks are literal Markdown, not expansions
  sed -i.bak \
    -e 's/The CGW PreToolUse guardrail blocks every/The CGW command guardrail (where installed) blocks every/' \
    -e 's/: the PreToolUse$/: the CGW command/' \
    -e 's/(the PreToolUse$/(the CGW command/' \
    -e 's#the table in `command/auto-git-workflow-cmd\.md`#the suggestion table in SKILL.md#' \
    -e 's#^3\. Create PR: `<skill-dir>/scripts/create_pr\.sh`$#3. Create PR: `gh pr create`#' \
    -e 's#^\(\# git status/log would verify\. A post-check IS required, though\): Rule 6 — run$#\1 (Rule 6): check the CI#' \
    -e 's#^\# verify_ci\.sh --branch <the branch just pushed> and wait for exit 0, see ci-verification\.md\.$#\# runs this push triggered and wait for them to pass.#' \
    -e 's#^5\. Merge after CI passes: GitHub UI, or `<skill-dir>/scripts/merge_pr\.sh <N>`.*#5. Merge after CI passes: GitHub UI, or `gh pr merge <N> --merge`#' \
    "${file}"
  rm -f "${file}.bak"
}

_check_skill() {
  local name="$1" dir="$2" f desc target
  f="${dir}/SKILL.md"
  [[ -f "${f}" ]] || {
    _fail "${name}: SKILL.md missing"
    return
  }
  [[ "$(sed -n 1p "${f}")" == "---" ]] || _fail "${name}: SKILL.md does not open with frontmatter"
  [[ "$(awk '/^name: /{print $2; exit}' "${f}")" == "${name}" ]] || _fail "${name}: frontmatter name does not match the folder"
  [[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || _fail "${name}: name must be lowercase letters, digits and hyphens"
  desc="$(awk '/^description: /{sub(/^description: /, ""); print; exit}' "${f}")"
  [[ -n "${desc}" ]] || _fail "${name}: description missing"
  [[ ${#desc} -le 1024 ]] || _fail "${name}: description is ${#desc} chars (max 1024)"
  if grep -qE '^(allowed-tools|user-invocable|hooks|context|model):' "${f}"; then
    _fail "${name}: SKILL.md uses agent-specific frontmatter"
  fi

  if grep -rnE "${PORTABILITY_PATTERN}" "${dir}" --include='*.md' >/dev/null; then
    _fail "${name}: agent-specific or vendored-path terms remain:"
    grep -rnE "${PORTABILITY_PATTERN}" "${dir}" --include='*.md' | sed 's/^/      /' >&2
  fi

  # Every relative Markdown link must resolve inside the zip.
  while IFS= read -r link; do
    f="${link%%:*}"
    target="${link#*](}"
    target="${target%%[)#]*}"
    [[ -z "${target}" || "${target}" == http* || "${target}" == mailto:* ]] && continue
    [[ -e "$(dirname "${f}")/${target}" ]] || _fail "${name}: broken link ${target} in ${f#"${dir}"/}"
  done < <(grep -roE '\]\([^)]+\)' "${dir}" --include='*.md')

  # Every script a doc names must ship.
  while IFS= read -r script; do
    [[ -f "${dir}/scripts/${script}" ]] || _fail "${name}: docs name scripts/${script}, which is not in the zip"
  done < <(grep -rhoE '<skill-dir>/scripts/[a-z_]+\.sh' "${dir}" --include='*.md' | sed 's#.*/##' | sort -u)

  if [[ -d "${dir}/scripts" ]]; then
    for f in "${dir}"/scripts/*.sh; do
      bash -n "${f}" || _fail "${name}: syntax error in ${f##*/}"
      [[ -x "${f}" ]] || _fail "${name}: ${f##*/} is not executable"
    done
  fi
}

_report_scan_patterns() {
  local dir="$1" hits
  hits="$(grep -rnE "${SCAN_PATTERN}" "${dir}" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "${hits}" ]]; then
    echo "  scan-sensitive lines (review, not fatal): $(wc -l <<<"${hits}")"
    # shellcheck disable=SC2001 # a per-line prefix swap over many lines
    sed "s#^${dir}/#      #" <<<"${hits}" | cut -c1-160
  else
    echo "  scan-sensitive lines: none"
  fi
}

_build_one() {
  local name="$1" stage s
  stage="${out_dir}/${name}"
  [[ -d "${REPO_ROOT}/agensi/${name}" ]] || {
    _fail "unknown skill: ${name}"
    return
  }
  echo "==> ${name}"
  rm -rf -- "${stage}" "${out_dir}/${name}.zip"
  mkdir -p "${stage}"
  cp -R "${REPO_ROOT}/agensi/${name}/." "${stage}/"

  if [[ "${name}" == "safe-git-workflow" ]]; then
    mkdir -p "${stage}/references" "${stage}/scripts" "${stage}/assets"
    for s in "${SAFE_REFERENCES[@]}"; do
      cp "${REPO_ROOT}/skill/references/${s}" "${stage}/references/${s}"
    done
    for s in "${BASE_SCRIPTS[@]}" "${SAFE_SCRIPTS[@]}"; do
      cp "${REPO_ROOT}/scripts/git/${s}" "${stage}/scripts/${s}"
      chmod 755 "${stage}/scripts/${s}"
    done
    cp "${REPO_ROOT}/cgw.conf.example" "${stage}/assets/cgw.conf.example"

    local -a unshipped=()
    for s in "${REPO_ROOT}"/scripts/git/*.sh; do
      s="${s##*/}"
      [[ " ${BASE_SCRIPTS[*]} ${SAFE_SCRIPTS[*]} " == *" ${s} "* ]] || unshipped+=("${s}")
    done
    _drop_sections "${stage}/references/wrapper-recipes.md" "${SAFE_DROP_SECTIONS[@]}"
    _drop_sections "${stage}/references/error-recovery.md" "${SAFE_DROP_SECTIONS[@]}"
    _drop_script_blocks "${stage}/references/script-reference.md" "${unshipped[@]}"
    for s in "${stage}"/references/*.md; do
      _rewrite_markdown "${s}" "${SAFE_REFERENCES[@]}"
      _package_edits "${s}"
    done

    sed -i.bak 's/^CGW_MARKDOWNLINT_NPX_FALLBACK|1|/CGW_MARKDOWNLINT_NPX_FALLBACK|0|/' "${stage}/scripts/_config.sh"
    sed -i.bak 's/^# CGW_MARKDOWNLINT_NPX_FALLBACK=1  # set to 0 to disable npx fallback/# CGW_MARKDOWNLINT_NPX_FALLBACK=0  # 0 in this package (no npx download); 1 allows the npx fallback/' \
      "${stage}/assets/cgw.conf.example"
    rm -f "${stage}/scripts/_config.sh.bak" "${stage}/assets/cgw.conf.example.bak"
    grep -q '^CGW_MARKDOWNLINT_NPX_FALLBACK|0|' "${stage}/scripts/_config.sh" ||
      _fail "${name}: could not set the npx fallback default"
  fi

  # Normal permissions inside the zip: mktemp leaves rewritten files at 0600.
  find "${stage}" -type d -exec chmod 755 {} +
  find "${stage}" -type f ! -name '*.sh' -exec chmod 644 {} +

  _check_skill "${name}" "${stage}"
  _report_scan_patterns "${stage}"
  (cd "${out_dir}" && zip -qr "${name}.zip" "${name}")
  echo "  zip: ${out_dir}/${name}.zip ($(du -k "${out_dir}/${name}.zip" | cut -f1) KB, $(find "${stage}" -type f | wc -l) files)"
}

mkdir -p "${out_dir}"
for skill in "${selected[@]}"; do
  _build_one "${skill}"
done

if [[ ${failures} -gt 0 ]]; then
  echo "[FAIL] ${failures} check(s) failed" >&2
  exit 1
fi
echo "[OK] built ${#selected[@]} skill(s) in ${out_dir}"
