@echo off
rem Runs deploy_frame.ps1 (drag a build's zip onto this file): what it does, its top says.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_frame.ps1" %*
pause
