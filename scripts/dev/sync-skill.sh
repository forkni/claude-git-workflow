#!/usr/bin/env bash
# scripts/dev/sync-skill.sh
# Re-sync the git-ignored local .claude/ install from the canonical sources.
# Run this after editing skill/ or command/ to refresh the active in-project
# Claude Code skill and slash command without re-running the full configure.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "Syncing skill/ and command/ → .claude/ ..."

mkdir -p "$REPO_ROOT/.claude/skills/auto-git-workflow/references"
mkdir -p "$REPO_ROOT/.claude/commands"

cp "$REPO_ROOT/skill/SKILL.md" "$REPO_ROOT/.claude/skills/auto-git-workflow/SKILL.md"
cp "$REPO_ROOT/skill/references/"*.md "$REPO_ROOT/.claude/skills/auto-git-workflow/references/"
cp "$REPO_ROOT/command/auto-git-workflow-cmd.md" "$REPO_ROOT/.claude/commands/auto-git-workflow-cmd.md"

echo "Done. Local install matches source."
