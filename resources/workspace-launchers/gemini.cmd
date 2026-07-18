@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"

rem Lightweight workspace check only.
if not exist "%~dp0project.yaml" (
  echo ERR project.yaml was not found.
  exit /b 2
)

if not exist "%~dp0AGENTS.md" (
  echo ERR AGENTS.md was not found.
  exit /b 2
)

if not exist "%~dp0guide\profile-system-prompt.md" (
  echo ERR guide\profile-system-prompt.md was not found.
  exit /b 2
)

rem Find the global Gemini CLI, excluding this launcher.
set "GEMINI_CLI="

for /f "delims=" %%G in ('where.exe gemini.cmd 2^>nul') do (
  if /I not "%%~fG"=="%~f0" (
    if not defined GEMINI_CLI set "GEMINI_CLI=%%~fG"
  )
)

if not defined GEMINI_CLI (
  for /f "delims=" %%G in ('where.exe gemini.exe 2^>nul') do (
    if not defined GEMINI_CLI set "GEMINI_CLI=%%~fG"
  )
)

if not defined GEMINI_CLI (
  echo ERR Gemini CLI was not found in PATH.
  exit /b 127
)

call "%GEMINI_CLI%" %*
exit /b %ERRORLEVEL%
