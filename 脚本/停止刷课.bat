@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0管理进程.ps1" -Action stop
set RESULT=%ERRORLEVEL%
pause
exit /b %RESULT%
