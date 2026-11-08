@echo off
rem Runs build-p2996-toolchain.ps1 (next to this file) without changing PowerShell's execution policy.
rem All arguments are passed through, e.g.:
rem   build-p2996-toolchain.bat -Src D:\dev\repo\clang-p2996 -Jobs 8

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-p2996-toolchain.ps1" %*
set "RC=%ERRORLEVEL%"

rem Keep the window open when started by double-clicking, so errors stay visible.
echo %cmdcmdline% | find /i "%~0" >nul && pause

exit /b %RC%