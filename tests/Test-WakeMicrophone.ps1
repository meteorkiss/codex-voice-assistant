$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\AudioBootstrap.ps1')
Add-Type -Path (Join-Path $project 'src\MicGuard.cs')
$wake=New-Object WakeListener
$wake.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
$guard=New-Object CodexReader.Audio.MicGuard
$guard.Start()
try {
    $wake.Start([WakeListener]::NormalizePhrase([string]([char]0x4f60)+[char]0x597d+[char]0x58f0+[char]0x4f34))
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 25
        $own=@($guard.Sessions | Where-Object { $_.Active -and $_.ProcessId -eq $PID })
    } while ((-not $wake.IsReady -or -not $own.Count) -and $watch.Elapsed.TotalSeconds -lt 8 -and -not $wake.Error)
    if($wake.Error) { throw $wake.Error }
    if(-not $own.Count) { throw 'Wake capture session was not attributed to the current PowerShell process.' }
    $openMs=$watch.ElapsedMilliseconds
    $scanBefore=$guard.ScanCount
    $watch.Restart(); $wake.Stop(); $stopCallMs=$watch.ElapsedMilliseconds
    while(($wake.IsListening -or $wake.IsStopping) -and $watch.Elapsed.TotalSeconds -lt 3) { Start-Sleep -Milliseconds 10 }
    if($wake.IsListening -or $wake.IsStopping) { throw 'Wake microphone did not close.' }
    $closedMs=$watch.ElapsedMilliseconds
    do {
        Start-Sleep -Milliseconds 25
        $remaining=@($guard.Sessions | Where-Object { $_.Active -and $_.ProcessId -eq $PID })
    } while (($remaining.Count -or $guard.ScanCount -le $scanBefore) -and $watch.Elapsed.TotalSeconds -lt 3)
    if($remaining.Count) { throw 'MicGuard still sees the wake microphone after Stop.' }
    $result=[pscustomobject]@{ProcessId=$PID;CaptureProcessIds=@($own.ProcessId);OpenMs=$openMs;StopRequestMs=$stopCallMs;ClosedMs=$closedMs;GuardReleasedMs=$watch.ElapsedMilliseconds;Error=$wake.Error}
    $output=Join-Path $project 'work\tests\wake\microphone-result.json'
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $output -Encoding UTF8
    $result | ConvertTo-Json -Depth 4
} finally { $wake.Dispose(); $guard.Dispose() }
