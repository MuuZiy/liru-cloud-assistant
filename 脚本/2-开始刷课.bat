@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 砺儒云课堂 · 开始刷课

set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe

echo ==============================================================
echo   第 2 步：开始刷课
echo --------------------------------------------------------------
echo   前置条件（在日常 Edge 中完成，且「1-接管Edge.bat」已确认成功）：
echo     * 已登录砺儒云课堂
echo     * 已打开你要开始的那一讲视频页面
echo   播放中若出现「学习确认」弹窗，沿用自动长按；未通过时提醒你本人操作。
echo   想停止：双击「停止刷课.bat」。
echo ==============================================================
echo.

if not exist "auto_course.ps1" (
    echo [错误] 找不到 auto_course.ps1
    echo        请确认本批处理与脚本文件在同一个文件夹内。
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_course.ps1"
set EXITCODE=%ERRORLEVEL%

echo.
echo --------------------------------------------------------------
echo   脚本已退出（返回码 %EXITCODE%）
echo   详细记录见同目录：运行日志.txt
echo --------------------------------------------------------------
pause
