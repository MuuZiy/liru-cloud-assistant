@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 刷课控制台

REM 优先用包内便携 Python（对方机器不用装 Python）；找不到再用系统里已装的
set PY=%~dp0runtime\python\pythonw.exe
if not exist "%PY%" (
    where pythonw.exe >nul 2>nul
    if errorlevel 1 (
        echo [错误] 找不到 Python，无法启动控制台。
        echo        请确认 runtime\python\pythonw.exe 存在（不要删掉 runtime 文件夹）。
        echo.
        pause
        exit /b 1
    )
    set PY=pythonw.exe
)

if not exist "webui.py" (
    echo [错误] 找不到 webui.py，请确认本文件与 webui.py 在同一个文件夹。
    echo.
    pause
    exit /b 1
)

start "" "%PY%" "%~dp0webui.py"
exit /b 0
