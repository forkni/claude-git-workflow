# shellcheck shell=bash
# _guardrail_core.sh — shared dangerous-git classifier for the CGW agent guardrails
# (cc-block-dangerous-git.sh, agy-block-dangerous-git.sh). Sourced, never executed.
#
# Interface:
#   cgw_guardrail_classify <command>
#     Pure: no stdin, no jq, no exit. Returns 0 when <command> is allowed.
#     Returns 1 when it is blocked, printing the matched pattern on line 1 and
#     the redirect guidance on line 2. The first matching invocation (in
#     command order) and the first matching check (in the order below) wins.
#
# Each host adapter owns its own stdin parsing and allow/deny protocol; this
# file owns only the decision, so a classifier fix lands once for every host.
#
# Heuristic limits (defense-in-depth, not a sandbox): this classifier does not
# evaluate `eval`, shell aliases/functions, nested shells (`bash -c '...'`),
# `git -C <path> <subcmd>` / `git --git-dir=... <subcmd>` (the subcommand isn't
# adjacent to `git`), or `$'...'` / `$"..."` ANSI-C and locale quoting (treated
# like plain quotes). It also never identifies the executable: matching is position-independent so
# `env git commit`, `command git commit`, `time git commit` are all caught, and
# the same rule redirects `echo git commit` -- quoted or not (`echo 'git' commit`
# dequotes to the identical text). Quoting changes nothing here: a quoted
# single word matches like its unquoted form by design; only a quoted span
# containing whitespace is kept as one non-matching token.
# The git pre-commit / pre-push hooks remain the enforcement layer for whatever
# gets through; the guardrails exist to redirect an agent to the CGW wrappers
# early.

cgw_guardrail_classify() {
  local command="$1"
  local unquoted joined segmented _invocation

  # Remove shell quotes but keep each quoted span as ONE token, so blocked keywords
  # inside a commit message or other quoted sentence cannot match, while a quoted
  # command word or flag still does. `commit_enhanced.sh "docs: explain git commit"`
  # must not match the 'git commit' block, but `git "push" --force` must match
  # 'git push --force' -- the shell runs it exactly like the unquoted form.
  unquoted=$(_cgw_guardrail_dequote "${command}")

  # Split into individual shell invocations before pattern matching, so a flag or
  # exemption belonging to one command (e.g. `--cached` after a `;`) cannot satisfy
  # a check for a different, earlier command on the same line. Join backslash-
  # newline continuations first so a wrapped command stays one invocation, then
  # split on shell separators (; | & newline). `&&` / `||` produce an empty
  # segment, which matches no pattern and is harmlessly skipped.
  # Windows jq.exe emits CRLF, so a continuation arrives as backslash-CR-LF;
  # drop CRs first so it still joins.
  joined="${unquoted//$'\r'/}"
  joined="${joined//\\$'\n'/ }"
  segmented="${joined//[;|&$'\n']/$'\n'}"

  while IFS= read -r _invocation; do
    _cgw_guardrail_check_invocation "${_invocation}" || return 1
  done <<<"${segmented}"
  return 0
}

# _cgw_guardrail_dequote <command> — print <command> with its "..." and '...'
# quotes removed. Whitespace and shell separators (; | &) inside a quoted span
# become \x1f, which is neither [[:space:]] nor a separator, so the span stays a
# single token: no check can match across it and segmentation cannot split it.
# Spans may cross newlines (multi-line messages). An unterminated quote leaves
# the rest of the command as written. Pure bash: one regex match per span.
# Backslash escapes follow the shell: outside quotes and inside "..." a `\x`
# pair is content (so `\"` neither opens nor closes a span and
# `"say \"git commit\" now"` stays one token); inside '...' a backslash is
# literal and the first `'` always closes.
_cgw_guardrail_dequote() {
  local rest="$1" out="" span
  local re_open='^((\\.|[^"'"'"'\\])*)(["'"'"'])(.*)$'
  local re_dq='^((\\.|[^"\\])*)"(.*)$'
  local re_sq="^([^']*)'(.*)$"

  # Group layout: re_open -> 1=prefix 3=quote 4=rest; re_dq -> 1=span 3=rest;
  # re_sq -> 1=span 2=rest (the (\\.|...) alternation adds an inner group).
  while [[ ${rest} =~ ${re_open} ]]; do
    out+="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[4]}"
    if [[ ${BASH_REMATCH[3]} == '"' ]]; then
      [[ ${rest} =~ ${re_dq} ]] || break
      span="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[3]}"
    else
      [[ ${rest} =~ ${re_sq} ]] || break
      span="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
    fi
    out+="${span//[[:space:];|&]/$'\x1f'}"
  done
  printf '%s' "${out}${rest}"
}

