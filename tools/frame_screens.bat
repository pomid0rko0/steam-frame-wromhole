@echo off
rem Runs frame_screens.ps1 (its top says what it does and how).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0frame_screens.ps1" %*
pause
