# Refresh outdated stock hooks, keep customised ones

**Status**: accepted (refines the preserve-everything rule introduced in 64bd62d)

## Context

Updates used to overwrite `.githooks/*` unconditionally, which wiped project-specific additions such
as a local test gate. 64bd62d fixed that by keeping **any** hook that differs from the template. The
side effect is that a hook which differs only because it is an *old copy of the stock hook* is kept
too. Every consumer project then froze on the hooks it was first installed with and missed later
fixes, while `cgw-batch-install.cmd` reported `[OK] Updated`: `configure.sh` did print a warning, but
the batch redirected its output to a log it deleted on success. Scripts under `scripts/git/` are
always overwritten, so projects silently ran new scripts under old hooks.

## Decision

- `configure.sh` classifies a differing hook before deciding. If its content, with `\r` stripped, is a
  blob that `hooks/<name>` has held in the template source's git history, it is an **outdated stock
  hook** and is replaced in place. Otherwise it is **customised** and kept with a warning (today's
  behaviour); `--overwrite-hooks` replaces it and keeps a `.bak`.
- When the template source is not a git checkout, nothing can be proven stock, so the hook is treated
  as customised.
- The rule lives in `_install_single_hook`, so batch, `cgw-install.cmd`, interactive runs and
  `--hooks-only` all behave the same. Interactive runs only prompt for customised hooks.
- A refresh writes no `.bak`: the old version is recoverable from CGW git and the output names the
  commit. `cgw-batch-install.cmd` no longer pre-copies hooks to `.bak` either — that copy kept only
  the first version ever seen, so it went stale.
- `cgw-batch-install.cmd` surfaces `configure.sh` warnings per project and in its summary, exit code
  unchanged.

## Considered and rejected

- **Always overwrite.** Simple, but it discards customisations that predate the `.local` extension
  point; a `.bak` makes that recoverable, not safe.
- **Shipped manifest of stock hashes.** Works without git, but is one more file that must be
  regenerated on every hook change and can drift from the real history.
- **Version stamp inside each hook.** Already-deployed hooks carry no stamp, and detecting an edit to
  a stamped hook needs the hash comparison anyway.
- **Keep preserving, only fix the warning.** Leaves the drift in place until someone remembers to
  pass `--overwrite-hooks`.

## Consequences

Projects pick up hook fixes on the next update with no flag. A hook that someone hand-edited stays put
and is called out on every run until it is moved to `.githooks/<hook>.local` or replaced on purpose. A
customised hook that was *itself* an edit of a stock version is indistinguishable from any other
custom hook, so it is kept.
