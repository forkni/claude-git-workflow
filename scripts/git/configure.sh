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
# sees it preset and skips its own detection (safe; _config.sh checks
# [[ -z "${PROJECT_ROOT:-}" ]]). Same resolution order as _config.sh: git's own
# discovery from the cwd first (the repo being configured), then a walk up from
# the script location for callers outside any work tree.
_find_project_root() {
  local root
  if root="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "${root}" ]]; then
    echo "${root}"
    return 0
  fi
  local dir
  dir="$(cd "${SCRIPT_DIR}" && pwd)"
  while [[ "${dir}" != "/" ]] && [[ -n "${dir}" ]]; do
    if [[ -e "${dir}/.git" ]]; then
      echo "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
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
  local check_files=(CLAUDE.md MEMORY.md SESSION_LOG.md GEMINI.md AGENTS.md .env .env.local .env.development .env.production)
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
      echo "CGW_LINT_CHECK_ARGS=\"check {files}\""
      echo "CGW_LINT_FIX_ARGS=\"check --fix {files}\""
      echo "CGW_LINT_EXCLUDES=\"${excludes}\""
      echo "CGW_FORMAT_CMD=\"ruff\""
      echo "CGW_FORMAT_CHECK_ARGS=\"format --check {files}\""
      echo "CGW_FORMAT_FIX_ARGS=\"format {files}\""
      local fmt_excludes="--exclude logs"
      if [[ -n "${venv_dir}" ]]; then fmt_excludes="${fmt_excludes} --exclude ${venv_dir}"; fi
      echo "CGW_FORMAT_EXCLUDES=\"${fmt_excludes}\""
      ;;
    flake8)
      echo "CGW_LINT_CMD=\"flake8\""
      echo "CGW_LINT_CHECK_ARGS=\"{files}\""
      echo "CGW_LINT_FIX_ARGS=\"{files}\"  # flake8 has no auto-fix; use autopep8 manually"
      echo "CGW_LINT_EXCLUDES=\"--exclude logs,.venv\""
      echo "CGW_FORMAT_CMD=\"\"  # set to 'black' or 'autopep8' if available"
      echo "CGW_FORMAT_CHECK_ARGS=\"\""
      echo "CGW_FORMAT_FIX_ARGS=\"\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    eslint)
      echo "CGW_LINT_CMD=\"eslint\""
      echo "CGW_LINT_CHECK_ARGS=\"{files}\""
      echo "CGW_LINT_FIX_ARGS=\"{files} --fix\""
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"prettier\""
      echo "CGW_FORMAT_CHECK_ARGS=\"--check {files}\""
      echo "CGW_FORMAT_FIX_ARGS=\"--write {files}\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    golangci-lint)
      echo "CGW_LINT_CMD=\"golangci-lint\""
      echo "CGW_LINT_CHECK_ARGS=\"run\""
      echo "CGW_LINT_FIX_ARGS=\"run --fix\""
      echo "CGW_LINT_EXCLUDES=\"\""
      echo "CGW_FORMAT_CMD=\"gofmt\""
      echo "CGW_FORMAT_CHECK_ARGS=\"-l {files}\""
      echo "CGW_FORMAT_FIX_ARGS=\"-w {files}\""
      echo "CGW_FORMAT_EXCLUDES=\"\""
      ;;
    clang-tidy)
      # clang-tidy/-format arg shapes keep the legacy form: scoped runs append
      # files after these flags, which is correct usage for both tools.
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
      echo "CGW_LINT_CHECK_ARGS=\"{files}\"  # adjust for your tool; {files} = scan target"
      echo "CGW_LINT_FIX_ARGS=\"{files}\"    # adjust for your tool"
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

# _resolve_template_dir <category>
#   Resolves an asset template directory (hooks, skill, command, templates)
#   using the priority chain:
#     1. TEMPLATE_DIR (from --template-dir <path> or CGW_TEMPLATE_DIR env var)
#     2. Sibling/parent relative lookup (${SCRIPT_DIR}/../../<category>)
#   Returns 0 and prints absolute path on success; returns 1 on failure.
_resolve_template_dir() {
  local sub="${1:-}"
  local resolved=""
  if [[ -n "${TEMPLATE_DIR:-}" ]]; then
    if resolved="$(cd "${TEMPLATE_DIR}/${sub}" 2>/dev/null && pwd)"; then
      echo "${resolved}"
      return 0
    fi
  fi
  # Fallback: relative to SCRIPT_DIR (active when running in CGW source repo or legacy in-repo staging)
  if resolved="$(cd "${SCRIPT_DIR}/../../${sub}" 2>/dev/null && pwd)"; then
    echo "${resolved}"
    return 0
  fi
  return 1
}

_install_single_hook() {
  local hook_name="$1"
  local template_file="$2"
  local overwrite="${3:-0}"
  local target_file="${PROJECT_ROOT}/.githooks/${hook_name}"
  local active_git_hook="${PROJECT_ROOT}/.git/hooks/${hook_name}"

  [[ -f "${template_file}" ]] || return 0

  mkdir -p "${PROJECT_ROOT}/.githooks"

  # Case 1: .githooks/<hook> does not exist yet
  if [[ ! -f "${target_file}" ]]; then
    # If a pre-existing hook is in .git/hooks, back it up so it is never lost
    if [[ -f "${active_git_hook}" ]] && ! cmp -s "${template_file}" "${active_git_hook}"; then
      cp "${active_git_hook}" "${active_git_hook}.bak" 2>/dev/null || true
      echo "  [INFO] Backed up pre-existing .git/hooks/${hook_name} -> .git/hooks/${hook_name}.bak"
    fi
    cp "${template_file}" "${target_file}"
    chmod +x "${target_file}"
    echo "  [OK] Installed .githooks/${hook_name}"
    return 0
  fi

  # Case 2: .githooks/<hook> exists and matches template
  if cmp -s "${template_file}" "${target_file}"; then
    chmod +x "${target_file}"
    echo "  [OK] .githooks/${hook_name} already up to date"
    return 0
  fi

  # Case 3: .githooks/<hook> exists and differs from template
  local do_overwrite="${overwrite}"
  if [[ "${do_overwrite}" -eq 0 ]] && [[ "${non_interactive:-0}" -eq 0 ]]; then
    if cgw_confirm "Existing .githooks/${hook_name} differs from template. Overwrite?" --default no; then
      do_overwrite=1
    fi
  fi

  if [[ "${do_overwrite}" -eq 1 ]]; then
    cp "${target_file}" "${target_file}.bak"
    echo "  [INFO] Backed up .githooks/${hook_name} -> .githooks/${hook_name}.bak"
    cp "${template_file}" "${target_file}"
    chmod +x "${target_file}"
    echo "  [OK] Overwrote .githooks/${hook_name} (--overwrite-hooks)"
  else
    chmod +x "${target_file}"
    echo "  [OK] Preserved locally established .githooks/${hook_name}"
  fi
}

