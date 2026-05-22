@echo off
title CenterState CEO -- PC Prep
echo.
echo  ============================================================
echo   CenterState CEO -- PC Prep Launcher
echo  ============================================================
echo.
echo  This will run as Administrator and walk through all setup
echo  steps automatically.  Do not close this window.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCPrep.ps1"

echo.
echo  Script finished.  Press any key to close.
pause > nul
