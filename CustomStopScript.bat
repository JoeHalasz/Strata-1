@echo off
rem The opposite of CustomStartScript.bat: closes everything that script leaves running.
rem Extra switches are passed to the PowerShell script, e.g.
rem   CustomStopScript.bat -DryRun        only report what would be stopped
rem   CustomStopScript.bat -KeepDocker    leave Docker Desktop running
rem   CustomStopScript.bat -KeepSearxng   leave the SearXNG containers running
rem   CustomStopScript.bat -StopOnly      "docker compose stop" instead of "down"
rem   CustomStopScript.bat -NoPause       don't wait for Enter at the end
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CustomStopScript.ps1" %*
