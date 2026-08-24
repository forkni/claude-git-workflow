# .gitignore Templates

## Contents

- How to Compose a .gitignore
- Pattern Syntax and Precedence
- The Four Ignore Layers
- The CGW Baseline Block
- Stack Templates (Python, Node/TypeScript, Rust, Go, C/C++, CUDA)
- Global Templates (OS, Editor, Tool)
- Debugging: Why Is This Path (Not) Ignored?
- The Already-Tracked Trap (and the CGW-Correct Fix)
- Upstream Catalog Index

Templates below are trimmed excerpts from [github/gitignore](https://github.com/github/gitignore)
(`57286c3`, 2026-07-23), licensed [CC0-1.0](https://github.com/github/gitignore/blob/main/LICENSE) —
public domain, no attribution required. 312 upstream templates exist; this doc inlines the subset
relevant to CGW projects (Python, Node, Rust, Go, C/C++, CUDA, plus the OS/editor/tool `Global/`
templates) and indexes the rest. Where a template was trimmed, a "full version upstream" link
points at the complete file.

---

## How to Compose a .gitignore

Upstream curates its templates in three tiers, and the tier tells you where a rule belongs:

- **Root templates** (`Python.gitignore`, `Node.gitignore`, …) — "a meaningful set of rules to
  help get started" for a language or framework. One of these is the base of almost every
  project's `.gitignore`.
- **`Global/` templates** (`Windows.gitignore`, `JetBrains.gitignore`, …) — editor, OS, and tool
  noise that has nothing to do with the project itself. Upstream's own recommendation: put these
  in your **personal global excludes file** (`core.excludesFile`, see below), not in the repo's
  `.gitignore` — a `.DS_Store` rule is about your machine, not the project.
- **`community/` templates** — specialized, adopt only once you actually use that framework/tool.

**The pragmatic composition rule:** one stack template (or a small merge of a few, e.g. C + C++)
as the base of the repo's `.gitignore`, plus the [CGW baseline block](#the-cgw-baseline-block).
Keep OS/editor rules out of the repo file and in `core.excludesFile` instead — with one exception:
a team that won't reliably configure a global excludes file (mixed OS, CI runners, contractors)
is better served by committing the relevant `Global/*` rules directly. Upstream's own
`CONTRIBUTING.md` is strict about *where* an OS rule lives even then: `.DS_Store` belongs only in
`Global/macOS.gitignore` content, never duplicated into a language template.

---

## Pattern Syntax and Precedence

- Blank lines and lines starting with `#` are ignored. A literal leading `#` or `!` is escaped
  with a backslash: `\#not-a-comment`, `\!not-negation`.
- A pattern **without** a slash (e.g. `*.log`) matches at any depth. A pattern **containing** a
  slash anywhere but the end (e.g. `/build`, `docs/_build/`) is anchored to the directory of the
  `.gitignore` file that defines it.
- A trailing `/` matches directories only (`build/` won't match a file named `build`).
- `*` matches anything except `/`. `**/` matches zero or more directories (`**/logs` matches
  `logs` anywhere). A trailing `/**` matches everything inside a directory (`assets/**`).
- `[Dd]esktop.ini` — bracket character classes make a rule case-insensitive per-character; this
  is the idiom `Global/Windows.gitignore` and `Global/macOS.gitignore` use for `desktop.ini`.
- A trailing space in a pattern is stripped unless escaped with a trailing backslash-space.
- **Last matching pattern wins.** A later line can override an earlier one, in either direction.
- A `.gitignore` in a subdirectory only adds rules for that subtree — it cannot override a
  broader ignore rule set by a parent directory's `.gitignore` (see the negation trap below for
  why that specifically fails).

### The negation trap

**You cannot re-include a file if one of its parent directories is already excluded.** Git never
descends into an excluded directory to evaluate deeper rules, so a `!` line inside it is silently
a no-op. This is the single most common way a hand-edited `.gitignore` breaks.

Broken — `.vscode/` excludes the whole directory, so git never looks inside it and the `!` line
below has no effect:

```gitignore
.vscode/
!.vscode/settings.json
```

Working — `.vscode/*` excludes the directory's *contents* one level at a time (the directory
itself stays traversable), so the negation can reach in and re-include a specific file. This is
the real idiom from `Global/VisualStudioCode.gitignore`:

```gitignore
.vscode/*
!.vscode/settings.json
!.vscode/tasks.json
!.vscode/launch.json
!.vscode/extensions.json
```

Two more real examples of the same working pattern — `Node.gitignore`'s yarn v3 block:

```gitignore
.yarn/*
!.yarn/patches
!.yarn/plugins
!.yarn/releases
!.yarn/sdks
!.yarn/versions
```

and `Python.gitignore`'s pixi block:

```gitignore
.pixi/*
!.pixi/config.toml
```

---

## The Four Ignore Layers

| Layer | Location | Committed? | Use for |
|---|---|:-:|---|
| Repo `.gitignore` | `<repo>/.gitignore` (or any subdirectory) | Yes | Build artifacts and stack noise every contributor hits |
| Per-clone excludes | `.git/info/exclude` | No — never leaves your clone | A one-off scratch file you don't want to share a rule for |
| Global excludes | `core.excludesFile` (`git config --global core.excludesFile ~/.gitignore_global`) | No — per-user | Editor/OS junk (every `Global/*` template belongs here) |
| `CGW_LOCAL_FILES` (`.cgw.conf`) | n/a — not a `.gitignore` mechanism | n/a | Commit-scoped protection, see below |

`CGW_LOCAL_FILES` is not an ignore layer — it doesn't touch git's ignore machinery at all. It is
enforced by `cgw_is_local_file` in `_common.sh` and checked by `commit_enhanced.sh` plus the
pre-commit/pre-push hooks, which unstage any configured path before a commit lands. The two
mechanisms are complementary, not redundant:

- `.gitignore` stops an **untracked** path from being added in the first place (`git add .`
  silently skips it).
- `CGW_LOCAL_FILES` stops a path that is **staged or already tracked** from being committed —
  it fires even if the path was force-added (`git add -f`) or was tracked before it was ever
  configured as local-only.

Put a path in both when it should never be committed under any circumstance (CGW's own defaults
— `CLAUDE.md`, `MEMORY.md`, `.claude/`, `logs/` — do exactly this).

---

## The CGW Baseline Block

`configure.sh` appends three entries automatically, but **only on a fresh install** (`_update_gitignore`, not run on `--reconfigure`):

```gitignore
logs/
.cgw.conf
.cgw.conf.bak
```

The `CGW_LOCAL_FILES` defaults (`CLAUDE.md`, `MEMORY.md`, `.claude/`) are deliberately **not**
auto-appended to `.gitignore` — they're often team-shared (hence `CGW_LOCAL_FILES_EXEMPT` for
carve-outs like `.claude/settings.json`), so CGW protects them at commit time instead of hiding
them from `git add`. Add them to `.gitignore` too only if this specific project wants them
invisible to `git status` as well as uncommittable.

