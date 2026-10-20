@echo off
setlocal EnableExtensions
title Strata
cd /d "%~dp0"
rem One launcher for every model. It asks four questions and starts the server in this window.
rem Anything you type here goes to launcher\start.ps1, e.g.  CustomStartScript.bat -Model iq3_s -Online -Vision
rem   -Parallel 2  answers up to 2 prompts at the same time instead of one (1 = one at a time, docs\BATCHING.md)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\start.ps1" %*
if errorlevel 1 (
  echo.
  echo The launcher stopped with an error.
  pause
  exit /b 1
)
endlocal
