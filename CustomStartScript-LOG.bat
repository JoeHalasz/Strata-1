@echo off
setlocal EnableExtensions
title Strata (logged)
cd /d "%~dp0"
rem Same launcher as CustomStartScript.bat, but always writes full server output to logs\run.log.
rem Anything else you type here is still forwarded, e.g.:
rem   CustomStartScript-LOG.bat -Model iq3_s -Online -Vision -Parallel 2 -Context 64k
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\start.ps1" -LogOutputFile "logs\run.log" %*
if errorlevel 1 (
  echo.
  echo The launcher stopped with an error.
  pause
  exit /b 1
)
endlocal
