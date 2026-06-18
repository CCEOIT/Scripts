@echo off
title CenterState CEO -- Install Student Cleanup Script
echo.
echo  ============================================================
echo   CenterState CEO -- Student Cleanup One-Time Install
echo  ============================================================
echo.
echo  This will copy the cleanup scripts to C:\Scripts and create
echo  a shortcut on the Desktop for easy access going forward.
echo.
echo  Run this once per machine from the flash drive.
echo.
pause

:: Create C:\Scripts if it doesn't exist
if not exist "C:\Scripts" (
    mkdir "C:\Scripts"
    echo  Created C:\Scripts
)

:: Copy both scripts
copy /y "%~dp0StudentCleanup.ps1"     "C:\Scripts\StudentCleanup.ps1"       >nul
copy /y "%~dp0LaunchStudentCleanup.bat" "C:\Scripts\LaunchStudentCleanup.bat" >nul
echo  Files copied to C:\Scripts.

:: Create a desktop shortcut for the P2A user
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('C:\Users\P2A\Desktop\Student Cleanup.lnk'); $s.TargetPath = 'C:\Scripts\LaunchStudentCleanup.bat'; $s.WorkingDirectory = 'C:\Scripts'; $s.Description = 'Pathways Surface Wipe'; $s.Save()"

echo  Shortcut created on P2A Desktop.
echo.
echo  ============================================================
echo   Install complete. You can remove the flash drive.
echo   Future cleanups: double-click "Student Cleanup" on Desktop
echo  ============================================================
echo.
pause
