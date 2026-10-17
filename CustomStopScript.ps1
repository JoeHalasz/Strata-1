# CustomStopScript.ps1
# The opposite of CustomStartScript.ps1: closes everything that script leaves running.
# Order is the reverse of the startup - notifier, Strata server, engine, launcher window,
# SearXNG containers, Docker Desktop - and every step says what it found.
# Windows PowerShell 5.1 compatible.

param(
    [switch]$DryRun,        # report what would be stopped, change nothing
    [switch]$KeepDocker,    # leave Docker Desktop running
    [switch]$KeepSearxng,   # leave the SearXNG containers running
    [switch]$StopOnly,      # "docker compose stop" instead of "down" (keeps the containers)
    [switch]$NoPause        # don't wait for Enter at the end
)

$ErrorActionPreference = "Stop"

# Configuration - the same values CustomStartScript.ps1 uses.
$SearxngDir = "$HOME\searxng"
$SearxngPort = 8888
$StrataDir = "$HOME\OneDrive\Documents\Strata"
$StrataPort = 8080
$NotifierName = "StrataStatusNotifier.ps1"
$KillWaitSeconds = 8
$PortFreeWaitSeconds = 15
$DockerStopTimeoutSeconds = 120
$DockerEngineWaitSeconds = 90

$script:Results = @()
$script:Failures = 0

function Add-Result {
    param(
        [string]$Item,
        [string]$Detail,
        [string]$Result
    )

    $script:Results += [PSCustomObject]@{
        Item   = $Item
        Detail = $Detail
        Result = $Result
    }

    $Color = "DarkGray"
    if ($Result -eq "Stopped" -or $Result -eq "Verified") { $Color = "Green" }
    elseif ($Result -eq "Would stop") { $Color = "Yellow" }
    elseif ($Result -eq "FAILED") { $Color = "Red" }

    Write-Host ("  {0,-17} {1} ({2})" -f $Item, $Detail, $Result) -ForegroundColor $Color
}

function Test-Docker {
    try {
        docker info *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-Searxng {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$SearxngPort/search?q=startup-check&format=json" -TimeoutSec 4
        return ($null -ne $r.results)
    } catch {
        return $false
    }
}

function Test-PortListening {
    param([int]$Port)

    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

# Native commands write progress on stderr; PowerShell 5.1 turns that into an error
# record while ErrorActionPreference is Stop, so run them with Continue.
function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$Arguments = @()
    )

    $Previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $Out = & $Exe @Arguments 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = (($Out | Out-String).Trim())
        }
    }
    finally {
        $ErrorActionPreference = $Previous
    }
}

