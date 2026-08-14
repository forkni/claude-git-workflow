#!/usr/bin/env bash
# tests/helpers/mocks.bash - Mock external tools for CGW integration tests
# Usage: load '../helpers/mocks'  (from within a .bats file)

# Each install_mock_* function:
#   1. Creates a fake executable in $MOCK_BIN_DIR
#   2. Prepends $MOCK_BIN_DIR to $PATH

# ── Shared bin dir ─────────────────────────────────────────────────────────────

setup_mock_bin() {
  MOCK_BIN_DIR="${TEST_TMPDIR}/mock-bin"
  export MOCK_BIN_DIR
  mkdir -p "${MOCK_BIN_DIR}"
  export PATH="${MOCK_BIN_DIR}:${PATH}"

  # This dir only shadows PATH for names it explicitly mocks -- a real npx
  # from the host/CI runner (e.g. GitHub Actions' preinstalled Node.js) is
  # still resolvable, and _cgw_detect_markdownlint()'s npx fallback would
  # invoke it for real: a live, network-dependent `npx --yes markdownlint-cli2`
  # call from inside a test. Disable the fallback by default so integration
  # tests get deterministic (empty) auto-detection unless a test explicitly
  # opts in via CGW_MARKDOWNLINT_CMD/install_mock_markdownlint or re-enables
  # this and installs install_mock_npx.
  export CGW_MARKDOWNLINT_NPX_FALLBACK=0
}

# ── Lint mock ──────────────────────────────────────────────────────────────────

# install_mock_lint
# Creates a fake `ruff` that exits with $MOCK_LINT_EXIT (default 0).
# Output is written to $MOCK_BIN_DIR/ruff.log on each call.
install_mock_lint() {
  local exit_code="${MOCK_LINT_EXIT:-0}"
  cat > "${MOCK_BIN_DIR}/ruff" << EOF
#!/usr/bin/env bash
echo "mock ruff \$*" >> "${MOCK_BIN_DIR}/ruff.log"
exit ${exit_code}
EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# install_mock_lint_with_errors
# Creates a fake `ruff` that exits 1 and prints lint-style diagnostic lines.
install_mock_lint_with_errors() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'EOF'
#!/usr/bin/env bash
echo "src/foo.py:10:5: E501 line too long"
echo "src/foo.py:22:1: F401 unused import"
exit 1
EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# ── gh CLI mock ────────────────────────────────────────────────────────────────

# install_mock_gh
# Creates a fake `gh` that:
#   - `gh auth status`  → exits $MOCK_GH_AUTH_EXIT (default 0)
#   - `gh pr create`    → exits $MOCK_GH_PR_EXIT (default 0), prints a fake PR URL
#   - All calls are logged to $MOCK_BIN_DIR/gh.log
install_mock_gh() {
  local auth_exit="${MOCK_GH_AUTH_EXIT:-0}"
  local pr_exit="${MOCK_GH_PR_EXIT:-0}"
  cat > "${MOCK_BIN_DIR}/gh" << EOF
#!/usr/bin/env bash
echo "gh \$*" >> "${MOCK_BIN_DIR}/gh.log"
if [[ "\$1" == "auth" && "\$2" == "status" ]]; then
  exit ${auth_exit}
fi
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then
  echo "https://github.com/owner/repo/pull/42"
  exit ${pr_exit}
fi
exit 0
EOF
  chmod +x "${MOCK_BIN_DIR}/gh"
}

# install_mock_gh_no_auth
# gh is present but `gh auth status` fails.
install_mock_gh_no_auth() {
  MOCK_GH_AUTH_EXIT=1 install_mock_gh
}

# ── Markdownlint mock ──────────────────────────────────────────────────────────

# install_mock_markdownlint
# Creates a fake markdownlint-cli2 at $MOCK_BIN_DIR.
# Exits with $MOCK_MDLINT_EXIT (default 0). Logs full argv to mdlint.log, plus
# a dedicated "FIX_FLAG_SEEN" marker line when --fix is among the args -- lets
# tests assert the fix path was actually invoked (vs. the check path) without
# parsing the raw argv line.
install_mock_markdownlint() {
  local exit_code="${MOCK_MDLINT_EXIT:-0}"
  local cmd_name="${1:-markdownlint-cli2}"
  cat > "${MOCK_BIN_DIR}/${cmd_name}" << EOF
#!/usr/bin/env bash
echo "mock ${cmd_name} \$*" >> "${MOCK_BIN_DIR}/mdlint.log"
for a in "\$@"; do
  [[ "\$a" == "--fix" ]] && echo "FIX_FLAG_SEEN" >> "${MOCK_BIN_DIR}/mdlint.log"
done
exit ${exit_code}
EOF
  chmod +x "${MOCK_BIN_DIR}/${cmd_name}"
}

# install_mock_markdownlint_fixable
# A markdownlint-cli2-compatible mock for --fix / re-stage flows. Like
# install_mock_ruff_reformatter, `--fix` REWRITES files on disk: a file is
# "unfixable-clean" iff it contains a line exactly equal to the marker
# "MDLINT-BAD"; --fix deletes that line. Without --fix (check mode), it reads
# disk and fails (exit 1) iff any given file still holds the marker. Flag/
# exclusion tokens (-*, !*, glob patterns) are ignored -- only concrete file
# arguments are inspected/rewritten. Portable: no `sed -i`, writes a temp file
# then `mv -f`. Logs argv to $MOCK_BIN_DIR/mdlint.log.
install_mock_markdownlint_fixable() {
  local cmd_name="${1:-markdownlint-cli2}"
  cat > "${MOCK_BIN_DIR}/${cmd_name}" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "mock md $*" >> "${0%/*}/mdlint.log"

is_fix=0
files=()
for a in "$@"; do
  case "$a" in
    --fix) is_fix=1 ;;
    -* | !* | *'*'*) : ;; # flags, exclusions, glob patterns -- not files
    *) files+=("$a") ;;
  esac
