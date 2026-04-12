@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: CGW (claude-git-workflow) Installer
:: Copies git workflow scripts into a target project and runs
:: configure.sh to set up branches, lint, hooks, and skill.
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
where bash >nul 2>&1
if not !ERRORLEVEL!==0 goto :pi03_fail
echo   [PASS] PI-03  bash available
goto :pi03_done
:pi03_fail
echo   [FAIL] PI-03  bash not found on PATH
echo          Install Git for Windows: https://git-scm.com/download/win
set "CHECKS_PASSED=0"
:pi03_done

rem PI-04: CGW source files complete
set "SOURCE_OK=1"
if not exist "!CGW_DIR!\scripts\git\configure.sh"    set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\pre-commit"             set "SOURCE_OK=0"
if not exist "!CGW_DIR!\hooks\pre-push"               set "SOURCE_OK=0"
if not exist "!CGW_DIR!\skill\SKILL.md"               set "SOURCE_OK=0"
if not exist "!CGW_DIR!\command\auto-git-workflow.md" set "SOURCE_OK=0"
if not "!SOURCE_OK!"=="1" goto :pi04_fail
echo   [PASS] PI-04  CGW source files complete
goto :pi04_done
:pi04_fail
echo   [FAIL] PI-04  CGW source missing required files
echo          Expected: scripts\git\configure.sh, hooks\pre-commit, hooks\pre-push,
echo                    skill\SKILL.md, command\auto-git-workflow.md
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

echo.

:: Abort if hard checks failed
if not "!CHECKS_PASSED!"=="1" goto :checks_failed
goto :checks_ok
:checks_failed
echo   One or more required checks failed. Installation aborted.
echo.
goto :abort
:checks_ok

rem --- Confirm ---
echo --- Installation Summary ---
echo.
echo(  Will copy into: !TARGET_DIR!
echo     scripts\git\    (25 shell scripts)
echo     hooks\          (pre-commit + pre-push templates)
echo     skill\          (Claude Code skill source)
echo     command\        (slash command source)
echo     cgw.conf.example (config reference)
echo.
echo   Then run: configure.sh (interactive)
echo   Finally:  offer to remove temp files (hooks\, skill\, command\)
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
if not exist "!TARGET_DIR!\.githooks\pre-push" goto :backup_done
copy /y "!TARGET_DIR!\.githooks\pre-push" "!TARGET_DIR!\.githooks\pre-push.bak" >nul
if errorlevel 1 (
    echo   [WARN] Could not back up .githooks\pre-push -- continuing without backup
) else (
    echo   Backed up .githooks\pre-push -^> .githooks\pre-push.bak
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
goto :abort
:cp_scripts_done

rem hooks/
if not exist "!TARGET_DIR!\hooks\" mkdir "!TARGET_DIR!\hooks\"
copy /y "!CGW_DIR!\hooks\pre-commit" "!TARGET_DIR!\hooks\pre-commit" >nul
if errorlevel 1 goto :cp_hooks_fail
copy /y "!CGW_DIR!\hooks\pre-push" "!TARGET_DIR!\hooks\pre-push" >nul
if errorlevel 1 goto :cp_hooks_fail
echo   [OK] Copied hooks\pre-commit + hooks\pre-push templates
goto :cp_hooks_done
:cp_hooks_fail
echo   [ERR] Failed to copy hook templates from hooks\
goto :abort
:cp_hooks_done

rem skill/
if not exist "!TARGET_DIR!\skill\" mkdir "!TARGET_DIR!\skill\"
xcopy /y /q /e "!CGW_DIR!\skill\" "!TARGET_DIR!\skill\" >nul
if errorlevel 1 goto :cp_skill_fail
echo   [OK] Copied skill\
goto :cp_skill_done
:cp_skill_fail
echo   [ERR] Failed to copy skill\
goto :abort
:cp_skill_done

rem command/
if not exist "!TARGET_DIR!\command\" mkdir "!TARGET_DIR!\command\"
xcopy /y /q /e "!CGW_DIR!\command\" "!TARGET_DIR!\command\" >nul
if errorlevel 1 goto :cp_cmd_fail
echo   [OK] Copied command\
goto :cp_cmd_done
:cp_cmd_fail
echo   [ERR] Failed to copy command\
goto :abort
:cp_cmd_done

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
bash -c "chmod +x scripts/git/*.sh 2>/dev/null" >nul 2>&1

rem Ensure .claude/ exists so configure.sh defaults to installing the
rem Claude Code skill and slash command (it checks for .claude/ presence).
if not exist ".claude\" mkdir ".claude"

echo.

rem --- Run configure.sh ---
echo --- Running configure.sh ---
echo.
echo   configure.sh will auto-detect your branches, lint tool, and
echo   local-only files. You can confirm or override each setting.
echo.
bash scripts/git/configure.sh
set "CONFIGURE_EXIT=!ERRORLEVEL!"
popd

echo.
if "!CONFIGURE_EXIT!"=="0" goto :cfg_ok
echo   [WARN] configure.sh exited with code !CONFIGURE_EXIT!
echo   Installation may be incomplete. Check output above.
set "EXIT_CODE=1"
goto :cfg_done
:cfg_ok
echo   configure.sh completed successfully.
:cfg_done

rem --- Cleanup temp files ---
echo.
echo --- Post-Install Cleanup ---
echo.
echo   The following directories were needed only during installation
echo   and can be safely removed from the target project:
echo(    !TARGET_DIR!\hooks\
echo(    !TARGET_DIR!\skill\
echo(    !TARGET_DIR!\command\
echo.
set /p "CLEANUP=Remove temporary install files? [Y/n]: "
if /i "!CLEANUP!"=="n"  goto :cleanup_skip
if /i "!CLEANUP!"=="no" goto :cleanup_skip
set "REMOVED_DIRS="
if exist "!TARGET_DIR!\hooks\"   ( rmdir /s /q "!TARGET_DIR!\hooks\"   & if not exist "!TARGET_DIR!\hooks\"   set "REMOVED_DIRS=!REMOVED_DIRS! hooks\" )
if exist "!TARGET_DIR!\skill\"   ( rmdir /s /q "!TARGET_DIR!\skill\"   & if not exist "!TARGET_DIR!\skill\"   set "REMOVED_DIRS=!REMOVED_DIRS! skill\" )
if exist "!TARGET_DIR!\command\" ( rmdir /s /q "!TARGET_DIR!\command\" & if not exist "!TARGET_DIR!\command\" set "REMOVED_DIRS=!REMOVED_DIRS! command\" )
if "!REMOVED_DIRS!"=="" (
    echo   [WARN] Could not fully remove temp directories (files may be locked)
) else (
    echo(  Removed:!REMOVED_DIRS!
)
goto :cleanup_done
:cleanup_skip
echo   Temp files kept.
:cleanup_done

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
if exist "!TARGET_DIR!\.git\hooks\pre-commit"                      echo(  Git hooks:    !TARGET_DIR!\.git\hooks\pre-commit + pre-push
if exist "!TARGET_DIR!\.claude\skills\auto-git-workflow\SKILL.md"  echo(  Claude skill: !TARGET_DIR!\.claude\skills\auto-git-workflow\
if exist "!TARGET_DIR!\.claude\commands\auto-git-workflow.md"      echo(  Slash cmd:    !TARGET_DIR!\.claude\commands\auto-git-workflow.md

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
