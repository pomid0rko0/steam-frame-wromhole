@echo off
rem Runs frame_screens.ps1: what it does, and its argument, its top says.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0frame_screens.ps1" %*
pause
