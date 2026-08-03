@echo off
REM Run the Daseeki-Conduit self-test harness under real Lua 5.1.
REM Reuses the interpreter vendored with the Nexus harness (no second copy).
REM Usage: run-selftests.cmd [CONDUIT_DIR]
setlocal
set HERE=%~dp0
REM DASEEKI_LUA51 overrides the search when the repo is checked out somewhere the
REM sibling layout does not hold (a git worktree under %TEMP%, for instance) -- an
REM agent running the gates from a worktree needs a way to point at the interpreter.
set LUA=%DASEEKI_LUA51%
if "%LUA%"=="" set LUA=%HERE%..\..\nexus-test-harness\lua51\lua5.1.exe
if not exist "%LUA%" set LUA=%HERE%..\..\..\nexus-test-harness\lua51\lua5.1.exe
if not exist "%LUA%" set LUA=%HERE%..\..\..\..\nexus-test-harness\lua51\lua5.1.exe
if not exist "%LUA%" (
  echo ERROR: lua5.1.exe not found. Expected under a sibling nexus-test-harness\lua51\
  echo        Set DASEEKI_LUA51 to its full path and re-run.
  exit /b 2
)
set CDTDIR=%~1
if "%CDTDIR%"=="" set CDTDIR=%HERE%..
"%LUA%" "%HERE%run-selftests.lua" "%CDTDIR%"
exit /b %ERRORLEVEL%
