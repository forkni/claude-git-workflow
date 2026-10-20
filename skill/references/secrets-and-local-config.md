# Secrets and Local Config

How to keep credentials and machine-specific settings out of git, and what CGW
does and does not enforce. For a secret that is **already committed**, go to
[removing-sensitive-data.md](removing-sensitive-data.md) instead.

## The pattern

- Keep real values in a **gitignored** config file (`.env`, `config.local.json`,
  `.cgw.conf`) and commit only a `*.sample` / `*.example` copy with placeholder
  values (`API_KEY="changeme"`). New clones copy the sample and fill it in.
- Never hardcode a key, token or password in a tracked script. Read it from the
  environment or the gitignored config file at run time.
- A secret that was **ever committed or pushed** must be **rotated** at its
  source. Deleting it from the file, or rewriting history, does not undo the
  exposure; a later commit only hides it from the current tree.

## What CGW protects

| Mechanism | Protects | Does not |
|---|---|---|
| `CGW_LOCAL_FILES` | Blocks commits and pushes of the named files or dirs (`commit_enhanced.sh` unstages them; hooks refuse them) | Scan file **contents**: a key pasted into a tracked file passes |
| `.gitignore` | Keeps untracked files out of `git status` and out of `git add` | Untrack a file that is already tracked (see removing-sensitive-data.md) |
| Untracked warning | `commit_enhanced.sh` prints `[WARN] N untracked file(s) are NOT included` for files the commit left out | Block anything: it is advisory |

Make the warning a gate with `--strict-untracked` (or `CGW_STRICT_UNTRACKED=1`):
the commit is refused, before anything is committed, until each listed file is
`git add`ed, ignored via `.gitignore`, or added to `CGW_LOCAL_FILES`. Silence it
for one run with `--no-untracked-check` (`CGW_UNTRACKED_CHECK=0`). Files matching
`CGW_LOCAL_FILES` are never listed.

## Checklist for a new config file

```bash
git check-ignore -v .env     # prints the matching rule when the file is ignored
git ls-files -- .env         # prints nothing when the file is not tracked
```

1. Add the real file to `.gitignore` (and to `CGW_LOCAL_FILES` for a push guard).
2. Commit `.env.example` with placeholders only; confirm it is not left untracked.
