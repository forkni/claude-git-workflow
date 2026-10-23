#!/usr/bin/env bash
# _lib_remote.sh - Remote and network helpers for claude-git-workflow scripts
# Usage: sourced automatically by _common.sh -- do not source directly
#
# Functions:
#   cgw_rev_count()             - Commits reachable from <tip> but not <base>
#   cgw_net_git()               - Network git call with CGW_NET_TIMEOUT (GNU timeout)
#   cgw_remote_reachable()      - Probe a remote with git ls-remote
#   cgw_remote_branch_exists()  - Check a branch on a remote
#   cgw_remote_owner_repo()     - Echo owner/repo for a remote URL
#   cgw_default_branch()        - Echo the repo's default branch
#   cgw_require_gh()            - Verify the gh CLI is installed and authenticated
#   cgw_pr_view()               - Echo one field of a PR via gh pr view --jq
#
# Uses err() and the CGW_* settings from _common.sh / _config.sh at call time.

# cgw_rev_count <base> <tip>
# Outputs the number of commits reachable from <tip> but not from <base>.
# Accepts any git ref (branch names, remote-tracking refs, SHAs).
# Exits non-zero on git failure; callers own their fallback (e.g. || echo "0").
cgw_rev_count() {
  git rev-list --count "${1}..${2}" 2>/dev/null
}

# _cgw_gnu_timeout_available
# Exits 0 when the `timeout` on PATH is GNU coreutils' (probed once per resolved
# path and cached). Windows ships C:\Windows\System32\timeout.exe -- a sleep
# command, not a wrapper -- that can shadow it, so a bare `command -v timeout`
# is not enough: GNU's answers `--version` with "(GNU coreutils)", the Windows
# one rejects the flag.
_CGW_TIMEOUT_PROBED_PATH=""
_CGW_TIMEOUT_IS_GNU=0
_cgw_gnu_timeout_available() {
  local tpath
  tpath="$(command -v timeout 2>/dev/null)" || return 1
  if [[ "${tpath}" != "${_CGW_TIMEOUT_PROBED_PATH}" ]]; then
    local banner
    banner="$(timeout --version 2>/dev/null | head -n 1)" || banner=""
    _CGW_TIMEOUT_PROBED_PATH="${tpath}"
    if [[ "${banner}" == *"GNU coreutils"* ]]; then _CGW_TIMEOUT_IS_GNU=1; else _CGW_TIMEOUT_IS_GNU=0; fi
  fi
  [[ "${_CGW_TIMEOUT_IS_GNU}" == "1" ]]
}

