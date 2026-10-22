
@echo off
setlocal
title OpenCode + Strata Setup

REM Use dragged folder or current working directory.
set "PROJECT_DIR=%~1"
if not defined PROJECT_DIR set "PROJECT_DIR=%CD%"

if not exist "%PROJECT_DIR%\" (
    echo ERROR: Project folder does not exist:
    echo "%PROJECT_DIR%"
    pause
    exit /b 1
)

where opencode >nul 2>nul
if errorlevel 1 (
    echo ERROR: OpenCode was not found on PATH.
    pause
    exit /b 1
)

echo.
echo Project: "%PROJECT_DIR%"
echo Checking Strata API...

set "STRATA_MODEL="
for /f "usebackq delims=" %%M in (`powershell -NoProfile -Command "try { $r=Invoke-RestMethod 'http://127.0.0.1:8080/v1/models' -TimeoutSec 5; if (-not $r.data -or -not $r.data[0].id) { exit 1 }; [Console]::WriteLine([string]$r.data[0].id) } catch { exit 1 }"`) do set "STRATA_MODEL=%%M"

if not defined STRATA_MODEL (
    echo ERROR: Could not detect a model from Strata.
    echo Start Strata and try again.
    pause
    exit /b 1
)

echo Detected model: %STRATA_MODEL%

set "CONFIG=%PROJECT_DIR%\opencode.json"

REM Update existing JSON or create a new config.
REM Compatible with Windows PowerShell 5.1.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference='Stop';" ^
 "$m=$env:STRATA_MODEL; $p=$env:CONFIG;" ^
 "if (Test-Path -LiteralPath $p) { $c=Get-Content -Raw -LiteralPath $p | ConvertFrom-Json } else { $c=New-Object PSObject };" ^
 "if (-not $c) { $c=New-Object PSObject };" ^
 "if (-not $c.PSObject.Properties['$schema']) { $c | Add-Member -MemberType NoteProperty -Name '$schema' -Value 'https://opencode.ai/config.json' } else { $c.'$schema'='https://opencode.ai/config.json' };" ^
 "if (-not $c.PSObject.Properties['providers'] -or -not $c.providers) { $c | Add-Member -MemberType NoteProperty -Name providers -Value (New-Object PSObject) };" ^
 "$providers=$c.providers;" ^
 "if (-not $providers.PSObject.Properties['strata'] -or -not $providers.strata) { $providers | Add-Member -MemberType NoteProperty -Name strata -Value (New-Object PSObject) };" ^
 "$s=$providers.strata;" ^
 "foreach ($pair in @(@('name','Strata (local)'),@('package','@opencode/ai/providers/openai-compatible'))) { $prop=$s.PSObject.Properties[$pair[0]]; if ($prop) { $s.($pair[0])=$pair[1] } else { $s | Add-Member -MemberType NoteProperty -Name $pair[0] -Value $pair[1] } };" ^
 "if (-not $s.PSObject.Properties['settings'] -or -not $s.settings) { $s | Add-Member -MemberType NoteProperty -Name settings -Value (New-Object PSObject) };" ^
 "foreach ($pair in @(@('baseURL','http://127.0.0.1:8080/v1'),@('apiKey','none'))) { $prop=$s.settings.PSObject.Properties[$pair[0]]; if ($prop) { $s.settings.($pair[0])=$pair[1] } else { $s.settings | Add-Member -MemberType NoteProperty -Name $pair[0] -Value $pair[1] } };" ^
 "if (-not $s.PSObject.Properties['models'] -or -not $s.models) { $s | Add-Member -MemberType NoteProperty -Name models -Value (New-Object PSObject) };" ^
 "$mc=[PSCustomObject]@{ name=('Strata: '+$m); modelID=$m; limit=[PSCustomObject]@{ context=262144; output=32768 }; capabilities=[PSCustomObject]@{ tools=$true; input=@('text'); output=@('text') } };" ^
 "$mp=$s.models.PSObject.Properties[$m]; if ($mp) { $s.models.($m)=$mc } else { $s.models | Add-Member -MemberType NoteProperty -Name $m -Value $mc };" ^
 "$qualified='strata/'+$m; if ($c.PSObject.Properties['model']) { $c.model=$qualified } else { $c | Add-Member -MemberType NoteProperty -Name model -Value $qualified };" ^
 "$json=ConvertTo-Json -InputObject $c -Depth 50;" ^
 "Set-Content -LiteralPath $p -Value $json -Encoding UTF8;"

if errorlevel 1 (
    echo.
    echo ERROR: Config update failed. OpenCode was not started.
    pause
    exit /b 1
)

echo.
echo Config updated: "%CONFIG%"
echo Active Strata model: %STRATA_MODEL%
echo Starting OpenCode...
echo.

cd /d "%PROJECT_DIR%"
opencode

set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo OpenCode exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
