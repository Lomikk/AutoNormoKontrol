@echo off
setlocal

cd /d "%~dp0"

if not defined AIDER_MODEL (
    set "AIDER_MODEL=gemini/gemini-3.1-flash-lite"
)

where aider >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Aider was not found in PATH.
    echo.
    pause
    exit /b 1
)

if not defined GEMINI_API_KEY (
    echo [ERROR] GEMINI_API_KEY is not set.
    echo.
    echo Set it with:
    echo   setx GEMINI_API_KEY "your-api-key"
    echo.
    pause
    exit /b 1
)

if not exist "metadata.yaml" (
    echo [ERROR] metadata.yaml was not found.
    echo Expected project root:
    echo   %CD%
    echo.
    pause
    exit /b 1
)

set "SYSTEM_PROMPT=profiles\susu-hsem-ceit-coursework-v1\prompts\SYSTEM_PROMPT_SUSU_COURSEWORK.md"

if not exist "%SYSTEM_PROMPT%" (
    echo [ERROR] System prompt was not found:
    echo   %SYSTEM_PROMPT%
    echo.
    pause
    exit /b 1
)

echo Starting Aider...
echo Model: %AIDER_MODEL%
echo Repo map: 1024 tokens
echo.
echo Read-only context:
echo   metadata.yaml
echo   %SYSTEM_PROMPT%
echo.

aider ^
    --model "%AIDER_MODEL%" ^
    --map-tokens 1024 ^
    --read "metadata.yaml" ^
    --read "%SYSTEM_PROMPT%"

set "AIDER_EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%AIDER_EXIT_CODE%"=="0" (
    echo Aider exited with code %AIDER_EXIT_CODE%.
)

pause
exit /b %AIDER_EXIT_CODE%