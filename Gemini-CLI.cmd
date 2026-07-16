@echo off
setlocal

rem Run from the directory where this CMD file is located.
cd /d "%~dp0"

rem Check that Gemini CLI is installed.
where gemini.cmd >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Gemini CLI was not found in PATH.
    echo.
    echo Install it with:
    echo   npm.cmd install -g @google/gemini-cli
    echo.
    pause
    exit /b 1
)

rem Check API key.
if not defined GEMINI_API_KEY (
    echo [ERROR] GEMINI_API_KEY is not set.
    echo.
    echo Set it permanently:
    echo   setx GEMINI_API_KEY "your-api-key"
    echo.
    echo Then close and reopen this terminal.
    echo.
    pause
    exit /b 1
)

rem Project instructions should be stored in GEMINI.md.
if not exist "GEMINI.md" (
    echo [WARNING] GEMINI.md was not found in:
    echo   %CD%
    echo.
    echo Gemini CLI will start, but project instructions will not be loaded.
    echo.
)

echo Starting Gemini CLI...
echo Project: %CD%
echo.

gemini.cmd

set "GEMINI_EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%GEMINI_EXIT_CODE%"=="0" (
    echo Gemini CLI exited with code %GEMINI_EXIT_CODE%.
)

pause
exit /b %GEMINI_EXIT_CODE%