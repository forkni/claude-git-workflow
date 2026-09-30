# Design: per-branch exemption from conventional-commit enforcement

Status: proposed 2026-09-02. Not implemented. Motivating case: forkni/voro-engine and
forkni/voro-td carry `up/*` branches whose commits go to dotsimulate as PRs, and dotsimulate's
own `hooks/commit-msg` rejects conventional prefixes and AI trailers. CGW currently has no way
to say "this branch uses another project's message style".

## Problem

Enforcement of the `type(scope)!: subject` grammar lives in one predicate,
`cgw_validate_commit_message` (`scripts/git/_common.sh:1444`), called from three places:

| Site | Behaviour on a non-conventional message |
|---|---|
| `scripts/git/commit_enhanced.sh:692` | `cgw_confirm "Continue anyway?" --non-interactive abort`: non-interactive runs exit, interactive runs prompt |
| `scripts/git/undo_last.sh:351` (amend-message) | `cgw_confirm ... --non-interactive accept`: passes non-interactively |
| `hooks/pre-push` check [2] | hard `exit 1`, suggests `git push --no-verify` |

The only bypasses are `--no-verify` and `SKIP_CGW_GUARDRAIL=1`, and the Claude Code
guardrail `hooks/cc-block-dangerous-git.sh:213` blocks the `--no-verify` token in every Bash
call. `CGW_EXTRA_PREFIXES` cannot help: the regex requires a `type:` colon form, and an
upstream-style subject ("Present track_anything count as a one-channel CHOP") has none.

Result today: every push of an `up/*` branch needs the user to run `git push --no-verify` by
hand, and every commit on such a branch has to be made with `git -C <path> commit`, which
the guardrail does not inspect (documented limitation, `cc-block-dangerous-git.sh:133-136`).
Both are workarounds around the tooling rather than uses of it.

## Non-goals and rejected options

- **Teach the guardrail to allow `--no-verify` on some branches.** The PreToolUse hook only
  sees command text; it cannot know the branch, and widening the `--no-verify` exemption
  reopens the pre-commit lint / local-file bypass for every branch. Rejected.
- **Widen `CGW_EXTRA_PREFIXES` or the regex to accept capitalised imperatives.** That
  disables the check for every branch. Rejected.
- **Skip the local-only-file guard on exempt branches.** Never. The reason `CLAUDE.md`,
  `.claude/`, `logs/` must stay out of an upstream PR is stronger, not weaker.

## Proposal

One new setting, one predicate, three call-site edits.

### Setting

```bash
# .cgw.conf / cgw.conf.example
# Space-separated bash glob patterns of branch names whose commit MESSAGE FORMAT is
# not checked (conventional-commit grammar). Everything else still applies: lint,
# local-only files, subject length, protected branches. Use for branches that
# target another project with its own commit-message style (upstream PR branches).
# Example: CGW_FREEFORM_MESSAGE_BRANCHES="up/* upstream/*"
CGW_FREEFORM_MESSAGE_BRANCHES=""
```

`_config.sh` (next to the prefix block, ~line 186):

```bash
CGW_FREEFORM_MESSAGE_BRANCHES="${CGW_FREEFORM_MESSAGE_BRANCHES:-}"
```

Same three-tier resolution as every other `CGW_*` var (env > `.cgw.conf` > default). Because
the pre-push hook and `_config.sh` already fall back to the main worktree's `.cgw.conf` from a
linked worktree (`_config.sh:88-101`), a setting made once in the fork's main checkout covers
`../voro-engine-up` with no further wiring.

### Predicate (`_common.sh`, beside `cgw_validate_commit_message`)

```bash
# cgw_branch_is_freeform <branch>
#   Returns 0 if <branch> matches any glob in CGW_FREEFORM_MESSAGE_BRANCHES.
#   Pure predicate, no output. Empty setting: always 1.
cgw_branch_is_freeform() {
  local branch="$1" pat
  local -a _pats=()
  read -r -a _pats <<<"${CGW_FREEFORM_MESSAGE_BRANCHES:-}" || true
  for pat in "${_pats[@]+"${_pats[@]}"}"; do
    # shellcheck disable=SC2053  # unquoted RHS is the point: glob match
    [[ "${branch}" == ${pat} ]] && return 0
  done
  return 1
}
```

Same shape as `cgw_is_local_file` (`_common.sh:598`): `read -r -a` from a space-separated
setting, loop, anchored `[[ == ]]`. Bash `[[ == glob ]]` lets `*` cross `/`, so `up/*`
matches `up/a/b` as well; that is the desired behaviour for a namespace prefix.

### Call sites

1. **`hooks/pre-push` check [2].** Derive the branch from the ref being pushed to, falling
   back to the local ref, so `git push origin HEAD:up/x` and `git push -u origin up/x` both
   resolve to `up/x`:

   ```bash
   _branch="${REMOTE_REF#refs/heads/}"
   [[ "${_branch}" == "${REMOTE_REF}" ]] && _branch="${LOCAL_REF#refs/heads/}"
   if cgw_branch_is_freeform "${_branch}"; then
     echo "pre-push: ${_branch} matches CGW_FREEFORM_MESSAGE_BRANCHES, commit-format check skipped"
   elif [[ -n "${CGW_ALL_PREFIXES}" ]]; then
     ... existing loop unchanged ...
   fi
   ```

   Check [1] (local-only files) runs before this and is untouched. Tag pushes
   (`refs/tags/...`) never match a branch glob, so their behaviour is unchanged.

