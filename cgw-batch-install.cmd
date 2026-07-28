@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: CGW (claude-git-workflow) Batch Updater
:: Reads a list of already-installed consumer project paths from
:: a config file and refreshes the toolkit (scripts, hooks, skill,
:: command, guardrail) across all of them in one run -- WITHOUT
:: touching any project's .cgw.conf.
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
:: Requires: Git for Windows (provides bash)
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
echo   scripts, hooks, the Claude Code skill/command, and the guardrail are
echo   updated; .cgw.conf is NEVER overwritten. Projects with no existing
echo   .cgw.conf are skipped -- run cgw-install.cmd for a first-time install.
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
where bash >nul 2>&1
if not !ERRORLEVEL!==0 goto :bf02_fail
echo   [PASS] BF-02  bash available
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
if not exist "!CGW_DIR!\skill\SKILL.md"                        set "SOURCE_OK=0"
if not exist "!CGW_DIR!\command\auto-git-workflow-cmd.md"      set "SOURCE_OK=0"
if not exist "!CGW_DIR!\templates\markdownlint.json"           set "SOURCE_OK=0"
if not "!SOURCE_OK!"=="1" goto :bf03_fail
echo   [PASS] BF-03  CGW source files complete
goto :bf03_done
:bf03_fail
echo   [FAIL] BF-03  CGW source missing required files
echo          Expected: scripts\git\configure.sh, hooks\pre-commit, hooks\pre-push,
echo                    hooks\pre-rebase, hooks\cc-block-dangerous-git.sh, skill\SKILL.md,
echo                    command\auto-git-workflow-cmd.md, templates\markdownlint.json
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

rem --- Record pre-existing state before staging, so :pp_cleanup_stage never
rem     deletes content this invocation did not create (a project could
rem     legitimately have its own top-level hooks\/skill\/command\ dirs).
set "HOOKS_PREEXISTED=0"
if exist "!P!\hooks\" set "HOOKS_PREEXISTED=1"
set "SKILL_PREEXISTED=0"
if exist "!P!\skill\" set "SKILL_PREEXISTED=1"
set "COMMAND_PREEXISTED=0"
if exist "!P!\command\" set "COMMAND_PREEXISTED=1"
set "TEMPLATES_PREEXISTED=0"
if exist "!P!\templates\" set "TEMPLATES_PREEXISTED=1"

