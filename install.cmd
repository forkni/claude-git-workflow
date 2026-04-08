@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: CGW (claude-git-workflow) Installer
:: Copies git workflow scripts into a target project and runs
:: configure.sh to set up branches, lint, hooks, and skill.
::
:: Usage: Double-click or run from cmd/terminal
:: Requires: Git for Windows (provides bash)
:: ============================================================

set "CGW_DIR=%~dp0"
if "%CGW_DIR:~-1%"=="\" set "CGW_DIR=%CGW_DIR:~0,-1%"

echo.
echo ===================================================
echo   CGW (claude-git-workflow) Installer
echo ===================================================
echo   Source: %CGW_DIR%
echo.

:: ─── Get target path ────────────────────────────────
:ask_target
set "TARGET_DIR="
set /p "TARGET_DIR=Enter path to your project folder: "

:: Strip surrounding quotes if present
set "TARGET_DIR=%TARGET_DIR:"=%"

:: Strip trailing backslash
if "%TARGET_DIR:~-1%"=="\" set "TARGET_DIR=%TARGET_DIR:~0,-1%"

if "%TARGET_DIR%"=="" (
    echo   ERROR: Path cannot be empty.
    goto ask_target
)

echo.
echo   Target: %TARGET_DIR%
echo.

:: ─── Pre-install checks ─────────────────────────────
echo --- Pre-Install Checks ---
echo.

set CHECKS_PASSED=1

:: PI-01: Target path exists
if exist "%TARGET_DIR%\" (
    echo   [PASS] PI-01  Target path exists
) else (
    echo   [FAIL] PI-01  Target path does not exist: %TARGET_DIR%
    set CHECKS_PASSED=0
)

:: PI-02: Target is a git repo
if exist "%TARGET_DIR%\.git\" (
    echo   [PASS] PI-02  Target is a git repository
) else if exist "%TARGET_DIR%\.git" (
    echo   [PASS] PI-02  Target is a git repository (worktree)
) else (
    echo   [FAIL] PI-02  No .git directory found — not a git repository
    set CHECKS_PASSED=0
)

:: PI-03: bash available (Git for Windows / Git Bash)
where bash >nul 2>&1
if %ERRORLEVEL%==0 (
    for /f "tokens=*" %%v in ('bash --version 2^>nul ^| head -1') do (
        echo   [PASS] PI-03  bash available: %%v
    )
) else (
    echo   [FAIL] PI-03  bash not found on PATH
    echo          Install Git for Windows: https://git-scm.com/download/win
    set CHECKS_PASSED=0
)

:: PI-04: CGW source files complete
set SOURCE_OK=1
if not exist "%CGW_DIR%\scripts\git\configure.sh" set SOURCE_OK=0
if not exist "%CGW_DIR%\hooks\pre-commit"          set SOURCE_OK=0
if not exist "%CGW_DIR%\skill\SKILL.md"            set SOURCE_OK=0
if not exist "%CGW_DIR%\command\auto-git-workflow.md" set SOURCE_OK=0

if "%SOURCE_OK%"=="1" (
    echo   [PASS] PI-04  CGW source files complete
) else (
    echo   [FAIL] PI-04  CGW source missing required files
    echo          Expected: scripts\git\configure.sh, hooks\pre-commit,
    echo                    skill\SKILL.md, command\auto-git-workflow.md
    echo          Ensure you cloned the full repository.
    set CHECKS_PASSED=0
)

:: PI-05: Existing CGW install detection (non-fatal — ask to overwrite)
set REINSTALL=0
if exist "%TARGET_DIR%\scripts\git\configure.sh" (
    echo   [WARN] PI-05  CGW scripts already present in target
    set /p "OVERWRITE=          Overwrite existing installation? [y/N]: "
    if /i "!OVERWRITE!"=="y" (
        echo          Proceeding with overwrite.
        set REINSTALL=1
    ) else (
        echo          Aborting. Run with a clean target or choose overwrite.
        goto :end
    )
) else (
    echo   [PASS] PI-05  No existing CGW installation
)

:: PI-06: Existing .githooks/pre-commit (informational)
if exist "%TARGET_DIR%\.githooks\pre-commit" (
    echo   [WARN] PI-06  Existing .githooks\pre-commit found
    echo          It will be backed up to .githooks\pre-commit.bak
) else (
    echo   [INFO] PI-06  No existing .githooks\pre-commit
)

echo.

:: Abort if hard checks failed
if "%CHECKS_PASSED%"=="0" (
    echo   One or more required checks failed. Installation aborted.
    echo.
    goto :end
)

:: ─── Confirm ────────────────────────────────────────
echo --- Installation Summary ---
echo.
echo   Will copy into: %TARGET_DIR%
echo     scripts\git\    (15 shell scripts)
echo     hooks\          (pre-commit template)
echo     skill\          (Claude Code skill source)
echo     command\        (slash command source)
echo     cgw.conf.example (config reference)
echo.
echo   Then run: configure.sh (interactive)
echo   Finally:  offer to remove temp files (hooks\, skill\, command\)
echo.
set /p "CONFIRM=Proceed with installation? [Y/n]: "
if /i "%CONFIRM%"=="n" (
    echo   Installation cancelled.
    goto :end
)
if /i "%CONFIRM%"=="no" (
    echo   Installation cancelled.
    goto :end
)

echo.

:: ─── Backup existing .githooks/pre-commit ───────────
if exist "%TARGET_DIR%\.githooks\pre-commit" (
    copy /y "%TARGET_DIR%\.githooks\pre-commit" "%TARGET_DIR%\.githooks\pre-commit.bak" >nul
    echo   Backed up .githooks\pre-commit → .githooks\pre-commit.bak
)

