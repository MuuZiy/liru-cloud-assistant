@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0管理进程.ps1" -Action close
set RESULT=%ERRORLEVEL%
if not "%RESULT%"=="0" goto finish
set "PY=%~dp0runtime\python\python.exe"
if not exist "%PY%" set "PY=python"
"%PY%" -X utf8 "%~dp0edge_attach.py" --disconnect
:finish
pause
exit /b %RESULT%
