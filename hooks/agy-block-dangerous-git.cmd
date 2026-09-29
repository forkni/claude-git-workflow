: << 'EOF'
@echo off
setlocal

rem ==============================================================================
rem agy-block-dangerous-git.cmd — Windows wrapper for Antigravity PreToolUse hook
rem Part of claude-git-workflow (CGW).
rem
rem Dispatches execution of agy-block-dangerous-git.sh to Git for Windows bash.exe,
rem avoiding WSL bash (which lacks Windows path awareness and native tools).
rem
rem Windows cmd.exe executes this file directly; Unix sh skips the batch block.
rem ==============================================================================

rem 1. Resolve Git for Windows bash.exe
set "BASH_EXE="
if exist "C:\Program Files\Git\bin\bash.exe" (
    set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
) else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    set "BASH_EXE=C:\Program Files (x86)\Git\bin\bash.exe"
) else if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" (
    set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
) else (
    rem Search PATH, rejecting WSL / System32 shims
    for /f "delims=" %%B in ('where bash.exe 2^>nul') do (
        echo "%%B" | findstr /i /c:"WindowsApps" /c:"System32" >nul
        if errorlevel 1 (
            if not defined BASH_EXE set "BASH_EXE=%%B"
        )
    )
)

rem Fail open if bash cannot be found
if not defined BASH_EXE (
    echo {"decision": "allow"}
    exit /b 0
)

rem 2. Resolve agy-block-dangerous-git.sh relative to this script
set "SH_SCRIPT=%~dp0agy-block-dangerous-git.sh"
if not exist "%SH_SCRIPT%" (
    if exist "%~dp0..\hooks\agy-block-dangerous-git.sh" (
        set "SH_SCRIPT=%~dp0..\hooks\agy-block-dangerous-git.sh"
    ) else (
        echo {"decision": "allow"}
        exit /b 0
    )
)

rem 3. Execute hook script via Git Bash, streaming stdin and stdout
"%BASH_EXE%" "%SH_SCRIPT%"
exit /b %ERRORLEVEL%
EOF
# ==============================================================================
# Unix fallback if executed under sh / bash
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/agy-block-dangerous-git.sh" ]]; then
  exec bash "${SCRIPT_DIR}/agy-block-dangerous-git.sh"
else
  printf '{"decision": "allow"}\n'
  exit 0
fi
