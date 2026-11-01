@echo off
rem Message of the day control window: double-click. What players see now, send a new message, clear it, admin token setup.
rem (the same calls on the command line: tools\motd.ps1)
start "" powershell -NoProfile -STA -WindowStyle Hidden -File "%~dp0motd-gui.ps1" %*
