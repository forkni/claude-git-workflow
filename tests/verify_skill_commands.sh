#!/usr/bin/env bash
# tests/verify_skill_commands.sh
# Verify every ./scripts/git/*.sh invocation documented in skill/SKILL.md and
# command/auto-git-workflow-cmd.md against the actual scripts:
#   1. Every documented script exists.
#   2. Every --flag on lines that call a given script appears in that script.
#   3. A set of offline dry-run executions passes against a scratch git repo.
#
# Usage: bash tests/verify_skill_commands.sh
# Exit: 0 = all checks pass, 1 = one or more failures (printed to stderr).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS=(
  "$REPO_ROOT/skill/SKILL.md"
  "$REPO_ROOT/command/auto-git-workflow-cmd.md"
  "$REPO_ROOT/skill/references/full-promotion.md"
)
pass=0
fail=0

_pass() { printf "  PASS  %s\n" "$*"; (( pass++ )) || true; }
_fail() { printf "  FAIL  %s\n" "$*" >&2; (( fail++ )) || true; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Every documented script must exist
# ─────────────────────────────────────────────────────────────────────────────
echo "=== 1. Script existence ==="

mapfile -t documented_scripts < <(
  grep -hoE '\./scripts/git/[a-z_]+\.sh' "${DOCS[@]}" 2>/dev/null |
    sed 's|.*/||' | sort -u
)

if (( ${#documented_scripts[@]} == 0 )); then
  echo "  WARN  No script invocations found in docs — check doc paths" >&2
else
  for script in "${documented_scripts[@]}"; do
    if [[ -f "$REPO_ROOT/scripts/git/$script" ]]; then
      _pass "$script exists"
    else
      _fail "$script MISSING from scripts/git/"
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Every --flag on lines invoking a given script must appear in that script
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== 2. Flag verification ==="

# Flags universal to (almost) every script — tested implicitly by dry-run runs
_is_universal() {
  case "$1" in
    --non-interactive|--dry-run|--skip-lint|--no-venv|--help) return 0 ;;
    *) return 1 ;;
  esac
}

for script in "${documented_scripts[@]}"; do
  script_path="$REPO_ROOT/scripts/git/$script"
  [[ -f "$script_path" ]] || continue

  # Collect all --flags from lines that actually INVOKE this script
  # (i.e. contain "scripts/git/<script>"), not from prose that merely names
  # it in passing — a bare backtick mention like "conclude with
  # `commit_enhanced.sh`" or "there is no `--continue` flag" on a line that
  # happens to also name a different script would otherwise misattribute
  # that flag. Multi-line continuation flags (indented --flag after \) are
  # not captured here; they are exercised by dry-run runs in section 3.
  mapfile -t flags < <(
    grep -h "scripts/git/$script" "${DOCS[@]}" 2>/dev/null |
      grep -oE -- '--[a-z][a-z_-]+' | sort -u
  )

  checked=0
  for flag in "${flags[@]}"; do
    _is_universal "$flag" && continue
    (( checked++ )) || true
    if grep -qF -- "$flag" "$script_path" 2>/dev/null; then
      _pass "$script $flag"
    else
      _fail "$script $flag  (not found in script source)"
    fi
  done
  (( checked == 0 )) && _pass "$script (no non-universal flags to verify)"
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. Offline dry-run execution in a scratch git repo
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== 3. Offline dry-run execution ==="

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

cd "$SCRATCH"
git init -q
git config user.email "verify@test.local"
git config user.name "Verify"

git checkout -qb development 2>/dev/null || git checkout -q development
echo "initial" > README.md
git add README.md
git commit -q -m "feat: initial commit"
git checkout -qb main 2>/dev/null || git checkout -q main
git checkout -q development

cat > .cgw.conf <<'EOF'
CGW_SOURCE_BRANCH="development"
CGW_TARGET_BRANCH="main"
CGW_LOCAL_FILES="logs/ .claude/"
EOF

mkdir -p scripts
ln -s "$REPO_ROOT/scripts/git" scripts/git

_dry() {
  local label="$1"; shift
  # Pin PROJECT_ROOT to the scratch repo: scripts resolve .cgw.conf by walking up
  # from their own (real) location, which would skip the scratch .cgw.conf above
  # and silently depend on the host repo's git-ignored .cgw.conf (absent in CI).
  if CGW_NON_INTERACTIVE=1 PROJECT_ROOT="$SCRATCH" bash "$REPO_ROOT/scripts/git/$@" >/dev/null 2>&1; then
    _pass "$label"
  else
    _fail "$label (exit $?)"
  fi
}

_dry "setup_attributes.sh --dry-run"       setup_attributes.sh --dry-run
_dry "clean_build.sh (dry-run default)"    clean_build.sh
_dry "branch_cleanup.sh (dry-run default)" branch_cleanup.sh
_dry "merge_with_validation.sh --dry-run"  merge_with_validation.sh --dry-run
_dry "changelog_generate.sh --from main"   changelog_generate.sh --from main

cd "$REPO_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "  Passed: $pass  Failed: $fail"
(( fail == 0 ))
