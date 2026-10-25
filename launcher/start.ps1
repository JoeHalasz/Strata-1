<#
    start.ps1 - the menu behind run-strata.bat: pick a model, online, internet search, vision, context, prompts at once,
    ntfy notifications. Nothing is
    asked again on the next run: Enter takes the last choice (the context is remembered per model, in
    launcher\.last-context). The configs are pre-written files (see launcher\make_configs.py); this reads one and
    starts the server in this window.

    Switches to skip the menu (for shortcuts and scheduled starts):
        -Model iq3_s -Online -InternetSearch -Vision  start that exact combination
        -NoOnline                         answer the network question: this PC only (127.0.0.1)
        -NoVision                         answer the vision question: no
        -NoInternetSearch                 skip Docker + SearXNG and start without the search tool
        -Context 65536                    one prompt sees that many tokens (64k and 65536 are the same)
        -Parallel 3                       answer up to 3 prompts at once instead of one (1 = one at a time)
        -LogOutputFile logs\run.log       write the full server output (stdout+stderr) to that file too
        -Notifications off                answer the notifications question: no ntfy notices at all
                                          (stops a notifier that is running)
        -Notifications on                 answer the notifications question: the status notifier
                                          always runs, even for a local-only start
        -List                             just show what is available
        -Port 8090                        use another port instead of 8080
        -DryRun                           show what would start, then stop
        -NoRefresh                        do not rewrite configs even if a base.json changed
#>
[CmdletBinding()]
param(
    [string]$Model,
    [switch]$Online,
    [switch]$NoOnline,       # answer the network question: this PC only (the opposite of -Online)
    [switch]$InternetSearch,
    [switch]$NoInternetSearch,
    [switch]$Vision,
    [switch]$NoVision,       # answer the vision question: no (the opposite of -Vision)
    [int]$Parallel,       # not given = ask; 1 = one at a time; 2 or more = that many prompts decoded together
    [string]$Context,     # not given = ask; tokens or k, so 65536 and 64k are the same thing
    [string]$LogOutputFile, # optional: copy the full server output (stdout+stderr) into this file
    [string]$Notifications, # not given = ask; on = notifier always; off = never (and stop a running one)
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
$ContextFile    = Join-Path $PSScriptRoot '.last-context'   # the context last used, one line per model
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

# ---------------------------------------------------------------- several prompts at once (docs\BATCHING.md)
# "parallel": N in the engine config is what the server reads (serve\server.py -> the engine's --batch N): up to
# N conversations decode together and the rest wait their turn. 1 or no key at all: one at a time, as before.
$ParallelMax     = 8              # serve\server.py PARALLEL_MAX: the engine's batch window holds at most 8
$ParallelChoices = @(1, 2, 3, 4, 6, 8)

# ---------------------------------------------------------------- how much one prompt can see
# "--max-context" in the config's args is what the server reads (serve\server.py:779). The steps are setup.py's
# CONTEXTS up to the trained length: past 262144 the engine needs rope scaling, which setup writes into the config
# and this launcher never touches - so it warns instead of quietly adding it.
$ContextSteps   = @(8192, 32768, 65536, 131072, 204800, 262144)
$TrainedContext = 262144
$ContextMin     = 1024            # below this an answer or a tool result can stop fitting mid-prompt

# "65536", "65,536", "64k", "128K" -> the number of tokens; anything else -> 0, and the caller re-asks.
function ConvertTo-Tokens([string]$Value) {
    $t = $Value.Trim().ToLower().Replace(',', '').Replace('_', '').Replace(' ', '')
    if ($t -notmatch '^([0-9]+)([km]?)$') { return 0 }
    $n = [long] $Matches[1]
    if ($Matches[2] -eq 'k') { $n *= 1024 } elseif ($Matches[2] -eq 'm') { $n *= 1048576 }
    return [Math]::Min([long] ([int]::MaxValue - 1), $n)
}

# A typed number rather than a numbered list: Enter takes the default, anything unusable re-asks.
function Read-ContextChoice([string]$Title, [int]$Default) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    $steps = @($ContextSteps | ForEach-Object { '{0}k' -f ($_ / 1024) })
    Write-Host ('  tokens or k (' + ($steps -join ', ') + '), or any number you like') -ForegroundColor DarkGray
    while ($true) {
        $answer = Read-Host ('  context [Enter = {0}]' -f $Default)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $n = ConvertTo-Tokens $answer
        if ($n -ge $ContextMin) { return [int] $n }
        Write-Host "  that is not a context length - give tokens (65536) or k (64k), $ContextMin or more." -ForegroundColor Yellow
    }
}

