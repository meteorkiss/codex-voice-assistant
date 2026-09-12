param([switch]$NoPlayback)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\AudioBootstrap.ps1')
Add-Type -Path (Join-Path $project 'src\MicGuard.cs')
$guard=New-Object CodexReader.Audio.MicGuard
try {
    $guard.Start()
    $deadline=[DateTime]::UtcNow.AddSeconds(4)
    while(-not $guard.Ready -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    if(-not $guard.Ready -or $guard.LastError) { throw "MicGuard failed: $($guard.LastError)" }
    $probe=[EchoCapture]::ProbeDefault()
    if($probe.Error) { throw $probe.Error }
    [CodexReader.AudioPlayer]::SelectEndpoint($probe.RenderEndpointId)
    if([CodexReader.AudioPlayer]::RenderEndpointId -ne $probe.RenderEndpointId) { throw 'Explicit playback route changed.' }
    if(-not $NoPlayback) {
        [CodexReader.AudioPlayer]::Play((Join-Path $project 'tests\fixtures\wake\positive-taiwan-chen.wav'))
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while([CodexReader.AudioPlayer]::State -eq 'playing' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        if([CodexReader.AudioPlayer]::State -ne 'stopped') { throw 'WASAPI clip did not complete.' }
        [CodexReader.AudioPlayer]::Stop()
    }
    # Re-enter custom COM inspection after NAudio has created its own enumerator.
    $again=[EchoCapture]::GetDefaultCaptureEndpointId()
    if(-not $again -or $guard.LastError -or -not $guard.Ready) { throw 'COM clients became invalid after playback.' }
    [pscustomobject]@{GuardFirst=$true;ProbeAndPlayer=$true;ProbeAfterPlayer=$true;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Playback=(-not $NoPlayback);Passed=$true} | ConvertTo-Json
} finally { [CodexReader.AudioPlayer]::Stop(); $guard.Dispose() }
