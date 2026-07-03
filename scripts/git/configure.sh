#!/usr/bin/env bash
# configure.sh - Auto-configure claude-git-workflow for a project
# Purpose: Scan project, generate .cgw.conf, install hooks and optional Claude skill
# Usage: ./scripts/git/configure.sh [OPTIONS]
#
# Run this once after copying scripts/git/ into your project.
# It auto-detects branch names, lint tools, and local-only files,
# then generates .cgw.conf so all scripts work without manual editing.
#
# Arguments:
#   --non-interactive   Accept all auto-detected defaults without prompting
#   --reconfigure       Overwrite existing .cgw.conf
#   --skip-hooks        Don't install git pre-commit hook
#   --skip-skill        Don't install Claude Code skill
#   -h, --help          Show help
# Returns:
#   0 on success, 1 on failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect PROJECT_ROOT before sourcing _common.sh so _config.sh's auto-detection
# sees it preset and skips its own walk (safe; _config.sh checks [[ -z "${PROJECT_ROOT:-}" ]]).
_find_project_root() {
  local dir
  dir="$(cd "${SCRIPT_DIR}" && pwd)"
  while [[ "${dir}" != "/" ]] && [[ -n "${dir}" ]]; do
    if [[ -d "${dir}/.git" ]]; then
      echo "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  git rev-parse --show-toplevel 2>/dev/null && return 0
  return 1
}

if [[ -z "${PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$(_find_project_root)" || {
    echo "[ERROR] Cannot find git repository root." >&2
    echo "  Are you inside a git repository? Run 'git init' first, or cd into one." >&2
    exit 1
  }
fi

# Source shared helpers (cgw_confirm, err, etc.).
# Safe here: _config.sh detects PROJECT_ROOT only if unset (it's set above);
# it also tolerates a missing .cgw.conf by applying defaults.
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

# Hard-fail if sourcing didn't expose cgw_confirm — prevents silent skips.
if ! command -v cgw_confirm >/dev/null 2>&1; then
  echo "[ERROR] cgw_confirm not loaded — _common.sh source failed." >&2
  echo "  Re-install CGW or report this as a bug." >&2
  exit 1
fi

# ============================================================================
# AUTO-DETECTION FUNCTIONS
# ============================================================================

# NOTE: target-branch detection lives in _config.sh now (origin/HEAD -> main -> master ->
# main), because TARGET is a repo-wide fact that every script should get for free at
# runtime, not something baked into .cgw.conf at install time. CGW_TARGET_BRANCH is
# already resolved by the time main() runs below (sourced via _common.sh above).

_detect_source_branch() {
  # SOURCE is an inherently per-operation choice ("what am I merging"), so we only ever
  # auto-detect it when a CONFIDENT, canonical dev-family branch exists -- no guessing at
  # "the most recently committed other branch", and no falling back to the target branch's
  # own name (that used to silently produce SOURCE == TARGET on single-branch repos).
  # Single-branch / trunk-based repos get nothing written; --source is explicit per call.
  for name in development develop dev staging; do
    if git show-ref --verify --quiet "refs/heads/${name}" 2>/dev/null; then
      echo "${name}"
      return 0
    fi
    if git show-ref --verify --quiet "refs/remotes/origin/${name}" 2>/dev/null; then
      # Remote-only: create local tracking branch so downstream scripts can
      # check out by name without relying on git's DWIM --guess behaviour.
      git branch --track "${name}" "origin/${name}" >/dev/null 2>&1 || true
      echo "${name}"
      return 0
    fi
  done
  echo "" # no canonical source branch found -- leave unconfigured
}

_detect_lint_tool() {
  # Python project detection
  if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "setup.cfg" ]] || [[ -f "requirements.txt" ]]; then
    if command -v ruff &>/dev/null; then
      echo "ruff"
      return 0
    fi
    if command -v flake8 &>/dev/null; then
      echo "flake8"
      return 0
    fi
    if command -v pylint &>/dev/null; then
      echo "pylint"
      return 0
    fi
  fi
  # JavaScript/TypeScript project detection
  if [[ -f "package.json" ]]; then
    if command -v eslint &>/dev/null; then
      echo "eslint"
      return 0
    fi
  fi
  # Go project detection
  if [[ -f "go.mod" ]]; then
    if command -v golangci-lint &>/dev/null; then
      echo "golangci-lint"
      return 0
    fi
  fi
  # Rust project detection
  if [[ -f "Cargo.toml" ]]; then
    if command -v cargo &>/dev/null; then
      echo "cargo"
      return 0
    fi
  fi
  # C/C++ project detection
  if [[ -f "CMakeLists.txt" ]] || [[ -f "Makefile" ]] || [[ -f "meson.build" ]]; then
    if command -v clang-tidy &>/dev/null; then
      echo "clang-tidy"
      return 0
    fi
    if command -v cppcheck &>/dev/null; then
      echo "cppcheck"
      return 0
    fi
  fi
  echo "" # no lint tool detected
}

_detect_format_tool() {
  local lint_tool="$1"
  case "${lint_tool}" in
    ruff) echo "ruff" ;;
    eslint)
      if command -v prettier &>/dev/null; then echo "prettier"; else echo ""; fi
      ;;
    clang-tidy | cppcheck)
      if command -v clang-format &>/dev/null; then echo "clang-format"; else echo ""; fi
      ;;
    *) echo "" ;;
  esac
}

