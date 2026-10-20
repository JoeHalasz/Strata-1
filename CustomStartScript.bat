@echo off
setlocal EnableExtensions
title Strata
cd /d "%~dp0"
rem One launcher for every model. It asks three questions and starts the server in this window.
rem Anything you type here goes to launcher\start.ps1, e.g.  run-strata.bat -Model iq3_s -Online -Vision
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\start.ps1" %*
if errorlevel 1 (
  echo.
  echo The launcher stopped with an error.
  pause
  exit /b 1
)
endlocal
