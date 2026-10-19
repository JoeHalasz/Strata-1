# Start-Strata-Online.ps1

$ErrorActionPreference = "Stop"

# Configuration
$SearxngDir = "$HOME\searxng"
$SearxngUrl = "http://127.0.0.1:8888"
$StrataDir = "$HOME\OneDrive\Documents\Strata"
$StrataBat = "$StrataDir\run-iq3_s-ONLINE-VISION.bat"
$NotifierScript = "$StrataDir\StrataStatusNotifier.ps1"
$DockerExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

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
        $r = Invoke-RestMethod "$SearxngUrl/search?q=startup-check&format=json" -TimeoutSec 4
        return ($null -ne $r.results)
    } catch {
        return $false
    }
}

Write-Host "`n=== Starting Strata + SearXNG ===" -ForegroundColor Cyan

# Check the model launcher exists.
if (!(Test-Path $StrataBat)) {
    Write-Host "ERROR: Model launcher not found: $StrataBat" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Check Docker is installed.
if (!(Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Docker command not found. Install or repair Docker Desktop." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Start Docker Desktop if its engine isn't running.
if (!(Test-Docker)) {
    Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow

    if (!(Test-Path $DockerExe)) {
        Write-Host "ERROR: Docker Desktop not found at $DockerExe" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    Start-Process -FilePath $DockerExe -WindowStyle Minimized

    $deadline = (Get-Date).AddMinutes(3)
    while (!(Test-Docker) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        Write-Host "Waiting for Docker engine..."
    }

    if (!(Test-Docker)) {
        Write-Host "ERROR: Docker did not become ready within 3 minutes." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host "[OK] Docker is running." -ForegroundColor Green

# Start SearXNG only if its HTTP endpoint isn't responding.
if (!(Test-Searxng)) {
    Write-Host "Starting SearXNG..." -ForegroundColor Yellow

    if (!(Test-Path "$SearxngDir\docker-compose.yml")) {
        Write-Host "ERROR: Compose file not found in $SearxngDir" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    Push-Location $SearxngDir
    try {
        docker compose up -d
        if ($LASTEXITCODE -ne 0) {
            throw "Docker Compose failed to start SearXNG."
        }
    } finally {
        Pop-Location
    }

    $deadline = (Get-Date).AddSeconds(120)
    while (!(Test-Searxng) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        Write-Host "Waiting for SearXNG..."
    }
}

if (!(Test-Searxng)) {
    Write-Host "ERROR: SearXNG isn't responding at $SearxngUrl" -ForegroundColor Red
    Write-Host "Check its logs with: docker compose logs --tail 80"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "[OK] SearXNG is responding." -ForegroundColor Green

# Launch the existing model startup batch file.
Write-Host "Launching Strata and the model..." -ForegroundColor Cyan
Start-Process -FilePath $StrataBat -WorkingDirectory $StrataDir

# Start Strata status notifier in a hidden PowerShell process.
if (Test-Path $NotifierScript) {

    # Avoid starting a second copy if the notifier is already running.
    $NotifierRunning = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            $_.CommandLine -like "*StrataStatusNotifier.ps1*"
        } |
        Select-Object -First 1

    if ($NotifierRunning) {
        Write-Host "[OK] Strata notifier is already running." -ForegroundColor Green
    }
    else {
        Write-Host "Starting hidden Strata status notifier..." -ForegroundColor Cyan

        try {
            Start-Process `
                -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$NotifierScript`"" `
                -WindowStyle Hidden `
                -ErrorAction Stop

            Write-Host "[OK] Strata notifier started in the background." -ForegroundColor Green
        }
        catch {
            Write-Host "WARNING: Could not start the notifier: $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host "WARNING: Notifier script not found: $NotifierScript" `
        -ForegroundColor Yellow
}

Write-Host "`nStartup sequence complete." -ForegroundColor Green
Start-Sleep -Seconds 3