_detect_typecheck_tool() {
  # Python project: prefer [tool.*] declarations in pyproject.toml over command availability.
  if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "setup.cfg" ]] || [[ -f "requirements.txt" ]]; then
    if grep -q '^\[tool\.pyrefly\]' "pyproject.toml" 2>/dev/null; then
      echo "pyrefly"
      return 0
    fi
    if grep -q '^\[tool\.pyright\]' "pyproject.toml" 2>/dev/null; then
      echo "pyright"
      return 0
    fi
    if grep -q '^\[tool\.mypy\]' "pyproject.toml" 2>/dev/null; then
      echo "mypy"
      return 0
    fi
    if command -v pyrefly &>/dev/null; then
      echo "pyrefly"
      return 0
    fi
    if command -v pyright &>/dev/null; then
      echo "pyright"
      return 0
    fi
    if command -v mypy &>/dev/null; then
      echo "mypy"
      return 0
    fi
    # Python project but no typechecker found — use sentinel so config can include the hint.
    echo "none-python"
    return 0
  fi
  # JavaScript/TypeScript project
  if [[ -f "tsconfig.json" ]] || [[ -f "package.json" ]]; then
    if command -v tsc &>/dev/null; then
      echo "tsc"
      return 0
    fi
  fi
  echo ""
}

_detect_local_files() {
  # Scan for files that exist on disk but are not tracked by git
  local files=()
  local check_files=(CLAUDE.md MEMORY.md SESSION_LOG.md GEMINI.md .env .env.local .env.development .env.production)
  local check_dirs=(.claude/ logs/)

  for f in "${check_files[@]}"; do
    if [[ -f "${PROJECT_ROOT}/${f}" ]] && ! git -C "${PROJECT_ROOT}" ls-files --error-unmatch "${f}" &>/dev/null 2>&1; then
      files+=("${f}")
    fi
  done

  for d in "${check_dirs[@]}"; do
    local dir_path="${PROJECT_ROOT}/${d%/}"
    if [[ -d "${dir_path}" ]] && ! git -C "${PROJECT_ROOT}" ls-files --error-unmatch "${d}" &>/dev/null 2>&1; then
      files+=("${d}")
    fi
  done

  echo "${files[*]:-}"
}

_detect_venv() {
  local venv_dirs=(".venv" "venv" "env" ".env")
  for d in "${venv_dirs[@]}"; do
    if [[ -d "${PROJECT_ROOT}/${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  echo ""
}

_build_lint_config() {
  local lint_tool="$1"
  local venv_dir="$2"

  case "${lint_tool}" in
    ruff)
      local excludes="--extend-exclude logs"
      if [[ -n "${venv_dir}" ]]; then
        excludes="${excludes} --extend-exclude ${venv_dir}"
      fi
      echo "CGW_LINT_CMD=\"ruff\""
      echo "CGW_LINT_CHECK_ARGS=\"check .\""
      echo "CGW_LINT_FIX_ARGS=\"check --fix .\""
      echo "CGW_LINT_EXCLUDES=\"${excludes}\""
      echo "CGW_FORMAT_CMD=\"ruff\""
      echo "CGW_FORMAT_CHECK_ARGS=\"format --check .\""
      echo "CGW_FORMAT_FIX_ARGS=\"format .\""
      local fmt_excludes="--exclude logs"
      if [[ -n "${venv_dir}" ]]; then fmt_excludes="${fmt_excludes} --exclude ${venv_dir}"; fi
      echo "CGW_FORMAT_EXCLUDES=\"${fmt_excludes}\""
      ;;
    flake8)
      echo "CGW_LINT_CMD=\"flake8\""
      echo "CGW_LINT_CHECK_ARGS=\".\""
      echo "CGW_LINT_FIX_ARGS=\".\"  # flake8 has no auto-fix; use autopep8 manually"
      echo "CGW_LINT_EXCLUDES=\"--exclude logs,.venv\""
      echo "CGW_FORMAT_CMD=\"\"  # set to 'black' or 'autopep8' if available"
      echo "CGW_FORMAT_CHECK_ARGS=\"\""
      echo "CGW_FORMAT_FIX_ARGS=\"\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    eslint)
      echo "CGW_LINT_CMD=\"eslint\""
      echo "CGW_LINT_CHECK_ARGS=\".\""
      echo "CGW_LINT_FIX_ARGS=\". --fix\""
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"prettier\""
      echo "CGW_FORMAT_CHECK_ARGS=\"--check .\""
      echo "CGW_FORMAT_FIX_ARGS=\"--write .\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    golangci-lint)
      echo "CGW_LINT_CMD=\"golangci-lint\""
      echo "CGW_LINT_CHECK_ARGS=\"run\""
      echo "CGW_LINT_FIX_ARGS=\"run --fix\""
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"gofmt\""
      echo "CGW_FORMAT_CHECK_ARGS=\"-l .\""
      echo "CGW_FORMAT_FIX_ARGS=\"-w .\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    clang-tidy)
      echo "CGW_LINT_CMD=\"clang-tidy\""
      echo "CGW_LINT_CHECK_ARGS=\"-p build\"  # adjust: path to compile_commands.json dir"
      echo "CGW_LINT_FIX_ARGS=\"-p build --fix\""
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"clang-format\""
      echo "CGW_FORMAT_CHECK_ARGS=\"--dry-run --Werror -r .\""
      echo "CGW_FORMAT_FIX_ARGS=\"-i -r .\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    cppcheck)
      echo "CGW_LINT_CMD=\"cppcheck\""
      echo "CGW_LINT_CHECK_ARGS=\"--enable=all --error-exitcode=1 .\""
      echo "CGW_LINT_FIX_ARGS=\"--enable=all --error-exitcode=1 .\"  # cppcheck has no auto-fix"
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"clang-format\""
      echo "CGW_FORMAT_CHECK_ARGS=\"--dry-run --Werror -r .\""
      echo "CGW_FORMAT_FIX_ARGS=\"-i -r .\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    "")
      echo "CGW_LINT_CMD=\"\"  # no lint tool detected; set to enable"
      echo "CGW_LINT_CHECK_ARGS=\"\""
      echo "CGW_LINT_FIX_ARGS=\"\""
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"\""
      echo "CGW_FORMAT_CHECK_ARGS=\"\""
      echo "CGW_FORMAT_FIX_ARGS=\"\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    *)
      echo "CGW_LINT_CMD=\"${lint_tool}\""
      echo "CGW_LINT_CHECK_ARGS=\".\"  # adjust for your tool"
      echo "CGW_LINT_FIX_ARGS=\".\"    # adjust for your tool"
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"\""
      echo "CGW_FORMAT_CHECK_ARGS=\"\""
      echo "CGW_FORMAT_FIX_ARGS=\"\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
  esac
}

