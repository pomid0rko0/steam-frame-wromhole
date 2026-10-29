@echo off
rem Runs deploy_frame.ps1 (its top says what it does and how).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_frame.ps1" %*
pause