# What each model was last started with: launcher\.last-context, one "<model>|<tokens>" line each. It is per model
# on purpose - a 12 GB card runs a big context on iq3_s and none on a bigger file.
function Read-LastContexts {
    $saved = @{}
    if (Test-Path $ContextFile) {
        foreach ($line in (Get-Content $ContextFile)) {
            $parts = $line.Trim() -split '\|'
            if ($parts.Count -eq 2) {
                $n = 0
                if ([int]::TryParse($parts[1].Trim(), [ref] $n) -and $n -ge $ContextMin) { $saved[$parts[0].Trim()] = $n }
            }
        }
    }
    return $saved
}

function Set-LastContext([string]$Key, [int]$Tokens) {
    $saved = Read-LastContexts
    $saved[$Key] = $Tokens
    $lines = @($saved.GetEnumerator() | Sort-Object Key | ForEach-Object { '{0}|{1}' -f $_.Key, $_.Value })
    [System.IO.File]::WriteAllLines($ContextFile, $lines)
}

# The context setup wrote for this model: models.json's own, or base.json's when that is missing.
function Get-OwnContext([string]$ModelKey) {
    $base = Join-Path (Join-Path $Configs $ModelKey) 'base.json'
    if (-not (Test-Path $base)) { return 0 }
    $a = @((Read-JsonFile $base).args)
    $i = [Array]::IndexOf($a, '--max-context')
    if ($i -ge 0 -and $i -lt ($a.Count - 1)) { return [int] $a[$i + 1] }
    return 0
}