_build_typecheck_config() {
  local tc_tool="$1"

  case "${tc_tool}" in
    pyrefly)
      echo "CGW_TYPECHECK_CMD=\"pyrefly\""
      echo "CGW_TYPECHECK_CHECK_ARGS=\"check\""
      echo "CGW_TYPECHECK_EXCLUDES=\"\""
      ;;
    pyright)
      echo "CGW_TYPECHECK_CMD=\"pyright\""
      echo "CGW_TYPECHECK_CHECK_ARGS=\"\""
      echo "CGW_TYPECHECK_EXCLUDES=\"\""
      ;;
    mypy)
      echo "CGW_TYPECHECK_CMD=\"mypy\""
      echo "CGW_TYPECHECK_CHECK_ARGS=\".\""
      echo "CGW_TYPECHECK_EXCLUDES=\"\""
      ;;
    tsc)
      echo "CGW_TYPECHECK_CMD=\"tsc\""
      echo "CGW_TYPECHECK_CHECK_ARGS=\"--noEmit\""
      echo "CGW_TYPECHECK_EXCLUDES=\"\""
      ;;
    none-python)
      echo "CGW_TYPECHECK_CMD=\"\"  # install pyrefly to enable: pip install pyrefly"
      echo "CGW_TYPECHECK_CHECK_ARGS=\"check\""
      echo "CGW_TYPECHECK_EXCLUDES=\"\""
      ;;
    *)
      echo "CGW_TYPECHECK_CMD=\"\""
      echo "CGW_TYPECHECK_CHECK_ARGS=\"\""
      echo "CGW_TYPECHECK_EXCLUDES=\"\""
      ;;
  esac
}

_install_hook() {
  local hooks_template_dir="${SCRIPT_DIR}/../../hooks"

  # Try staging area first (present during install.cmd), then fall back to already-installed hook
  hooks_template_dir="$(cd "${SCRIPT_DIR}" && cd "../../hooks" 2>/dev/null && pwd)" || {
    hooks_template_dir="${PROJECT_ROOT}/.cgw-hooks-template"
  }

  local hook_template="${hooks_template_dir}/pre-commit"

  if [[ ! -f "${hook_template}" ]]; then
    # If hook is already installed, nothing to do
    if [[ -f "${PROJECT_ROOT}/.githooks/pre-commit" ]]; then
      echo "  [OK] Pre-commit hook already installed"
      return 0
    fi
    echo "  [!] Hook template not found at: ${hook_template}" >&2
    echo "      Fix: copy the hooks/ directory from the CGW source repo into your project root," >&2
    echo "      then re-run: ./scripts/git/configure.sh" >&2
    return 1
  fi

  # Hooks read CGW_LOCAL_FILES from .cgw.conf at run time — no pattern substitution needed.
  echo "Installing pre-commit hook..."
  mkdir -p "${PROJECT_ROOT}/.githooks"
  cp "${hook_template}" "${PROJECT_ROOT}/.githooks/pre-commit"
  chmod +x "${PROJECT_ROOT}/.githooks/pre-commit"

  local pre_push_template="${hooks_template_dir}/pre-push"
  if [[ -f "${pre_push_template}" ]]; then
    cp "${pre_push_template}" "${PROJECT_ROOT}/.githooks/pre-push"
    chmod +x "${PROJECT_ROOT}/.githooks/pre-push"
  fi

  local pre_rebase_template="${hooks_template_dir}/pre-rebase"
  if [[ -f "${pre_rebase_template}" ]]; then
    cp "${pre_rebase_template}" "${PROJECT_ROOT}/.githooks/pre-rebase"
    chmod +x "${PROJECT_ROOT}/.githooks/pre-rebase"
  fi

  # Run install_hooks.sh to copy to .git/hooks/
  if bash "${SCRIPT_DIR}/install_hooks.sh" >/dev/null 2>&1; then
    echo "  [OK] Git hooks installed (pre-commit + pre-push + pre-rebase)"
  else
    echo "  [!] Hooks written to .githooks/ but failed to copy to .git/hooks/" >&2
    echo "      Fix: run manually: ./scripts/git/install_hooks.sh" >&2
    echo "      If that also fails, check that .git/hooks/ is writable." >&2
  fi
}

