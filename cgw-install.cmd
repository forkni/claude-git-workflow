@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: CGW (claude-git-workflow) Installer
:: Copies git workflow scripts into a target project and runs
:: configure.sh to set up branches, lint, hooks, and skills
:: for Claude Code and Antigravity Agents.
::
:: Usage: Double-click or run from cmd/terminal
:: Requires: Git for Windows (provides bash)
::
:: Note on special characters in paths:
::   Paths containing ! are corrupted by EnableDelayedExpansion (cmd.exe
::   limitation). Paths with & | < > work correctly because all echo
::   lines use the echo( trick which prevents cmd.exe from parsing
::   meta-characters in the output.
:: ============================================================

set "CGW_DIR=%~dp0"
if "%CGW_DIR:~-1%"=="\" set "CGW_DIR=%CGW_DIR:~0,-1%"
set "EXIT_CODE=0"

echo.
echo ===================================================
echo   CGW (claude-git-workflow) Installer
echo ===================================================
echo(  Source: !CGW_DIR!
echo.

rem --- Get target path ---
:ask_target
set "TARGET_DIR="
set /p "TARGET_DIR=Enter path to your project folder: "

rem Strip surrounding quotes if present
set "TARGET_DIR=%TARGET_DIR:"=%"

rem Strip trailing backslash
if "%TARGET_DIR:~-1%"=="\" set "TARGET_DIR=%TARGET_DIR:~0,-1%"

if "%TARGET_DIR%"=="" (
    echo   ERROR: Path cannot be empty.
    goto ask_target
)

echo.
echo(  Target: !TARGET_DIR!
echo.

rem --- Agent harness options ---
set "INSTALL_CLAUDE=1"
set "INSTALL_AGY=1"
set "GLOBAL_SKILL=0"

echo   Agent harnesses:
echo   Configure for Claude Code and/or Antigravity Agents.
echo.
set /p "CLAUDE_CHOICE=Configure Claude Code integration? [Y/n]: "
if /i "!CLAUDE_CHOICE!"=="n"  set "INSTALL_CLAUDE=0"
if /i "!CLAUDE_CHOICE!"=="no" set "INSTALL_CLAUDE=0"

set /p "AGY_CHOICE=Configure Antigravity Agents integration? [Y/n]: "
if /i "!AGY_CHOICE!"=="n"  set "INSTALL_AGY=0"
if /i "!AGY_CHOICE!"=="no" set "INSTALL_AGY=0"

echo.
echo   Skills can be installed locally (this project only) or
echo   globally (all projects: %%USERPROFILE%%\.claude and %%USERPROFILE%%\.gemini\config).
echo.
set /p "GLOBAL_CHOICE=Install skills globally to %%USERPROFILE%%? [y/N]: "
if /i "!GLOBAL_CHOICE!"=="y"   set "GLOBAL_SKILL=1"
if /i "!GLOBAL_CHOICE!"=="yes" set "GLOBAL_SKILL=1"
echo.

rem --- Pre-install checks ---
echo --- Pre-Install Checks ---
echo.

set "CHECKS_PASSED=1"

rem All checks use goto to avoid CMD if/else fall-through with special chars in echo

rem PI-00: Target must not be the CGW source directory (prevent self-install)
if /i "!TARGET_DIR!"=="!CGW_DIR!" goto :pi00_fail
rem Also compare with trailing backslash stripped CGW_DIR
goto :pi00_pass
:pi00_fail
echo   [FAIL] PI-00  Target is the CGW source directory -- cannot install into itself
set "CHECKS_PASSED=0"
goto :pi00_done
:pi00_pass
echo   [PASS] PI-00  Target is not the CGW source directory
:pi00_done

rem PI-01: Target path exists
if exist "!TARGET_DIR!\" goto :pi01_pass
echo(  [FAIL] PI-01  Target path does not exist: !TARGET_DIR!
set "CHECKS_PASSED=0"
goto :pi01_done
:pi01_pass
echo   [PASS] PI-01  Target path exists
:pi01_done

rem PI-02: Target is a git repo
if exist "!TARGET_DIR!\.git\" goto :pi02_pass
if exist "!TARGET_DIR!\.git"  goto :pi02_pass
echo   [FAIL] PI-02  No .git directory found -- not a git repository
set "CHECKS_PASSED=0"
goto :pi02_done
:pi02_pass
echo   [PASS] PI-02  Target is a git repository
:pi02_done

rem PI-03: bash available
rem Always prepend known Git for Windows locations to PATH so Git Bash
rem takes priority over the Windows/System32 WSL bash shim (bash.exe in
rem System32 fails with "no installed distributions" when WSL has no distro).
if exist "C:\Program Files\Git\bin\bash.exe" (
    set "PATH=C:\Program Files\Git\bin;!PATH!"
) else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    set "PATH=C:\Program Files (x86)\Git\bin;!PATH!"
)
rem Resolve an ABSOLUTE bash.exe from PATH once and use it for every later
rem invocation. %%~$PATH:B searches PATH directories only -- never the current
rem directory -- so a target project that ships its own bash.cmd (Antigravity-
rem enabled projects carry one that delegates to a Python shim) cannot shadow
rem it. cmd.exe resolves a bare "bash" against the cwd first, and a batch file
rem invoked from a batch file without "call" never returns: with bare "bash"
rem after pushd, the installer chained into the project's bash.cmd and
rem silently terminated before configure.sh ever ran.
set "BASH_EXE="
for %%B in (bash.exe) do set "BASH_EXE=%%~$PATH:B"
if "!BASH_EXE!"=="" goto :pi03_fail
echo(  [PASS] PI-03  bash available: !BASH_EXE!
goto :pi03_done
:pi03_fail
echo   [FAIL] PI-03  bash not found on PATH
echo          Install Git for Windows: https://git-scm.com/download/win
echo          After installing, restart your terminal and run this installer again.
set "CHECKS_PASSED=0"
:pi03_done

rem PI-04: CGW source files complete
set "SOURCE_OK=1"
if not exist "!CGW_DIR!\scripts\git\configure.sh"             set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\pre-commit"                      set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\pre-push"                        set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\pre-rebase"                      set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\cc-block-dangerous-git.sh"       set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\agy-block-dangerous-git.sh"      set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\agy-block-dangerous-git.cmd"     set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\_guardrail_core.sh"              set "SOURCE_OK=0"
if not exist "!CGW_DIR!\skill\SKILL.md"                        set "SOURCE_OK=0"
if not exist "!CGW_DIR!\command\auto-git-workflow-cmd.md"      set "SOURCE_OK=0"
if not exist "!CGW_DIR!\templates\markdownlint.json"           set "SOURCE_OK=0"
if not "!SOURCE_OK!"=="1" goto :pi04_fail
echo   [PASS] PI-04  CGW source files complete
goto :pi04_done
:pi04_fail
echo   [FAIL] PI-04  CGW source missing required files
echo          Expected: scripts\git\configure.sh, hooks\pre-commit, hooks\pre-push,
echo                    hooks\pre-rebase, hooks\cc-block-dangerous-git.sh,
echo                    hooks\agy-block-dangerous-git.sh, hooks\agy-block-dangerous-git.cmd,
echo                    hooks\_guardrail_core.sh,
echo                    skill\SKILL.md, command\auto-git-workflow-cmd.md,
echo                    templates\markdownlint.json
set "CHECKS_PASSED=0"
:pi04_done

rem PI-05: Existing CGW install detection
if not exist "!TARGET_DIR!\scripts\git\configure.sh" goto :pi05_clean
echo   [WARN] PI-05  CGW scripts already present in target
set /p "OVERWRITE=          Overwrite existing installation? [y/N]: "
if /i "!OVERWRITE!"=="y" goto :pi05_done
echo          Aborting. Run with a clean target or choose overwrite.
goto :abort
:pi05_clean
echo   [PASS] PI-05  No existing CGW installation
:pi05_done

rem PI-06: Existing .githooks/pre-commit
if not exist "!TARGET_DIR!\.githooks\pre-commit" goto :pi06_clean
echo   [WARN] PI-06  Existing .githooks\pre-commit found
echo          It will be backed up to .githooks\pre-commit.bak
goto :pi06_done
:pi06_clean
echo   [INFO] PI-06  No existing .githooks\pre-commit
:pi06_done

rem PI-07: jq (optional — used for guardrail settings.json install; Python fallback available)
where jq >nul 2>nul
if not errorlevel 1 (
    echo   [PASS] PI-07  jq available
    goto :pi07_done
)
echo   [INFO] PI-07  jq not found ^(optional; configure.sh will use Python fallback if absent^)
where winget >nul 2>nul
if errorlevel 1 goto :pi07_done
set /p "INSTALL_JQ=          Install jq now via winget? [Y/n]: "
if /i "!INSTALL_JQ!"=="n"  goto :pi07_done
if /i "!INSTALL_JQ!"=="no" goto :pi07_done
winget install jqlang.jq
rem Refresh user PATH in this session so jq is visible to configure.sh
for /f "tokens=*" %%p in ('powershell -NoProfile -Command "[Environment]::GetEnvironmentVariable('PATH','User')"') do (
    if not "%%p"=="" set "PATH=%%p;!PATH!"
)
where jq >nul 2>nul
if not errorlevel 1 (
    echo   [OK] jq installed and available
) else (
    echo   [INFO] jq installed ^(will be active in new terminals^)
)
:pi07_done

echo.

:: Abort if hard checks failed
if not "!CHECKS_PASSED!"=="1" goto :checks_failed
goto :checks_ok
:checks_failed
echo   One or more required checks failed. Fix the issues above and re-run the installer.
echo.
goto :abort
:checks_ok

rem --- Confirm ---
echo --- Installation Summary ---
echo(  Will copy into: !TARGET_DIR!
echo     scripts\git\     (shell scripts)
echo     cgw.conf.example (config reference)
echo.
echo(  Will configure via templates in: !CGW_DIR!
echo     git hooks        (pre-commit, pre-push, pre-rebase)
echo     agent skills     (auto-git-workflow)
echo     slash commands   (auto-git-workflow-cmd)
echo     guardrails       (cc-block-dangerous-git, agy-block-dangerous-git)
echo     templates        (markdownlint.json)
echo.
if "!INSTALL_CLAUDE!"=="1" (
    if "!GLOBAL_SKILL!"=="1" (
        echo(  Claude Code:  global install to !USERPROFILE!\.claude\
    ) else (
        echo   Claude Code:  local install to .claude\ in target project
    )
)
if "!INSTALL_AGY!"=="1" (
    if "!GLOBAL_SKILL!"=="1" (
        echo(  Antigravity:  global install to !USERPROFILE!\.gemini\config\
    ) else (
        echo   Antigravity:  local install to .agents\ in target project
    )
)
echo.
echo   Then run: configure.sh (interactive)
echo.
set /p "CONFIRM=Proceed with installation? [Y/n]: "
if /i "!CONFIRM!"=="n"  goto :cancel
if /i "!CONFIRM!"=="no" goto :cancel
goto :install_start
:cancel
echo   Installation cancelled.
goto :abort
:install_start

echo.

rem --- Backup existing .githooks/ hook templates ---
if not exist "!TARGET_DIR!\.githooks\pre-commit" goto :backup_pc_done
copy /y "!TARGET_DIR!\.githooks\pre-commit" "!TARGET_DIR!\.githooks\pre-commit.bak" >nul
if errorlevel 1 (
    echo   [WARN] Could not back up .githooks\pre-commit -- continuing without backup
) else (
    echo   Backed up .githooks\pre-commit -^> .githooks\pre-commit.bak
)
:backup_pc_done
if not exist "!TARGET_DIR!\.githooks\pre-push" goto :backup_pp_done
copy /y "!TARGET_DIR!\.githooks\pre-push" "!TARGET_DIR!\.githooks\pre-push.bak" >nul
if errorlevel 1 (
    echo   [WARN] Could not back up .githooks\pre-push -- continuing without backup
) else (
    echo   Backed up .githooks\pre-push -^> .githooks\pre-push.bak
)
:backup_pp_done
if not exist "!TARGET_DIR!\.githooks\pre-rebase" goto :backup_done
copy /y "!TARGET_DIR!\.githooks\pre-rebase" "!TARGET_DIR!\.githooks\pre-rebase.bak" >nul
if errorlevel 1 (
    echo   [WARN] Could not back up .githooks\pre-rebase -- continuing without backup
) else (
    echo   Backed up .githooks\pre-rebase -^> .githooks\pre-rebase.bak
)
:backup_done

rem --- Copy files ---
echo --- Copying Files ---
echo.

rem scripts/git/
if not exist "!TARGET_DIR!\scripts\git\" mkdir "!TARGET_DIR!\scripts\git\"
xcopy /y /q "!CGW_DIR!\scripts\git\*.sh" "!TARGET_DIR!\scripts\git\" >nul
if errorlevel 1 goto :cp_scripts_fail
for /f %%c in ('dir /b "!TARGET_DIR!\scripts\git\*.sh" 2^>nul ^| find /c ".sh"') do echo   [OK] Copied %%c scripts to scripts\git\
goto :cp_scripts_done
:cp_scripts_fail
echo   [ERR] Failed to copy scripts\git\
echo          Check that the target directory is writable and not locked by another process.
goto :abort
:cp_scripts_done

rem cgw.conf.example (optional)
if not exist "!CGW_DIR!\cgw.conf.example" goto :cp_example_done
copy /y "!CGW_DIR!\cgw.conf.example" "!TARGET_DIR!\cgw.conf.example" >nul
if errorlevel 1 (
    echo   [WARN] Could not copy cgw.conf.example
) else (
    echo   [OK] Copied cgw.conf.example
)
:cp_example_done

rem Ensure .sh files are executable (needed by Git Bash on Windows)
pushd "!TARGET_DIR!"
if errorlevel 1 (
    echo(  [ERR] Cannot enter target directory: !TARGET_DIR!
    goto :abort
)
rem Always the absolute BASH_EXE resolved in PI-03, never bare "bash": we are
rem inside the target now, and a project-local bash.cmd would win the cwd
rem lookup and swallow the rest of this script (see PI-03).
"!BASH_EXE!" -c "chmod +x scripts/git/*.sh 2>/dev/null" >nul 2>&1

rem Ensure target agent directories exist so configure.sh defaults to installing
if "!INSTALL_CLAUDE!"=="1" (
    if not exist ".claude\" mkdir ".claude"
)
if "!INSTALL_AGY!"=="1" (
    if not exist ".agents\" mkdir ".agents"
)

echo.

rem --- Run configure.sh ---
echo --- Running configure.sh ---
echo.
echo   configure.sh will auto-detect your branches, lint tool, and
echo   local-only files. You can confirm or override each setting.
echo.
set "CFG_FLAGS="
if "!GLOBAL_SKILL!"=="1"   set "CFG_FLAGS=!CFG_FLAGS! --global"
if "!INSTALL_CLAUDE!"=="0" set "CFG_FLAGS=!CFG_FLAGS! --skip-claude"
if "!INSTALL_AGY!"=="0"    set "CFG_FLAGS=!CFG_FLAGS! --skip-antigravity"

"!BASH_EXE!" scripts/git/configure.sh --template-dir "!CGW_DIR!" !CFG_FLAGS!
set "CONFIGURE_EXIT=!ERRORLEVEL!"
popd

echo.
if "!CONFIGURE_EXIT!"=="0" goto :cfg_ok
echo   [WARN] configure.sh exited with code !CONFIGURE_EXIT!
echo   Installation may be incomplete. Common causes:
echo     - Branch detection failed (no remote configured yet -- this is OK, branches can be set in .cgw.conf)
echo     - Hook or skill template directory not found
echo   To fix and re-run configure.sh manually (from your project root in Git Bash):
echo(    cd "!TARGET_DIR!" ^&^& bash scripts/git/configure.sh --template-dir "!CGW_DIR!"
set "EXIT_CODE=1"
goto :cfg_done
:cfg_ok
echo   configure.sh completed successfully.
:cfg_done


rem --- Summary ---
echo.
echo ===================================================
echo   Installation Complete
echo ===================================================
echo.

if not exist "!TARGET_DIR!\scripts\git\commit_enhanced.sh" goto :sum_scripts_done
for /f %%c in ('dir /b "!TARGET_DIR!\scripts\git\*.sh" 2^>nul ^| find /c ".sh"') do echo(  Scripts:      !TARGET_DIR!\scripts\git\ ^(%%c files^)
:sum_scripts_done
if exist "!TARGET_DIR!\.cgw.conf"                                  echo(  Config:       !TARGET_DIR!\.cgw.conf
if exist "!TARGET_DIR!\.git\hooks\pre-commit"                      echo(  Git hooks:    !TARGET_DIR!\.git\hooks\pre-commit + pre-push + pre-rebase
if exist "!TARGET_DIR!\.claude\skills\auto-git-workflow\SKILL.md"  echo(  Claude skill: !TARGET_DIR!\.claude\skills\auto-git-workflow\
if exist "!TARGET_DIR!\.claude\commands\auto-git-workflow-cmd.md"  echo(  Slash cmd:    !TARGET_DIR!\.claude\commands\auto-git-workflow-cmd.md
if exist "!TARGET_DIR!\.claude\settings.json"                      echo(  Claude guard: !TARGET_DIR!\.claude\settings.json
if exist "!TARGET_DIR!\.agents\skills\auto-git-workflow\SKILL.md"  echo(  AGY skill:    !TARGET_DIR!\.agents\skills\auto-git-workflow\
if exist "!TARGET_DIR!\.agents\hooks.json"                         echo(  AGY guard:    !TARGET_DIR!\.agents\hooks.json
if exist "!TARGET_DIR!\.markdownlint.json"                         echo(  Markdown cfg: !TARGET_DIR!\.markdownlint.json
if exist "!TARGET_DIR!\.markdownlint-cli2.jsonc"                   echo(  Markdown tool: !TARGET_DIR!\.markdownlint-cli2.jsonc ^(gitignore-skip^)

echo.
echo   Quick start (from your project root in Git Bash):
echo     bash scripts/git/commit_enhanced.sh "feat: your feature"
echo.

goto :end

:abort
set "EXIT_CODE=1"
goto :end

:end
echo.
pause
endlocal & exit /b %EXIT_CODE%
