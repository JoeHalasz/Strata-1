@echo off
title Strata unsloth-UD-Q4_K_XL
cd /d "C:\Users\jhala\OneDrive\Documents\Strata"
"C:\Users\jhala\OneDrive\Documents\Strata\.venv\Scripts\python.exe" "C:\Users\jhala\OneDrive\Documents\Strata\serve\server.py" "--engine" "strata" "--config" "C:\Users\jhala\OneDrive\Documents\Strata\strata-unsloth-ud-q4_k_xl.json" "--port" "8080" "--open"
if errorlevel 1 pause
