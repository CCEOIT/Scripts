@echo off
title CenterState CEO -- Install Student Cleanup Script
echo.
echo  ============================================================
echo   CenterState CEO -- Student Cleanup One-Time Install
echo  ============================================================
echo.
echo  This will copy the cleanup scripts to C:\Scripts, create
echo  an Edge shortcut on the Desktop if one does not exist,
echo  then launch the cleanup as Administrator.
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
copy /y "%~dp0StudentCleanup.ps1"       "C:\Scripts\StudentCleanup.ps1"       >nul
copy /y "%~dp0LaunchStudentCleanup.bat" "C:\Scripts\LaunchStudentCleanup.bat" >nul
echo  Files copied to C:\Scripts.

:: Create Edge desktop shortcut if it doesn't already exist
if not exist "C:\Users\P2A\Desktop\Microsoft Edge.lnk" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('C:\Users\P2A\Desktop\Microsoft Edge.lnk'); $s.TargetPath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; $s.Description = 'Microsoft Edge'; $s.Save()"
    echo  Edge shortcut created on Desktop.
) else (
    echo  Edge shortcut already exists -- skipped.
)

echo.
echo  ============================================================
echo   Install complete. You can now remove the flash drive.
echo   Launching cleanup as Administrator in 5 seconds...
echo  ============================================================
echo.
timeout /t 5 >nul

:: Launch the cleanup script from C:\Scripts elevated and exit this window
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process 'C:\Scripts\LaunchStudentCleanup.bat' -Verb RunAs"
exit
