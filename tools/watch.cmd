@echo off
rem Session watch: double-click before (or during) a co-op / Realm session; Ctrl+C or close the window to stop.
rem Notes for later: python tools\sessionwatch.py report
python "%~dp0sessionwatch.py" %*
pause
