@echo off
rem Runs frame_logs.ps1: what it does, its top says.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0frame_logs.ps1" %*
pause
