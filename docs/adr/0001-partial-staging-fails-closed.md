# Partial staging fails closed instead of being silently collapsed or validated by materializing the index

**Status**: accepted

## Context

`commit_enhanced.sh`'s lint/format/markdownlint checks read files from the **working tree**, but
`git commit` records the **index**. Ordinarily these are the same content. They diverge on
purpose when a user (or a concurrent process) runs `git add --patch` to stage one hunk of a file
and deliberately leaves another hunk unstaged — a **partial stage** (see `CONTEXT.md`).

Before this decision, `commit_enhanced.sh`'s post-auto-fix re-stage (`git add -f -- "${f}"` over
every originally-staged path) did not distinguish a partial stage from an ordinary fully-staged
file. Any staged file swept up by an auto-fix re-stage — even one whose divergence was a
deliberate partial `git add -p`, not the fixer's own edit — got promoted whole into the index,
silently absorbing the unstaged hunk into the commit. This fired against a real incident: a
concurrent Claude Code session's deliberately-unstaged comment-only hunks in a shared file were
absorbed into an unrelated commit because that commit's lint auto-fix pass re-staged the whole
file.

## Decision

CGW never silently re-stages a partial stage, and never silently commits one either. The rule
(implemented across `_restage_after_fix` and the `[3.5]` congruence guard in
`commit_enhanced.sh`):

- A per-file predicate measured **at snapshot time** (`cgw_staged_paths_diverging_from_index`)
  marks which originally-staged files are already partially staged. The post-auto-fix re-stage
  skips those paths outright — it only ever replays files that were congruent (index ==
  working tree) when the snapshot was taken.
- After both auto-fix blocks run, the `[3.5]` guard checks the **validated path set** (staged
  lint-eligible files when a code checker is actually configured, plus staged `*.md` when
  markdownlint genuinely ran — not skipped via `--skip-md-lint`/`CGW_SKIP_MD_LINT`, and
  `CGW_MARKDOWNLINT_CMD` set) for any remaining divergence.
  In a whole-file-staging-intent mode (bulk/`--all`, or `--only <paths>`) it re-stages and
  re-verifies. In a genuine staged-only commit it fails the commit closed instead, with guidance
  that leads with the non-destructive options: `CGW_ALLOW_STAGED_DIVERGENCE=1` to commit the
  staged blob as-is, or `--skip-lint` to bypass validation — both ahead of `git add <file>`,
  which discards the user's hunk selection.

Fail-closed was chosen deliberately over the alternative of quietly ignoring lint-eligible files
with unstaged divergence: CGW's entire purpose is a code-quality gate before commit, so ignoring a
staged-but-unvalidated blob would just move the "commits something CGW never checked" problem from
one silent failure mode to another.

## Considered and rejected: lint the materialized index blob

The principled alternative is to validate exactly what will be committed: materialize each staged
blob to a temp location (`git show :<path>`) and run lint/format/markdownlint against that,
instead of against the working tree. This closes the working-tree-vs-index gap entirely — there
would be nothing left to diverge.

Rejected because auto-fix cannot round-trip through it. `cgw_run_lint_fix` / markdownlint's
`--fix` rewrite files **on disk**; there is no `git apply`-style path to take a fixer's rewrite of
a materialized temp copy and turn it back into a hunk-level update of the index without
essentially reimplementing `git add --patch` from a diff. A working-tree-first design lets the
fixer do what it already does (rewrite disk) and lets CGW re-stage the result when that's known to
be safe (whole-file staging intent) — the materialized-index approach would need a second,
much larger mechanism just to get auto-fix working again, for a case (deliberate partial staging
during a commit that also needs auto-fix) that is comparatively rare.

## Consequences

- The guard's scope is exactly the **validated path set** — a partially-staged file CGW never
  validates (e.g. a `.json` file with no configured linter) is invisible to `[3.5]` by design; only
  `cgw_staged_paths_diverging_from_index`'s wider up-front snapshot protects it from the
  auto-fix re-stage.
- `CGW_ALLOW_STAGED_DIVERGENCE=1` remains the one supported way to commit a staged blob CGW
  validated something different from — an explicit, logged opt-out rather than a default.
- `--skip-md-lint` (and, symmetrically, an unconfigured code checker — both `CGW_LINT_CMD` and
  `CGW_FORMAT_CMD` empty) removes that file class from the guard's scope for the run, the same
  treatment already granted to a `.json` file with no configured linter above: a check that never
  ran cannot have a divergence opinion, so a partial stage of that file class commits exactly the
  staged hunk instead of false-aborting.
