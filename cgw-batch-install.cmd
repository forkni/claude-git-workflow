@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: CGW (claude-git-workflow) Batch Updater
:: Reads a list of already-installed consumer project paths from
:: a config file and refreshes the toolkit (scripts, hooks, skills,
:: command, guardrails for Claude Code and Antigravity) across
:: all of them in one run -- WITHOUT touching any project's .cgw.conf.
::
:: This is an UPDATER, not an installer: a project with no existing
:: .cgw.conf is skipped -- use cgw-install.cmd for a first-time
:: install.
::
:: Usage:
::   cgw-batch-install.cmd [config-file] [--dry-run] [--no-pause]
::   (config-file defaults to cgw-install-batch.conf next to this
::   script; see cgw-install-batch.conf.example)
::
:: Requires: Git for Windows (provides bash). bash.exe is resolved to an
::   absolute path from PATH in BF-02 and never invoked by bare name, because
::   a project's own bash.cmd (Antigravity shim) would otherwise shadow it.
::
:: Note on special characters in paths:
::   Paths containing ! are corrupted by EnableDelayedExpansion (cmd.exe
::   limitation) once they are re-expanded via !VAR! -- same limitation
::   as cgw-install.cmd. Paths with & | < > work correctly because all
::   echo lines use the echo( trick which prevents cmd.exe from parsing
::   meta-characters in the output.
:: ============================================================

set "CGW_DIR=%~dp0"
if "%CGW_DIR:~-1%"=="\" set "CGW_DIR=%CGW_DIR:~0,-1%"
set "EXIT_CODE=0"
set "DRY_RUN=0"
set "NO_PAUSE=0"
set "CONFIG_FILE="

echo.
echo ===================================================
echo   CGW (claude-git-workflow) Batch Updater
echo ===================================================
echo(  Source: !CGW_DIR!
echo.

rem --- Parse arguments ---
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--dry-run"  (set "DRY_RUN=1" & shift & goto :parse_args)
if /i "%~1"=="--no-pause" (set "NO_PAUSE=1" & shift & goto :parse_args)
if /i "%~1"=="-h"     goto :show_help
if /i "%~1"=="--help" goto :show_help
if "!CONFIG_FILE!"=="" (set "CONFIG_FILE=%~1" & shift & goto :parse_args)
echo   ERROR: Unrecognized argument: %~1
goto :abort

:show_help
echo   Usage: cgw-batch-install.cmd [config-file] [--dry-run] [--no-pause]
echo.
echo     config-file   Path to the batch list (default: cgw-install-batch.conf
echo                   next to this script). One project path per line,
echo                   "#" starts a comment, blank lines are ignored.
echo     --dry-run     Validate every project and report what would be
echo                   updated; makes no changes.
echo     --no-pause    Skip the final "Press any key" pause (for automation).
echo.
echo   Each listed project is refreshed via configure.sh --non-interactive:
echo   scripts, hooks, Claude Code and Antigravity skills, commands, and
echo   guardrails are updated; .cgw.conf is NEVER overwritten. Projects
echo   with no existing .cgw.conf are skipped -- run cgw-install.cmd for a
echo   first-time install.
echo.
goto :end

:args_done
if "!CONFIG_FILE!"=="" set "CONFIG_FILE=!CGW_DIR!\cgw-install-batch.conf"

echo(  Config: !CONFIG_FILE!
if "!DRY_RUN!"=="1" echo(  Mode:   DRY RUN (no changes will be made)
echo.

rem --- Pre-flight checks ---
echo --- Pre-Flight Checks ---
echo.

set "CHECKS_PASSED=1"

rem BF-01: config file exists
if exist "!CONFIG_FILE!" goto :bf01_pass
echo(  [FAIL] BF-01  Config file not found: !CONFIG_FILE!
echo          Copy cgw-install-batch.conf.example to cgw-install-batch.conf
echo          and list your project paths, one per line.
set "CHECKS_PASSED=0"
goto :bf01_done
:bf01_pass
echo   [PASS] BF-01  Config file found
:bf01_done

rem BF-02: bash available (same PATH fix as cgw-install.cmd PI-03)
if exist "C:\Program Files\Git\bin\bash.exe" (
    set "PATH=C:\Program Files\Git\bin;!PATH!"
) else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    set "PATH=C:\Program Files (x86)\Git\bin;!PATH!"
)
rem Resolve an ABSOLUTE bash.exe from PATH once and use it for every later
rem invocation. %%~$PATH:B searches PATH directories only -- never the current
rem directory -- so a project that ships its own bash.cmd (Antigravity-enabled
rem projects carry one that delegates to a Python shim) cannot shadow it.
rem cmd.exe resolves a bare "bash" against the cwd first, and a batch file
rem invoked from a batch file without "call" never returns: with bare "bash"
rem after pushd, the updater chained into the project's bash.cmd and silently
rem terminated right after printing "Project: ...".
set "BASH_EXE="
for %%B in (bash.exe) do set "BASH_EXE=%%~$PATH:B"
if "!BASH_EXE!"=="" goto :bf02_fail
echo(  [PASS] BF-02  bash available: !BASH_EXE!
goto :bf02_done
:bf02_fail
echo   [FAIL] BF-02  bash not found on PATH
echo          Install Git for Windows: https://git-scm.com/download/win
set "CHECKS_PASSED=0"
:bf02_done

rem BF-03: CGW source files complete (mirror cgw-install.cmd PI-04)
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
if not "!SOURCE_OK!"=="1" goto :bf03_fail
echo   [PASS] BF-03  CGW source files complete
goto :bf03_done
:bf03_fail
echo   [FAIL] BF-03  CGW source missing required files
echo          Expected: scripts\git\configure.sh, hooks\pre-commit, hooks\pre-push,
echo                    hooks\pre-rebase, hooks\cc-block-dangerous-git.sh,
echo                    hooks\agy-block-dangerous-git.sh, hooks\agy-block-dangerous-git.cmd,
echo                    hooks\_guardrail_core.sh,
echo                    skill\SKILL.md, command\auto-git-workflow-cmd.md,
echo                    templates\markdownlint.json
set "CHECKS_PASSED=0"
:bf03_done

echo.
if not "!CHECKS_PASSED!"=="1" (
    echo   One or more required checks failed. Fix the issues above and re-run.
    echo.
    goto :abort
)

rem --- Process each project ---
set "UPDATED=0"
set "SKIPPED=0"
set "FAILED=0"
set "SKIP_LOG=%TEMP%\cgw-batch-skipped-%RANDOM%.txt"
set "FAIL_LOG=%TEMP%\cgw-batch-failed-%RANDOM%.txt"
if exist "!SKIP_LOG!" del /q "!SKIP_LOG!" 2>nul
if exist "!FAIL_LOG!" del /q "!FAIL_LOG!" 2>nul

echo --- Processing Projects ---
echo.

for /f "usebackq eol=# tokens=* delims=" %%L in ("!CONFIG_FILE!") do call :process_project "%%~L"

echo.
goto :summary

rem ============================================================
rem :process_project <path>
rem   No setlocal here on purpose: UPDATED/SKIPPED/FAILED and the
rem   log-file variables are shared with the outer scope, same
rem   pattern used for the counters throughout this script.
rem ============================================================
:process_project
set "P=%~1"
if "!P!"=="" goto :eof
if "!P:~-1!"=="\" set "P=!P:~0,-1!"

echo(  Project: !P!

rem NOTE: this guard must stay goto-based, not a multi-line ( ... ) block --
rem an "echo(" line inside a multi-line parenthesized block throws off
rem cmd.exe's paren-balance counting (an unmatched literal "(") and can
rem cause the rest of the block to be mis-scoped.
if /i "!P!"=="!CGW_DIR!" goto :pp_self_fail
goto :pp_self_ok
:pp_self_fail
echo(  [SKIP] Target is the CGW source directory -- cannot update itself
set /a SKIPPED+=1
>>"!SKIP_LOG!" echo(!P!  (source directory)
echo.
goto :eof
:pp_self_ok

if exist "!P!\" goto :pp_exists
echo(  [FAIL] Path does not exist: !P!
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (path not found)
echo.
goto :eof
:pp_exists

if exist "!P!\.git\" goto :pp_isgit
if exist "!P!\.git" goto :pp_isgit
echo(  [FAIL] Not a git repository: !P!
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (not a git repository)
echo.
goto :eof
:pp_isgit

if exist "!P!\.cgw.conf" goto :pp_configured
echo(  [SKIP] No .cgw.conf found -- not a CGW-managed project yet
echo(         Run cgw-install.cmd against this project for a first-time install.
set /a SKIPPED+=1
>>"!SKIP_LOG!" echo(!P!  (no .cgw.conf)
echo.
goto :eof
:pp_configured

if not "!DRY_RUN!"=="1" goto :pp_do_update
echo(  [DRY] Would update: !P!
echo.
goto :eof
:pp_do_update

rem --- Copy runtime scripts ---
set "STAGE_OK=1"

if not exist "!P!\scripts\git\" mkdir "!P!\scripts\git\"
xcopy /y /q "!CGW_DIR!\scripts\git\*.sh" "!P!\scripts\git\" >nul
if errorlevel 1 set "STAGE_OK=0"

if exist "!CGW_DIR!\cgw.conf.example" copy /y "!CGW_DIR!\cgw.conf.example" "!P!\cgw.conf.example" >nul

if not "!STAGE_OK!"=="0" goto :pp_stage_ok
echo(  [FAIL] Failed to copy runtime scripts into !P!
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (failed to copy runtime scripts)
echo.
goto :eof
:pp_stage_ok

rem Ensure .claude\ and .agents\ exist so configure.sh defaults to installing
rem skills, hooks, and commands for both Claude Code and Antigravity Agents.
if not exist "!P!\.claude\" mkdir "!P!\.claude\"
if not exist "!P!\.agents\" mkdir "!P!\.agents\"

set "CFG_LOG=%TEMP%\cgw-batch-configure-%RANDOM%.log"
pushd "!P!" 2>nul
if not errorlevel 1 goto :pp_pushd_ok
echo(  [FAIL] Cannot enter project directory: !P!
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (cannot enter directory)
echo.
goto :eof
:pp_pushd_ok

rem Always the absolute BASH_EXE resolved in BF-02, never bare "bash": we are
rem inside the project now, and a project-local bash.cmd would win the cwd
rem lookup and swallow the rest of this script (see BF-02).
"!BASH_EXE!" -c "chmod +x scripts/git/*.sh 2>/dev/null" >nul 2>&1
"!BASH_EXE!" scripts/git/configure.sh --template-dir "!CGW_DIR!" --non-interactive >"!CFG_LOG!" 2>&1
set "CFG_EXIT=!ERRORLEVEL!"
popd

if not "!CFG_EXIT!"=="0" goto :pp_cfg_fail
echo(  [OK] Updated: !P!
set /a UPDATED+=1
del /q "!CFG_LOG!" 2>nul
echo.
goto :eof
:pp_cfg_fail
echo(  [FAIL] configure.sh exited !CFG_EXIT! for !P!
echo(         See log: !CFG_LOG!
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (configure.sh exit !CFG_EXIT!, log: !CFG_LOG!)
echo.
goto :eof

:summary
set /a TOTAL=!UPDATED!+!SKIPPED!+!FAILED!
echo ===================================================
echo   Batch Update Summary
echo ===================================================
echo.
rem Same goto-based rule as above: no "echo(" inside a multi-line ( ... ) block.
if not !TOTAL!==0 goto :summary_has_entries
echo(  No project entries found in !CONFIG_FILE!
echo(  Add one path per line ^(see cgw-install-batch.conf.example^).
echo.
goto :summary_done
:summary_has_entries
echo(  Updated: !UPDATED!
echo(  Skipped: !SKIPPED!
echo(  Failed:  !FAILED!
echo.

if not exist "!SKIP_LOG!" goto :summary_no_skip
echo   Skipped projects:
type "!SKIP_LOG!"
echo.
del /q "!SKIP_LOG!" 2>nul
:summary_no_skip

if not exist "!FAIL_LOG!" goto :summary_no_fail
echo   Failed projects:
type "!FAIL_LOG!"
echo.
del /q "!FAIL_LOG!" 2>nul
:summary_no_fail

if "!DRY_RUN!"=="1" (
    echo   Dry run complete -- no changes were made.
    echo.
)
:summary_done

if !FAILED! GTR 0 set "EXIT_CODE=1"
goto :end

:abort
set "EXIT_CODE=1"
goto :end

:end
echo.
if not "!NO_PAUSE!"=="1" pause
endlocal & exit /b %EXIT_CODE%
