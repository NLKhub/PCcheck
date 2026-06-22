@echo off
chcp 65001 >nul
setlocal

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Restarting with administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit
)

netsh advfirewall firewall show rule name="PCCheck-Server-8080" >nul 2>&1
if errorlevel 1 (
    netsh advfirewall firewall add rule name="PCCheck-Server-8080" protocol=TCP dir=in localport=8080 action=allow >nul 2>&1
    echo [Firewall] TCP 8080 inbound rule added.
)

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server_receive.ps1"

endlocal
pause
