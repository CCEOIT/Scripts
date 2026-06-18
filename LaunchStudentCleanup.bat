@echo off
title CenterState CEO -- Student Cleanup

:: -----------------------------------------------------------------------
:: STEP 1 - If we are not already running from C:\Scripts, copy both files
::          there and relaunch from that location as Administrator.
::          This lets the flash drive be removed before the wipe runs.
:: -----------------------------------------------------------------------
if /i "%~dp0"=="C:\Scripts\" goto :already_in_place

echo.
echo  Copying files to C:\Scripts...
if not exist "C:\Scripts" mkdir "C:\Scripts"
copy /y "%~f0"                        "C:\Scripts\LaunchStudentCleanup.bat" >nul
copy /y "%~dp0StudentCleanup.ps1"     "C:\Scripts\StudentCleanup.ps1"       >nul
echo  Done.  You can now remove the flash drive.
echo.
echo  Relaunching from C:\Scripts as Administrator...
echo  (You may see a UAC prompt -- click Yes.)
echo.

:: Relaunch the copy in C:\Scripts elevated, then exit this instance
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process 'C:\Scripts\LaunchStudentCleanup.bat' -Verb RunAs"
exit /b

:: -----------------------------------------------------------------------
:: STEP 2 - Running from C:\Scripts as Administrator -- do the wipe
:: -----------------------------------------------------------------------
:already_in_place
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

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\StudentCleanup.ps1"

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
