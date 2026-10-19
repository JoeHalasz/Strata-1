<#
    start.ps1 - the menu behind run-strata.bat: pick a model, online, vision. Nothing is asked again
    on the next run: Enter takes the last choice. The configs are pre-written files (see
    launcher\make_configs.py); this only reads one and starts the server in this window.

    Switches to skip the menu (for shortcuts and scheduled starts):
        -Model iq3_s -Online -Vision      start that exact combination
        -List                             just show what is available
        -Port 8090                        use another port instead of 8080
        -DryRun                           show what would start, then stop
        -NoRefresh                        do not rewrite configs even if a base.json changed
#>
[CmdletBinding()]
param(
    [string]$Model,
    [switch]$Online,
    [switch]$Vision,
    [switch]$List,
    [switch]$DryRun,
    [switch]$NoRefresh,
    [int]$Port = 8080
)
$ErrorActionPreference = 'Stop'

$ROOT           = Split-Path -Parent $PSScriptRoot
$Configs        = Join-Path $ROOT 'configs'
$ModelsFile     = Join-Path $Configs 'models.json'
$MakeConfigs    = Join-Path $PSScriptRoot 'make_configs.py'
$LastChoiceFile = Join-Path $PSScriptRoot '.last-choice'
$Py             = Join-Path $ROOT '.venv\Scripts\python.exe'
$Server         = Join-Path $ROOT 'serve\server.py'
$Notifier       = Join-Path $ROOT 'StrataStatusNotifier.ps1'
$SearxngDir     = Join-Path $HOME 'searxng'
$SearxngUrl     = 'http://127.0.0.1:8888'
$DockerExe      = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'

function Die([string]$Message) {
    Write-Host "`n$Message" -ForegroundColor Red
    exit 1
}

function Read-JsonFile([string]$Path) {
    ([System.IO.File]::ReadAllText($Path)) | ConvertFrom-Json      # ReadAllText drops Notepad's BOM
}

