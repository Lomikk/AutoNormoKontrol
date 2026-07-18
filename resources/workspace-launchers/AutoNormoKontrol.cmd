@echo off
setlocal
if not exist "%~dp0..\..\AutoNormoKontrol.cmd" (
  echo ERR AutoNormoKontrol engine was not found two directories above this workspace.
  echo Keep the project inside AutoNormoKontrol\Workspaces or use the central launcher.
  exit /b 2
)
call "%~dp0..\..\AutoNormoKontrol.cmd" -WorkspaceRoot "%~dp0." %*
exit /b %ERRORLEVEL%