_install_hook() {
  local overwrite_hooks="${1:-0}"
  local hooks_template_dir
  if ! hooks_template_dir="$(_resolve_template_dir hooks)"; then
    hooks_template_dir="${PROJECT_ROOT}/.cgw-hooks-template"
  fi

  local hook_template="${hooks_template_dir}/pre-commit"

  if [[ ! -f "${hook_template}" ]]; then
    # If hook is already installed, nothing to do
    if [[ -f "${PROJECT_ROOT}/.githooks/pre-commit" ]]; then
      echo "  [OK] Pre-commit hook already installed"
      return 0
    fi
    echo "  [!] Hook template not found at: ${hook_template}" >&2
    echo "      Fix: pass --template-dir <path-to-cgw-source> or set CGW_TEMPLATE_DIR," >&2
    echo "      then re-run: ./scripts/git/configure.sh" >&2
    return 1
  fi

  # Hooks read CGW_LOCAL_FILES from .cgw.conf at run time — no pattern substitution needed.
  echo "Installing git hooks..."
  _install_single_hook "pre-commit" "${hooks_template_dir}/pre-commit" "${overwrite_hooks}"
  _install_single_hook "pre-push" "${hooks_template_dir}/pre-push" "${overwrite_hooks}"
  _install_single_hook "pre-rebase" "${hooks_template_dir}/pre-rebase" "${overwrite_hooks}"

  # Run install_hooks.sh to copy to .git/hooks/
  if bash "${SCRIPT_DIR}/install_hooks.sh" >/dev/null 2>&1; then
    echo "  [OK] Git hooks active (pre-commit + pre-push + pre-rebase)"
  else
    echo "  [!] Hooks written to .githooks/ but failed to copy to .git/hooks/" >&2
    echo "      Fix: run manually: ./scripts/git/install_hooks.sh" >&2
    echo "      If that also fails, check that .git/hooks/ is writable." >&2
  fi
}

# ── Agent harnesses (Claude Code = cc, Antigravity = agy) ────────────────────
#
# _harness_spec <host> <field>
#   Where each harness keeps CGW's skill, slash command and guardrail, plus the
#   wording configure.sh uses for it. Guardrail *registration* facts live in
#   _guardrail_spec; host-specific hook command strings stay in the
#   _install_<host>_guardrail installers. Fields ending in :local / :global
#   are per install mode.
# Literal tildes in the *_hint / *_note fields are display strings for prompts,
# never expanded or executed.
# shellcheck disable=SC2088
_harness_spec() {
  case "$1:$2" in
    cc:label) echo "Claude Code" ;;
    cc:dir) echo ".claude" ;;
    cc:skill_dst:local) echo "${PROJECT_ROOT}/.claude/skills/auto-git-workflow" ;;
    cc:skill_dst:global) echo "${HOME}/.claude/skills/auto-git-workflow" ;;
    # cmd_layout file: the command is a plain markdown file in cmd_dst.
    cc:cmd_layout) echo "file" ;;
    cc:cmd_dst:local) echo "${PROJECT_ROOT}/.claude/commands" ;;
    cc:cmd_dst:global) echo "${HOME}/.claude/commands" ;;
    cc:guardrail_dst:local) echo "${PROJECT_ROOT}/.claude/hooks/cc-block-dangerous-git.sh" ;;
    cc:guardrail_dst:global) echo "${HOME}/.claude/hooks/cc-block-dangerous-git.sh" ;;
    cc:settings_json:local) echo "${PROJECT_ROOT}/.claude/settings.json" ;;
    cc:settings_json:global) echo "${HOME}/.claude/settings.json" ;;
    cc:skill_hint:local) echo "project .claude/" ;;
    cc:skill_hint:global) echo "global ~/.claude/" ;;
    cc:skill_global_note) echo "  (--global: skill will be installed to ~/.claude/ for all projects)" ;;
    cc:guardrail_hint:local) echo ".claude/settings.json" ;;
    cc:guardrail_hint:global) echo "~/.claude/settings.json" ;;
    cc:skill_blurb)
      echo "The Claude Code skill teaches Claude to use CGW scripts instead of raw"
      echo "git commands, ensuring lint checks and local-file protection are never bypassed."
      ;;
    cc:guardrail_blurb)
      echo "The PreToolUse guardrail is a Claude Code hook that blocks dangerous git"
      echo "commands (raw 'git commit', '--no-verify', 'git reset --hard', etc.) at the"
      echo "harness layer, before they execute. This is defense-in-depth on top of the"
      echo "repo-side git hooks — the model cannot bypass it by being asked to skip CGW."
      ;;
    cc:summary_skill) echo "Claude skill:" ;;
    cc:summary_guardrail) echo "Claude guard:" ;;

    agy:label) echo "Antigravity" ;;
    agy:dir) echo ".agents" ;;
    agy:skill_dst:local) echo "${PROJECT_ROOT}/.agents/skills/auto-git-workflow" ;;
    agy:skill_dst:global) echo "${HOME}/.gemini/config/skills/auto-git-workflow" ;;
    # cmd_layout skill: Antigravity slash commands are skills
    # (<cmd_dst>/SKILL.md), with links rewritten for that layout.
    agy:cmd_layout) echo "skill" ;;
    agy:cmd_dst:local) echo "${PROJECT_ROOT}/.agents/skills/auto-git-workflow-cmd" ;;
    agy:cmd_dst:global) echo "${HOME}/.gemini/config/skills/auto-git-workflow-cmd" ;;
    agy:guardrail_dst:local) echo "${PROJECT_ROOT}/.agents/hooks/agy-block-dangerous-git.sh" ;;
    agy:guardrail_dst:global) echo "${HOME}/.gemini/config/hooks/agy-block-dangerous-git.sh" ;;
    agy:settings_json:local) echo "${PROJECT_ROOT}/.agents/hooks.json" ;;
    agy:settings_json:global) echo "${HOME}/.gemini/config/hooks.json" ;;
    agy:skill_hint:local) echo "project .agents/skills/auto-git-workflow/" ;;
    agy:skill_hint:global) echo "global ~/.gemini/config/skills/auto-git-workflow/" ;;
    agy:skill_global_note) echo "  (--global: skill will be installed to ~/.gemini/config/skills/ for all projects)" ;;
    agy:guardrail_hint:local) echo ".agents/hooks.json" ;;
    agy:guardrail_hint:global) echo "~/.gemini/config/hooks.json" ;;
    agy:skill_blurb)
      echo "The Antigravity skill teaches Antigravity Agents to use CGW scripts instead"
      echo "of raw git commands, ensuring lint checks and local-file protection are never bypassed."
      ;;
    agy:guardrail_blurb)
      echo "The Antigravity PreToolUse guardrail intercepts run_command tool calls to block"
      echo "dangerous git commands at the harness layer before they execute."
      ;;
    agy:summary_skill) echo "Antigravity:" ;;
    agy:summary_guardrail) echo "AGY guard:" ;;
    *) return 1 ;;
  esac
}

