@echo off
title Strata IQ3_S
cd /d "C:\Users\jhala\OneDrive\Documents\Strata"
"C:\Users\jhala\OneDrive\Documents\Strata\.venv\Scripts\python.exe" "C:\Users\jhala\OneDrive\Documents\Strata\serve\server.py" "--engine" "strata" "--config" "C:\Users\jhala\OneDrive\Documents\Strata\strata-iq3_s.json" "--port" "8080" "--open"
if errorlevel 1 pause
