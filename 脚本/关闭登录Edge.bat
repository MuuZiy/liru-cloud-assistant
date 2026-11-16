@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 砺儒云课堂 - 断开 Edge 接管
echo 请先停止任务。本操作只断开接管，不关闭 Edge 或删除浏览器资料。
set "PY=%~dp0runtime\python\python.exe"
if not exist "%PY%" set "PY=python"
"%PY%" -X utf8 "%~dp0edge_attach.py" --disconnect
pause
