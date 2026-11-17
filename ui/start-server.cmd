@echo off
rem Starts the UI server as a normal (non-elevated) process. Used by "vpn ui" when it is run from an admin shell.
start "" /min conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\vpn.ps1" ui-server
