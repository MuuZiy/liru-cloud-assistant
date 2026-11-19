@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title 刷课控制台

REM 优先用包内便携 Python（对方机器不用装 Python）；找不到再用系统里已装的
set "PY=%~dp0runtime\python\pythonw.exe"
if not exist "%PY%" (
    where pythonw.exe >nul 2>nul
    if errorlevel 1 (
        echo [错误] 找不到 Python，无法启动控制台。
        echo        请确认 runtime\python\pythonw.exe 存在（不要删掉 runtime 文件夹）。
        echo.
        pause
        exit /b 1
    )
    set "PY=pythonw.exe"
)

if not exist "webui.py" (
    echo [错误] 找不到 webui.py，请确认本文件与 webui.py 在同一个文件夹。
    echo.
    pause
    exit /b 1
)

set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe"
set "CURL=%SystemRoot%\System32\curl.exe"
set "CONSOLE_URL=http://127.0.0.1:8765"

if not exist "%EDGE%" goto default_browser
if not exist "%CURL%" goto default_browser

REM 等本地服务就绪后直接打开 Edge，避免依赖 Windows 的 HTTP 默认关联。
start "" "%PY%" "%~dp0webui.py" --no-open
if errorlevel 1 goto startup_failed
"%CURL%" -q --noproxy "*" --fail --silent --max-time 2 --retry 5 --retry-delay 1 --retry-max-time 8 --retry-connrefused "%CONSOLE_URL%/api/status?no_cancel=1" >nul
if errorlevel 1 goto startup_failed

start "" "%EDGE%" --new-window "%CONSOLE_URL%/"
if errorlevel 1 (
    echo [提示] 控制台已启动，请在 Edge 地址栏打开 %CONSOLE_URL%/
    pause
    exit /b 1
)
exit /b 0

:startup_failed
echo [错误] 控制台未能启动。请检查端口 8765 是否被其他程序占用。
pause
exit /b 1

:default_browser
start "" "%PY%" "%~dp0webui.py"
if errorlevel 1 goto startup_failed
exit /b 0
