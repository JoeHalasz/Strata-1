@echo off
title Strata coder-IQ1_M
cd /d "C:\Program Files (x86)\Strata"
"C:\Program Files (x86)\Strata\.venv\Scripts\python.exe" "C:\Program Files (x86)\Strata\serve\server.py" "--engine" "strata" "--config" "C:\Program Files (x86)\Strata\strata-coder-iq1_m.json" "--port" "8080" "--open"
if errorlevel 1 pause
