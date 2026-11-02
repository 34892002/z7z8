@echo off
rem Startup launcher for the cline-pin proxy. Closing this window stops it.
rem Keep this file ASCII-only: cmd.exe parses .cmd in the ANSI code page,
rem so UTF-8 comments get misread and can break up the following lines.
rem See README.md for details (why the reverse proxy is needed, env vars).
setlocal
cd /d "%~dp0"
node proxy.mjs
if errorlevel 1 pause
