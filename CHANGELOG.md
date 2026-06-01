## d4f20ac (2026-06-01)

> Changes since `v0.4.0`

### New Features

  - cgw-install.cmd — offer to install jq via winget if not found (PI-07) (c782c2c)
  - add signing support, recover.sh, pre-rebase hook, worktree_manage.sh (98387f0)

### Bug Fixes

  - guardrail false positives — strip quoted strings before pattern matching (d4f20ac)
  - configure.sh — add Python fallback for PreToolUse guardrail when jq is not available (70f4c52)
  - cgw-install.cmd — add pre-rebase to PI-04 check, copy step, backup, and summaries; remove hardcoded script count (21364b4)
  - Pro Git audit — worktree-safe rebase detection, NUL conflict paths, exact path matching, changelog separators, bisect ref (e92b00f)

### Documentation

  - update skill, script-reference, usage, configuration, installation for new tools; fix pre-commit CGW_SKIP_TYPECHECK bug (6a2cf34)