2. **`commit_enhanced.sh` step [5].** `current_branch` is already computed at line 294:

   ```bash
   if cgw_branch_is_freeform "${current_branch}"; then
     echo "  [i] ${current_branch} matches CGW_FREEFORM_MESSAGE_BRANCHES, conventional format not enforced"
   elif ! cgw_validate_commit_message "${commit_msg}"; then
     ... existing warning + cgw_confirm unchanged ...
   fi
   ```

   The subject-length check that follows stays on. It strips at the first colon; a message
   with no colon is measured whole, which is the right measurement for a freeform subject.

3. **`undo_last.sh amend-message`.** Same two-line guard around the validation at line 351.

`cc-block-dangerous-git.sh` is not changed. With the exemption in place there is no longer
any reason to reach for `--no-verify` or for raw `git -C ... commit`, so the guardrail keeps
blocking both. That is the whole point: the sanctioned path becomes the easy path.

### Optional follow-up (not in the first cut)

`CGW_FREEFORM_MESSAGE_CHECK="<command>"`: when set, freeform branches run this command with
the message file as `$1` instead of skipping validation, e.g. the target project's own
`hooks/commit-msg`. Gives upstream-style branches a real gate instead of none. Deferred
because it needs a worktree-relative path convention and the upstream hook is already
exercised by hand today (`sh hooks/commit-msg <file>`).

## Files touched

| File | Change |
|---|---|
| `scripts/git/_config.sh` | default + comment for `CGW_FREEFORM_MESSAGE_BRANCHES` |
| `scripts/git/_common.sh` | `cgw_branch_is_freeform` |
| `hooks/pre-push` | branch derivation + skip of check [2] |
| `scripts/git/commit_enhanced.sh` | step [5] guard |
| `scripts/git/undo_last.sh` | amend-message guard |
| `scripts/git/configure.sh:947` | emit the new var (empty) into generated `.cgw.conf` |
| `cgw.conf.example` | documented entry after `CGW_EXTRA_PREFIXES` |
| `docs/configuration.md:89` | table row |
| `docs/usage.md:33` | one sentence after the `CGW_EXTRA_PREFIXES` mention |
| `skill/SKILL.md:188` (+ `.claude/skills/...` mirror via `scripts/dev/sync-skill.sh`) | paragraph: on a freeform branch `commit_enhanced.sh` is still the only commit path; `--no-verify` and raw `git commit` stay forbidden |
| `skill/references/script-reference.md:589` | env-var table row |
| `CHANGELOG.md` | entry under the next release |

## Tests (Bats, existing helpers)

`tests/unit/common.bats`

- `cgw_branch_is_freeform`: empty setting returns 1; exact name; `up/*` matches `up/x` and
  `up/a/b`; does not match `upstream` or `feature/up/x`; two patterns; env override.

`tests/unit/config.bats` (mirror the `CGW_ALL_PREFIXES` block at 369-393)

- default empty; env wins over `.cgw.conf`; `.cgw.conf` value honoured.

`tests/integration/pre_push_hook.bats` (uses `_bypass_commit` + `create_test_repo_with_remote`)

- freeform branch: "Present X as Y" pushes with status 0 and the skip line in output.
- same message on `development`: still blocked (regression guard).
- freeform branch + committed `CLAUDE.md`: still blocked by check [1].
- `git push origin HEAD:refs/heads/up/x` from a differently named local branch: exempt via
  `REMOTE_REF`.
- linked worktree (`create_test_worktree`, `.cgw.conf` only in main): exempt from the
  worktree, proving the config fallback.

`tests/integration/commit_enhanced.bats` (mirror line 1053)

- non-interactive freeform message on a matching branch exits 0 and commits.
- same message on `development` still exits 1 with "conventional format".

## Rollout to the two consumers

Both forks track `scripts/git/` and `.githooks/` in git (voro-engine: 34 files), so the
change is a normal commit in each fork, not a machine-local install.

1. Land in CGW (`development`, PR, `main`), tag.
2. **voro-engine**: `cgw-batch-install.cmd` (it is in `cgw-install-batch.conf`) or copy the
   five changed files, then `./scripts/git/install_hooks.sh` to refresh `.git/hooks/pre-push`
   (hooks are shared with `../voro-engine-up` through `$GIT_COMMON_DIR/hooks`). Add
   `CGW_FREEFORM_MESSAGE_BRANCHES="up/*"` to the fork's `.cgw.conf` (git-ignored, per
   machine). Commit the tooling update with `commit_enhanced.sh` as a `chore:`.
3. **voro-td: do not batch-install.** Its `.githooks/pre-push` and `scripts/git/` carry a
   local extension CGW does not have (`_protected_ref_guard.sh`, check [0], plus the coverage
   ratchet; commits `3f25af8`, `e5c6f1c`, `df075fa`). A blind copy from `hooks/pre-push`
   would drop it. Hand-merge the check [2] hunk into voro-td's hook, or first upstream the
   protected-ref guard into CGW so both consumers converge on one template again. The
   `_config.sh` / `_common.sh` / `commit_enhanced.sh` / `undo_last.sh` copies are safe to
   overwrite there (`diff -q` against CGW to confirm before copying).
4. Global mirror: `claude-dotfiles/.claude/hooks/cc-block-dangerous-git.sh` and its
   `settings.json` PreToolUse entry are unchanged by this design; no redeploy needed.

## Interim, until this lands

The four pending `up/*` pushes still need `git push --no-verify` run by the user, or
`SKIP_CGW_GUARDRAIL=1` in the Claude session environment. Neither should be needed again once
step 2 above is done.