_install_skill() {
  local install_mode="${1:-local}" # "local" or "global"
  local skill_src
  local cmd_src
  local skill_dst cmd_dst

  # Determine destination based on install mode
  if [[ "${install_mode}" == "global" ]]; then
    skill_dst="${HOME}/.claude/skills/auto-git-workflow"
    cmd_dst="${HOME}/.claude/commands"
  else
    skill_dst="${PROJECT_ROOT}/.claude/skills/auto-git-workflow"
    cmd_dst="${PROJECT_ROOT}/.claude/commands"
  fi

  # Try staging area first (present during install.cmd), then CGW source repo
  if skill_src="$(cd "${SCRIPT_DIR}" && cd "../../skill" 2>/dev/null && pwd)"; then
    cmd_src="${skill_src}/../command/auto-git-workflow.md"
  elif [[ -f "${skill_dst}/SKILL.md" ]]; then
    echo "  [OK] Claude Code skill already installed (${install_mode})"
    return 0
  else
    echo "  [!] Skill template not found." >&2
    echo "      Fix: copy skill/ and command/ from the CGW source repo into your" >&2
    echo "      project root, then re-run: ./scripts/git/configure.sh" >&2
    return 1
  fi

  echo "Installing Claude Code skill (${install_mode})..."
  mkdir -p "${skill_dst}/references"

  cp "${skill_src}/SKILL.md" "${skill_dst}/SKILL.md" 2>/dev/null || true
  cp "${skill_src}/references/"*.md "${skill_dst}/references/" 2>/dev/null || true

  if [[ -f "${cmd_src}" ]]; then
    mkdir -p "${cmd_dst}"
    cp "${cmd_src}" "${cmd_dst}/auto-git-workflow.md" 2>/dev/null || true
    echo "  [OK] Claude Code skill + slash command installed (${install_mode})"
  else
    echo "  [OK] Claude Code skill installed (${install_mode}, command template not found)"
  fi
}

_install_guardrail_nojq() {
  local settings_json="${1}"
  local hook_cmd="${2}"

  # Already registered? (grep is enough without jq)
  if [[ -f "${settings_json}" ]] && grep -qF "cc-block-dangerous-git" "${settings_json}" 2>/dev/null; then
    echo "  [OK] PreToolUse guardrail already registered in ${settings_json}"
    return 0
  fi

  # Simple case: no file yet, or just bare {}  — write from scratch
  local existing_stripped=""
  if [[ -f "${settings_json}" ]]; then
    existing_stripped="$(tr -d '[:space:]' <"${settings_json}" 2>/dev/null)"
  fi
  if [[ -z "${existing_stripped}" ]] || [[ "${existing_stripped}" == "{}" ]]; then
    printf '{\n  "hooks": {\n    "PreToolUse": [\n      {\n        "matcher": "Bash",\n        "hooks": [{"type": "command", "command": "%s"}]\n      }\n    ]\n  }\n}\n' \
      "${hook_cmd}" >"${settings_json}"
    echo "  [OK] PreToolUse guardrail registered in ${settings_json}"
    return 0
  fi

  # Complex case: try Python to merge into existing settings
  local py_cmd
  for py_cmd in python3 python; do
    if command -v "${py_cmd}" &>/dev/null; then
      if "${py_cmd}" - "${settings_json}" "${hook_cmd}" 2>/dev/null <<'PYEOF'; then
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
ptu = data.setdefault('hooks', {}).setdefault('PreToolUse', [])
ptu[:] = [e for e in ptu
          if not any('cc-block-dangerous-git' in h.get('command', '')
                     for h in e.get('hooks', []))]
ptu.append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': cmd}]})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
        echo "  [OK] PreToolUse guardrail registered in ${settings_json} (via python)"
        return 0
      fi
    fi
  done

  # Nothing available — manual instructions
  echo "  [!] jq and python not found — cannot auto-merge ${settings_json}" >&2
  echo "      Manually add the following hook entry to ${settings_json}:" >&2
  printf '      {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "${hook_cmd}" >&2
  return 1
}