# _install_harness_skill <host> <local|global>
#   Installs the auto-git-workflow skill (SKILL.md + references/) and the
#   auto-git-workflow-cmd slash command into the host's skill/command dirs.
_install_harness_skill() {
  local host="$1" install_mode="${2:-local}"
  local label skill_dst cmd_dst cmd_layout skill_src cmd_src
  label="$(_harness_spec "${host}" label)"
  skill_dst="$(_harness_spec "${host}" "skill_dst:${install_mode}")"
  cmd_dst="$(_harness_spec "${host}" "cmd_dst:${install_mode}")"
  cmd_layout="$(_harness_spec "${host}" cmd_layout)"

  # Where an already-installed command lives, per layout.
  local cmd_installed="${cmd_dst}/auto-git-workflow-cmd.md"
  [[ "${cmd_layout}" == "skill" ]] && cmd_installed="${cmd_dst}/SKILL.md"

  # Try template source first, then already-installed fallback
  if skill_src="$(_resolve_template_dir skill)"; then
    if ! cmd_src="$(cd "${skill_src}/../command" 2>/dev/null && pwd)/auto-git-workflow-cmd.md" || [[ ! -f "${cmd_src}" ]]; then
      local cmd_dir
      if cmd_dir="$(_resolve_template_dir command)"; then
        cmd_src="${cmd_dir}/auto-git-workflow-cmd.md"
      fi
    fi
  elif [[ "${cmd_layout}" == "skill" && -f "${skill_dst}/SKILL.md" && -f "${cmd_installed}" ]]; then
    # A skill-layout command is its own skill: require both to call it installed.
    echo "  [OK] ${label} skill + command already installed (${install_mode})"
    return 0
  elif [[ "${cmd_layout}" == "file" && -f "${skill_dst}/SKILL.md" ]]; then
    echo "  [OK] ${label} skill already installed (${install_mode})"
    return 0
  else
    echo "  [!] Skill template not found." >&2
    echo "      Fix: pass --template-dir <path-to-cgw-source> or set CGW_TEMPLATE_DIR," >&2
    echo "      then re-run: ./scripts/git/configure.sh" >&2
    return 1
  fi

  echo "Installing ${label} skill (${install_mode})..."
  mkdir -p "${skill_dst}/references"

  cp "${skill_src}/SKILL.md" "${skill_dst}/SKILL.md" 2>/dev/null || true
  cp "${skill_src}/references/"*.md "${skill_dst}/references/" 2>/dev/null || true

  if [[ ! -f "${cmd_src}" ]]; then
    echo "  [OK] ${label} skill installed (${install_mode}, command template not found)"
    return 0
  fi
  mkdir -p "${cmd_dst}"
  if [[ "${cmd_layout}" == "skill" ]]; then
    # Adapt links and paths so they work in the skills-directory layout.
    sed -e 's|\.\./skills/auto-git-workflow/|../auto-git-workflow/|g' \
      -e 's|\.claude/skills/auto-git-workflow/|auto-git-workflow/|g' \
      "${cmd_src}" >"${cmd_installed}" 2>/dev/null || true
  else
    cp "${cmd_src}" "${cmd_installed}" 2>/dev/null || true
  fi
  echo "  [OK] ${label} skill + slash command installed (${install_mode})"
}

# _offer_harness_install <host> <skill|guardrail> <skip> <enable> <global>
#   One configure.sh step for one harness: explain it, default to "yes" when
#   the project already has the harness's directory (or --global / --claude /
#   --antigravity was given), confirm, then install locally or globally.
_offer_harness_install() {
  local host="$1" what="$2" skip="$3" enable="$4" global="$5"
  [[ ${skip} -eq 1 ]] && return 0
  local mode="local"
  [[ ${global} -eq 1 ]] && mode="global"

  echo ""
  _harness_spec "${host}" "${what}_blurb"
  if [[ "${what}" == "skill" && ${global} -eq 1 ]]; then
    _harness_spec "${host}" skill_global_note
  fi

  local default="no"
  if [[ -d "$(_harness_spec "${host}" dir)" ]] || [[ ${global} -eq 1 ]] || [[ ${enable} -eq 1 ]]; then
    default="yes"
  fi
  local label hint prompt
  label="$(_harness_spec "${host}" label)"
  hint="$(_harness_spec "${host}" "${what}_hint:${mode}")"
  if [[ "${what}" == "skill" ]]; then
    prompt="Install ${label} skill to ${hint}?"
  else
    prompt="Install ${label} PreToolUse guardrail to ${hint}?"
  fi
  cgw_confirm "${prompt}" --default "${default}" --non-interactive accept || return 0

  if [[ "${what}" == "skill" ]]; then
    _install_harness_skill "${host}" "${mode}"
  else
    "_install_${host}_guardrail" "${mode}"
  fi
}

_install_markdownlint_config() {
  local template_src

  # Try template source first, then in-repo fallback
  if ! template_src="$(_resolve_template_dir templates)"; then
    echo "  [!] Markdown lint template not found -- skipping" >&2
    return 0
  fi

  if [[ ! -f "${template_src}/markdownlint.json" ]]; then
    echo "  [!] Markdown lint template not found -- skipping" >&2
    return 0
  fi

  # Never overwrite an existing markdownlint config, however the project names it
  if compgen -G ".markdownlint*" >/dev/null || compgen -G ".markdownlint-cli2*" >/dev/null; then
    echo "  [OK] Markdown lint config already present -- not overwriting"
    return 0
  fi

  cp "${template_src}/markdownlint.json" "${PROJECT_ROOT}/.markdownlint.json"
  echo "  [OK] Markdown lint baseline installed (.markdownlint.json)"

  # Tool config (gitignore-skip) is a separate file from the rule set above --
  # optional so a stale staging area missing it still installs the rules.
  if [[ -f "${template_src}/markdownlint-cli2.jsonc" ]]; then
    cp "${template_src}/markdownlint-cli2.jsonc" "${PROJECT_ROOT}/.markdownlint-cli2.jsonc"
    echo "  [OK] Markdown lint tool config installed (.markdownlint-cli2.jsonc -- auto-skips gitignored files)"
  fi
}