done

marker='MDLINT-BAD'

if [[ $is_fix -eq 1 ]]; then
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    tmp="${f}.cgwmock.$$"
    grep -v -x "$marker" "$f" > "$tmp"
    mv -f "$tmp" "$f"
  done
  exit 0
fi

rc=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  grep -q -x "$marker" "$f" && rc=1
done
exit $rc
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/${cmd_name}"
}

# install_mock_npx
# Creates a fake `npx` that, when invoked as `npx --yes <tool> ...`, delegates
# to whatever mock is already installed in $MOCK_BIN_DIR under <tool>'s name
# (install_mock_markdownlint / install_mock_markdownlint_fixable must be
# installed first, under the name the npx fallback resolves to --
# "markdownlint-cli2"). Exercises the _cgw_detect_markdownlint() npx fallback
# end-to-end without a real npm/node install. Logs argv to
# $MOCK_BIN_DIR/npx.log.
install_mock_npx() {
  cat > "${MOCK_BIN_DIR}/npx" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "mock npx $*" >> "${0%/*}/npx.log"
[[ "$1" == "--yes" ]] && shift
tool="$1"; shift
exec "${0%/*}/${tool}" "$@"
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/npx"
}

# install_mock_lint_content_aware
# Creates a ruff mock whose exit status depends on the FILES it receives: for
# each real-file argument, if the file contains the marker "LINT-BAD" it fails
# (exit 1), otherwise it passes. Flags/subcommands are ignored. Lets tests
# assert the commit gate scans only the staged files (G1 scoping).
install_mock_lint_content_aware() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'EOF'
#!/usr/bin/env bash
echo "mock ruff $*" >> "${0%/*}/ruff.log"
rc=0
for a in "$@"; do
  [[ "$a" == -* ]] && continue
  [[ -f "$a" ]] || continue
  grep -q "LINT-BAD" "$a" && rc=1
done
exit $rc
EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# install_mock_markdownlint_content_aware
# Creates a markdownlint mock whose exit status depends on the FILES it receives:
# for each real-file argument, if the file contains the marker "MDLINT-BAD" it
# fails (exit 1), otherwise it passes. Flag/exclusion tokens (-x, !foo) and glob
# patterns (**/*.md) are ignored. Lets tests assert that only the intended files
# are actually scanned (the A1 scoping fix).
install_mock_markdownlint_content_aware() {
  local cmd_name="${1:-markdownlint-cli2}"
  cat > "${MOCK_BIN_DIR}/${cmd_name}" << 'EOF'
#!/usr/bin/env bash
echo "mock md $*" >> "${0%/*}/mdlint.log"
rc=0
for a in "$@"; do
  # Skip flags, exclusions, and glob patterns — inspect only concrete files.
  [[ "$a" == -* || "$a" == !* || "$a" == *'*'* ]] && continue
  [[ -f "$a" ]] || continue
  grep -q "MDLINT-BAD" "$a" && rc=1
done
exit $rc
EOF
  chmod +x "${MOCK_BIN_DIR}/${cmd_name}"
}

