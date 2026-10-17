
# StrataStatusNotifier.ps1
# Windows PowerShell 5.1 compatible

$BaseUrl = "http://192.168.1.68:8080"
$Topic = "Strata_Notifs"
$PollSeconds = 3
$IdleThresholdSeconds = 30
$ApiKey = ""

# Startup notification: sent once, when the notifier gets its first answer from Strata.
$NotifyOnStartup = $true
$StartupNotifyPriority = "default"

# "Strata is Up" already says the server is sitting there doing nothing, so the
# "Strata is Idle" notice is skipped for that first idle stretch - no Up and Idle
# one after the other. The idle notice re-arms on any real work: the next
# busy/generating -> idle change starts the idle timer again.
$SuppressIdleAfterStartup = $true

# Optional: alert if Strata never answers the notifier. Off unless you want it.
$NotifyOnStartupFailure = $false
$StartupFailureSeconds = 600

# Cline loop detection
$ClineSessionsPath = "$env:USERPROFILE\.cline\data\sessions"
$LoopRepeatThreshold = 3
$LoopMinimumSegmentChars = 50
$LoopAlertCooldownSeconds = 300
$ClineDirectoryRescanSeconds = 15

# Idle notice hold while Cline is mid-command. A tool call that Cline announced
# but has not answered yet means the agent is busy running it - a shell command
# with Start-Sleep -Seconds 60, a Unity batchmode run. Strata being idle then is
# by design, so an "Idle" notice is not a "your turn" signal. The hold gives up
# after $ClineToolHoldMaxSeconds in case a session was cancelled mid-command.
$HoldIdleDuringClineTool = $true
$ClineToolHoldMaxSeconds = 900

# Single-instance protection
$MutexName = "Local\StrataStatusNotifier_SingleInstance"
$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$MutexOwned = $false