rem --- Stage payload (mirror cgw-install.cmd's copy block) ---
set "STAGE_OK=1"

if not exist "!P!\scripts\git\" mkdir "!P!\scripts\git\"
xcopy /y /q "!CGW_DIR!\scripts\git\*.sh" "!P!\scripts\git\" >nul
if errorlevel 1 set "STAGE_OK=0"

if not exist "!P!\hooks\" mkdir "!P!\hooks\"
copy /y "!CGW_DIR!\hooks\pre-commit" "!P!\hooks\pre-commit" >nul
if errorlevel 1 set "STAGE_OK=0"
copy /y "!CGW_DIR!\hooks\pre-push" "!P!\hooks\pre-push" >nul
if errorlevel 1 set "STAGE_OK=0"
copy /y "!CGW_DIR!\hooks\pre-rebase" "!P!\hooks\pre-rebase" >nul
if errorlevel 1 set "STAGE_OK=0"
copy /y "!CGW_DIR!\hooks\cc-block-dangerous-git.sh" "!P!\hooks\cc-block-dangerous-git.sh" >nul
if errorlevel 1 set "STAGE_OK=0"

if not exist "!P!\skill\" mkdir "!P!\skill\"
xcopy /y /q /e "!CGW_DIR!\skill\" "!P!\skill\" >nul
if errorlevel 1 set "STAGE_OK=0"

if not exist "!P!\command\" mkdir "!P!\command\"
xcopy /y /q /e "!CGW_DIR!\command\" "!P!\command\" >nul
if errorlevel 1 set "STAGE_OK=0"

if not exist "!P!\templates\" mkdir "!P!\templates\"
xcopy /y /q /e "!CGW_DIR!\templates\" "!P!\templates\" >nul
if errorlevel 1 set "STAGE_OK=0"

if exist "!CGW_DIR!\cgw.conf.example" copy /y "!CGW_DIR!\cgw.conf.example" "!P!\cgw.conf.example" >nul

if not "!STAGE_OK!"=="0" goto :pp_stage_ok
echo(  [FAIL] Failed to stage toolkit files into !P!
call :pp_cleanup_stage "!P!"
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (failed to copy toolkit files)
echo.
goto :eof
:pp_stage_ok

rem Ensure .claude\ exists so configure.sh defaults to installing the
rem Claude Code skill and slash command (it checks for .claude\ presence).
if not exist "!P!\.claude\" mkdir "!P!\.claude\"

set "CFG_LOG=%TEMP%\cgw-batch-configure-%RANDOM%.log"
pushd "!P!" 2>nul
if not errorlevel 1 goto :pp_pushd_ok
echo(  [FAIL] Cannot enter project directory: !P!
call :pp_cleanup_stage "!P!"
set /a FAILED+=1
>>"!FAIL_LOG!" echo(!P!  (cannot enter directory)
echo.
goto :eof
:pp_pushd_ok

bash -c "chmod +x scripts/git/*.sh 2>/dev/null" >nul 2>&1
bash scripts/git/configure.sh --non-interactive >"!CFG_LOG!" 2>&1
set "CFG_EXIT=!ERRORLEVEL!"
popd

call :pp_cleanup_stage "!P!"

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

rem ============================================================
rem :pp_cleanup_stage <path>
rem   Remove the staged hooks\, skill\, command\, templates\ temp
rem   dirs. These are staging directories only (same as
rem   cgw-install.cmd's post-install cleanup) -- never the runtime
rem   install location. Only removes a dir if HOOKS_PREEXISTED/
rem   SKILL_PREEXISTED/COMMAND_PREEXISTED/TEMPLATES_PREEXISTED (set
rem   in :process_project before staging) says this invocation
rem   created it -- a project that legitimately already had one of
rem   these top-level dirs keeps its content instead of it being
rem   recursively deleted.
rem   NOTE: goto-based on purpose, not "( ... echo( ... )" -- an
rem   echo( inside a multi-line parenthesized block throws off
rem   cmd.exe's paren-balance counting (see :process_project).
rem ============================================================
:pp_cleanup_stage
set "CP=%~1"

if "!HOOKS_PREEXISTED!"=="1" goto :pp_cleanup_hooks_kept
if exist "!CP!\hooks\" rmdir /s /q "!CP!\hooks\" 2>nul
goto :pp_cleanup_skill
:pp_cleanup_hooks_kept
if exist "!CP!\hooks\" echo(  [WARN] !CP!\hooks\ pre-existed -- left in place, not deleted
:pp_cleanup_skill

if "!SKILL_PREEXISTED!"=="1" goto :pp_cleanup_skill_kept
if exist "!CP!\skill\" rmdir /s /q "!CP!\skill\" 2>nul
goto :pp_cleanup_command
:pp_cleanup_skill_kept
if exist "!CP!\skill\" echo(  [WARN] !CP!\skill\ pre-existed -- left in place, not deleted
:pp_cleanup_command

if "!COMMAND_PREEXISTED!"=="1" goto :pp_cleanup_command_kept
if exist "!CP!\command\" rmdir /s /q "!CP!\command\" 2>nul
goto :pp_cleanup_templates
:pp_cleanup_command_kept
if exist "!CP!\command\" echo(  [WARN] !CP!\command\ pre-existed -- left in place, not deleted
:pp_cleanup_templates

if "!TEMPLATES_PREEXISTED!"=="1" goto :pp_cleanup_templates_kept
if exist "!CP!\templates\" rmdir /s /q "!CP!\templates\" 2>nul
goto :eof
:pp_cleanup_templates_kept
if exist "!CP!\templates\" echo(  [WARN] !CP!\templates\ pre-existed -- left in place, not deleted
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