# Escape a string for interpolation inside a JSON string literal. The no-jq
# write paths below build settings.json / hooks.json with printf, and the
# hook commands they embed carry literal double quotes (e.g.
# "$CLAUDE_PROJECT_DIR"/... and bash -c "..."), which would otherwise land
# unescaped in the file and make it unparseable.
_json_escape_string() {
  local s="${1}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

# _install_guardrail_core <guardrail_src> <hook_dst>
#   Both guardrail adapters source _guardrail_core.sh from their own directory,
#   so the core travels with whichever adapter is installed: copied from next to
#   the adapter's source into the adapter's destination directory. A missing
#   core is reported here and caught again by each installer's smoke test (the
#   adapter fails open without it).
_install_guardrail_core() {
  local core_src core_dst
  core_src="$(dirname "${1}")/_guardrail_core.sh"
  core_dst="$(dirname "${2}")/_guardrail_core.sh"
  # A pre-core (self-contained) guardrail, e.g. an older installed copy picked
  # up by the reconfigure fallback, carries its own classifier and needs none.
  grep -qF "_guardrail_core.sh" "${1}" 2>/dev/null || return 0
  if [[ ! -f "${core_src}" ]]; then
    echo "  [!] ${core_src} not found — the guardrail cannot classify commands without it." >&2
    echo "      Re-copy hooks/ from the CGW source directory, then re-run: ./scripts/git/configure.sh" >&2
    return 1
  fi
  if [[ "${core_src}" != "${core_dst}" ]]; then
    cp "${core_src}" "${core_dst}"
  fi
}

# ── Guardrail registration (shared by every agent harness) ───────────────────
#
# _guardrail_spec <host> <field>
#   The per-harness facts the registrar needs; everything else is shared.
#     label   — name used in status messages
#     keys    — space-separated JSON keys leading to the PreToolUse entry array
#     matcher — tool matcher for the registered entry
#     marker  — substring that identifies a CGW guardrail command
#     bad     — one substring per line marking a corrupted / legacy CGW entry
#               that must be replaced rather than counted as registered
_guardrail_spec() {
  case "$1:$2" in
    cc:label) echo "PreToolUse guardrail" ;;
    cc:keys) echo "hooks PreToolUse" ;;
    cc:matcher) echo "Bash" ;;
    cc:marker) echo "cc-block-dangerous-git" ;;
    cc:bad) echo "Program Files/Git" ;; # MSYS path mangling on Git Bash
    agy:label) echo "Antigravity PreToolUse guardrail" ;;
    agy:keys) echo "cgw-git-guardrail PreToolUse" ;;
    agy:matcher) echo "run_command" ;;
    agy:marker) echo "agy-block-dangerous-git" ;;
    agy:bad) printf '%s\n' "bash -c" "if [" ;; # pre-.cmd-runner command format
    *) return 1 ;;
  esac
}

# _guardrail_is_registered <host> <json_file>
#   Query: true when some registered command names the host's marker and
#   contains none of its bad substrings. jq checks the entry array itself;
#   without jq, the same rule is applied per line (each command is on its own
#   line in every file this installer writes).
_guardrail_is_registered() {
  local host="$1" json="$2" marker keys b
  [[ -f "${json}" ]] || return 1
  marker="$(_guardrail_spec "${host}" marker)" || return 1
  local -a bad=()
  mapfile -t bad < <(_guardrail_spec "${host}" bad)
  if command -v jq &>/dev/null; then
    keys="$(_guardrail_spec "${host}" keys)"
    local k1 k2 bad_json=""
    read -r k1 k2 <<<"${keys}"
    for b in "${bad[@]}"; do bad_json+="\"$(_json_escape_string "${b}")\","; done
    jq -e --arg k1 "${k1}" --arg k2 "${k2}" --arg marker "${marker}" \
      --argjson bad "[${bad_json%,}]" '
      [.[$k1][$k2][]?.hooks[]?.command | strings
        | select(contains($marker))
        | select(. as $c | any($bad[]; . as $b | $c | contains($b)) | not)
      ] | length > 0' "${json}" >/dev/null 2>&1
    return
  fi
  local lines
  lines="$(grep -F -- "${marker}" "${json}" 2>/dev/null)" || return 1
  for b in "${bad[@]}"; do
    lines="$(grep -vF -- "${b}" <<<"${lines}")" || return 1
  done
  [[ -n "${lines}" ]]
}

