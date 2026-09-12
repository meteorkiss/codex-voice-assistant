$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\AudioBootstrap.ps1')
Add-Type -Path (Join-Path $project 'src\MicGuard.cs')
$guard=New-Object CodexReader.Audio.MicGuard
$wake=New-Object WakeListener
$phrase=([char]0x4f60).ToString()+[char]0x597d+[char]0x58f0+[char]0x4f34
try {
    $guard.Start()
    $deadline=[DateTime]::UtcNow.AddSeconds(4)
    while(-not $guard.Ready -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if(-not $guard.Ready -or $guard.LastError) { throw "Guard failed: $($guard.LastError)" }
    $wake.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
    $wake.StartEcho($phrase,[EchoCapture]::GetDefaultCaptureEndpointId(),[CodexReader.AudioPlayer]::RenderEndpointId)
    $deadline=[DateTime]::UtcNow.AddSeconds(7)
    while(-not $wake.FullDuplexReady -and $wake.IsListening -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if(-not $wake.FullDuplexReady -or $wake.Error) { throw "Live AEC wake failed: $($wake.Error)" }
    Start-Sleep -Milliseconds 150
    $active=@($guard.Sessions | Where-Object Active)
    if(-not $guard.AnyCaptureActive -or $active.Count -eq 0) { throw 'MicGuard missed the real AEC capture stream.' }
    if(@($active | Where-Object { [int]$_.ProcessId -ne $PID }).Count -gt 0) { throw 'AEC capture was attributed to another process.' }
    if($wake.RenderEndpointId -ne [CodexReader.AudioPlayer]::RenderEndpointId) { throw 'AEC and player route differ.' }
    for($i=0;$i -lt 3;$i++) {
        [CodexReader.AudioPlayer]::Play((Join-Path $project 'tests\fixtures\wake\positive-taiwan-chen.wav'))
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while([CodexReader.AudioPlayer]::State -eq 'playing' -and [DateTime]::UtcNow -lt $deadline) {
            if(-not $wake.FullDuplexReady -or $wake.Error -or $guard.LastError) { throw "AEC reference/guard failed during playback: $($wake.Error) $($guard.LastError)" }
            Start-Sleep -Milliseconds 20
        }
        [CodexReader.AudioPlayer]::Stop()
        Start-Sleep -Milliseconds 250
    }
    if($wake.ActivationVersion -ne 0) { throw 'The live wake listener activated on its own speaker fixture.' }
    $stop=[Diagnostics.Stopwatch]::StartNew()
    if(-not $wake.StopAndWait(3000)) { throw 'Live wake microphone failed to close.' }
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while($guard.AnyCaptureActive -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if($guard.AnyCaptureActive) { throw 'Capture session remained active after Stop.' }
    [pscustomobject]@{Pid=$PID;CaptureSessionPids=@($active.ProcessId);EchoAndPlayerRouteMatch=$true;SelfPlaybackRepetitions=3;FalseWakes=$wake.ActivationVersion;MicrophoneReleasedMs=$stop.ElapsedMilliseconds;AudioSaved=$false;Passed=$true} | ConvertTo-Json
} finally { [CodexReader.AudioPlayer]::Stop(); $wake.Dispose(); $guard.Dispose() }