# ---------------------------------------------------------------- the file the server is started with
# The pre-written configs are never edited - a config that should say something else gets a small file next to it
# (<model>--<variant>--p2--ctx65536.json), rewritten from that config on every start. It can therefore never go
# stale, and a configs refresh is free to delete it: the next start writes it again.
function Set-EngineOverrides([string]$ConfigPath, [int]$Slots, [int]$Tokens, [bool]$EnableInternetSearch) {
    $Config  = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    $Changes = @()

    $InConfig = if ($Config.PSObject.Properties['parallel']) { [int] $Config.parallel } else { 1 }
    if ($InConfig -ne $Slots) {                                    # 1 = no key at all, exactly as before
        if ($Slots -le 1) { $Config.PSObject.Properties.Remove('parallel') }
        else { $Config | Add-Member -Force -NotePropertyName parallel -NotePropertyValue $Slots }
        $Changes += "p$Slots"
    }

    $ArgList = @($Config.args)
    $At      = [Array]::IndexOf($ArgList, '--max-context')
    $HasFlag = ($At -ge 0 -and $At -lt ($ArgList.Count - 1))
    $InArgs  = if ($HasFlag) { [int] $ArgList[$At + 1] } else { 0 }
    if ($InArgs -ne $Tokens) {
        if ($HasFlag) { $ArgList[$At + 1] = "$Tokens" } else { $ArgList += @('--max-context', "$Tokens") }
        $Config | Add-Member -Force -NotePropertyName args -NotePropertyValue $ArgList
        $Changes += "ctx$Tokens"
    }

    $hasMcpServers = $Config.PSObject.Properties['mcp_servers'] -and $null -ne $Config.mcp_servers
    $hasSearxng    = $hasMcpServers -and $Config.mcp_servers.PSObject.Properties['searxng']
    if ($EnableInternetSearch) {
        if (-not $hasMcpServers) {
            $Config | Add-Member -Force -NotePropertyName mcp_servers -NotePropertyValue ([PSCustomObject]@{})
            $hasMcpServers = $true
            $hasSearxng = $false
        }
        if (-not $hasSearxng) {
            $Config.mcp_servers | Add-Member -Force -NotePropertyName searxng -NotePropertyValue ([PSCustomObject]@{
                command = 'npx'
                args    = @('-y', 'mcp-searxng')
                env     = [PSCustomObject]@{
                    SEARXNG_URL = $SearxngUrl
                }
            })
            $Changes += 'search-on'
        }
        if (-not $Config.PSObject.Properties['mcp']) {
            $Config | Add-Member -Force -NotePropertyName mcp -NotePropertyValue ([PSCustomObject]@{
                timeout_s        = 60
                max_result_chars = 20000
                max_rounds       = 8
            })
            if (-not ($Changes -contains 'search-on')) { $Changes += 'search-on' }
        }
    }
    elseif ($hasSearxng) {
        $Config.mcp_servers.PSObject.Properties.Remove('searxng')
        if (($Config.mcp_servers.PSObject.Properties | Measure-Object).Count -eq 0) {
            $Config.PSObject.Properties.Remove('mcp_servers')
        }
        $Changes += 'search-off'
    }

    if (-not $Changes) { return $ConfigPath }                      # this config already says what is wanted
    $Derived = Join-Path (Split-Path -Parent $ConfigPath) ("{0}--{1}.json" -f `
               [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath), ($Changes -join '--'))
    [System.IO.File]::WriteAllText($Derived, ($Config | ConvertTo-Json -Depth 100))
    return $Derived
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
$SavedContext = Read-LastContexts          # the context each model was last started with: key -> tokens

# The ctx column shows what a model will actually start with: the number you last used on it (marked *), else setup's own.
function Format-ContextCell([object]$M) {
    $saved = 0
    if ($SavedContext.ContainsKey($M.key)) { $saved = $SavedContext[$M.key] }
    if ($saved -gt 0 -and $saved -ne [int] $M.context) { return "$saved*" }
    return "$($M.context)"
}

if ($List) {
    foreach ($m in $Catalog.models) {
        $v = if ($m.vision) { 'yes' } else { 'no' }
        Write-Host ('  {0,-22} {1,7} ctx  {2}  vision {3}' -f $m.key, (Format-ContextCell $m), $m.backend, $v)
    }
    Write-Host '  (* = the context you last set for that model; the menu asks again and Enter keeps it)'
    exit 0
}

# ---------------------------------------------------------------- the questions
$Last = @('', '0', '0', '1', '1')
if (Test-Path $LastChoiceFile) {
    $Last = (Get-Content $LastChoiceFile -First 1).Trim() -split '\|'
    if ($Last.Count -lt 3) { $Last = @('', '0', '0', '1') }
    if ($Last.Count -eq 3) { $Last += '1' }        # a file written before the prompts-at-once question existed
    if ($Last.Count -eq 4) { $Last += $(if ($Last[1] -eq '1') { '1' } else { '0' }) }
    if ($Last.Count -eq 5) { $Last += $(if ($Last[1] -eq '1') { '1' } else { '0' }) }   # written before the notifications question existed
}

$modelOptions = @($Catalog.models | ForEach-Object {
    $v = if ($_.vision) { 'vision: yes' } else { 'vision: no  (no image encoder: mmproj or strata-vision.exe)' }
    '{0,-22} {1,7} ctx   {2}' -f $_.label, (Format-ContextCell $_), $v
})
$lastIndex = [Array]::IndexOf(@($Catalog.models.key), $Last[0])
if ($Model) {
    $picked = @($Catalog.models | Where-Object { $_.key -eq $Model -or $_.label -eq $Model })
    if (-not $picked) { Die "No model `"$Model`". Available: $(@($Catalog.models.key) -join ', ')" }
    $chosen = @($picked)[0]
}
else {
    $n = Read-Choice 'Model:  (* = the context you last set for it)' $modelOptions `
                     $(if ($lastIndex -ge 0) { $lastIndex + 1 } else { 1 })
    $chosen = $Catalog.models[$n - 1]
}

$wantOnline = [bool] $Online
$wantInternetSearch = [bool] $InternetSearch
$wantVision = [bool] $Vision
if ($PSBoundParameters.ContainsKey('Online') -and $PSBoundParameters.ContainsKey('NoOnline')) {
    Die 'Use either -Online or -NoOnline, not both.'
}
if ($PSBoundParameters.ContainsKey('Vision') -and $PSBoundParameters.ContainsKey('NoVision')) {
    Die 'Use either -Vision or -NoVision, not both.'
}
if ($PSBoundParameters.ContainsKey('InternetSearch') -and $PSBoundParameters.ContainsKey('NoInternetSearch')) {
    Die 'Use either -InternetSearch or -NoInternetSearch, not both.'
}
if ($PSBoundParameters.ContainsKey('NoInternetSearch')) { $wantInternetSearch = $false }
if ($PSBoundParameters.ContainsKey('NoOnline')) { $wantOnline = $false }
elseif (-not $PSBoundParameters.ContainsKey('Online')) {
    # [bool]"0" is $true in PowerShell - compare the saved text, do not cast it.
    $wantOnline = (Read-Choice 'Reachable from other devices on your network?' `
                               @('no  - this PC only', 'yes - listen on 0.0.0.0') `
                               $(if ($Last[1] -eq '1') { 2 } else { 1 })) -eq 2
}
if (-not ($PSBoundParameters.ContainsKey('InternetSearch') -or $PSBoundParameters.ContainsKey('NoInternetSearch'))) {
    $wantInternetSearch = (Read-Choice 'Internet search tool? (uses Docker + SearXNG)' `
                                      @('off - skip Docker + SearXNG startup', 'on  - start Docker + SearXNG for web search') `
                                      $(if ($Last[4] -eq '1') { 2 } else { 1 })) -eq 2
}
if (-not $chosen.vision) {
    if ($wantVision) { Write-Host "`n$($chosen.label) has no image encoder (mmproj) - starting without vision." -ForegroundColor Yellow }
    $wantVision = $false
}
elseif ($PSBoundParameters.ContainsKey('NoVision')) { $wantVision = $false }
elseif (-not $PSBoundParameters.ContainsKey('Vision')) {
    $wantVision = (Read-Choice 'Vision? (the model can read pictures you send it)' `
                              @('no', 'yes') $(if ($Last[2] -eq '1') { 2 } else { 1 })) -eq 2
}

# how much one prompt can see: "--max-context" in the config's args. What you last used is kept per model
# (launcher\.last-context) and said out loud before asking, so Enter keeps it.
$OwnContext = [int] $chosen.context
if ($OwnContext -le 0) { $OwnContext = Get-OwnContext $chosen.key }
if ($OwnContext -le 0) { Die "no --max-context for $($chosen.key): run `"$Py`" `"launcher\make_configs.py`"" }
$LastContext = 0
if ($SavedContext.ContainsKey($chosen.key)) { $LastContext = $SavedContext[$chosen.key] }
if ($PSBoundParameters.ContainsKey('Context')) {
    $wantContext = ConvertTo-Tokens $Context
    if ($wantContext -lt $ContextMin) {
        Die "-Context `"$Context`" is not a context length: give tokens (65536) or k (64k), $ContextMin or more."
    }
    # said out loud, because "the config's own 131072" read like it was still in charge when
    # only the summary line mentioned it - this start's -Context is what the server gets.
    $was = if ($LastContext -gt 0) { "you last used $LastContext" } else { "setup wrote $OwnContext" }
    Write-Host "`n$($chosen.key): context $wantContext tokens as given ($was - this start overrides it)." -ForegroundColor Cyan
}
else {
    if ($LastContext -gt 0) {
        Write-Host "`n$($chosen.key): you last started it with $LastContext tokens of context (setup wrote $OwnContext for it)." -ForegroundColor Cyan
    }
    else {
        Write-Host "`n$($chosen.key): context $OwnContext tokens, what setup wrote - you have not changed it on this model yet." -ForegroundColor Cyan
    }
    $wantContext = Read-ContextChoice 'Context: how many tokens one prompt can see (the chat so far, files, tool output)' `
                                 $(if ($LastContext -gt 0) { $LastContext } else { $OwnContext })
}
if ($wantContext -gt $TrainedContext) {
    Write-Host "`n$wantContext is past the trained $TrainedContext positions: this launcher does not write rope scaling" -ForegroundColor Yellow
    Write-Host "(setup adds --rope-scaling yarn for those), so answers past 256K are out of spec." -ForegroundColor Yellow
}
if ($wantContext -gt $OwnContext) {
    Write-Host "a longer context takes VRAM from the expert cache: answers can be slower, and the start can run out of memory." -ForegroundColor DarkGray
}
if ($wantContext -lt 8192) {
    Write-Host "under 8192, the shortest setup offers: a long chat or a big tool result may stop fitting." -ForegroundColor Yellow
}

# how many prompts are answered at the same time: "parallel" in the config -> the engine's --batch N
$wantParallel = 0
if ($PSBoundParameters.ContainsKey('Parallel')) {
    $wantParallel = [Math]::Max(1, $Parallel)
}
else {
    $lastParallel = 1
    [int]::TryParse(([string] $Last[3]).Trim(), [ref] $lastParallel) | Out-Null
    $pDefault = [Array]::IndexOf($ParallelChoices, [Math]::Max(1, $lastParallel))
    if ($pDefault -lt 0) { $pDefault = 0 }
    $parallelOptions = @($ParallelChoices | ForEach-Object {
        if ($_ -eq 1) { 'one at a time - the others wait their turn' } else { '{0} at once' -f $_ }
    })
    $pTitle = 'Prompts to answer at the same time? (several users or agents at once - docs\BATCHING.md)'
    $wantParallel = $ParallelChoices[(Read-Choice $pTitle $parallelOptions ($pDefault + 1)) - 1]
}
if ($wantParallel -gt $ParallelMax) {
    Write-Host "`nthe engine runs at most $ParallelMax prompts together: it will use $ParallelMax, you asked for $wantParallel." -ForegroundColor Yellow
}
if ($wantParallel -gt 1) {
    Write-Host 'each one takes VRAM from the expert cache and costs about 10-25% speed per answer.' -ForegroundColor DarkGray
    Write-Host 'more, --batch-mtp included: docs\BATCHING.md' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- ntfy notifications, all of them in one question
# Every ntfy notice comes from the one background script (StrataStatusNotifier.ps1), so this one
# question covers all of them. off also stops a notifier left running from an earlier start, so
# off really means off. -Notifications on|off answers the question for shortcuts and scheduled starts.
if ($PSBoundParameters.ContainsKey('Notifications')) {
    $notif = $Notifications.Trim().ToLower()
    if     ($notif -in @('on', 'yes', 'true', '1'))  { $wantNotifications = $true }
    elseif ($notif -in @('off', 'no', 'false', '0')) { $wantNotifications = $false }
    else { Die "-Notifications `"$Notifications`" means nothing: use on or off." }
}
else {
    $wantNotifications = (Read-Choice 'ntfy notifications? (Strata up, idle and error notices to your phone)' `
                                      @('off - no notifications', 'on  - the status notifier sends them') `
                                      $(if ($Last[5] -eq '1') { 2 } else { 1 })) -eq 2
}

$variant = $(if ($wantOnline) { 'online' } else { 'local' }) + $(if ($wantVision) { '-vision' } else { '' })
$BaseConfig = Join-Path $Configs "$($chosen.key)\$($chosen.key)--$variant.json"
if (-not (Test-Path $BaseConfig)) {
    Die "$BaseConfig does not exist.`nThis model offers: $(@($chosen.variants) -join ', ')"
}

$ResolvedLogOutputFile = ''
if ($PSBoundParameters.ContainsKey('LogOutputFile')) {
    if ([string]::IsNullOrWhiteSpace($LogOutputFile)) {
        Die '-LogOutputFile needs a file path, for example -LogOutputFile logs\run.log'
    }
    $ResolvedLogOutputFile = $LogOutputFile.Trim()
    if (-not [System.IO.Path]::IsPathRooted($ResolvedLogOutputFile)) {
        $ResolvedLogOutputFile = Join-Path $ROOT $ResolvedLogOutputFile
    }
    $logDir = Split-Path -Parent $ResolvedLogOutputFile
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path $logDir)) {
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
    }
}

$ChosenConfig = Set-EngineOverrides $BaseConfig $wantParallel $wantContext $wantInternetSearch
Set-Content -Path $LastChoiceFile -Value "$($chosen.key)|$([int] $wantOnline)|$([int] $wantVision)|$wantParallel|$([int] $wantInternetSearch)|$([int] $wantNotifications)" -Encoding ASCII
Set-LastContext $chosen.key $wantContext

$serverArgs = @('--engine', 'strata', '--config', $ChosenConfig, '--port', "$Port")
if (-not $wantOnline) { $serverArgs += '--open' }   # online opens from the phone; local opens the browser here

if ($DryRun) {
    Write-Host "`nwould run: `"$Py`" `"$Server`" $($serverArgs -join ' ')"
    Write-Host "would listen: $(if ($wantOnline) { "0.0.0.0:$Port (your whole network)" } else { "127.0.0.1:$Port (this PC only)" })"
    Write-Host "vision: $(if ($wantVision) { 'on' } else { 'off' })   internet search: $(if ($wantInternetSearch) { 'on (Docker + SearXNG)' } else { 'off' })"
    Write-Host "context: $wantContext tokens$(if ($wantContext -ne $OwnContext) { " (setup's own is $OwnContext, overridden by this start)" })"
    Write-Host "prompts at once: $wantParallel$(if ($wantParallel -gt 1) { " (the engine's batch slots, docs\BATCHING.md)" })"
    if ($ResolvedLogOutputFile) { Write-Host "full output log: $ResolvedLogOutputFile" }
    Write-Host "ntfy notifications: $(if ($wantNotifications) { 'on (the status notifier)' } else { 'off (no status notifier)' })"
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

if ($wantInternetSearch) {
    Write-Host "`n--- web search: Docker + SearXNG ---" -ForegroundColor Cyan
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Die 'Docker is not installed. Install Docker Desktop, or turn internet search off.'
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

# ---------------------------------------------------------------- the status notifier (the notifications
# question above decides; off stops a notifier left running, so off really means off)
if ($wantNotifications -eq $false) {
    # off means off: a notifier still running from an earlier start would keep sending.
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*StrataStatusNotifier.ps1*'
    })
    if ($running.Count -gt 0) {
        foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Host "  [OK] stopped the running status notifier ($($running.Count)) - notifications are off." -ForegroundColor Green
    }
    else {
        Write-Host '  ntfy notifications: off (the status notifier will not start).' -ForegroundColor DarkGray
    }
}
elseif ($wantNotifications -and (Test-Path $Notifier)) {
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
Write-Host "  context  $(if ($wantContext -ne $OwnContext) { "$wantContext tokens (setup's own is $OwnContext, this start overrides it)" } else { "$wantContext tokens" })"
Write-Host "  prompts  $(if ($wantParallel -le 1) { 'one at a time (the others wait their turn)' } else { "$wantParallel at once (engine batch slots)" })"
Write-Host "  internet search: $(if ($wantInternetSearch) { 'on (Docker + SearXNG)' } else { 'off (no Docker/SearXNG startup)' })"
Write-Host "  ntfy notifications: $(if ($wantNotifications) { 'on (the status notifier)' } else { 'off (no ntfy notices)' })"
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
if ($ResolvedLogOutputFile) { Write-Host "  full output log  $ResolvedLogOutputFile" }

if ($ResolvedLogOutputFile) {
    & $Py $Server @serverArgs 2>&1 | Tee-Object -FilePath $ResolvedLogOutputFile -Append
}
else {
    & $Py $Server @serverArgs
}
exit $LASTEXITCODE
