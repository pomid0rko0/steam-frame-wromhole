@echo off
rem Copies Wormhole VR's logs from the Steam Frame into Downloads as one text file, to attach to the chat.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0frame_logs.ps1" %*
pause