# install_mock_lint_fixable
# Creates a ruff mock that exits 1 on the first call, then exits 0.
# Use to test the NI auto-fix path where the fix succeeds.
install_mock_lint_fixable() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'MOCK_EOF'
#!/usr/bin/env bash
calls_file="${0%/*}/ruff.calls"
n=$(cat "$calls_file" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$calls_file"
echo "mock ruff $*" >> "${0%/*}/ruff.log"
[[ $n -eq 1 ]] && { echo "src/foo.py:10:5: E501 line too long"; exit 1; }
exit 0
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# install_mock_format_with_errors
# Creates a ruff mock that always outputs "would reformat" and exits 1.
# Use to exercise the FORMAT ERRORS branch in commit_enhanced.sh.
install_mock_format_with_errors() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "mock ruff $*" >> "${0%/*}/ruff.log"
echo "1 file would reformat"
exit 1
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# install_mock_ruff_reformatter
# A ruff-compatible mock for staged-blob vs working-tree divergence tests.
# Unlike every other mock above, `format <files>` (the FIX) REWRITES files on
# disk, simulating a real formatter. A file is "unformatted" iff it contains a
# line exactly equal to the marker "#UNFORMATTED#"; formatting deletes that
# line. `format --check <files>` fails (exit 1) iff any given file still holds
# the marker -- it reads disk, matching the real ruff CLI. `check [--fix]
# <files>` (the lint path) is an intentional no-op so tests can isolate the
# format divergence behavior; exit 0 always. Portable: no `sed -i`, writes a
# temp file then `mv -f`. Logs argv to $MOCK_BIN_DIR/ruff.log.
install_mock_ruff_reformatter() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "mock ruff $*" >> "${0%/*}/ruff.log"

subcmd=""
is_check=0
files=()
for a in "$@"; do
  case "$a" in
    --check) is_check=1 ;;
    --fix) : ;; # lint-fix flag; mock lint fix is a no-op
    check | format)
      if [[ -z "$subcmd" ]]; then subcmd="$a"; else files+=("$a"); fi
      ;;
    -*) : ;; # ignore any other flags/excludes
    *) files+=("$a") ;; # a path
  esac
done

marker='#UNFORMATTED#'

# FORMAT FIX: rewrite each file to its formatted form (strip the marker line).
if [[ "$subcmd" == "format" && $is_check -eq 0 ]]; then
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    tmp="${f}.cgwmock.$$"
    grep -v -x "$marker" "$f" > "$tmp"
    mv -f "$tmp" "$f"
  done
  exit 0
fi

# FORMAT CHECK: fail iff any file still contains the marker (reads DISK).
if [[ "$subcmd" == "format" && $is_check -eq 1 ]]; then
  rc=0
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q -x "$marker" "$f"; then
      echo "would reformat: $f"
      rc=1
    fi
  done
  exit $rc
fi

# LINT check / lint --fix: intentionally inert for these tests.
exit 0
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# install_mock_ruff_lint_reformatter
# The LINT-path mirror of install_mock_ruff_reformatter: drives `check` /
# `check --fix` (CGW_LINT_CHECK_ARGS / CGW_LINT_FIX_ARGS defaults) instead of
# `format` / `format --check`. A file is "lint-dirty" iff it contains a line
# exactly equal to the marker "#LINTDIRTY#"; `check --fix` REWRITES disk to
# strip that line, matching a real auto-fixing linter. `check` (no --fix)
# fails (exit 1) iff any given file still holds the marker -- it reads disk.
# `format [--check]` is an intentional no-op so tests can isolate the LINT
# auto-fix / re-stage path without a format pass also firing. Portable: no
# `sed -i`, writes a temp file then `mv -f`. Logs argv to
# $MOCK_BIN_DIR/ruff.log.
install_mock_ruff_lint_reformatter() {
  cat > "${MOCK_BIN_DIR}/ruff" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "mock ruff $*" >> "${0%/*}/ruff.log"

subcmd=""
is_fix=0
files=()
for a in "$@"; do
  case "$a" in
    --fix) is_fix=1 ;;
    --check) : ;; # format-check flag; mock format is a no-op here
    check | format)
      if [[ -z "$subcmd" ]]; then subcmd="$a"; else files+=("$a"); fi
      ;;
    -*) : ;; # ignore any other flags/excludes
    *) files+=("$a") ;; # a path
  esac
done

marker='#LINTDIRTY#'

# LINT FIX: rewrite each file to its fixed form (strip the marker line).
if [[ "$subcmd" == "check" && $is_fix -eq 1 ]]; then
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    tmp="${f}.cgwmock.$$"
    grep -v -x "$marker" "$f" > "$tmp"
    mv -f "$tmp" "$f"
  done
  exit 0
fi

# LINT CHECK: fail iff any file still contains the marker (reads DISK).
if [[ "$subcmd" == "check" && $is_fix -eq 0 ]]; then
  rc=0
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q -x "$marker" "$f"; then
      echo "$f: LINTDIRTY"
      rc=1
    fi
  done
  exit $rc
fi

# FORMAT check / format fix: intentionally inert for these tests.
exit 0
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/ruff"
}

# ── gh CLI absence helper ──────────────────────────────────────────────────────

# hide_gh
# Installs a shim in MOCK_BIN_DIR that exits 1 on any invocation, simulating
# an unusable gh CLI. setup_mock_bin must be called first.
# NOTE: `command -v gh` will still find this shim (it's executable), so tests
# exercise the auth-failure path rather than the command-not-found path. On CI,
# gh lives in /usr/bin alongside rm/bash/etc — we cannot safely remove that
# directory from PATH.
hide_gh() {
  cat > "${MOCK_BIN_DIR}/gh" << 'EOF'
#!/usr/bin/env bash
echo "gh: command not found" >&2
exit 1
EOF
  chmod +x "${MOCK_BIN_DIR}/gh"
}
