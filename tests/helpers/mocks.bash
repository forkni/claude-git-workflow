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
# Exits with $MOCK_MDLINT_EXIT (default 0).
install_mock_markdownlint() {
  local exit_code="${MOCK_MDLINT_EXIT:-0}"
  local cmd_name="${1:-markdownlint-cli2}"
  cat > "${MOCK_BIN_DIR}/${cmd_name}" << EOF
#!/usr/bin/env bash
echo "mock ${cmd_name} \$*" >> "${MOCK_BIN_DIR}/mdlint.log"
exit ${exit_code}
EOF
  chmod +x "${MOCK_BIN_DIR}/${cmd_name}"
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