# _cgw_guardrail_verdict <pattern> <redirect> — report a block to the caller.
_cgw_guardrail_verdict() {
  printf '%s\n%s\n' "$1" "$2"
}

# ── Pattern checks ────────────────────────────────────────────────────────────
# Each invocation (one shell command — see segmentation above) is checked in
# isolation with bash's built-in [[ =~ ]] regex operator against a padded copy
# (" ${cmd} "), so every token is whitespace-delimited on both sides. That
# absorbs tabs/repeated spaces without spawning a subprocess per check — with
# segmentation multiplying the check count by segment count, per-check grep
# subprocesses would be visibly slow under Git Bash on Windows.
# CGW wrapper scripts in scripts/git/ are trusted; their subprocesses
# are not intercepted by this hook (PreToolUse only fires for direct Bash calls).

_cgw_guardrail_check_invocation() {
  local padded=" $1 "

  # Reusable flag fragments (unquoted so [[ =~ ]] treats them as regex, not literals)
  local _force='[[:space:]](-[A-Za-z]*f[A-Za-z]*|--force)[[:space:]]'
  local _cached='[[:space:]]--cached([[:space:]]|=)'
  local _dryrun='[[:space:]](-[A-Za-z]*n[A-Za-z]*|--dry-run)[[:space:]]'
  local _dot='[[:space:]][.][[:space:]]'
  local _staged='[[:space:]]--staged([[:space:]]|=)'
  local _worktree='[[:space:]]--worktree([[:space:]]|=)'

  # Raw git commit — bypasses lint, local-file protection, conventional commit enforcement
  if [[ ${padded} =~ git[[:space:]]+commit[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git commit' \
      'Use ./scripts/git/commit_enhanced.sh "<type>: <msg>" instead — it runs lint, protects local-only files, and enforces conventional commit format.'
    return 1
  fi

  # --no-verify — bypasses pre-commit and pre-push hooks entirely
  if [[ ${padded} =~ [[:space:]]--no-verify([[:space:]]|=) ]]; then
    _cgw_guardrail_verdict '--no-verify' \
      'CGW pre-commit/pre-push hooks cannot be bypassed with --no-verify. Fix the underlying issue (run ./scripts/git/fix_lint.sh for lint errors, or inspect the hook output).'
    return 1
  fi

  # Force-push without lease — overwrites others' work and bypasses protection.
  # --force-with-lease is explicitly allowed (it is what push_validated.sh uses):
  # a '-' follows "--force" in that flag, so the trailing [[:space:]] never matches.
  if [[ ${padded} =~ git[[:space:]]+push[[:space:]] ]] && [[ ${padded} =~ ${_force} ]]; then
    _cgw_guardrail_verdict 'git push --force' \
      'Use ./scripts/git/push_validated.sh instead — it uses --force-with-lease and requires confirmation on protected branches. Note: --force-with-lease is allowed.'
    return 1
  fi

  # Hard reset — irreversibly discards uncommitted work and index changes
  if [[ ${padded} =~ git[[:space:]]+reset[[:space:]] ]] && [[ ${padded} =~ [[:space:]]--hard([[:space:]]|=) ]]; then
    _cgw_guardrail_verdict 'git reset --hard' \
      'Confirm with the user before running git reset --hard. This irreversibly discards uncommitted work and index changes.'
    return 1
  fi

  # git clean -f — permanently deletes untracked files (covers -f, -fd, -df, -fdx, ...).
  # A dry-run flag (-n / --dry-run) only previews the deletion, so it is exempt.
  if [[ ${padded} =~ git[[:space:]]+clean[[:space:]] ]] &&
    [[ ${padded} =~ ${_force} ]] &&
    ! [[ ${padded} =~ ${_dryrun} ]]; then
    _cgw_guardrail_verdict 'git clean -f' \
      'Confirm with the user before running git clean. This permanently deletes untracked files from the working tree.'
    return 1
  fi

  # git rm with a force flag deletes files from the WORKING TREE. git itself refuses
  # `git rm` on modified/added files ("use -f to force"); -f overrides that and can
  # UNRECOVERABLY delete git-ignored / untracked-turned-added files (e.g. local-only
  # artifacts staged by `git cherry-pick -n`). --cached is index-only (keeps the file
  # on disk — the documented untrack workflow), so a --cached in the SAME invocation
  # is always allowed.
  if [[ ${padded} =~ git[[:space:]]+rm[[:space:]] ]] &&
    ! [[ ${padded} =~ ${_cached} ]] &&
    [[ ${padded} =~ ${_force} ]]; then
    _cgw_guardrail_verdict 'git rm -f' \
      'git rm -f deletes files from the working tree — for git-ignored or untracked files this is UNRECOVERABLE. To untrack a file while keeping it on disk, use git rm --cached <path>. To force-delete a tracked file, confirm with the user first.'
    return 1
  fi

  # Force-delete branch — may lose commits on an unmerged branch (-D, not -d)
  if [[ ${padded} =~ git[[:space:]]+branch[[:space:]] ]] &&
    [[ ${padded} =~ [[:space:]]-[A-Za-z]*D[A-Za-z]*[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git branch -D' \
      'Use ./scripts/git/branch_cleanup.sh --execute to prune merged branches, or confirm with the user before force-deleting an unmerged branch.'
    return 1
  fi

  # Raw worktree removal — on Windows, git's recursive delete follows the NTFS
  # junctions that older `worktree_manage.sh link` runs created, and empties the
  # MAIN worktree's gitignored scripts/git and .githooks (unrecoverable from git).
  # Fail closed on git's global options (-C <path>, -C<path>, -c k=v, --exec-path
  # <dir>, escaped spaces, ...): if the first token after `git` is an option,
  # anything may sit between it and `worktree remove`. If it is a plain word
  # (a subcommand), only a direct `worktree remove` matches, so
  # `git grep worktree remove` is not blocked. Quoted arguments are already
  # dequoted by now (`-C "/my repo"` becomes `-C /my<US>repo`, one token).
  if [[ ${padded} =~ git[[:space:]]+(-[^[:space:]]*[[:space:]]+(.*[[:space:]])?)?worktree[[:space:]]+remove[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git worktree remove' \
      'Use ./scripts/git/worktree_manage.sh remove --execute <path> instead — it unlinks CGW tooling first. A raw remove can follow a legacy junction and delete the main checkout'"'"'s scripts/git and .githooks.'
    return 1
  fi

  # Discard all working-tree changes (. = current directory = everything)
  if [[ ${padded} =~ git[[:space:]]+checkout[[:space:]] ]] && [[ ${padded} =~ ${_dot} ]]; then
    _cgw_guardrail_verdict 'git checkout .' \
      'Confirm with the user — git checkout . irreversibly discards all working-tree changes.'
    return 1
  fi

  if [[ ${padded} =~ git[[:space:]]+restore[[:space:]] ]] && [[ ${padded} =~ ${_dot} ]]; then
    # --staged alone only touches the index (reversible with `git reset`) — exempt.
    # --staged combined with --worktree (or --worktree/default alone) discards
    # working-tree changes and stays blocked.
    if ! { [[ ${padded} =~ ${_staged} ]] && ! [[ ${padded} =~ ${_worktree} ]]; }; then
      _cgw_guardrail_verdict 'git restore .' \
        'Confirm with the user — git restore . irreversibly discards all working-tree changes.'
      return 1
    fi
  fi

  # History rewrites — permanently alter commit history; extremely destructive
  if [[ ${padded} =~ git[[:space:]]+filter-branch[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git filter-branch' \
      'Destructive history rewrite — confirm with the user before proceeding.'
    return 1
  fi

  if [[ ${padded} =~ git[[:space:]]+filter-repo[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git filter-repo' \
      'Destructive history rewrite — confirm with the user before proceeding.'
    return 1
  fi

  # Recovery ref destruction — eliminates the ability to recover lost commits
  if [[ ${padded} =~ git[[:space:]]+reflog[[:space:]]+expire[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git reflog expire' \
      'This destroys reflog recovery references — confirm with the user.'
    return 1
  fi

  if [[ ${padded} =~ git[[:space:]]+gc[[:space:]] ]] && [[ ${padded} =~ [[:space:]]--prune=now[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git gc --prune=now' \
      'This destroys unreachable objects needed for recovery — confirm with the user.'
    return 1
  fi

  if [[ ${padded} =~ git[[:space:]]+update-ref[[:space:]] ]] &&
    [[ ${padded} =~ [[:space:]]-[A-Za-z]*d[A-Za-z]*[[:space:]] ]]; then
    _cgw_guardrail_verdict 'git update-ref -d' \
      'Destructive ref operation — confirm with the user.'
    return 1
  fi

  # .git directory destruction
  # Catches: rm -rf .git  rm -r -f .git  rm -rf .git/  rm -rf /path/to/.git
  # Allows:  rm -rf .gitignore  rm -rf .github  (character after .git is alphanumeric)
  if [[ ${padded} =~ [[:space:]]rm[[:space:]] ]] &&
    [[ ${padded} =~ [[:space:]]-[A-Za-z]*r[A-Za-z]*[[:space:]] ]] &&
    [[ ${padded} =~ ${_force} ]] &&
    [[ ${padded} =~ [.]git(/|[[:space:]]) ]]; then
    _cgw_guardrail_verdict 'rm -rf .git' \
      'This would destroy the git repository — confirm with the user first.'
    return 1
  fi
}
