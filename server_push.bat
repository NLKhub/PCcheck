@echo off
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server_push.ps1"
pause