_install_cc_guardrail() {
  local install_mode="${1:-local}" # "local" or "global"

  # Find source script (staging area during install.cmd, or already-installed copy)
  local guardrail_src
  guardrail_src="$(cd "${SCRIPT_DIR}" && cd "../../hooks" 2>/dev/null && pwd)/cc-block-dangerous-git.sh" 2>/dev/null || true

  if [[ ! -f "${guardrail_src:-}" ]]; then
    # Fallback: accept the already-installed copy so reconfigure works after
    # the staging hooks/ directory has been cleaned up.
    if [[ -f "${PROJECT_ROOT}/.claude/hooks/cc-block-dangerous-git.sh" ]]; then
      guardrail_src="${PROJECT_ROOT}/.claude/hooks/cc-block-dangerous-git.sh"
    else
      echo "  [!] hooks/cc-block-dangerous-git.sh not found." >&2
      echo "      Re-copy hooks/ from the CGW source directory, then re-run: ./scripts/git/configure.sh" >&2
      return 1
    fi
  fi

  # Determine destination paths
  local hook_dst settings_json hook_cmd
  if [[ "${install_mode}" == "global" ]]; then
    hook_dst="${HOME}/.claude/hooks/cc-block-dangerous-git.sh"
    settings_json="${HOME}/.claude/settings.json"
    # Literal tilde is intentional (SC2088): this string is written verbatim
    # into settings.json as the hook's "command" value, not executed here --
    # Claude Code expands it via its own shell when it invokes the hook.
    # shellcheck disable=SC2088
    hook_cmd="~/.claude/hooks/cc-block-dangerous-git.sh"
  else
    hook_dst="${PROJECT_ROOT}/.claude/hooks/cc-block-dangerous-git.sh"
    settings_json="${PROJECT_ROOT}/.claude/settings.json"
    # Literal double-quotes around $CLAUDE_PROJECT_DIR are intentional:
    # they become JSON-escaped \" in settings.json and are expanded by the shell
    # when Claude Code executes the hook command at runtime.
    # shellcheck disable=SC2016
    hook_cmd='"$CLAUDE_PROJECT_DIR"/.claude/hooks/cc-block-dangerous-git.sh'
  fi

  # Copy guardrail script to .claude/hooks/ (skip if source and destination are the same)
  mkdir -p "$(dirname "${hook_dst}")"
  if [[ "${guardrail_src}" != "${hook_dst}" ]]; then
    cp "${guardrail_src}" "${hook_dst}"
  fi
  chmod +x "${hook_dst}"

  # Merge into settings.json — jq preferred; Python fallback; manual instructions as last resort
  if ! command -v jq &>/dev/null; then
    _install_guardrail_nojq "${settings_json}" "${hook_cmd}"
    return $?
  fi

  # Initialize settings.json if it does not exist
  if [[ ! -f "${settings_json}" ]]; then
    echo '{}' >"${settings_json}"
  fi

  # Idempotency: skip if a valid guardrail command is already registered.
  # "Valid" means it contains "cc-block-dangerous-git" but does NOT contain a
  # known-bad MSYS-converted substring (Program Files/Git).  A corrupted entry
  # falls through so it gets replaced below.
  if jq -e '
      [.hooks.PreToolUse[]?.hooks[]?.command
        | select(contains("cc-block-dangerous-git"))
        | select(contains("Program Files/Git") | not)
      ] | length > 0' \
    "${settings_json}" >/dev/null 2>&1; then
    echo "  [OK] PreToolUse guardrail already registered in ${settings_json}"
    return 0
  fi

  echo "Installing PreToolUse guardrail..."
  # Remove any corrupted/stale guardrail entries before re-registering
  local clean_settings
  clean_settings="$(mktemp)"
  jq '
    .hooks.PreToolUse |= if . then
      map(select(
        .hooks | map(.command | contains("cc-block-dangerous-git")) | any | not
      ))
    else . end' \
    "${settings_json}" >"${clean_settings}" && mv "${clean_settings}" "${settings_json}"

  # Merge: append a new PreToolUse Bash-matcher entry without overwriting existing hooks
  # Split hook_cmd at the first "/" and reconstruct inside jq, so neither
  # argument fragment starts with "/" and MSYS2 has nothing to path-convert
  # when the value crosses into jq.exe on Git Bash (Windows).
  # e.g. '"$CLAUDE_PROJECT_DIR"/.claude/hooks/...' →
  #        pfx='"$CLAUDE_PROJECT_DIR"'  sfx='.claude/hooks/...'
  # This is a no-op on macOS / Linux / WSL where MSYS is not in play.
  local tmp_settings hook_pfx hook_sfx
  tmp_settings="$(mktemp)"
  hook_pfx="${hook_cmd%%/*}"
  hook_sfx="${hook_cmd#*/}"
  jq --arg pfx "${hook_pfx}" --arg sfx "${hook_sfx}" \
    '.hooks.PreToolUse |= (. // []) + [{"matcher":"Bash","hooks":[{"type":"command","command":($pfx + "/" + $sfx)}]}]' \
    "${settings_json}" >"${tmp_settings}" && mv "${tmp_settings}" "${settings_json}"
  echo "  [OK] PreToolUse guardrail registered in ${settings_json}"

  # Smoke test: read the registered command back out of settings.json, substitute
  # $CLAUDE_PROJECT_DIR with the actual project root, verify the file exists, and
  # then confirm it blocks a raw git commit.  This catches path-corruption bugs
  # (e.g. MSYS converting /.claude/... to C:/Program Files/Git/.claude/...) that
  # direct script invocation cannot detect.
  local registered_cmd resolved_cmd
  registered_cmd="$(jq -r \
    '[.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("cc-block-dangerous-git")) | .command][0] // empty' \
    "${settings_json}")"
  resolved_cmd="${registered_cmd//\"\$CLAUDE_PROJECT_DIR\"/${PROJECT_ROOT}}"
  resolved_cmd="${resolved_cmd//\$CLAUDE_PROJECT_DIR/${PROJECT_ROOT}}"
  resolved_cmd="${resolved_cmd#\"}"
  resolved_cmd="${resolved_cmd%\"}"

  if [[ -z "${registered_cmd}" ]]; then
    echo "  [WARN] Smoke test: no guardrail entry found in ${settings_json}" >&2
  elif [[ ! -f "${resolved_cmd}" ]]; then
    echo "  [FAIL] Smoke test: registered command does not resolve to a file." >&2
    echo "         Registered: ${registered_cmd}" >&2
    echo "         Resolved:   ${resolved_cmd}" >&2
    echo "         Guardrail will silently fail at runtime — re-run configure.sh." >&2
    return 1
  else
    local test_input='{"tool_input":{"command":"git commit -m \"smoke-test\""}}'
    local exit_code=0
    echo "${test_input}" | CLAUDE_PROJECT_DIR="${PROJECT_ROOT}" \
      bash -c "${registered_cmd}" >/dev/null 2>&1 || exit_code=$?
    if [[ "${exit_code}" -eq 2 ]]; then
      echo "  [OK] Smoke test passed: registered command blocks raw git commit"
    else
      echo "  [WARN] Smoke test: registered command did not block (exit=${exit_code})" >&2
    fi
  fi
}

