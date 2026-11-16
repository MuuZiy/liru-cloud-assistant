@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 砺儒云课堂 - 接管现有 Edge
echo 请先正常打开 Edge，在 edge://inspect 左侧点 Remote debugging，允许调试连接。
echo 本工具只连接已有窗口，不新建浏览器配置；请在 Edge 中本人确认连接授权。
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_course.ps1" -AttachEdge
set RESULT=%ERRORLEVEL%
if not "%RESULT%"=="0" goto incomplete
echo 已确认接管成功。请在 Edge 中保留一个课堂标签，打开一讲后运行 2-开始刷课.bat。
goto finish
:incomplete
echo 接管尚未完成。请先在 Edge 中确认授权，再重新运行本入口。
:finish
pause
exit /b %RESULT%
