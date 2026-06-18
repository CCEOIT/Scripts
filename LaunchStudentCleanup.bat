@echo off
title CenterState CEO -- Student Cleanup
echo.
echo  ============================================================
echo   CenterState CEO -- Surface Go 2 Student Cleanup
echo  ============================================================
echo.
echo  This will clear all student data, reset Chrome and Edge,
echo  and disconnect any Microsoft account from the P2A profile.
echo.
echo  Make sure you are running as P2A (local admin).
echo  Do not close this window until it finishes.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StudentCleanup.ps1"

echo.
echo  ============================================================
echo   Pathways Surface Wipe Complete
echo  ============================================================
echo.
echo  This computer will restart in 15 seconds.
echo  Press any key to restart immediately.
echo.
timeout /t 15
shutdown /r /t 0
