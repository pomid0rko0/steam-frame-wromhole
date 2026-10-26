@echo off
rem Copies screenshots from the Steam Frame into Downloads as one zip, to attach to the chat.
rem frame_screens.bat 30 takes those of the last 30 days (7 without it).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0frame_screens.ps1" %*
pause
