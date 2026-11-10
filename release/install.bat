@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Installing Claude Nexus...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File; & '%~dp0install.ps1'"
if errorlevel 1 (
  echo.
  echo Install failed. See the error above, or read README.txt.
) else (
  echo.
  echo Done. The widget should appear on your screen.
)
pause