# Ask with a numbered list; Enter takes the default, anything else re-asks.
function Read-Choice([string]$Title, [string[]]$Options, [int]$Default) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $Options[$i]) }
    while ($true) {
        $answer = Read-Host ('  pick 1-{0} [Enter = {1}]' -f $Options.Count, $Default)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $n = 0
        if ([int]::TryParse($answer.Trim(), [ref] $n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
        Write-Host "  that is not one of the numbers above." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- the configs are pre-written; refresh if a base.json changed
function Test-ConfigsStale {
    if (-not (Test-Path $ModelsFile)) { return $true }
    $written = (Get-Item $ModelsFile).LastWriteTime
    foreach ($base in (Get-ChildItem $Configs -Recurse -Filter 'base.json' -File)) {
        if ($base.LastWriteTime -gt $written) { return $true }
    }
    return $false
}

if (-not (Test-Path $Py)) { Die "Python not found: $Py`nRun setup first (START-HERE.bat)." }

if ($NoRefresh -or -not (Test-ConfigsStale)) {
    if (-not (Test-Path $ModelsFile)) { Die "No $ModelsFile - run: `"$Py`" `"$MakeConfigs`"" }
}
else {
    Write-Host 'Configs out of date with configs\<model>\base.json - rewriting them...' -ForegroundColor Yellow
    & $Py $MakeConfigs
    if ($LASTEXITCODE -ne 0) { Die 'make_configs.py failed.' }
}
$Catalog = Read-JsonFile $ModelsFile
if (-not $Catalog.models -or -not @($Catalog.models).Count) { Die "No models listed in $ModelsFile" }
$Catalog.models = @($Catalog.models)

if ($List) {
    foreach ($m in $Catalog.models) {
        $v = if ($m.vision) { 'yes' } else { 'no' }
        Write-Host ('  {0,-22} {1,7} ctx  {2}  vision {3}' -f $m.key, $m.context, $m.backend, $v)
    }
    exit 0
}

# ---------------------------------------------------------------- the three questions
$Last = @('', '0', '0')
if (Test-Path $LastChoiceFile) {
    $Last = (Get-Content $LastChoiceFile -First 1).Trim() -split '\|'
    if ($Last.Count -lt 3) { $Last = @('', '0', '0') }
}

$modelOptions = @($Catalog.models | ForEach-Object {
    $v = if ($_.vision) { 'vision: yes' } else { 'vision: no  (no mmproj file next to the model)' }
    '{0,-22} {1,7} ctx   {2}' -f $_.label, $_.context, $v
})
$lastIndex = [Array]::IndexOf(@($Catalog.models.key), $Last[0])
if ($Model) {
    $picked = @($Catalog.models | Where-Object { $_.key -eq $Model -or $_.label -eq $Model })
    if (-not $picked) { Die "No model `"$Model`". Available: $(@($Catalog.models.key) -join ', ')" }
    $chosen = @($picked)[0]
}
else {
    $n = Read-Choice 'Model:' $modelOptions $(if ($lastIndex -ge 0) { $lastIndex + 1 } else { 1 })
    $chosen = $Catalog.models[$n - 1]
}

$wantOnline = [bool] $Online
$wantVision = [bool] $Vision
if (-not $PSBoundParameters.ContainsKey('Online')) {
    # [bool]"0" is $true in PowerShell - compare the saved text, do not cast it.
    $wantOnline = (Read-Choice 'Reachable from other devices on your network, with web search? (starts Docker + SearXNG)' `
                               @('no  - this PC only', 'yes - listen on 0.0.0.0, start Docker + SearXNG') `
                               $(if ($Last[1] -eq '1') { 2 } else { 1 })) -eq 2
}
if (-not $chosen.vision) {
    if ($wantVision) { Write-Host "`n$($chosen.label) has no image encoder (mmproj) - starting without vision." -ForegroundColor Yellow }
    $wantVision = $false
}
elseif (-not $PSBoundParameters.ContainsKey('Vision')) {
    $wantVision = (Read-Choice 'Vision? (the model can read pictures you send it)' `
                              @('no', 'yes') $(if ($Last[2] -eq '1') { 2 } else { 1 })) -eq 2
}

$variant = $(if ($wantOnline) { 'online' } else { 'local' }) + $(if ($wantVision) { '-vision' } else { '' })
$ChosenConfig = Join-Path $Configs "$($chosen.key)\$($chosen.key)--$variant.json"
if (-not (Test-Path $ChosenConfig)) {
    Die "$ChosenConfig does not exist.`nThis model offers: $(@($chosen.variants) -join ', ')"
}
Set-Content -Path $LastChoiceFile -Value "$($chosen.key)|$([int] $wantOnline)|$([int] $wantVision)" -Encoding ASCII

$serverArgs = @('--engine', 'strata', '--config', $ChosenConfig, '--port', "$Port")
if (-not $wantOnline) { $serverArgs += '--open' }   # online opens from the phone; local opens the browser here

if ($DryRun) {
    Write-Host "`nwould run: `"$Py`" `"$Server`" $($serverArgs -join ' ')"
    Write-Host "would listen: $(if ($wantOnline) { "0.0.0.0:$Port (your whole network)" } else { "127.0.0.1:$Port (this PC only)" })"
    Write-Host "vision: $(if ($wantVision) { 'on' } else { 'off' })   Docker + SearXNG: $(if ($wantOnline) { 'yes' } else { 'no' })"
    exit 0
}

# ---------------------------------------------------------------- online: Docker + SearXNG, as the old script did
# docker answers on stderr for the ordinary cases - no daemon yet, a container being created - and
# $ErrorActionPreference='Stop' turns that into a dead script. So these ask docker with 'Continue'
# (a function-local copy) and read $LASTEXITCODE, which is docker's own answer.
function Test-DockerEngine {
    $ErrorActionPreference = 'Continue'
    docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-Searxng {
    try {
        $r = Invoke-RestMethod "$SearxngUrl/search?q=startup-check&format=json" -TimeoutSec 4
        return ($null -ne $r.results)
    } catch {
        return $false
    }
}

function Wait-Until([scriptblock]$Ready, [int]$Seconds, [string]$What) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (-not (& $Ready) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        Write-Host "  waiting for $What..."
    }
    return (& $Ready)
}

if ($wantOnline) {
    Write-Host "`n--- web search: Docker + SearXNG ---" -ForegroundColor Cyan
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Die 'Docker is not installed. Install Docker Desktop, or answer "no" to the online question.'
    }
    if (-not (Test-DockerEngine)) {
        if (-not (Test-Path $DockerExe)) { Die "Docker Desktop not found: $DockerExe" }
        Write-Host '  starting Docker Desktop...' -ForegroundColor Yellow
        Start-Process -FilePath $DockerExe -WindowStyle Minimized
        if (-not (Wait-Until { Test-DockerEngine } 180 'the Docker engine')) {
            Die 'Docker was not ready within 3 minutes.'
        }
    }
    Write-Host '  [OK] Docker is running.' -ForegroundColor Green

    if (-not (Test-Searxng)) {
        $compose = Join-Path $SearxngDir 'docker-compose.yml'
        if (-not (Test-Path $compose)) { Die "SearXNG's compose file is not at $compose" }
        Write-Host '  starting SearXNG...' -ForegroundColor Yellow
        $composeCode = 0
        Push-Location $SearxngDir
        try {
            $ErrorActionPreference = 'Continue'          # docker's progress reports go to stderr
            docker compose up -d
            $composeCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = 'Stop'
            Pop-Location
        }
        if ($composeCode -ne 0) {
            Die "docker compose up -d exited $composeCode - look in $SearxngDir with: docker compose logs --tail 80"
        }
        if (-not (Wait-Until { Test-Searxng } 120 'SearXNG')) {
            Die "SearXNG is not answering at $SearxngUrl - look in $SearxngDir with: docker compose logs --tail 80"
        }
    }
    Write-Host "  [OK] SearXNG is answering at $SearxngUrl" -ForegroundColor Green
}

# ---------------------------------------------------------------- the status notifier (online runs, as before)
if ($wantOnline -and (Test-Path $Notifier)) {
    $already = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*StrataStatusNotifier.ps1*'
    } | Select-Object -First 1
    if ($already) {
        Write-Host '  [OK] the status notifier is already running.' -ForegroundColor Green
    }
    else {
        try {
            Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                          -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Notifier`"" `
                          -WindowStyle Hidden -ErrorAction Stop
            Write-Host '  [OK] status notifier started in the background.' -ForegroundColor Green
        } catch {
            Write-Host "  warning: the notifier did not start: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------- start the server in THIS window
$Host.UI.RawUI.WindowTitle = "Strata - $($chosen.label) ($variant)"

Write-Host "`n=== Strata: $($chosen.label) - $variant ===" -ForegroundColor Cyan
Write-Host "  config   $ChosenConfig"
if ($wantOnline) {
    $ips = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' }).IPAddress)
    Write-Host "  this PC       http://127.0.0.1:$Port"
    foreach ($ip in $ips) { Write-Host "  other devices  http://${ip}:$Port" }
    Write-Host '  (no API key: the server warns about this, and about the firewall, once the model is ready)'
}
else {
    Write-Host "  this PC only  http://127.0.0.1:$Port   (the browser opens when the model is ready)"
}
Write-Host "  vision: $(if ($wantVision) { 'on' } else { 'off' })   |   stop with Ctrl+C, or CustomStopScript.bat`n"

& $Py $Server @serverArgs
exit $LASTEXITCODE