# _register_guardrail <host> <json_file> <hook_cmd>
#   Modifier: registers <hook_cmd> as the host's PreToolUse guardrail. Removes
#   every stale CGW entry (anything naming the marker), keeps all other
#   entries, appends the new one. Backends, first that applies: a fresh write
#   when the file is missing, blank or {}; jq; python; manual instructions.
#   Returns 1 when nothing was registered. Always (re)writes -- callers ask
#   _guardrail_is_registered first.
_register_guardrail() {
  local host="$1" json="$2" cmd="$3"
  local label keys matcher marker k1 k2
  label="$(_guardrail_spec "${host}" label)" || return 1
  keys="$(_guardrail_spec "${host}" keys)"
  matcher="$(_guardrail_spec "${host}" matcher)"
  marker="$(_guardrail_spec "${host}" marker)"
  read -r k1 k2 <<<"${keys}"

  echo "Installing ${label}..."

  # Fresh write: no file yet, or only whitespace / {} -- no JSON tool needed.
  local existing_stripped=""
  if [[ -f "${json}" ]]; then
    existing_stripped="$(tr -d '[:space:]' <"${json}" 2>/dev/null)"
  fi
  if [[ -z "${existing_stripped}" ]] || [[ "${existing_stripped}" == "{}" ]]; then
    printf '{\n  "%s": {\n    "%s": [\n      {\n        "matcher": "%s",\n        "hooks": [{"type": "command", "command": "%s"}]\n      }\n    ]\n  }\n}\n' \
      "${k1}" "${k2}" "${matcher}" "$(_json_escape_string "${cmd}")" >"${json}"
    echo "  [OK] ${label} registered in ${json}"
    return 0
  fi

  # Split the command at its first "/" and rejoin inside jq/python, so no argument
  # starts with "/" and MSYS2 has nothing to path-convert when it crosses
  # into jq.exe or python.exe on Git Bash (Windows). A no-op everywhere else.
  #   '"$CLAUDE_PROJECT_DIR"/.claude/hooks/...' -> pfx='"$CLAUDE_PROJECT_DIR"'  sfx='.claude/hooks/...'
  local pfx sfx has_slash=false
  pfx="${cmd%%/*}"
  sfx="${cmd#*/}"
  [[ "${cmd}" == */* ]] && has_slash=true

  if command -v jq &>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    jq --arg k1 "${k1}" --arg k2 "${k2}" --arg matcher "${matcher}" --arg marker "${marker}" \
      --arg pfx "${pfx}" --arg sfx "${sfx}" --argjson has_slash "${has_slash}" '
      .[$k1][$k2] |= (
        (. // [])
        | map(select((.hooks // []) | map((.command // "") | contains($marker)) | any | not))
        + [{"matcher": $matcher, "hooks": [{"type": "command",
             "command": (if $has_slash then $pfx + "/" + $sfx else $pfx end)}]}]
      )' "${json}" >"${tmp}" || {
      rm -f "${tmp}"
      echo "  [!] Failed to update ${json} (malformed JSON?). Guardrail NOT registered." >&2
      echo "      Fix or remove the file, then re-run: ./scripts/git/configure.sh" >&2
      return 1
    }
    if ! mv "${tmp}" "${json}"; then
      rm -f "${tmp}"
      echo "  [!] Failed to write ${json}. Guardrail NOT registered." >&2
      return 1
    fi
    echo "  [OK] ${label} registered in ${json}"
    return 0
  fi

  local py_cmd
  for py_cmd in python3 python; do
    if command -v "${py_cmd}" &>/dev/null; then
      if "${py_cmd}" - "${json}" "${pfx}" "${sfx}" "${has_slash}" "${k1}" "${k2}" "${matcher}" "${marker}" 2>/dev/null <<'PYEOF'; then
import json, sys
path, pfx, sfx, has_slash, k1, k2, matcher, marker = sys.argv[1:9]
cmd = f"{pfx}/{sfx}" if has_slash == "true" else pfx
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    data = {}
ptu = data.setdefault(k1, {}).setdefault(k2, [])
ptu[:] = [e for e in ptu
          if not any(marker in h.get('command', '')
                     for h in e.get('hooks', []))]
ptu.append({'matcher': matcher, 'hooks': [{'type': 'command', 'command': cmd}]})
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
PYEOF
        echo "  [OK] ${label} registered in ${json} (via python)"
        return 0
      fi
    fi
  done

  echo "  [!] jq and python not found — cannot auto-merge ${json}" >&2
  echo "      Manually add the following hook entry to ${json}:" >&2
  printf '      {"%s":{"%s":[{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "${k1}" "${k2}" "${matcher}" "$(_json_escape_string "${cmd}")" >&2
  return 1
}

_install_cc_guardrail() {
  local install_mode="${1:-local}" # "local" or "global"

  # Find source script from template directory, or fallback to already-installed copy
  local guardrail_src=""
  local hooks_dir
  if hooks_dir="$(_resolve_template_dir hooks)"; then
    guardrail_src="${hooks_dir}/cc-block-dangerous-git.sh"
  fi

  if [[ ! -f "${guardrail_src:-}" ]]; then
    # Fallback: accept the already-installed copy so reconfigure works after
    # staging has finished.
    if [[ -f "${PROJECT_ROOT}/.claude/hooks/cc-block-dangerous-git.sh" ]]; then
      guardrail_src="${PROJECT_ROOT}/.claude/hooks/cc-block-dangerous-git.sh"
    else
      echo "  [!] hooks/cc-block-dangerous-git.sh not found." >&2
      echo "      Fix: pass --template-dir <path-to-cgw-source> or set CGW_TEMPLATE_DIR," >&2
      echo "      then re-run: ./scripts/git/configure.sh" >&2
      return 1
    fi
  fi

  # Determine destination paths
  local hook_dst settings_json hook_cmd
  if [[ "${install_mode}" == "global" ]]; then
    hook_dst="$(_harness_spec cc guardrail_dst:global)"
    settings_json="$(_harness_spec cc settings_json:global)"
    # Literal tilde is intentional (SC2088): this string is written verbatim
    # into settings.json as the hook's "command" value, not executed here --
    # Claude Code expands it via its own shell when it invokes the hook.
    # shellcheck disable=SC2088
    hook_cmd="~/.claude/hooks/cc-block-dangerous-git.sh"
  else
    hook_dst="$(_harness_spec cc guardrail_dst:local)"
    settings_json="$(_harness_spec cc settings_json:local)"
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
  _install_guardrail_core "${guardrail_src}" "${hook_dst}" || return 1

  if _guardrail_is_registered cc "${settings_json}"; then
    echo "  [OK] PreToolUse guardrail already registered in ${settings_json}"
    return 0
  fi
  _register_guardrail cc "${settings_json}" "${hook_cmd}" || return 1
  # The smoke test reads the registration back with jq.
  command -v jq &>/dev/null || return 0

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

_install_agy_guardrail() {
  local install_mode="${1:-local}" # "local" or "global"

  local guardrail_src="" guardrail_cmd_src=""
  local hooks_dir
  if hooks_dir="$(_resolve_template_dir hooks)"; then
    guardrail_src="${hooks_dir}/agy-block-dangerous-git.sh"
    guardrail_cmd_src="${hooks_dir}/agy-block-dangerous-git.cmd"
  fi

  # No fallback to cc-block-dangerous-git.sh: a cc script older than the
  # Antigravity integration cannot parse the toolCall payload and would
  # silently allow every command while reporting the guardrail as installed.
  if [[ ! -f "${guardrail_src:-}" ]]; then
    if [[ -f "${PROJECT_ROOT}/.agents/hooks/agy-block-dangerous-git.sh" ]]; then
      guardrail_src="${PROJECT_ROOT}/.agents/hooks/agy-block-dangerous-git.sh"
    else
      echo "  [!] hooks/agy-block-dangerous-git.sh not found." >&2
      echo "      Fix: pass --template-dir <path-to-cgw-source> or set CGW_TEMPLATE_DIR," >&2
      echo "      then re-run: ./scripts/git/configure.sh" >&2
      return 1
    fi
  fi
  if [[ ! -f "${guardrail_cmd_src:-}" && -f "${PROJECT_ROOT}/.agents/hooks/agy-block-dangerous-git.cmd" ]]; then
    guardrail_cmd_src="${PROJECT_ROOT}/.agents/hooks/agy-block-dangerous-git.cmd"
  fi

  local is_windows=0
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) is_windows=1 ;;
  esac

  local hook_dst hook_cmd_dst hooks_json hook_cmd
  if [[ "${install_mode}" == "global" ]]; then
    hook_dst="$(_harness_spec agy guardrail_dst:global)"
    hook_cmd_dst="${hook_dst%.sh}.cmd"
    hooks_json="$(_harness_spec agy settings_json:global)"
    if [[ "${is_windows}" -eq 1 ]]; then
      local win_cmd_path
      win_cmd_path="$(cygpath -m "${hook_cmd_dst}" 2>/dev/null || echo "${hook_cmd_dst}")"
      hook_cmd="${win_cmd_path}"
    else
      hook_cmd="bash ~/.gemini/config/hooks/agy-block-dangerous-git.sh"
    fi
  else
    hook_dst="$(_harness_spec agy guardrail_dst:local)"
    hook_cmd_dst="${hook_dst%.sh}.cmd"
    hooks_json="$(_harness_spec agy settings_json:local)"
    if [[ "${is_windows}" -eq 1 ]]; then
      local win_cmd_path
      win_cmd_path="$(cygpath -m "${hook_cmd_dst}" 2>/dev/null || echo "${hook_cmd_dst}")"
      hook_cmd="${win_cmd_path}"
    else
      hook_cmd="bash ${hook_dst}"
    fi
  fi

  mkdir -p "$(dirname "${hook_dst}")"
  mkdir -p "$(dirname "${hooks_json}")"
  if [[ "${guardrail_src}" != "${hook_dst}" ]]; then
    cp "${guardrail_src}" "${hook_dst}"
  fi
  chmod +x "${hook_dst}"
  _install_guardrail_core "${guardrail_src}" "${hook_dst}" || return 1

  if [[ -f "${guardrail_cmd_src:-}" && "${guardrail_cmd_src}" != "${hook_cmd_dst}" ]]; then
    cp "${guardrail_cmd_src}" "${hook_cmd_dst}"
  fi

  if _guardrail_is_registered agy "${hooks_json}"; then
    echo "  [OK] Antigravity PreToolUse guardrail already registered in ${hooks_json}"
    return 0
  fi
  _register_guardrail agy "${hooks_json}" "${hook_cmd}" || return 1
  # The smoke test reads the registration back with jq.
  command -v jq &>/dev/null || return 0

  # Smoke test: read registered command from hooks.json and test with dummy input
  local registered_cmd
  registered_cmd="$(jq -r '."cgw-git-guardrail".PreToolUse[0].hooks[0].command // empty' "${hooks_json}" 2>/dev/null || true)"
  local test_input='{"toolCall":{"name":"run_command","args":{"CommandLine":"git commit -m \"smoke-test\""}}}'
  local smoke_output=""

  if [[ "${is_windows}" -eq 1 ]]; then
    smoke_output="$(echo "${test_input}" | cmd.exe //c "${registered_cmd}" 2>/dev/null || true)"
  else
    smoke_output="$(echo "${test_input}" | bash -c "${registered_cmd}" 2>/dev/null || true)"
  fi

  if [[ "${smoke_output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]; then
    echo "  [OK] Smoke test passed: registered Antigravity guardrail blocks raw git commit"
  else
    echo "  [WARN] Smoke test: Antigravity guardrail did not return expected decision:deny (output=${smoke_output})" >&2
  fi
}

# Append a single entry to .gitignore if it isn't already present (exact-line match).
# Returns 0 if the entry was added, 1 if it was already present, 2 if the write failed.
# Echoes nothing itself -- callers report what was added or failed.
_ensure_gitignore_entry() {
  local entry="$1"
  local gitignore="${PROJECT_ROOT}/.gitignore"

  if [[ -f "${gitignore}" ]] && grep -qxF "${entry}" "${gitignore}" 2>/dev/null; then
    return 1
  fi

  # A file missing its final newline would otherwise glue this entry onto the last
  # line (e.g. "node_modules/" + "logs/" -> "node_modules/logs/"), silently
  # corrupting an existing rule instead of adding a new one.
  if [[ -s "${gitignore}" ]] && [[ -n "$(tail -c 1 "${gitignore}")" ]]; then
    printf '\n' >>"${gitignore}" || return 2
  fi
  echo "${entry}" >>"${gitignore}" || return 2
  return 0
}

_update_gitignore() {
  local entries=("logs/" ".cgw.conf" ".cgw.conf.bak")
  local added=()
  local failed=()
  local status

  for entry in "${entries[@]}"; do
    _ensure_gitignore_entry "${entry}"
    status=$?
    if [[ ${status} -eq 0 ]]; then
      added+=("${entry}")
    elif [[ ${status} -eq 2 ]]; then
      failed+=("${entry}")
    fi
  done

  if [[ ${#added[@]} -gt 0 ]]; then
    echo "  [OK] Added to .gitignore: ${added[*]}"
  elif [[ ${#failed[@]} -eq 0 ]]; then
    echo "  [OK] .gitignore already up to date"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "  [WARN] Could not write to .gitignore: ${failed[*]}" >&2
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

  # Never clean staging directories when running inside the CGW source repository itself.
  if [[ -f "${PROJECT_ROOT}/cgw-batch-install.cmd" && -f "${PROJECT_ROOT}/cgw-install.cmd" && -f "${PROJECT_ROOT}/tests/run.sh" ]]; then
    return 0
  fi

  # Prune legacy staging directories in consumer projects if they carry CGW markers
  if [[ -d "${PROJECT_ROOT}/skill" ]]; then
    if [[ -f "${PROJECT_ROOT}/skill/SKILL.md" ]] && grep -q "auto-git-workflow" "${PROJECT_ROOT}/skill/SKILL.md" 2>/dev/null; then
      rm -rf "${PROJECT_ROOT}/skill"
      echo "  [OK] Removed legacy staging directory: skill/"
    fi
  fi
  if [[ -d "${PROJECT_ROOT}/command" ]]; then
    if [[ -f "${PROJECT_ROOT}/command/auto-git-workflow-cmd.md" ]] && grep -q "auto-git-workflow-cmd" "${PROJECT_ROOT}/command/auto-git-workflow-cmd.md" 2>/dev/null; then
      rm -rf "${PROJECT_ROOT}/command"
      echo "  [OK] Removed legacy staging directory: command/"
    fi
  fi
  if [[ -d "${PROJECT_ROOT}/templates" ]]; then
    if [[ -f "${PROJECT_ROOT}/templates/markdownlint.json" || -f "${PROJECT_ROOT}/templates/markdownlint-cli2.jsonc" ]]; then
      local foreign_files=0
      local f b
      for f in "${PROJECT_ROOT}/templates/"*; do
        [[ ! -e "${f}" ]] && continue
        b="$(basename "${f}")"
        case "${b}" in
          markdownlint.json | markdownlint-cli2.jsonc) ;;
          *)
            foreign_files=1
            ;;
        esac
      done
      if [[ ${foreign_files} -eq 0 ]]; then
        rm -rf "${PROJECT_ROOT}/templates"
        echo "  [OK] Removed legacy staging directory: templates/"
      else
        rm -f "${PROJECT_ROOT}/templates/markdownlint.json" "${PROJECT_ROOT}/templates/markdownlint-cli2.jsonc"
        echo "  [OK] Removed legacy staging CGW template files from templates/"
      fi
    fi
  fi
  if [[ -d "${PROJECT_ROOT}/hooks" ]]; then
    if [[ -f "${PROJECT_ROOT}/hooks/pre-commit" ]] && grep -q "claude-git-workflow" "${PROJECT_ROOT}/hooks/pre-commit" 2>/dev/null; then
      local foreign_files=0
      local f b
      for f in "${PROJECT_ROOT}/hooks/"*; do
        [[ ! -e "${f}" ]] && continue
        b="$(basename "${f}")"
        case "${b}" in
          pre-commit | pre-push | pre-rebase | cc-block-dangerous-git.sh | agy-block-dangerous-git.sh | agy-block-dangerous-git.cmd | _guardrail_core.sh) ;;
          *)
            foreign_files=1
            ;;
        esac
      done
      if [[ ${foreign_files} -eq 0 ]]; then
        rm -rf "${PROJECT_ROOT}/hooks"
        echo "  [OK] Removed legacy staging directory: hooks/"
      else
        rm -f "${PROJECT_ROOT}/hooks/pre-commit" "${PROJECT_ROOT}/hooks/pre-push" "${PROJECT_ROOT}/hooks/pre-rebase" \
          "${PROJECT_ROOT}/hooks/cc-block-dangerous-git.sh" "${PROJECT_ROOT}/hooks/agy-block-dangerous-git.sh" \
          "${PROJECT_ROOT}/hooks/agy-block-dangerous-git.cmd" "${PROJECT_ROOT}/hooks/_guardrail_core.sh"
        echo "  [OK] Removed legacy staging CGW hook files from hooks/"
      fi
    fi
  fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local non_interactive=0
  local reconfigure=0
  local overwrite_hooks=0
  local skip_hooks=0
  local skip_skill=0
  local skip_cc_guardrail=0
  local skip_agy_skill=0
  local skip_agy_guardrail=0
  local enable_claude=0
  local enable_agy=0
  local global_skill=0
  TEMPLATE_DIR="${TEMPLATE_DIR:-${CGW_TEMPLATE_DIR:-}}"

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help | -h)
        echo "Usage: ./scripts/git/configure.sh [OPTIONS]"
        echo ""
        echo "Auto-configure claude-git-workflow for this project."
        echo "Scans the project and generates .cgw.conf, installs hooks,"
        echo "and installs skills/guardrails for Claude Code and Antigravity Agents."
        echo ""
        echo "Options:"
        echo "  --template-dir <dir> Path to CGW source toolkit providing asset templates"
        echo "  --non-interactive    Accept all auto-detected defaults"
        echo "  --reconfigure        Overwrite existing .cgw.conf"
        echo "  --overwrite-hooks    Overwrite existing .githooks/* with templates (default: preserve)"
        echo "  --skip-hooks         Don't install git pre-commit hook"
        echo "  --skip-skill         Don't install skills (skips both Claude and Antigravity)"
        echo "  --skip-claude        Skip Claude Code integration (skill + guardrail)"
        echo "  --skip-antigravity   Skip Antigravity integration (skill + guardrail)"
        echo "  --skip-cc-guardrail  Don't install Claude Code PreToolUse guardrail"
        echo "  --skip-agy-skill     Don't install Antigravity skill"
        echo "  --skip-agy-guardrail Don't install Antigravity PreToolUse guardrail"
        echo "  --claude             Explicitly enable Claude Code integration"
        echo "  --antigravity        Explicitly enable Antigravity Agents integration"
        echo "  --global             Install skills globally (~/.claude/ and ~/.gemini/config/)"
        echo "  -h, --help           Show this help"
        echo ""
        echo "After running, edit .cgw.conf to customize any detected values."
        exit 0
        ;;
      --template-dir)
        shift
        TEMPLATE_DIR="${1:-}"
        ;;
      --template-dir=*)
        TEMPLATE_DIR="${1#*=}"
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      --reconfigure) reconfigure=1 ;;
      --overwrite-hooks) overwrite_hooks=1 ;;
      --skip-hooks) skip_hooks=1 ;;
      --skip-skill)
        skip_skill=1
        skip_agy_skill=1
        ;;
      --skip-claude)
        skip_skill=1
        skip_cc_guardrail=1
        ;;
      --skip-antigravity)
        skip_agy_skill=1
        skip_agy_guardrail=1
        ;;
      --skip-cc-guardrail) skip_cc_guardrail=1 ;;
      --skip-agy-skill) skip_agy_skill=1 ;;
      --skip-agy-guardrail) skip_agy_guardrail=1 ;;
      --claude) enable_claude=1 ;;
      --antigravity) enable_agy=1 ;;
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
    echo "     Answering yes regenerates it from auto-detection and discards any"
    echo "     manually-edited settings (a .cgw.conf.bak backup is made first)."
    echo "     Scripts, hooks, and the skill are refreshed either way."
    if cgw_confirm "Regenerate .cgw.conf from auto-detection (discards manual edits)?" --default no --non-interactive deny; then
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
    # Back up the existing config before it is regenerated -- this only runs on the
    # --reconfigure path (the fresh-install path has no ".cgw.conf" to back up), so a
    # run that preserves the config never produces a stray .bak.
    if [[ -f ".cgw.conf" ]]; then
      if ! cp ".cgw.conf" ".cgw.conf.bak"; then
        echo "[ERROR] Could not back up .cgw.conf -> .cgw.conf.bak." >&2
        echo "        Refusing to regenerate .cgw.conf without a backup; config left untouched." >&2
        exit 1
      fi
      echo "  [OK] Backed up existing .cgw.conf -> .cgw.conf.bak"
      # _update_gitignore only runs on fresh installs (see below); an existing project
      # being reconfigured still needs .cgw.conf.bak kept out of git status.
      local gitignore_status
      _ensure_gitignore_entry ".cgw.conf.bak"
      gitignore_status=$?
      if [[ ${gitignore_status} -eq 2 ]]; then
        echo "  [WARN] Could not write to .gitignore: .cgw.conf.bak" >&2
      fi
    fi
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
      echo "# Options: any files/dirs (trailing \"/\" for dirs); commit_enhanced.sh"
      echo "# unstages these before every commit."
      echo "CGW_LOCAL_FILES=\"${local_files}\""
      echo ""
      echo "# Lint configuration (auto-detected)"
      _build_lint_config "${detected_lint}" "${detected_venv}"
      echo ""
      echo "# Typecheck configuration (auto-detected)"
      _build_typecheck_config "${detected_typecheck}"
      echo ""
      echo "# Commit message prefix extras (pipe-separated, e.g. \"cuda|tensorrt\")"
      echo "# Options: \"\" (standard prefixes only: feat fix docs chore test refactor"
      echo "# style perf) or extra words pipe-separated. Not needed for scopes or \"!\""
      echo "# -- type(scope)!: is accepted natively."
      echo "CGW_EXTRA_PREFIXES=\"\""
      echo ""
      echo "# Freeform-message branches (space-separated bash globs; empty = none)"
      echo "# Branches matching a glob here skip the conventional-format check and the"
      echo "# subject-length hard cap -- use for branches that target another project"
      echo "# with its own commit-message style (e.g. an upstream PR branch)."
      echo "# Guard-proof: the source, target, and protected branches are never"
      echo "# exempted, even by \"*\" -- a matching-but-guarded branch falls back to"
      echo "# the normal format check."
      echo "# Example: CGW_FREEFORM_MESSAGE_BRANCHES=\"up/* upstream/*\""
      echo "CGW_FREEFORM_MESSAGE_BRANCHES=\"\""
      echo ""
      echo "# Optional delegated check for freeform-branch messages (empty = skip only)"
      echo "# Options: \"\" (no check runs) or a command run with the message as \$1,"
      echo "# e.g. the target project's own commit-msg hook. Relative paths resolve"
      echo "# against the project root."
      echo "CGW_FREEFORM_MESSAGE_CHECK=\"\""
      echo ""
      echo "# Docs CI pattern (empty = skip; set to enable doc filename validation)"
      echo "# Options: \"\" (skip) or a bash ERE matching allowed docs/ filenames."
      echo "# Example: CGW_DOCS_PATTERN=\"^(README\\.md|.*_GUIDE\\.md|.*_REFERENCE\\.md)$\""
      echo "CGW_DOCS_PATTERN=\"\""
      echo ""
      echo "# Dev-only files warning for cherry-pick (space-separated; empty = skip)"
      echo "# Options: \"\" (no check) or paths; a cherry-pick touching them warns"
      echo "# (aborts in non-interactive). Example: CGW_DEV_ONLY_FILES=\"tests/ pytest.ini\""
      echo "CGW_DEV_ONLY_FILES=\"\""
      echo ""
      echo "# Markdown lint tool is auto-detected at runtime (markdownlint-cli2 ->"
      echo "# markdownlint -> npx --yes markdownlint-cli2 fallback -> disabled); not"
      echo "# stored here -- see _config.sh. Set CGW_MARKDOWNLINT_CMD=\"\" to opt out,"
      echo "# or override CMD/ARGS/PATHS/FIX_ARGS explicitly:"
      echo "# CGW_MARKDOWNLINT_CMD=\"markdownlint-cli2\""
      echo "# CGW_MARKDOWNLINT_ARGS=\"!CLAUDE.md !MEMORY.md\""
      echo "# CGW_MARKDOWNLINT_PATHS=\"**/*.md\""
      echo "# CGW_MARKDOWNLINT_FIX_ARGS=\"--fix\""
      echo ""
      echo "# Allow merge/cherry-pick to carry CGW_LOCAL_FILES into shared history"
      echo "# (guard aborts non-interactively when 0)"
      echo "# CGW_ALLOW_LOCAL_FILES_IN_MERGE=\"0\""
      echo ""
      echo "# Remove tests/ from target branch if gitignored (0=disabled, 1=enabled)"
      echo "# Options: \"0\" (leave tests/ alone -- default) | \"1\" (merge_with_validation.sh"
      echo "# removes tests/ from target when \"tests/\" is gitignored)."
      echo "CGW_CLEANUP_TESTS=\"0\""
      echo ""
      echo "# Merge mode for promoting source -> target (agent-facing; read by the"
      echo "# skill's full-promotion flow, not by the scripts)."
      echo "# Options: \"direct\" (merge locally via merge_with_validation.sh, no review)"
      echo "#        | \"pr\"     (create_pr.sh -> GitHub PR + CI agent review;"
      echo "#                    requires gh CLI installed + authenticated)"
      echo "CGW_MERGE_MODE=\"direct\""
      echo "# CGW_MERGE_MODE=\"pr\""
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

  # -- Install markdown lint baseline config ---------------------------------

  echo ""
  _install_markdownlint_config

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
      _install_hook "${overwrite_hooks}"
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

  # -- Agent harness integrations (skill + PreToolUse guardrail per harness) --

  _offer_harness_install cc skill "${skip_skill}" "${enable_claude}" "${global_skill}"
  _offer_harness_install cc guardrail "${skip_cc_guardrail}" "${enable_claude}" "${global_skill}"
  _offer_harness_install agy skill "${skip_agy_skill}" "${enable_agy}" "${global_skill}"
  _offer_harness_install agy guardrail "${skip_agy_guardrail}" "${enable_agy}" "${global_skill}"

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
  local _host _mode
  for _host in cc agy; do
    for _mode in local global; do
      [[ "${_mode}" == "global" && ${global_skill} -eq 0 ]] && continue
      if [[ -f "$(_harness_spec "${_host}" "skill_dst:${_mode}")/SKILL.md" ]]; then
        printf '  %-16sinstalled\n' "$(_harness_spec "${_host}" summary_skill)"
        break
      fi
    done
    for _mode in local global; do
      [[ "${_mode}" == "global" && ${global_skill} -eq 0 ]] && continue
      if [[ -f "$(_harness_spec "${_host}" "guardrail_dst:${_mode}")" ]]; then
        printf '  %-16sinstalled\n' "$(_harness_spec "${_host}" summary_guardrail)"
        break
      fi
    done
  done
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
