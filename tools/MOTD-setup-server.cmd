@echo off
rem One-time message of the day setup on the Realms server (the MOTD window's Set up server button runs this):
rem the motd table, the admin token from tools\motd-token.txt as the MOTD_TOKEN secret, then deploy realms-backend.
rem Safe to run again (the table step skips an existing table; the token and the code are replaced).
cd /d "%~dp0..\realms-backend" || goto fail
if not exist "%~dp0motd-token.txt" (echo tools\motd-token.txt is missing - press Make token in the MOTD window first & goto fail)

echo [1/3] the motd table
call npx wrangler d1 execute surrounsync-realms --remote --file migrations/2026-10-30-motd.sql || goto fail

echo.
echo [2/3] the admin token (read from tools\motd-token.txt, not shown)
type "%~dp0motd-token.txt" | npx wrangler secret put MOTD_TOKEN || goto fail

echo.
echo [3/3] deploy realms-backend
call npx wrangler deploy || goto fail

echo.
echo Done. Press Refresh in the MOTD window.
pause
exit /b 0

:fail
echo.
echo FAILED - see the message above. The steps after it did not run.
pause
exit /b 1
