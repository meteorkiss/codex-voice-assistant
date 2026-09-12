. (Join-Path $PSScriptRoot 'Persistence.ps1')

function Sync-PendingSend {
    $script:pendingUncertain = if ($script:pendingSends.ContainsKey($script:threadId)) { [string]$script:pendingSends[$script:threadId].requestId } else { '' }
}
function Save-PendingSends {
    Write-AtomicJson -Path $script:pendingPath -Value @{version=1;sends=@($script:pendingSends.Values)} -Depth 8
}
function Set-PendingSend($Pending) {
    $previous = $script:pendingSends[$Pending.threadId]
    $script:pendingSends[$Pending.threadId] = $Pending
    try { Save-PendingSends } catch {
        if ($previous) { $script:pendingSends[$Pending.threadId]=$previous } else { $script:pendingSends.Remove($Pending.threadId) }
        throw
    }
    Sync-PendingSend
}
function Clear-PendingSend([string]$TargetThreadId) {
    if (-not $script:pendingSends.ContainsKey($TargetThreadId)) { return }
    $previous = $script:pendingSends[$TargetThreadId]
    $script:pendingSends.Remove($TargetThreadId)
    try { Save-PendingSends } catch { $script:pendingSends[$TargetThreadId]=$previous; throw }
    Sync-PendingSend
}
function Get-SendReceiptState($Result,[string]$TargetThreadId,[string]$RequestId) {
    if ($Result -and $Result.ok -is [bool] -and $Result.ok -eq $true -and $Result.accepted -is [bool] -and $Result.accepted -eq $true -and $Result.threadId -eq $TargetThreadId -and $Result.requestId -eq $RequestId) { return 'accepted' }
    if ($Result -and $Result.ok -is [bool] -and $Result.ok -eq $false -and $Result.error -and $Result.error.uncertain -is [bool] -and $Result.error.uncertain -eq $false) { return 'rejected' }
    return 'unknown'
}
function Test-PendingSendRunning($Pending) {
    if ($Pending.processId -and $Pending.processStartedUtc) {
        try {
            $process=Get-Process -Id ([int]$Pending.processId) -ErrorAction Stop
            return (-not $process.HasExited -and [Math]::Abs(($process.StartTime.ToUniversalTime()-[DateTime]::Parse($Pending.processStartedUtc).ToUniversalTime()).TotalSeconds) -lt 1)
        } catch { return $false }
    }
    # A crash between Process.Start and persisting its PID leaves an unknown dispatch.
    return (([DateTime]::UtcNow-[DateTime]::Parse($Pending.createdUtc).ToUniversalTime()).TotalSeconds -lt 90)
}
function Reconcile-PendingSends {
    foreach ($target in @($script:pendingSends.Keys)) {
        $pending = $script:pendingSends[$target]
        if (-not $pending.outputPath -or -not $pending.outputPath.StartsWith($stateDir+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $pending.outputPath)) { continue }
        try { $receipt=Get-Content -LiteralPath $pending.outputPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $state=Get-SendReceiptState $receipt $target $pending.requestId
        if ($state -in @('accepted','rejected')) {
            Clear-PendingSend $target
            if ($target -eq $script:threadId) { $script:notice=if ($state -eq 'accepted') { '上次发送已获 Codex 确认，无需重发。' } else { '上次发送未被接收，可以检查文字后再发送。' } }
        }
    }
}
function Initialize-PendingSends {
    if (Test-Path -LiteralPath $script:pendingPath) {
        $saved=Get-Content -LiteralPath $script:pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($pending in @($saved.sends)) {
            if (-not $pending) { continue }
            [void][Guid]::Parse([string]$pending.threadId); [void][Guid]::Parse([string]$pending.requestId)
            $script:pendingSends[[string]$pending.threadId]=$pending
        }
    }
    Reconcile-PendingSends
    Sync-PendingSend
}
