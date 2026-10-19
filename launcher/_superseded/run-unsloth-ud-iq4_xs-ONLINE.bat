@echo off

title Strata unsloth-UD-IQ4_XS

cd /d "C:\Users\jhala\OneDrive\Documents\Strata"

"C:\Users\jhala\OneDrive\Documents\Strata\.venv\Scripts\python.exe" "C:\Users\jhala\OneDrive\Documents\Strata\serve\server.py" "--engine" "strata" "--config" "C:\Users\jhala\OneDrive\Documents\Strata\strata-unsloth-ud-iq4_xs.json" "--port" "8080" "--host" "0.0.0.0"

if errorlevel 1 pause