_update_gitignore() {
  local gitignore="${PROJECT_ROOT}/.gitignore"
  local entries=("logs/" ".cgw.conf")
  local added=()

  for entry in "${entries[@]}"; do
    if [[ ! -f "${gitignore}" ]] || ! grep -qxF "${entry}" "${gitignore}" 2>/dev/null; then
      echo "${entry}" >>"${gitignore}"
      added+=("${entry}")
    fi
  done

  if [[ ${#added[@]} -gt 0 ]]; then
    echo "  [OK] Added to .gitignore: ${added[*]}"
  else
    echo "  [OK] .gitignore already up to date"
  fi
}

_cleanup_legacy_artifacts() {
  # Remove files that older CGW versions installed but the current version does
  # not produce.  Safe to call on fresh installs (both checks are no-ops).
  if [[ -d "${PROJECT_ROOT}/scripts/git/batch" ]]; then
    rm -rf "${PROJECT_ROOT}/scripts/git/batch"
    echo "  [OK] Removed legacy scripts/git/batch/ (.bat wrappers from pre-v0.3 CGW)"
  fi
  if [[ -f "${PROJECT_ROOT}/scripts/git/README.md" ]]; then
    rm -f "${PROJECT_ROOT}/scripts/git/README.md"
    echo "  [OK] Removed legacy scripts/git/README.md"
  fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local non_interactive=0
  local reconfigure=0
  local skip_hooks=0
  local skip_skill=0
  local skip_cc_guardrail=0
  local global_skill=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help | -h)
        echo "Usage: ./scripts/git/configure.sh [OPTIONS]"
        echo ""
        echo "Auto-configure claude-git-workflow for this project."
        echo "Scans the project and generates .cgw.conf, installs hooks,"
        echo "and optionally installs the Claude Code skill."
        echo ""
        echo "Options:"
        echo "  --non-interactive    Accept all auto-detected defaults"
        echo "  --reconfigure        Overwrite existing .cgw.conf"
        echo "  --skip-hooks         Don't install git pre-commit hook"
        echo "  --skip-skill         Don't install Claude Code skill"
        echo "  --skip-cc-guardrail  Don't install PreToolUse harness guardrail"
        echo "  --global             Install Claude Code skill to ~/.claude/ (available in all projects)"
        echo "  -h, --help           Show this help"
        echo ""
        echo "After running, edit .cgw.conf to customize any detected values."
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      --reconfigure) reconfigure=1 ;;
      --skip-hooks) skip_hooks=1 ;;
      --skip-skill) skip_skill=1 ;;
      --skip-cc-guardrail) skip_cc_guardrail=1 ;;
      --global) global_skill=1 ;;
      *)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  cd "${PROJECT_ROOT}" || {
    echo "[ERROR] Cannot change to project root: ${PROJECT_ROOT}" >&2
    exit 1
  }

  _cleanup_legacy_artifacts

  echo ""
  echo "=== claude-git-workflow: Auto-Configuration ==="
  echo ""
  echo "Project root: ${PROJECT_ROOT}"
  echo ""

  # Track whether this is a fresh install (no existing .cgw.conf)
  local fresh_install=0
  [[ ! -f ".cgw.conf" ]] && fresh_install=1

  # Check if .cgw.conf already exists
  if [[ -f ".cgw.conf" ]] && [[ ${reconfigure} -eq 0 ]]; then
    echo "[OK] .cgw.conf already exists."
    if cgw_confirm "Reconfigure?" --default no --non-interactive deny; then
      reconfigure=1
    else
      echo ""
      echo "Using existing configuration. Use --reconfigure to overwrite."
      echo ""
      # Still run hook + skill install
    fi
  fi

  # -- Detection phase ------------------------------------------------------

  echo "Scanning project..."
  echo "  Detecting branch names, lint tools, typecheck tool, virtual environment, and local-only files..."
  echo ""

  # Already resolved at source time by _config.sh (origin/HEAD -> main -> master -> main).
  local detected_target="${CGW_TARGET_BRANCH}"

  local detected_source
  detected_source="$(_detect_source_branch)"

  local detected_lint
  detected_lint="$(_detect_lint_tool)"

  local detected_venv
  detected_venv="$(_detect_venv)"

  local detected_local_files
  detected_local_files="$(_detect_local_files)"

  local detected_typecheck
  detected_typecheck="$(_detect_typecheck_tool)"

  local _tc_display="${detected_typecheck}"
  [[ "${_tc_display}" == "none-python" ]] && _tc_display="none detected (Tip: pip install pyrefly to enable)"

  echo "  Target branch (stable):  ${detected_target} (auto-detected at runtime, not written to .cgw.conf)"
  echo "  Source branch (dev):     ${detected_source:-none detected -- pass --source <branch> per invocation}"
  echo "  Lint tool:               ${detected_lint:-none detected}"
  echo "  Typecheck tool:          ${_tc_display:-none detected}"
  echo "  Venv directory:          ${detected_venv:-none found}"
  echo "  Local-only files:        ${detected_local_files:-none found}"
  echo ""

  # -- Interactive confirmation (only when generating/updating config) ----------

  local source_branch="${detected_source}"

  local local_files="${detected_local_files:-CLAUDE.md MEMORY.md .claude/ logs/}"

  # When .cgw.conf already exists (not reconfiguring), honour its CGW_LOCAL_FILES value
  # for hook generation so manually-configured extras survive re-runs.
  if [[ -f ".cgw.conf" ]] && [[ ${reconfigure} -eq 0 ]]; then
    local conf_local_files
    conf_local_files=$(grep -m1 '^CGW_LOCAL_FILES=' ".cgw.conf" || true)
    conf_local_files="${conf_local_files#*=}"
    conf_local_files="${conf_local_files//\"/}"
    [[ -n "${conf_local_files}" ]] && local_files="${conf_local_files}"
  fi

  # Branch names are no longer prompted for here: TARGET is auto-detected at runtime
  # (see _config.sh) and SOURCE is an explicit per-invocation choice (--source flag, or
  # a manually-added CGW_SOURCE_BRANCH in .cgw.conf) -- not something to guess or confirm
  # interactively at install time.
  if [[ ${non_interactive} -eq 0 ]] && { [[ ! -f ".cgw.conf" ]] || [[ ${reconfigure} -eq 1 ]]; }; then
    echo "Press Enter to accept [default], or type a different value."
    echo ""
    echo "Local-only files (never committed): ${local_files}"
    read -e -r -p "Add/change local files? (press Enter to keep, or type new list): " answer
    [[ -n "${answer}" && ! "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]] && local_files="${answer}"
  fi

  # -- Generate .cgw.conf ----------------------------------------------------

  if [[ ! -f ".cgw.conf" ]] || [[ ${reconfigure} -eq 1 ]]; then
    echo "Generating .cgw.conf..."
    echo "  This config file controls branch names, lint settings, and local-only"
    echo "  file protection. It is git-ignored so each developer can have their own."

    {
      echo "# .cgw.conf -- Auto-generated by configure.sh on $(date)"
      echo "# Edit as needed. See cgw.conf.example for all options."
      echo "# This file is git-ignored (.cgw.conf in .gitignore)."
      echo ""
      # TARGET is intentionally NOT written -- _config.sh auto-detects it at runtime
      # (origin/HEAD -> main -> master -> main) so it's never stale and never needs
      # pinning here. SOURCE is written only when a canonical dev-family branch (development/
      # develop/dev/staging) was confidently detected; single-branch/trunk-based repos get
      # no branch lines at all -- pass --source <branch> per invocation instead.
      if [[ -n "${source_branch}" ]]; then
        echo "# Branch configuration"
        echo "# (target branch is auto-detected at runtime; not stored here -- see _config.sh)"
        echo "CGW_SOURCE_BRANCH=\"${source_branch}\""
        echo ""
      fi
      echo "# Local-only files (space-separated; never committed)"
      echo "CGW_LOCAL_FILES=\"${local_files}\""
      echo ""
      echo "# Lint configuration (auto-detected)"
      _build_lint_config "${detected_lint}" "${detected_venv}"
      echo ""
      echo "# Typecheck configuration (auto-detected)"
      _build_typecheck_config "${detected_typecheck}"
      echo ""
      echo "# Commit message prefix extras (pipe-separated, e.g. \"cuda|tensorrt\")"
      echo "CGW_EXTRA_PREFIXES=\"\""
      echo ""
      echo "# Docs CI pattern (empty = skip; set to enable doc filename validation)"
      echo "# Example: CGW_DOCS_PATTERN=\"^(README\\.md|.*_GUIDE\\.md|.*_REFERENCE\\.md)$\""
      echo "CGW_DOCS_PATTERN=\"\""
      echo ""
      echo "# Dev-only files warning for cherry-pick (space-separated; empty = skip)"
      echo "# Example: CGW_DEV_ONLY_FILES=\"tests/ pytest.ini\""
      echo "CGW_DEV_ONLY_FILES=\"\""
      echo ""
      echo "# Remove tests/ from target branch if gitignored (0=disabled, 1=enabled)"
      echo "CGW_CLEANUP_TESTS=\"0\""
    } >".cgw.conf"

    echo "  [OK] .cgw.conf generated"
  fi

  # -- Update .gitignore (first install only) --------------------------------
  # Only on fresh installs -- not on --reconfigure, so existing .gitignore
  # entries the user has customised are not modified.
  if [[ ${fresh_install} -eq 1 ]] && [[ ${reconfigure} -eq 0 ]]; then
    echo "Updating .gitignore..."
    _update_gitignore
  fi

  # -- Install pre-commit hook -----------------------------------------------

  if [[ ${skip_hooks} -eq 0 ]]; then
    echo ""
    echo "Git hooks enforce lint checks and local-file protection on every commit"
    echo "and push, catching issues before they reach the remote."
    local install_hook
    if cgw_confirm "Install pre-commit hook?" --default yes --non-interactive accept; then
      install_hook="yes"
    else
      install_hook="no"
    fi

    if [[ "${install_hook}" == "yes" ]]; then
      _install_hook
    fi
  fi

  # -- Enable git rerere -----------------------------------------------------
  # rerere (reuse recorded resolution) auto-replays known conflict resolutions.
  # Recommended for two-branch models where the same conflicts recur across merges.

  echo ""
  echo "git rerere remembers how you resolved conflicts so it can auto-replay"
  echo "the same resolution next time the same conflict reappears."
  local enable_rerere
  if cgw_confirm "Enable git rerere (auto-replay conflict resolutions)?" --default yes --non-interactive accept; then
    enable_rerere="yes"
  else
    enable_rerere="no"
  fi

  if [[ "${enable_rerere}" == "yes" ]]; then
    if git config rerere.enabled true 2>/dev/null; then
      echo "  [OK] rerere.enabled = true (conflict resolutions will be remembered)"
    else
      echo "    Note: Could not enable rerere -- run: git config rerere.enabled true"
    fi
  fi

  # -- Install Claude Code skill ---------------------------------------------

  if [[ ${skip_skill} -eq 0 ]]; then
    echo ""
    echo "The Claude Code skill teaches Claude to use CGW scripts instead of raw"
    echo "git commands, ensuring lint checks and local-file protection are never bypassed."
    if [[ ${global_skill} -eq 1 ]]; then
      echo "  (--global: skill will be installed to ~/.claude/ for all projects)"
    fi
    local install_skill="no"
    # Default to yes if .claude/ directory already exists (local mode)
    # or if --global was specified
    if [[ -d ".claude" ]] || [[ ${global_skill} -eq 1 ]]; then
      install_skill="yes"
    fi

    local skill_dest_hint="project .claude/"
    [[ ${global_skill} -eq 1 ]] && skill_dest_hint="global ~/.claude/"
    if cgw_confirm "Install Claude Code skill to ${skill_dest_hint}?" --default "${install_skill}" --non-interactive accept; then
      install_skill="yes"
    else
      install_skill="no"
    fi

    if [[ "${install_skill}" == "yes" ]]; then
      if [[ ${global_skill} -eq 1 ]]; then
        _install_skill "global"
      else
        _install_skill "local"
      fi
    fi
  fi

  # -- Install PreToolUse harness guardrail ----------------------------------

  if [[ ${skip_cc_guardrail} -eq 0 ]]; then
    echo ""
    echo "The PreToolUse guardrail is a Claude Code hook that blocks dangerous git"
    echo "commands (raw 'git commit', '--no-verify', 'git reset --hard', etc.) at the"
    echo "harness layer, before they execute. This is defense-in-depth on top of the"
    echo "repo-side git hooks — the model cannot bypass it by being asked to skip CGW."
    local install_guardrail
    local guardrail_dest_hint=".claude/settings.json"
    # Literal tilde is intentional (SC2088): purely a display string in the
    # prompt below, never expanded or executed.
    # shellcheck disable=SC2088
    [[ ${global_skill} -eq 1 ]] && guardrail_dest_hint="~/.claude/settings.json"
    if cgw_confirm "Install PreToolUse guardrail to ${guardrail_dest_hint}?" --default yes --non-interactive accept; then
      install_guardrail="yes"
    else
      install_guardrail="no"
    fi

    if [[ "${install_guardrail}" == "yes" ]]; then
      if [[ ${global_skill} -eq 1 ]]; then
        _install_cc_guardrail "global"
      else
        _install_cc_guardrail "local"
      fi
    fi
  fi

  # -- Summary --------------------------------------------------------------

  echo ""
  echo "=== Configuration Complete ==="
  echo ""
  echo "  Config file:    ${PROJECT_ROOT}/.cgw.conf"
  # When not reconfiguring, show the value from existing .cgw.conf rather than detected.
  # Target is never read from .cgw.conf here -- CGW_TARGET_BRANCH is already the fully
  # resolved runtime value (env > .cgw.conf > auto-detect), sourced above.
  if [[ -f ".cgw.conf" ]] && [[ ${reconfigure} -eq 0 ]]; then
    local conf_source
    conf_source=$(grep -m1 '^CGW_SOURCE_BRANCH=' .cgw.conf || true)
    conf_source="${conf_source#*=}"
    conf_source="${conf_source//\"/}"
    echo "  Source branch:  ${conf_source:-none configured -- pass --source <branch> per invocation}"
  else
    echo "  Source branch:  ${source_branch:-none configured -- pass --source <branch> per invocation}"
  fi
  echo "  Target branch:  ${CGW_TARGET_BRANCH} (auto-detected at runtime)"
  if [[ -n "${detected_lint}" ]]; then
    echo "  Lint tool:      ${detected_lint}"
  fi
  echo ""
  echo "Quick start:"
  echo "  ./scripts/git/commit_enhanced.sh \"feat: your feature\""
  echo "  ./scripts/git/merge_with_validation.sh --dry-run"
  echo "  ./scripts/git/push_validated.sh"
  echo ""
  echo "Edit .cgw.conf to customize any settings."
  echo ""
}

main "$@"
