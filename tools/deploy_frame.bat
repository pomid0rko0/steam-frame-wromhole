@echo off
rem Drag a wormhole_vr_*_steam_frame.zip onto this file, or double-click it for the newest one in Downloads.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_frame.ps1" %*
pause
