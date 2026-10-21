@echo off
setlocal EnableExtensions
title Strata
cd /d "%~dp0"
rem One launcher for every model. It asks about model, network, internet search, vision, context, and prompt parallelism.
rem Anything you type here goes to launcher\start.ps1, e.g.  CustomStartScript.bat -Model iq3_s -Online -InternetSearch -Vision
rem   -NoInternetSearch  skip Docker + SearXNG startup and run without the internet search tool
rem   -Parallel 2  answers up to 2 prompts at the same time instead of one (1 = one at a time, docs\BATCHING.md)
rem   -Context 64k  how many tokens one prompt can see (--max-context; 64k = 65536; remembered per model)
rem   -LogOutputFile logs\run.log  copy the full server output (stdout+stderr) to a file
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\start.ps1" %*
if errorlevel 1 (
  echo.
  echo The launcher stopped with an error.
  pause
  exit /b 1
)
endlocal