function Get-MatchProcess {
    param(
        [string[]]$Names,
        [string[]]$CommandLike = @("*")
    )

    # Several command-line patterns are OR-ed, so the server step can match both the
    # backslash and the forward-slash spelling of serve/server.py without also catching
    # look-alikes such as serve/test_server.py.
    $Found = @()

    foreach ($Proc in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($Names -notcontains $Proc.Name) { continue }
        if ($Proc.ProcessId -eq $PID) { continue }

        foreach ($Pattern in $CommandLike) {
            if ($Proc.CommandLine -like $Pattern) {
                $Found += $Proc
                break
            }
        }
    }

    return $Found
}
function Stop-MatchProcess {
    param(
        [string]$Item,
        [object[]]$Processes
    )

    $List = @($Processes)

    if ($List.Count -eq 0) {
        Add-Result -Item $Item -Detail "not running" -Result "Skipped"
        return
    }

    foreach ($Proc in $List) {
        Write-Host ("      PID {0,-6} {1}" -f $Proc.ProcessId, $Proc.Name)
    }

    if ($DryRun) {
        Add-Result -Item $Item -Detail "$($List.Count) process(es)" -Result "Would stop"
        return
    }

    # A hard stop is what closing the console window does, and serve/winjob.py ties the
    # engine, the vision encoder and the MCP helpers to the server's own lifetime, so
    # they end with it. Anything left over is caught by the engine step below.
    foreach ($Proc in $List) {
        try {
            Stop-Process -Id $Proc.ProcessId -Force -ErrorAction Stop
        }
        catch {
            Write-Host ("      could not stop PID {0}: {1}" -f $Proc.ProcessId, $_.Exception.Message) `
                -ForegroundColor Yellow
        }
    }

    $Deadline = (Get-Date).AddSeconds($KillWaitSeconds)
    $Alive = @()

    while ((Get-Date) -lt $Deadline) {
        $Alive = @($List | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        if ($Alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }

    if ($Alive.Count -eq 0) {
        Add-Result -Item $Item -Detail "$($List.Count) process(es)" -Result "Stopped"
    }
    else {
        $script:Failures += 1
        Add-Result -Item $Item -Detail "$($Alive.Count) of $($List.Count) still alive" -Result "FAILED"
    }
}

function Wait-PortFree {
    param([int]$Port)

    $Deadline = (Get-Date).AddSeconds($PortFreeWaitSeconds)

    while ((Test-PortListening -Port $Port) -and (Get-Date) -lt $Deadline) {
        Start-Sleep -Milliseconds 500
    }

    if (Test-PortListening -Port $Port) {
        $script:Failures += 1
        Add-Result -Item "Port $Port" "still listening" -Result "FAILED"
    }
    else {
        Add-Result -Item "Port $Port" "free" -Result "Verified"
    }
}

Write-Host "`n=== Stopping Strata + SearXNG ===" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "DRY RUN - nothing will be stopped." -ForegroundColor Yellow
}

# 1. The status notifier first, so it can't alert while the server disappears.
Write-Host "`nStatus notifier..." -ForegroundColor Cyan
Stop-MatchProcess -Item "Notifier" -Processes (
    Get-MatchProcess -Names @("powershell.exe", "pwsh.exe") -CommandLike "*$NotifierName*"
)

# 2. The server. .venv\Scripts\python.exe is a launcher, so the venv process and the
#    real interpreter it started are both running and both have to go.
Write-Host "`nStrata server..." -ForegroundColor Cyan
Stop-MatchProcess -Item "Strata server" -Processes (
    Get-MatchProcess -Names @("python.exe", "pythonw.exe", "python3.exe") `
        -CommandLike @("*serve\server.py*", "*serve/server.py*")
)

# 3. Engine processes, in case the server ended on its own and left them behind.
Write-Host "`nStrata engine..." -ForegroundColor Cyan
Stop-MatchProcess -Item "Strata engine" -Processes (
    Get-MatchProcess -Names @("strata.exe", "strata-device.exe")
)

# 4. The launcher console window, which waits at "Press any key" once the server ends.
Write-Host "`nLauncher window..." -ForegroundColor Cyan
Stop-MatchProcess -Item "Launcher window" -Processes (
    Get-MatchProcess -Names @("cmd.exe") -CommandLike "*$StrataDir*run-*.bat*"
)

if ($DryRun) {
    if (Test-PortListening -Port $StrataPort) {
        Add-Result -Item "Port $StrataPort" "listening" -Result "Would stop"
    }
    else {
        Add-Result -Item "Port $StrataPort" "already free" -Result "Skipped"
    }
}
else {
    Wait-PortFree -Port $StrataPort
}
# 5. SearXNG: "docker compose down" is the reverse of the start script's "up -d".
#    Named volumes (the search cache) are kept, so the next start is warm.
Write-Host "`nSearXNG..." -ForegroundColor Cyan

if ($KeepSearxng) {
    Add-Result -Item "SearXNG" "-KeepSearxng" -Result "Skipped"
}
elseif (!(Get-Command docker -ErrorAction SilentlyContinue)) {
    $script:Failures += 1
    Add-Result -Item "SearXNG" "docker command not found" -Result "FAILED"
}
elseif (!(Test-Path "$SearxngDir\docker-compose.yml")) {
    $script:Failures += 1
    Add-Result -Item "SearXNG" "no compose file in $SearxngDir" -Result "FAILED"
}
else {
    $Running = Invoke-Native -Exe "docker" `
        -Arguments @("ps", "--filter", "name=searxng", "--format", "{{.Names}}")
    $Names = @($Running.Output -split "\r?\n" | Where-Object { $_.Trim() -ne "" })

    if ($Running.ExitCode -ne 0) {
        $script:Failures += 1
        Add-Result -Item "SearXNG" "docker ps failed: $($Running.Output)" -Result "FAILED"
    }
    elseif ($Names.Count -eq 0) {
        Add-Result -Item "SearXNG" "no containers running" -Result "Skipped"
    }
    elseif ($DryRun) {
        Add-Result -Item "SearXNG" ($Names -join ", ") -Result "Would stop"
    }
    else {
        $ComposeArgs = if ($StopOnly) {
            @("compose", "stop")
        }
        else {
            @("compose", "down", "--remove-orphans")
        }

        Write-Host ("      docker {0}" -f ($ComposeArgs -join " "))

        Push-Location $SearxngDir
        try {
            $Compose = Invoke-Native -Exe "docker" -Arguments $ComposeArgs
        }
        finally {
            Pop-Location
        }

        if ($Compose.ExitCode -eq 0) {
            Add-Result -Item "SearXNG" ($Names -join ", ") -Result "Stopped"
        }
        else {
            $script:Failures += 1
            Add-Result -Item "SearXNG" $Compose.Output -Result "FAILED"
        }

        # Verify with the same HTTP probe the start script waits on: it must stop answering.
        $Deadline = (Get-Date).AddSeconds($PortFreeWaitSeconds)

        while ((Test-Searxng) -and (Get-Date) -lt $Deadline) {
            Start-Sleep -Milliseconds 500
        }

        if (Test-Searxng) {
            $script:Failures += 1
            Add-Result -Item "SearXNG HTTP" "still answering on $SearxngPort" -Result "FAILED"
        }
        else {
            Add-Result -Item "SearXNG HTTP" "no longer answering" -Result "Verified"
        }
    }
}

# 6. Docker Desktop last - the containers above still need its engine while they stop.
Write-Host "`nDocker Desktop..." -ForegroundColor Cyan

if ($KeepDocker) {
    Add-Result -Item "Docker Desktop" "-KeepDocker" -Result "Skipped"
}
elseif (!(Test-Docker)) {
    Add-Result -Item "Docker Desktop" "engine not running" -Result "Skipped"
}
elseif ($DryRun) {
    Add-Result -Item "Docker Desktop" "engine running" -Result "Would stop"
}
else {
    Write-Host "      docker desktop stop"
    $Stop = Invoke-Native -Exe "docker" `
        -Arguments @("desktop", "stop", "--timeout", "$DockerStopTimeoutSeconds")

    if ($Stop.ExitCode -ne 0) {
        Write-Host "      'docker desktop stop' did not finish cleanly, closing it directly." `
            -ForegroundColor Yellow
        Stop-Process -Name "Docker Desktop", "com.docker.backend" -Force -ErrorAction SilentlyContinue
    }

    $Deadline = (Get-Date).AddSeconds($DockerEngineWaitSeconds)

    while ((Test-Docker) -and (Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds 2
        Write-Host "      waiting for the Docker engine to stop..."
    }

    if (Test-Docker) {
        $script:Failures += 1
        Add-Result -Item "Docker Desktop" "engine still up" -Result "FAILED"
    }
    else {
        Add-Result -Item "Docker Desktop" "engine stopped" -Result "Stopped"
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$script:Results | Format-Table -AutoSize | Out-String -Width 130 | Write-Host

Write-Host "Left alone: your editor's MCP helpers (for example npx mcp-searxng) and any browser tab Strata opened." `
    -ForegroundColor DarkGray

$ExitCode = 0

if ($DryRun) {
    Write-Host "`nDry run: nothing was stopped." -ForegroundColor Yellow
}
elseif ($script:Failures -gt 0) {
    Write-Host "`n$($script:Failures) step(s) did not finish. Run CustomStopScript.bat again to retry." `
        -ForegroundColor Red
    $ExitCode = 1
}
else {
    Write-Host "`nEverything CustomStartScript started is closed." -ForegroundColor Green
}

if (-not $NoPause) {
    Read-Host "`nPress Enter to close"
}

exit $ExitCode