:: ─── Copy files ─────────────────────────────────────
echo --- Copying Files ---
echo.

:: scripts/git/
if not exist "%TARGET_DIR%\scripts\git\" mkdir "%TARGET_DIR%\scripts\git\"
xcopy /y /q "%CGW_DIR%\scripts\git\*.sh" "%TARGET_DIR%\scripts\git\" >nul
if %ERRORLEVEL%==0 (
    for /f %%c in ('dir /b "%TARGET_DIR%\scripts\git\*.sh" 2^>nul ^| find /c ".sh"') do (
        echo   [OK] Copied %%c scripts to scripts\git\
    )
) else (
    echo   [ERR] Failed to copy scripts\git\
    goto :end
)

:: hooks/
if not exist "%TARGET_DIR%\hooks\" mkdir "%TARGET_DIR%\hooks\"
copy /y "%CGW_DIR%\hooks\pre-commit" "%TARGET_DIR%\hooks\pre-commit" >nul
if %ERRORLEVEL%==0 (
    echo   [OK] Copied hooks\pre-commit template
) else (
    echo   [ERR] Failed to copy hooks\pre-commit
    goto :end
)

:: skill/
if not exist "%TARGET_DIR%\skill\" mkdir "%TARGET_DIR%\skill\"
xcopy /y /q /e "%CGW_DIR%\skill\" "%TARGET_DIR%\skill\" >nul
if %ERRORLEVEL%==0 (
    echo   [OK] Copied skill\
) else (
    echo   [ERR] Failed to copy skill\
    goto :end
)

:: command/
if not exist "%TARGET_DIR%\command\" mkdir "%TARGET_DIR%\command\"
xcopy /y /q /e "%CGW_DIR%\command\" "%TARGET_DIR%\command\" >nul
if %ERRORLEVEL%==0 (
    echo   [OK] Copied command\
) else (
    echo   [ERR] Failed to copy command\
    goto :end
)

:: cgw.conf.example (optional)
if exist "%CGW_DIR%\cgw.conf.example" (
    copy /y "%CGW_DIR%\cgw.conf.example" "%TARGET_DIR%\cgw.conf.example" >nul
    echo   [OK] Copied cgw.conf.example
)

:: ─── Convert path for bash ──────────────────────────
:: Git Bash (MSYS2) handles Windows paths with forward slashes natively
set "TARGET_FWD=%TARGET_DIR:\=/%"

:: Ensure .sh files are executable (needed by Git Bash on Windows)
bash -c "chmod +x '%TARGET_FWD%/scripts/git/'*.sh 2>/dev/null" >nul 2>&1

echo.

:: ─── Run configure.sh ────────────────────────────────
echo --- Running configure.sh ---
echo.
echo   configure.sh will auto-detect your branches, lint tool, and
echo   local-only files. You can confirm or override each setting.
echo.
bash -c "cd '%TARGET_FWD%' && bash scripts/git/configure.sh"
set CONFIGURE_EXIT=%ERRORLEVEL%

echo.
if %CONFIGURE_EXIT%==0 (
    echo   configure.sh completed successfully.
) else (
    echo   [WARN] configure.sh exited with code %CONFIGURE_EXIT%
    echo   Installation may be incomplete. Check output above.
)

:: ─── Cleanup temp files ──────────────────────────────
echo.
echo --- Post-Install Cleanup ---
echo.
echo   The following directories were needed only during installation
echo   and can be safely removed from the target project:
echo     %TARGET_DIR%\hooks\
echo     %TARGET_DIR%\skill\
echo     %TARGET_DIR%\command\
echo.
set /p "CLEANUP=Remove temporary install files? [Y/n]: "
if /i not "%CLEANUP%"=="n" if /i not "%CLEANUP%"=="no" (
    if exist "%TARGET_DIR%\hooks\"   rmdir /s /q "%TARGET_DIR%\hooks\"
    if exist "%TARGET_DIR%\skill\"   rmdir /s /q "%TARGET_DIR%\skill\"
    if exist "%TARGET_DIR%\command\" rmdir /s /q "%TARGET_DIR%\command\"
    echo   Removed hooks\, skill\, command\
)

:: ─── Summary ─────────────────────────────────────────
echo.
echo ===================================================
echo   Installation Complete
echo ===================================================
echo.

if exist "%TARGET_DIR%\scripts\git\commit_enhanced.sh" (
    for /f %%c in ('dir /b "%TARGET_DIR%\scripts\git\*.sh" 2^>nul ^| find /c ".sh"') do (
        echo   Scripts:      %TARGET_DIR%\scripts\git\ (%%c files)
    )
)
if exist "%TARGET_DIR%\.cgw.conf" (
    echo   Config:       %TARGET_DIR%\.cgw.conf
)
if exist "%TARGET_DIR%\.git\hooks\pre-commit" (
    echo   Git hook:     %TARGET_DIR%\.git\hooks\pre-commit
)
if exist "%TARGET_DIR%\.claude\skills\auto-git-workflow\SKILL.md" (
    echo   Claude skill: %TARGET_DIR%\.claude\skills\auto-git-workflow\
)
if exist "%TARGET_DIR%\.claude\commands\auto-git-workflow.md" (
    echo   Slash cmd:    %TARGET_DIR%\.claude\commands\auto-git-workflow.md
)

echo.
echo   Quick start (from your project root in Git Bash):
echo     bash scripts/git/commit_enhanced.sh "feat: your feature"
echo.

:end
echo.
pause
endlocal
