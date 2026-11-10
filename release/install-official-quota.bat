@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Installing Claude Nexus + official quota bridge...
echo This adds a statusLine entry to your Claude Code settings.json.
echo A backup is saved as settings.json.bak-claudenexus.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File; & '%~dp0install.ps1' -StatusLine"
echo.
pause