Two interactions worth knowing before you add lines here:

- `Global/Backup.gitignore`'s `*.bak` pattern already covers `.cgw.conf.bak` — no need to
  duplicate it if you pull in that Global template.
- **Don't add a bare `tests/` line casually.** `merge_with_validation.sh` greps
  `^tests/$` in `.gitignore` and, when `CGW_CLEANUP_TESTS=1`, treats that as permission to
  strip `tests/` from the target branch on merge. Only add it if that's the intended policy.

`clean_build.sh` *deletes* `.DS_Store`, `Thumbs.db`, `desktop.ini`, `*.tmp`, `*.bak`,
`ehthumbs.db` unconditionally as part of its common-patterns pass — ignoring the same set here
is the preventive half of that job (stops them from being committed in the first place; doesn't
replace running `clean_build.sh` to remove ones that already exist on disk).

---

## Stack Templates

### Python

Trimmed from `Python.gitignore` (220 lines) — dropped the framework-specific blocks (Django,
Flask, Scrapy, Celery, SageMath, Marimo, Abstra, Streamlit); keep those if the project actually
uses them, from the [full version upstream](https://github.com/github/gitignore/blob/main/Python.gitignore).
The commented-out lock-file lines are intentional — upstream's stance is that lock files
generally *should* be committed for reproducibility, so these are documented opt-outs, not
active rules:

```gitignore
# Byte-compiled / optimized / DLL files
__pycache__/
*.py[codz]
*$py.class

# C extensions
*.so

# Distribution / packaging
build/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/
share/python-wheels/
*.egg-info/
.installed.cfg
*.egg
MANIFEST

# Unit test / coverage reports
htmlcov/
.tox/
.nox/
.coverage
.coverage.*
.cache
nosetests.xml
coverage.xml
*.cover
*.py.cover
*.lcov
.hypothesis/
.pytest_cache/
cover/

# Jupyter Notebook
.ipynb_checkpoints

# IPython
profile_default/
ipython_config.py

# pyenv
#   For a library or package, you might want to ignore these files since the code is
#   intended to run in multiple environments; otherwise, check them in:
# .python-version

# pipenv
#   It is generally recommended to include Pipfile.lock in version control.
# Pipfile.lock

# UV
#   It is generally recommended to include uv.lock in version control.
# uv.lock

# poetry
#   It is generally recommended to include poetry.lock in version control.
# poetry.lock

# pdm
#   It is generally recommended to include pdm.lock in version control.
# pdm.lock
.pdm-python
.pdm-build/

# pixi
# pixi.lock
.pixi/*
!.pixi/config.toml

# PEP 582
__pypackages__/

# Environments
.env
.envrc
.venv
env/
venv/
ENV/
env.bak/
venv.bak/

# mypy
.mypy_cache/
.dmypy.json
dmypy.json

# Pyre type checker
.pyre/

# pytype static type analyzer
.pytype/

# Cython debug symbols
cython_debug/

# Ruff stuff:
.ruff_cache/

# PyPI configuration file
.pypirc
```

### Node / TypeScript

Trimmed from `Node.gitignore` (143 lines); dropped per-framework build-output lines that don't
apply outside their framework. [Full version upstream](https://github.com/github/gitignore/blob/main/Node.gitignore).

```gitignore
# Logs
logs
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Coverage directory used by tools like istanbul
coverage
*.lcov
.nyc_output

# Dependency directories
node_modules/
jspm_packages/

# TypeScript cache
*.tsbuildinfo

# Optional eslint / stylelint cache
.eslintcache
.stylelintcache

# dotenv environment variable files
.env
.env.*
!.env.example

# Build output (Next.js/Nuxt/Gatsby/etc. — trim to what this project uses)
.next
.nuxt
.cache/
dist
out

# pnpm
.pnpm-store

# yarn v3 — see the negation trap above for why these must stay as `!` lines
# under `.yarn/*`, not under `.yarn/`
.pnp.*
.yarn/*
!.yarn/patches
!.yarn/plugins
!.yarn/releases
!.yarn/sdks
!.yarn/versions

# Vite
vite.config.js.timestamp-*
vite.config.ts.timestamp-*
.vite/
```

### Rust

Verbatim — [full version upstream](https://github.com/github/gitignore/blob/main/Rust.gitignore):

```gitignore
# Generated by Cargo
# will have compiled files and executables
debug
target

# These are backup files generated by rustfmt
**/*.rs.bk

# MSVC Windows builds of rustc generate these, which store debugging information
*.pdb

# Generated by cargo mutants
# Contains mutation testing data
**/mutants.out*/

# rustc will dump stack traces when hitting an internal compiler error to PWD
rustc-ice-*.txt

# RustRover / JetBrains
#  JetBrains-specific rules live in Global/JetBrains.gitignore (see Global Templates below).
#  For a more nuclear option (not recommended) you can uncomment the following:
#.idea/
```

### Go

Verbatim — [full version upstream](https://github.com/github/gitignore/blob/main/Go.gitignore).
Note the deny-list-vs-allow-list choice is deliberate upstream; if you'd rather ignore
everything except source, use the linked `community/Golang/Go.AllowList.gitignore` instead of
this file:

```gitignore
# If you prefer the allow list template instead of the deny list, see community template:
# https://github.com/github/gitignore/blob/main/community/Golang/Go.AllowList.gitignore

# Binaries for programs and plugins
*.exe
*.exe~
*.dll
*.so
*.dylib

# Test binary, built with `go test -c`
*.test

# Code coverage profiles and other test artifacts
*.out
coverage.*
*.coverprofile
profile.cov

# Dependency directories (remove the comment below to include it)
# vendor/

# Go workspace file
go.work
go.work.sum

# env file
.env
```

### C / C++

Merged and trimmed from `C.gitignore` (55 lines) and `C++.gitignore` (68 lines) — full versions
upstream: [C](https://github.com/github/gitignore/blob/main/C.gitignore),
[C++](https://github.com/github/gitignore/blob/main/C++.gitignore). The root `Fortran.gitignore`
is a symlink to `C++.gitignore` upstream, for projects that mix Fortran modules into a C++ build.

```gitignore
# Prerequisites
*.d

# Compiled object files
*.slo
*.lo
*.o
*.obj
*.ko
*.elf

# Precompiled headers
*.gch
*.pch

# Linker output
*.ilk
*.map
*.exp

# Debugger / debug files
*.pdb
*.dSYM/
*.su
*.idb
*.dwo

# Fortran module files
*.mod
*.smod

# Compiled dynamic libraries
*.so
*.so.*
*.dylib
*.dll

# Compiled static libraries
*.lai
*.la
*.a
*.lib

# Executables
*.exe
*.out
*.app

# CMake generated files
build/
Build/
build-*/
CMakeFiles/
CMakeCache.txt
cmake_install.cmake
compile_commands.json

# vcpkg
vcpkg_installed/
```

### CUDA

Verbatim — [full version upstream](https://github.com/github/gitignore/blob/main/CUDA.gitignore).
**This is additive, not standalone** — pair it with the C/C++ template above, since CUDA
compilation produces both these intermediate files and ordinary object/executable output:

```gitignore
*.i
*.ii
*.gpu
*.ptx
*.cubin
*.fatbin
```

---

## Global Templates (OS, Editor, Tool)

These belong in `core.excludesFile` by default (see [The Four Ignore Layers](#the-four-ignore-layers))
— commit them into the repo only for a team that won't reliably configure a personal global
excludes file.

### Windows

Verbatim — [full version upstream](https://github.com/github/gitignore/blob/main/Global/Windows.gitignore):

```gitignore
# Windows thumbnail cache files
Thumbs.db
Thumbs.db:encryptable
ehthumbs.db
ehthumbs_vista.db

# Dump file
*.stackdump

# Folder config file
[Dd]esktop.ini

# Recycle Bin used on file shares
$RECYCLE.BIN/

# Windows Installer files
*.cab
*.msi
*.msix
*.msm
*.msp

# Windows shortcuts
*.lnk
```

### macOS

Trimmed from `Global/macOS.gitignore` (57 lines) — dropped the rarely-relevant AFP-share and
Mac OS 6-9 blocks. [Full version upstream](https://github.com/github/gitignore/blob/main/Global/macOS.gitignore):

```gitignore
# General
.DS_Store
.localized
__MACOSX/
.AppleDouble
.LSOverride
Icon[]

# Resource forks
._*

# Files and directories that might appear in the root of a volume
.DocumentRevisions-V100
.fseventsd
.Spotlight-V100
.TemporaryItems
.Trashes
.VolumeIcon.icns
.com.apple.timemachine.donotpresent
.com.apple.timemachine.supported
.apdisk
```

### Linux

Verbatim — [full version upstream](https://github.com/github/gitignore/blob/main/Global/Linux.gitignore):

```gitignore
*~

# temporary files which can be created if a process still has a handle open of a deleted file
.fuse_hidden*

# Metadata left by Dolphin file manager, which comes with KDE Plasma
.directory

# Linux trash folder which might appear on any partition or disk
.Trash-*

# .nfs files are created when an open file is removed but is still being accessed
.nfs*

# Log files created by default by the nohup command
nohup.out
```

### Visual Studio Code

Verbatim — [full version upstream](https://github.com/github/gitignore/blob/main/Global/VisualStudioCode.gitignore).
Also the canonical real-world example of the negation-trap idiom above:

```gitignore
# Visual Studio Code
.vscode/*
!.vscode/settings.json
!.vscode/tasks.json
!.vscode/launch.json
!.vscode/extensions.json
!.vscode/*.code-snippets
!*.code-workspace

# Built Visual Studio Code Extensions
*.vsix
```

### JetBrains

Trimmed from `Global/JetBrains.gitignore` (87 lines) — dropped plugin-specific entries
(Crashlytics, Cursive Clojure, SonarLint, Apifox, Copilot, JIRA). [Full version upstream](https://github.com/github/gitignore/blob/main/Global/JetBrains.gitignore).
Covers IntelliJ, GoLand, RubyMine, PhpStorm, PyCharm, CLion, Android Studio, WebStorm, Rider:

```gitignore
# User-specific stuff
.idea/**/workspace.xml
.idea/**/tasks.xml
.idea/**/usage.statistics.xml
.idea/**/dictionaries
.idea/**/shelf

# Sensitive or high-churn files
.idea/**/dataSources/
.idea/**/dataSources.ids
.idea/**/dataSources.local.xml
.idea/**/sqlDataSources.xml
.idea/**/dynamic.xml
.idea/**/uiDesigner.xml
.idea/**/dbnavigator.xml

# Gradle and Maven with auto-import
# Uncomment if using auto-import — module files get regenerated and cause churn.
# .idea/artifacts
# .idea/compiler.xml
# .idea/jarRepositories.xml
# .idea/modules.xml
# .idea/*.iml
# .idea/modules
# *.iml
# *.ipr

# CMake
cmake-build-*/

# File-based project format
*.iws

# IntelliJ
out/
```

### AI Agents

Trimmed from `Global/Agents.gitignore` (68 lines) — full version has commented-out entries for
Gemini CLI, Continue, Cline, Windsurf, GitHub Copilot, and more; see the
[full version upstream](https://github.com/github/gitignore/blob/main/Global/Agents.gitignore).
This is the highest-value Global template for a CGW project — its active Claude Code rules and
its commented `# .claude/` line map directly onto the `CGW_LOCAL_FILES` defaults
(`CLAUDE.md`, `MEMORY.md`, `.claude/`, see [The CGW Baseline Block](#the-cgw-baseline-block)).
Note the same "comment it out, only opt in if it's actually local-only" idiom used for Python
lock files above — most of these files are often intentionally committed and shared with a team:

```gitignore
# AI agents and assistants
#
# Some common agent instruction and project configuration files are listed
# below as commented-out examples. Only uncomment them if they are local-only
# in your project.

# CLAUDE.md
# AGENTS.md

# Claude Code
.claude/*.local.json
.claude/**/*.log
CLAUDE.local.md
# .claude/

# Aider
.aider.input.history
.aider.chat.history.md
.aider.llm.history
.aider.tags.cache.v*
# .aiderignore

# Cursor AI
# .cursorrules
# .cursor/
```

### Backup / Archives

`Global/Backup.gitignore` verbatim, `Global/Archives.gitignore` trimmed to the common formats
(full archive list is [upstream](https://github.com/github/gitignore/blob/main/Global/Archives.gitignore)).
Upstream's rationale for Archives, worth keeping as a comment if you adopt it: git already
compresses internally, and an archive hides its contents from diff/blame — better to unpack and
commit the raw source:

```gitignore
# Generic backup files
*.bak
*.back
*.backup

# Generic original files
*.ori
*.orig
*.original

# Generic temporary files
*.tmp
*.temp
*.temporary

# It's better to unpack these files and commit the raw source because
# git has its own built-in compression methods.
*.7z
*.zip
*.gz
*.tgz
*.bz2
*.xz
*.rar
```

---

## Debugging: Why Is This Path (Not) Ignored?

Read-only inspection — always safe to run directly, no CGW wrapper needed:

```bash
git check-ignore -v <path>                          # names the file:line:pattern that matched
git status --ignored                                # ignored files alongside tracked/modified
git ls-files --others --ignored --exclude-standard  # every ignored path, one per line
git config --get core.excludesFile                  # is a personal global file even configured?
```

`git check-ignore -v` exits 0 and prints the winning `file:line:pattern` whenever *any* pattern
matches the path — including a negation pattern that re-includes it, so exit code alone doesn't
tell you whether the path is ignored. Read the printed pattern instead: a `!`-prefixed pattern
means the path is *not* ignored; anything else means it is. This is the fastest way to catch the
negation trap — if you expected the `!` line to win but the tool reports the plain excluding
line instead (e.g. `.gitignore:1:.vscode/` instead of `.gitignore:2:!.vscode/settings.json`),
a parent directory is swallowing the file before your negation ever gets a chance to apply. No
match at all (exit 1, no output) means the path isn't ignored by any layer — a different, simpler
case than the trap.

---

## The Already-Tracked Trap (and the CGW-Correct Fix)

**Mental model:** `.gitignore` only filters paths that are *not already in the index*. Adding a
pattern for a path that's already tracked does nothing on its own — the file stays tracked and
continues to show as clean in `git status`. This is the trap: it looks handled, but isn't.

Fix it with the CGW-correct sequence, not a bare `git rm --cached`:

```bash
# 1. add the pattern to .gitignore first
# 2. untrack it (keeps the file on disk — never plain `git rm`, which deletes it)
git rm --cached <path>
# 3. commit through the wrapper — Rule 1 applies to this commit too
./scripts/git/commit_enhanced.sh "chore: stop tracking <path>"
```

Two things worth knowing about this flow:

- `commit_enhanced.sh` and the pre-push hook scope their `CGW_LOCAL_FILES` check to
  `--diff-filter=AM` (added/modified), so a `git rm --cached` *deletion* of a protected path
  passes straight through instead of being unstaged — this is intentional, not a loophole: it's
  what lets you untrack a local-only file that was accidentally committed before it was
  configured as local-only.
- Never run `git rm -f` or `git clean -f` on a local-only or already-ignored path — for an
  ignored file this is unrecoverable, since git never tracked a copy to restore from.

If the already-tracked path is a **secret** (API key, token, credential) and it may have been
pushed, this doc's fix is not enough — go to
[removing-sensitive-data.md](removing-sensitive-data.md) instead, which covers rotation and
history rewriting. Don't improvise that procedure from here.

---

## Upstream Catalog Index

For anything not inlined above. Upstream's evergreen-versioning convention: root holds the
*current* supported version of a template (no version in the filename); older versions live
under `community/` with the version embedded in the filename (e.g. root `Drupal.gitignore` vs.
`community/PHP/Drupal7.gitignore`, root `Java`'s JBoss support vs.
`community/Java/JBoss4.gitignore` / `JBoss6.gitignore`).

| Tier | Count | Reach for it when |
|---|---:|---|
| Root | 163 | Starting a new project in a mainstream language/framework |
| `Global/` | 76 | Configuring your personal `core.excludesFile`, or a team needs OS/editor rules committed |
| `community/` | 73 (across 14 subdirs + a flat root) | Adopting a specialized framework/tool/legacy version not covered above |

Fetch any template directly:

```text
https://github.com/github/gitignore/blob/main/<Name>.gitignore
https://github.com/github/gitignore/blob/main/Global/<Name>.gitignore
https://github.com/github/gitignore/blob/main/community/<Category>/<Name>.gitignore
```

A sample of other root templates likely to come up: Android, Angular, Autotools, CMake, Composer,
Dart, Deno, Dotnet, Drupal, Elixir, Elm, Erlang, Flutter, GitBook, Godot, Gradle, Haskell, Java,
Kotlin, Laravel, Lua, Maven, Nim, Nix, OCaml, Objective-C, Packer, Perl, PlayFramework, Processing,
Rails, Ruby, Scala, Swift, Terraform, Unity, UnrealEngine, VBA, VisualStudio, WordPress, Zig.

Full `Global/` list: AL, Agents, Anjuta, Ansible, Archives, Backup, Bazaar, BricxCC, CVS, Calabash,
Cloud9, CodeKit, Cursor, DartEditor, Diff, Dreamweaver, Dropbox, Eclipse, EiffelStudio, Emacs,
Ensime, Espresso, FlexBuilder, GPG, Images, JDeveloper, JEnv, JetBrains, KDevelop4, Kate, Lazarus,
Lefthook, LibreOffice, Linux, LyX, MATLAB, Mercurial, Metals, MicrosoftOffice, Momentics,
MonoDevelop, NetBeans, Ninja, NotepadPP, Octave, OhMyOpenAgent, Otto, PSoCCreator, Patch,
PlatformIO, PuTTY, Redcar, Redis, SBT, STM32CubeIDE, SVN, SlickEdit, Stata, SublimeText, Syncthing,
SynopsysVCS, Tags, TextMate, TortoiseGit, Vagrant, Vim, VirtualEnv, Virtuoso, VisualStudioCode,
WebMethods, Windows, Xcode, XilinxISE, Zed, macOS, mise.

`community/` subdirectories: AWS, BoxLang, CFML, DotNet, Elixir, GNOME, Golang, Java, JavaScript,
Linux, Obsidian, PHP, Python, embedded (plus a flat set of ~35 templates at `community/` root).