# cgw_net_git <git args...>
# Drop-in for `git` on commands that talk to a remote (fetch, push, pull,
# ls-remote, remote prune): runs git under `timeout ${CGW_NET_TIMEOUT}s` so an
# unreachable or hung remote cannot block a script forever. stdin, stdout,
# stderr and git's exit code pass through unchanged, except that a timeout
# returns 124 (GNU timeout's code) after printing an [ERROR] naming the
# operation, the limit and the knob.
#   CGW_NET_TIMEOUT=0           plain git, no limit
#   no GNU `timeout` on PATH    plain git (see _cgw_gnu_timeout_available)
#   CGW_NON_INTERACTIVE=1       also sets GIT_TERMINAL_PROMPT=0 (unless already set),
#                               so a credential prompt fails fast instead of waiting
#                               for input that never comes. Interactive runs keep
#                               their prompts, and `timeout --foreground` keeps git
#                               attached to the terminal so those prompts still work.
cgw_net_git() {
  local limit="${CGW_NET_TIMEOUT:-120}"
  [[ "${limit}" =~ ^[0-9]+$ ]] || limit=120
  local -a wrap=()
  if ((limit > 0)) && _cgw_gnu_timeout_available; then
    wrap=(timeout)
    [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] || wrap+=(--foreground)
    wrap+=("${limit}s")
  fi

  local rc
  if [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]]; then
    GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}" ${wrap[@]+"${wrap[@]}"} git "$@"
  else
    ${wrap[@]+"${wrap[@]}"} git "$@"
  fi
  rc=$?
  if ((rc == 124)) && ((${#wrap[@]} > 0)); then
    local op="${1:-command}"
    [[ "${op}" == "remote" && -n "${2:-}" ]] && op="remote ${2}"
    _cgw_net_timeout_err "${op}" "${limit}"
    return 124
  fi
  return "${rc}"
}

# _cgw_net_timeout_err <git subcommand> <seconds>
_cgw_net_timeout_err() {
  err "git ${1} timed out after ${2}s (remote unreachable or hung). Raise the limit, or set 0 to disable it: CGW_NET_TIMEOUT=<seconds>"
}

# cgw_remote_reachable <remote>
# Exits 0 when <remote> is reachable, non-zero otherwise (124 = timed out). Silent
# apart from the one-line timeout error.
# Uses git ls-remote with no ref pattern — exits non-zero on any connection failure.
cgw_remote_reachable() {
  local rc=0
  # Output is discarded here, so cgw_net_git's timeout error is re-issued below.
  cgw_net_git ls-remote "${1}" >/dev/null 2>&1 || rc=$?
  if ((rc == 124)); then _cgw_net_timeout_err ls-remote "${CGW_NET_TIMEOUT:-120}"; fi
  return "${rc}"
}

# cgw_remote_branch_exists <remote> <branch>
# Exits 0 when <branch> exists on <remote>, non-zero otherwise. Silent apart from
# the one-line timeout error (exit 124).
# Accepts a plain branch name; builds refs/heads/ internally.
#
# Contract: the exit code is git ls-remote's raw exit code, unmodified --
# 0 = exists, 2 = genuinely absent, anything else (128 = unreachable/auth
# failure, 124 = timed out, etc.) = the probe itself failed and must NOT be
# read as absent.
# `if cgw_remote_branch_exists ...` callers that only branch on zero/non-zero
# are fine either way; a caller that needs to tell "absent" apart from "probe
# failed" (e.g. before weakening a force-push guard) must capture "$?" itself
# rather than treating this as a plain boolean.
cgw_remote_branch_exists() {
  local rc=0
  cgw_net_git ls-remote --exit-code "${1}" "refs/heads/${2}" >/dev/null 2>&1 || rc=$?
  if ((rc == 124)); then _cgw_net_timeout_err ls-remote "${CGW_NET_TIMEOUT:-120}"; fi
  return "${rc}"
}

# cgw_remote_owner_repo <remote>
# Echoes "<owner>/<repo>" parsed from <remote>'s configured URL, for github.com
# SSH/HTTPS remotes only. Returns 1 and prints nothing if <remote> is unset or
# its URL isn't a recognizable github.com URL.
#
# Reads remote.<remote>.pushurl first, falling back to remote.<remote>.url
# when pushurl is unset -- a remote with a separate fetch/push URL (e.g.
# fetch=upstream, push=fork) is actually targeted, on push, at pushurl, so
# that is the identity that must drive gh's --repo. Reads the RAW config
# value (`git config --get`), not `git remote get-url` -- the latter expands
# any `url.<base>.insteadOf` rewrite and would report the rewritten transport
# (e.g. a corporate mirror or, in tests, a local bare repo) instead of the
# remote's real GitHub identity. Used by create_pr.sh to pass gh CLI an
# explicit `--repo`: without it, `gh pr create` resolves the target repo
# itself and -- when the remote is a fork -- defaults to the fork's
# parent/upstream repo, silently opening (or failing to open) the PR against
# the wrong repository.
#
# Accepts github.com, www.github.com, and ssh.github.com (SSH-over-443) as
# hosts, matched case-insensitively. Parses by decomposing the URL into
# (scheme, host, path) rather than matching whole-URL shapes with per-form
# regexes -- the latter is what silently mis-parsed a port as the owner
# (ssh://...:22/owner/repo) and left a trailing ".git" in place
# (.../repo.git/, where the "/" strip ran before the ".git" strip). Any
# unparseable or non-github.com URL returns 1 with nothing echoed; callers
# that need an explicit --repo (create_pr.sh) treat that as fatal.
cgw_remote_owner_repo() {
  local remote="$1"
  local url
  url=$(git config --get "remote.${remote}.pushurl" 2>/dev/null) || url=""
  if [[ -z "${url}" ]]; then
    url=$(git config --get "remote.${remote}.url" 2>/dev/null) || return 1
  fi
  [[ -z "${url}" ]] && return 1

  local scheme host path owner repo
  if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/@]+@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
    # scheme://[userinfo@]host[:port]/path -- userinfo captured only to
    # discard it (may carry a CI token; never echoed, never logged).
    scheme=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    case "${scheme}" in ssh | https | http | git) ;; *) return 1 ;; esac
    host="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[5]}"
  elif [[ "${url}" =~ ^([^/@]+@)?([^/:]+):(.+)$ ]]; then
    # scp-like [user@]host:path -- ':' is the path separator here, so no port
    # can appear in this form. Conflating scp-like ':' with a URL port
    # separator is what made ssh://...:22/owner/repo parse "22" as the owner.
    # A Windows path (C:/...) also lands here and is rejected by the host
    # check below.
    host="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  host=$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')
  case "${host}" in
    github.com | www.github.com | ssh.github.com) ;;
    *) return 1 ;;
  esac

  path="${path#/}"
  while [[ "${path}" == */ ]]; do path="${path%/}"; done
  # Strip ".git" AFTER trailing slashes, not before -- "repo.git/" does not
  # end in literal ".git", so the opposite order leaves ".git" in the result.
  path="${path%.git}"
  while [[ "${path}" == */ ]]; do path="${path%/}"; done

  owner="${path%%/*}"
  repo="${path#*/}"
  [[ "${owner}" == "${path}" ]] && return 1 # no '/' at all
  [[ -z "${owner}" ]] || [[ -z "${repo}" ]] && return 1
  [[ "${repo}" == */* ]] && return 1 # 3+ path segments is not a repo URL
  # This value is handed straight to `gh --repo`: constrain to GitHub's real
  # owner/repo charset and reject a leading '-' so it can never be read as a
  # flag by a downstream command line.
  [[ "${owner}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "${repo}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "${owner}" == -* ]] || [[ "${repo}" == -* ]] && return 1
  echo "${owner}/${repo}"
}

# cgw_default_branch [--refresh]
# Echoes the repository's default branch name (no remote prefix).
# Resolution order:
#   1. ${CGW_REMOTE}/HEAD symbolic ref (set by `git clone`, or `git remote set-head`)
#   2. CGW_TARGET_BRANCH (config default, e.g. "main") -- used when origin/HEAD is
#      unset, which is common for repos created via `remote add` + `push` rather
#      than `git clone` (origin/HEAD is only auto-populated by a clone).
# Pass --refresh to attempt `git remote set-head ${CGW_REMOTE} --auto` first
# (requires network access to CGW_REMOTE; failure is silently ignored so this
# stays usable offline). Returns 0 always.
cgw_default_branch() {
  if [[ "${1:-}" == "--refresh" ]]; then
    git remote set-head "${CGW_REMOTE}" --auto >/dev/null 2>&1 || true
  fi
  local ref
  ref="$(git symbolic-ref --quiet --short "refs/remotes/${CGW_REMOTE}/HEAD" 2>/dev/null)"
  if [[ -n "${ref}" ]]; then
    echo "${ref#"${CGW_REMOTE}"/}"
  else
    echo "${CGW_TARGET_BRANCH}"
  fi
}

# cgw_require_gh
# Verifies the gh CLI is installed and authenticated.
# Prints an [ERROR] line via err() and returns 1 on either failure.
# Silent, returns 0, on success. Callers own any section logging around it
# (see create_pr.sh, pr_checkout.sh).
cgw_require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    err "gh CLI not found. Install from https://cli.github.com/"
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    err "gh CLI not authenticated. Run: gh auth login"
    return 1
  fi
  return 0
}

# cgw_pr_view <owner/repo> <number> <json-field> <jq-expr>
# Echoes one field of a PR via gh's built-in --jq (no external jq needed), with
# CRs stripped (gh on Windows can emit CRLF). gh's exit status reaches the caller
# through pipefail; callers fall back on an empty value.
cgw_pr_view() {
  gh pr view "${2}" --repo "${1}" --json "${3}" --jq "${4}" 2>/dev/null | tr -d '\r'
}
