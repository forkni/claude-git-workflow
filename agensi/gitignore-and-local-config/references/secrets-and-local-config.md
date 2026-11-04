# Secrets and Local Config

How to keep credentials and machine-specific settings out of git, and what `.gitignore` does and
does not protect.

## The pattern

- Keep real values in a **gitignored** config file (`.env`, `config.local.json`) and commit only
  a `*.sample` / `*.example` copy with placeholder values (`API_KEY="changeme"`). New clones copy
  the sample and fill it in.
- Never hardcode a key, token or password in a tracked script. Read it from the environment or the
  gitignored config file at run time.
- A secret that was **ever committed or pushed** must be **rotated** at its source. Deleting it
  from the file, or rewriting history, does not undo the exposure; a later commit only hides it
  from the current tree.

## What each mechanism protects

| Mechanism | Protects | Does not |
|---|---|---|
| `.gitignore` | Keeps untracked files out of `git status` and out of `git add` | Untrack a file that is already tracked, or stop `git add -f` |
| A pre-commit check (hook or commit wrapper) | Refuses commits that stage named paths | Scan file **contents** unless it runs a secret scanner |
| A secret scanner (for example gitleaks or trufflehog, run in a hook or CI) | Flags key-shaped strings in staged content | Catch secrets in an unrecognised format |

Use `.gitignore` for prevention, a commit-time check for paths that must never be committed even
by accident, and a scanner for content.

## Checklist for a new config file

```bash
git check-ignore -v .env     # prints the matching rule when the file is ignored
git ls-files -- .env         # prints nothing when the file is not tracked
```

1. Add the real file to `.gitignore`.
2. Commit `.env.example` with placeholders only, and confirm it is not left untracked.
3. If `git ls-files` shows the real file is already tracked, follow "The Already-Tracked Trap" in
   [gitignore-templates.md](gitignore-templates.md#the-already-tracked-trap-and-the-fix). If it
   holds a real secret and was ever pushed, rotate the secret first.
