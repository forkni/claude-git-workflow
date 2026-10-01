# Protected branches sync fast-forward only

**Status**: accepted

## Context

`sync_branches.sh` used `git pull --rebase` for every branch. On a `--no-ff` workflow the target
branch (`main`) carries local merge commits; `--rebase` without `--rebase-merges` flattens them,
linearising history and rewriting commits that other clones or a pending push may already depend on.
Nothing warned the operator.

## Decision

- Branches matching the `push` protection policy (`CGW_PROTECTED_BRANCHES`, default: the target
  branch) are pulled with `--ff-only`. If the branch has diverged, sync exits 1, prints the
  reconcile options (push the local commits first, `git pull --no-rebase`, or reset to the remote
  after a backup tag) and changes nothing.
- All other branches are pulled with `--rebase=merges`, which replays local merge commits instead of
  flattening them.

## Considered and rejected

- **`--rebase=merges` everywhere.** Preserves merges but still rewrites commits on `main`, which
  should only ever move forward; a failed or surprising rebase there is costly.
- **`--no-rebase` (merge) everywhere.** Adds noisy "Merge branch 'main' of origin" commits to
  feature branches whose history is meant to stay linear.
- **Auto-reconcile on divergence.** Divergence on a protected branch means someone committed to it
  outside the PR flow; resolving it is a human decision, not something a sync should guess.

## Consequences

A diverged `main` now stops the sync with exit 1 instead of silently succeeding. This is deliberate
and hard to walk back once agents rely on the stop; the trade-off is one extra manual step in a case
that indicates a workflow violation.
