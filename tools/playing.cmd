@echo off
rem Tells the test kit you are playing on this PC: while the flag is on, tools/ingame/t.sh won't start, kill
rem or re-configure any game. Double-click to switch it on/off, or: playing on | playing off
set "F=%LOCALAPPDATA%\SurrounSync\playing.txt"
if not exist "%LOCALAPPDATA%\SurrounSync" mkdir "%LOCALAPPDATA%\SurrounSync"
if /i "%~1"=="on" goto on
if /i "%~1"=="off" goto off
if exist "%F%" (goto off) else goto on
:on
echo %DATE% %TIME%> "%F%"
echo PLAYING: on - the test kit leaves your games alone.
goto end
:off
del "%F%" 2>nul
echo PLAYING: off - the test kit may use the games again.
:end
if "%~1"=="" pause