try {
    try {
        $MutexOwned = $Mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $MutexOwned = $true
    }

    if (-not $MutexOwned) {
        Write-Host "Another notifier instance is already running. Exiting."
        exit
    }

    $RequestHeaders = @{}
    if ($ApiKey -ne "") {
        $RequestHeaders["Authorization"] = "Bearer $ApiKey"
    }

    $PreviousState = $null
    $HadSuccessfulRead = $false
    $NotifierStartTime = Get-Date
    $StartupFailureNotified = $false
    $IdleSince = $null
    $IdleNotificationSent = $false

    $LastClineDirectoryScan = [datetime]::MinValue
    $CachedLatestSessionPath = $null
    $LastScannedSessionPath = $null
    $LastScannedWriteTimeUtc = [datetime]::MinValue
    $LastScannedLength = -1
    $LoopBaselineEstablished = $false
    $LastTextLoopAlertTime = $null
    $LastActionLoopAlertTime = $null

    $ClineToolInFlight = $false
    $ClineToolName = ""
    $ClineToolStartTime = $null

    function Send-Ntfy {
        param(
            [string]$Title,
            [string]$Message,
            [string]$Priority = "high",
            [string]$Tags = "robot"
        )

        try {
            Invoke-RestMethod `
                -Method Post `
                -Uri "https://ntfy.sh/$Topic" `
                -Headers @{
                    Title    = $Title
                    Priority = $Priority
                    Tags     = $Tags
                } `
                -Body $Message `
                -TimeoutSec 10 `
                -ErrorAction Stop | Out-Null

            Write-Host "Notification sent: $Title" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "ntfy delivery failed: $($_.Exception.Message)" `
                -ForegroundColor Red
            return $false
        }
    }

    function Get-Endpoint {
        param([string]$Path)

        try {
            Invoke-RestMethod `
                -Uri "$BaseUrl$Path" `
                -Headers $RequestHeaders `
                -TimeoutSec 5 `
                -ErrorAction Stop
        }
        catch {
            Write-Host "Endpoint $Path unavailable: $($_.Exception.Message)" `
                -ForegroundColor Yellow
            return $null
        }
    }

    function Get-ExplicitError {
        param($Object)

        if ($null -eq $Object) { return $false }

        foreach ($Name in @("has_error", "is_error", "failed")) {
            $Property = $Object.PSObject.Properties[$Name]
            if ($null -ne $Property -and $Property.Value -eq $true) {
                return $true
            }
        }

        foreach ($Name in @("error", "error_message")) {
            $Property = $Object.PSObject.Properties[$Name]
            if ($null -ne $Property -and
                $null -ne $Property.Value -and
                "$($Property.Value)".Trim() -ne "") {
                return $true
            }
        }

        return $false
    }

    function Get-StrataState {
        param($Metrics, $Status)

        if (Get-ExplicitError $Status) { return "error" }

        if ($null -ne $Metrics) {
            if (Get-ExplicitError $Metrics) { return "error" }

            $Live = $Metrics.live
            if ($null -ne $Live) {
                $State = "$($Live.state)".Trim().ToLowerInvariant()

                if ($State -match "error|failed") {
                    return "error"
                }

                if ($State -match "^(idle|reading|generating|queued)$") {
                    return $State
                }

                if ($State -ne "") {
                    Write-Host "Unrecognized metrics state: $State" `
                        -ForegroundColor Yellow
                    return "unknown"
                }
            }
        }

        if ($null -ne $Status) {
            if ($Status.busy -eq $true) {
                $Phase = "$($Status.phase)".ToLowerInvariant()

                if ($Phase -match "reading") { return "reading" }
                if ($Phase -match "generat|writing") { return "generating" }

                if ($Status.queued -gt 0 -and $Phase -eq "") {
                    return "queued"
                }

                return "working"
            }

            if ($Status.busy -eq $false) {
                return "idle"
            }
        }

        return "unknown"
    }

    function Get-LatestClineSessionFile {
        $Now = Get-Date

        if (($Now - $script:LastClineDirectoryScan).TotalSeconds `
            -lt $ClineDirectoryRescanSeconds) {

            if ($script:CachedLatestSessionPath -and
                (Test-Path -LiteralPath $script:CachedLatestSessionPath)) {
                return Get-Item -LiteralPath $script:CachedLatestSessionPath `
                    -ErrorAction SilentlyContinue
            }

            return $null
        }

        $script:LastClineDirectoryScan = $Now

        if (-not (Test-Path -LiteralPath $ClineSessionsPath)) {
            return $null
        }

        $Latest = Get-ChildItem -LiteralPath $ClineSessionsPath `
            -Filter "*.messages.json" `
            -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($null -ne $Latest) {
            $script:CachedLatestSessionPath = $Latest.FullName
        }

        return $Latest
    }

    # A tool call that Cline announced but has not answered yet means the agent is
    # busy running it. Computed inside the loop detector's existing parse, so the
    # idle check itself costs nothing extra.
    function Update-ClineToolInFlight {
        param(
            $Messages,
            [string]$SessionFilePath
        )

        $script:ClineToolInFlight = $false
        $script:ClineToolName = ""
        $script:ClineToolStartTime = $null

        $LastAssistantIndex = -1

        for ($i = $Messages.Count - 1; $i -ge 0; $i--) {
            if ($Messages[$i].role -eq "assistant") {
                $LastAssistantIndex = $i
                break
            }
        }

        if ($LastAssistantIndex -lt 0) { return }

        $Pending = @(
            $Messages[$LastAssistantIndex].content |
                Where-Object { $null -ne $_ -and $_.type -eq "tool_use" }
        )

        if ($Pending.Count -eq 0) { return }

        # Every tool_result that arrived after that assistant message.
        $AnsweredIds = @()

        for ($j = $LastAssistantIndex + 1; $j -lt $Messages.Count; $j++) {
            $AnsweredIds += @(
                $Messages[$j].content |
                    Where-Object { $null -ne $_ -and $_.type -eq "tool_result" } |
                    ForEach-Object { $_.tool_use_id }
            )
        }

        $Unanswered = @(
            $Pending |
                Where-Object {
                    $null -ne $_.id -and -not ($AnsweredIds -contains $_.id)
                }
        )

        if ($Unanswered.Count -eq 0) { return }

        # A session that already ended cannot still be running a command. The
        # session metadata sits next to the messages file as <id>.json. Its pid is
        # not the process that runs shell commands, so only the status is checked.
        $MetaPath = $SessionFilePath -replace '\.messages\.json$', ".json"

        if (Test-Path -LiteralPath $MetaPath) {
            try {
                $Meta = (Get-Content -LiteralPath $MetaPath -Raw -ErrorAction Stop) |
                    ConvertFrom-Json -ErrorAction Stop

                if ("$($Meta.status)" -ne "" -and "$($Meta.status)" -ne "running") {
                    return
                }
            }
            catch {
                # No readable metadata: fall back to the pending tool call alone.
            }
        }

        $script:ClineToolInFlight = $true
        $script:ClineToolName = "$($Unanswered[0].name)"

        # ts is the epoch milliseconds of the message that made the call.
        if ($null -ne $Messages[$LastAssistantIndex].ts) {
            try {
                $script:ClineToolStartTime =
                    [DateTimeOffset]::FromUnixTimeMilliseconds(
                        [int64]$Messages[$LastAssistantIndex].ts
                    ).LocalDateTime
            }
            catch {
                $script:ClineToolStartTime = $null
            }
        }
    }

    function Get-ClineLoopSignal {
        try {
            $File = Get-LatestClineSessionFile
            if ($null -eq $File) { return $null }

            # Don't reparse an unchanged session file.
            if ($File.FullName -eq $script:LastScannedSessionPath -and
                $File.LastWriteTimeUtc -eq $script:LastScannedWriteTimeUtc -and
                $File.Length -eq $script:LastScannedLength) {
                return $null
            }

            $Raw = Get-Content -LiteralPath $File.FullName -Raw `
                -ErrorAction Stop
            $Data = $Raw | ConvertFrom-Json -ErrorAction Stop

            if ($null -eq $Data.messages) { return $null }

            $Messages = @($Data.messages)

            Update-ClineToolInFlight `
                -Messages $Messages `
                -SessionFilePath $File.FullName

            $AssistantMessages = @(
                $Messages |
                    Where-Object { $_.role -eq "assistant" } |
                    Select-Object -Last 12
            )

            $TextParts = New-Object 'System.Collections.Generic.List[string]'
            $ToolCalls = New-Object 'System.Collections.Generic.List[object]'

            foreach ($Message in $AssistantMessages) {
                foreach ($Block in @($Message.content)) {
                    if ($null -eq $Block) { continue }

                    # Visible assistant text only; don't inspect thinking blocks.
                    if ($Block.type -eq "text" -and
                        $Block.text -is [string] -and
                        $Block.text.Trim() -ne "") {
                        $TextParts.Add($Block.text)
                    }

                    # Fingerprint tool name + input without logging input values.
                    if ($Block.type -eq "tool_use" -and
                        $Block.name -is [string] -and
                        $Block.name.Trim() -ne "") {

                        $InputJson = "{}"
                        if ($null -ne $Block.input) {
                            $InputJson = ConvertTo-Json `
                                -InputObject $Block.input -Depth 30 -Compress
                        }

                        $FingerprintSource =
                            $Block.name.ToLowerInvariant() + "|" + $InputJson
                        $Bytes = [System.Text.Encoding]::UTF8.GetBytes(
                            $FingerprintSource
                        )

                        $Sha = [System.Security.Cryptography.SHA256]::Create()
                        try {
                            $HashBytes = $Sha.ComputeHash($Bytes)
                            $Fingerprint = [System.BitConverter]::ToString(
                                $HashBytes
                            ).Replace("-", "")
                        }
                        finally {
                            $Sha.Dispose()
                        }

                        $ToolCalls.Add([PSCustomObject]@{
                            Name = $Block.name
                            Fingerprint = $Fingerprint
                        })
                    }
                }
            }

            $TextSignal = $null

            if ($TextParts.Count -gt 0) {
                $CombinedText = $TextParts -join "`n"
                $Segments = [regex]::Split(
                    $CombinedText,
                    '(?:\r?\n)+|(?<=[.!?])\s+'
                )

                $NormalizedSegments = foreach ($Segment in $Segments) {
                    $Normalized = $Segment.ToLowerInvariant()
                    $Normalized = $Normalized -replace '[^\p{L}\p{Nd}\s]', ' '
                    $Normalized = $Normalized -replace '\s+', ' '
                    $Normalized = $Normalized.Trim()

                    if ($Normalized.Length -ge $LoopMinimumSegmentChars) {
                        $Normalized
                    }
                }

                $RepeatedText = @(
                    $NormalizedSegments |
                        Group-Object |
                        Where-Object {
                            $_.Count -ge $LoopRepeatThreshold
                        } |
                        Sort-Object Count -Descending |
                        Select-Object -First 1
                )

                if ($RepeatedText.Count -gt 0) {
                    $TextSignal = [int]$RepeatedText[0].Count
                }
            }

            # Same tool name + identical inputs repeated among recent calls.
            $RecentToolCalls = @($ToolCalls | Select-Object -Last 20)
            $ActionSignal = $null

            if ($RecentToolCalls.Count -gt 0) {
                $RepeatedAction = @(
                    $RecentToolCalls |
                        Group-Object Fingerprint |
                        Where-Object {
                            $_.Count -ge $LoopRepeatThreshold
                        } |
                        Sort-Object Count -Descending |
                        Select-Object -First 1
                )

                if ($RepeatedAction.Count -gt 0) {
                    $ActionSignal = [PSCustomObject]@{
                        Count = [int]$RepeatedAction[0].Count
                        Tool = $RepeatedAction[0].Group[0].Name
                    }
                }
            }

            # Record successful scan. Initial scan is baseline only.
            $script:LastScannedSessionPath = $File.FullName
            $script:LastScannedWriteTimeUtc = $File.LastWriteTimeUtc
            $script:LastScannedLength = $File.Length

            if (-not $script:LoopBaselineEstablished) {
                $script:LoopBaselineEstablished = $true
                Write-Host "Cline loop detector baseline established." `
                    -ForegroundColor DarkCyan
                return $null
            }

            return [PSCustomObject]@{
                TextRepeatCount = $TextSignal
                ActionRepeatCount = if ($null -ne $ActionSignal) {
                    $ActionSignal.Count
                } else { $null }
                RepeatedToolName = if ($null -ne $ActionSignal) {
                    $ActionSignal.Tool
                } else { $null }
            }
        }
        catch {
            Write-Host "Cline loop check skipped: $($_.Exception.Message)" `
                -ForegroundColor Yellow
            return $null
        }
    }

    Write-Host "Strata Status Notifier started." -ForegroundColor Cyan
    Write-Host "Server: $BaseUrl"
    Write-Host "Polling every $PollSeconds seconds."
    Write-Host "Idle notification after $IdleThresholdSeconds seconds."
    Write-Host "Cline repeated-output/action checks enabled."

    if ($HoldIdleDuringClineTool) {
        Write-Host "Idle notice held while a Cline command is running (up to $ClineToolHoldMaxSeconds seconds)."
    }

    if ($NotifyOnStartup) {
        if ($SuppressIdleAfterStartup) {
            Write-Host "Startup notification on the first successful read; the first idle notice is skipped."
        }
        else {
            Write-Host "Startup notification on the first successful read."
        }
    }

    if ($NotifyOnStartupFailure) {
        Write-Host "Startup failure notification after $StartupFailureSeconds seconds without an answer."
    }

    Write-Host "Press Ctrl+C to stop.`n"

    while ($true) {
        # Loop detection from local Cline session records.
        $LoopSignal = Get-ClineLoopSignal
        $LoopNow = Get-Date

        if ($null -ne $LoopSignal) {
            if ($null -ne $LoopSignal.TextRepeatCount) {
                $CooldownElapsed = (
                    $null -eq $LastTextLoopAlertTime -or
                    ($LoopNow - $LastTextLoopAlertTime).TotalSeconds `
                        -ge $LoopAlertCooldownSeconds
                )

                if ($CooldownElapsed) {
                    Send-Ntfy `
                        -Title "Possible Cline Output Loop" `
                        -Message "Repeated assistant text detected $($LoopSignal.TextRepeatCount) times in recent Cline output. Check the task in VS Code." `
                        -Priority "high" | Out-Null

                    $LastTextLoopAlertTime = $LoopNow
                }
            }

            if ($null -ne $LoopSignal.ActionRepeatCount) {
                $CooldownElapsed = (
                    $null -eq $LastActionLoopAlertTime -or
                    ($LoopNow - $LastActionLoopAlertTime).TotalSeconds `
                        -ge $LoopAlertCooldownSeconds
                )

                if ($CooldownElapsed) {
                    Send-Ntfy `
                        -Title "Possible Cline Action Loop" `
                        -Message "The same Cline tool action was recorded $($LoopSignal.ActionRepeatCount) times among recent calls. Tool: $($LoopSignal.RepeatedToolName). Check the task in VS Code." `
                        -Priority "high" | Out-Null

                    $LastActionLoopAlertTime = $LoopNow
                }
            }
        }

        $Metrics = Get-Endpoint "/metrics"
        $Status = Get-Endpoint "/status"

        if ($null -eq $Metrics -and $null -eq $Status) {
            if ($NotifyOnStartupFailure -and
                -not $HadSuccessfulRead -and
                -not $StartupFailureNotified -and
                ((Get-Date) - $NotifierStartTime).TotalSeconds -ge $StartupFailureSeconds) {

                Send-Ntfy `
                    -Title "Strata Did Not Start" `
                    -Message "The notifier has had no answer from $BaseUrl since it started $([int](((Get-Date) - $NotifierStartTime).TotalSeconds)) seconds ago. Check the Strata window." `
                    -Priority "urgent" `
                    -Tags "warning" | Out-Null

                $StartupFailureNotified = $true
            }

            Write-Host "Cannot read Strata; retaining previous state." `
                -ForegroundColor Yellow
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $CurrentState = Get-StrataState $Metrics $Status
        $Now = Get-Date
        $Timestamp = $Now.ToString("yyyy-MM-dd HH:mm:ss")

        Write-Host "[$Timestamp] State: $CurrentState"

        if ($CurrentState -eq "unknown") {
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        if (-not $HadSuccessfulRead) {
            $PreviousState = $CurrentState
            $HadSuccessfulRead = $true

            # First answer from Strata: the startup worked, say so once.
            $StartupNotified = $false

            if ($NotifyOnStartup) {
                $ModelName = ""
                $EngineVersion = ""

                if ($null -ne $Metrics -and $null -ne $Metrics.engine) {
                    if ($null -ne $Metrics.engine.model) {
                        $ModelName = "$($Metrics.engine.model)".Trim()
                    }
                    if ($null -ne $Metrics.engine.version) {
                        $EngineVersion = "$($Metrics.engine.version)".Trim()
                    }
                }

                $Details = "State: $CurrentState."

                if ($ModelName -ne "") {
                    if ($EngineVersion -ne "") {
                        $Details = "Model $ModelName (engine $EngineVersion). $Details"
                    }
                    else {
                        $Details = "Model $ModelName. $Details"
                    }
                }

                $StartupNotified = Send-Ntfy `
                    -Title "Strata is Up" `
                    -Message "Strata answered $((Get-Date).ToString('HH:mm:ss')) at $BaseUrl. $Details The status notifier is watching it every $PollSeconds seconds." `
                    -Priority $StartupNotifyPriority `
                    -Tags "white_check_mark"
            }

            if ($CurrentState -eq "idle") {
                $IdleSince = $Now

                if ($SuppressIdleAfterStartup -and $StartupNotified) {
                    # The startup notice already reported this idle stretch, so an
                    # "Idle" notice 30 seconds later would be the same news twice.
                    # The transition branch below re-arms the idle notice as soon as
                    # Strata does anything: busy or generating, then back to idle.
                    $IdleNotificationSent = $true
                    Write-Host "Idle notice skipped; the startup notice covered it." `
                        -ForegroundColor DarkGray
                }
                else {
                    $IdleNotificationSent = $false
                }
            }

            Write-Host "Initial state recorded: $CurrentState"
        }
        elseif ($CurrentState -ne $PreviousState) {
            Write-Host "Transition: $PreviousState -> $CurrentState" `
                -ForegroundColor Cyan

            if ($CurrentState -eq "idle") {
                $IdleSince = $Now
                $IdleNotificationSent = $false
                Write-Host "Idle timer started."
            }
            else {
                $IdleSince = $null
                $IdleNotificationSent = $false
            }

            if ($CurrentState -eq "error") {
                Send-Ntfy `
                    -Title "Strata Error" `
                    -Message "Strata reports an error state. Check the Strata monitor and VS Code." `
                    -Priority "urgent" | Out-Null
            }

            $PreviousState = $CurrentState
        }

        if ($CurrentState -eq "idle" -and
            $null -ne $IdleSince -and
            -not $IdleNotificationSent) {

            $IdleDuration = ($Now - $IdleSince).TotalSeconds

            $ClineHoldSeconds = $null
            if ($null -ne $ClineToolStartTime) {
                $ClineHoldSeconds = [int](($Now - $ClineToolStartTime).TotalSeconds)
            }

            $HoldForCline = (
                $HoldIdleDuringClineTool -and
                $ClineToolInFlight -and
                ($null -eq $ClineHoldSeconds -or
                    $ClineHoldSeconds -lt $ClineToolHoldMaxSeconds)
            )

            if ($HoldForCline) {
                # Strata is idle because Cline is running a command, not because it
                # is waiting for you. Restart the timer so the notice still needs a
                # full threshold once the command is done.
                $IdleSince = $Now

                $HoldText = "Idle notice held; Cline is running {0}" -f $ClineToolName

                if ($null -ne $ClineHoldSeconds) {
                    $HoldText += " ($ClineHoldSeconds s so far)"
                }

                Write-Host $HoldText -ForegroundColor DarkGray
            }
            elseif ($IdleDuration -ge $IdleThresholdSeconds) {
                Send-Ntfy `
                    -Title "Strata is Idle" `
                    -Message "Your model has been idle for at least $IdleThresholdSeconds seconds. You can return to VS Code and give Cline another prompt." | Out-Null

                $IdleNotificationSent = $true
            }
            else {
                $Remaining = [math]::Ceiling(
                    $IdleThresholdSeconds - $IdleDuration
                )
                Write-Host "Idle for $([math]::Floor($IdleDuration)) seconds; notification in about $Remaining seconds."
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($MutexOwned) {
        try { $Mutex.ReleaseMutex() } catch {}
    }

    if ($null -ne $Mutex) {
        $Mutex.Dispose()
    }
}
