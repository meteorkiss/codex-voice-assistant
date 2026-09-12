param([int]$Seconds=5)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $project 'src\EchoCapture.cs')
$capability=[EchoCapture]::ProbeDefault()
if ($capability.Error) { throw $capability.Error }
$capture=New-Object EchoCapture
try {
    $capture.Start($capability.CaptureEndpointId,$capability.RenderEndpointId)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not $capture.IsReady -and $capture.IsRunning -and $clock.ElapsedMilliseconds -lt 6000) { Start-Sleep -Milliseconds 20 }
    if (-not $capture.IsReady) { throw "AEC did not start: $($capture.Error)" }
    $startup=$clock.ElapsedMilliseconds
    Start-Sleep -Seconds $Seconds
    $frames=$capture.FramesCaptured
    $reference=$capture.ReferenceBound
    $failure=$capture.Error
    $stop=[Diagnostics.Stopwatch]::StartNew()
    if (-not $capture.StopAndWait(3000)) { throw 'AEC microphone did not release in time.' }
    [pscustomobject]@{Provider=$capture.Provider;ReadyMs=$startup;Frames=$frames;ReferenceBound=$reference;StoppedMs=$stop.ElapsedMilliseconds;Error=$failure;AudioSaved=$false} | ConvertTo-Json
    if($failure) { throw $failure }
    if($frames -lt 16000) { throw 'AEC did not produce microphone samples.' }
} finally { $capture.Dispose() }
