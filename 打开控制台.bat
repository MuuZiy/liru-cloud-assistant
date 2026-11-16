@echo off
chcp 65001 >nul
call "%~dp0脚本\打开控制台.bat"
exit /b %errorlevel%
