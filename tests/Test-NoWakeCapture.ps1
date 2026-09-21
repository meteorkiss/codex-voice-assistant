$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
if(-not ('NoWakeSegmenter' -as [type])) { Add-Type -Path @((Join-Path $Root 'src\EchoCapture.cs'),(Join-Path $Root 'src\NoWakeCapture.cs')) }

$checks=0
function Assert-NoWakeCapture($Condition,[string]$Message) { $script:checks++; if(-not $Condition){throw $Message} }
function New-PcmFrame([double]$Amplitude,[double]$Phase=0) {
    $bytes=New-Object byte[] 640
    for($i=0;$i -lt 320;$i++) {
        $sample=[int16]([Math]::Sin(($i+$Phase)*0.17)*32767*$Amplitude)
        $bytes[$i*2]=[byte]($sample -band 255)
        $bytes[$i*2+1]=[byte](($sample -shr 8) -band 255)
    }
    return ,$bytes
}
function Feed($segmenter,[double]$amplitude,[int]$frames) { for($i=0;$i -lt $frames;$i++){ $segmenter.AcceptPcm((New-PcmFrame $amplitude $i)) } }

$segmenter=New-Object NoWakeSegmenter 41
Feed $segmenter 0 30
Assert-NoWakeCapture ($null -eq $segmenter.TryDequeue()) 'Silence created an utterance.'
Feed $segmenter 0.20 20
Feed $segmenter 0 50
$segment=$segmenter.TryDequeue()
Assert-NoWakeCapture ($null -ne $segment -and $segment.Generation -eq 41) 'A voiced utterance was not segmented with its generation.'
Assert-NoWakeCapture ($segment.EndReason -eq 'silence' -and $segment.VoiceFrames -ge 8) 'Silence endpoint or voiced evidence is wrong.'
Assert-NoWakeCapture ($segment.DurationSeconds -gt 1 -and $segment.DurationSeconds -lt 2.5) 'Pre-roll or bounded silence duration is implausible.'
Assert-NoWakeCapture ($segment.Rms -gt 0 -and $segment.Peak -gt 0.1) 'Acoustic evidence is missing.'

$short=New-Object NoWakeSegmenter 42
Feed $short 0.20 2
Feed $short 0 60
Assert-NoWakeCapture ($null -eq $short.TryDequeue()) 'A two-frame transient created a segment.'

$bounded=New-Object NoWakeSegmenter 43
Feed $bounded 0.20 910
$maximum=$bounded.TryDequeue()
Assert-NoWakeCapture ($null -ne $maximum -and $maximum.EndReason -eq 'maximum-duration') 'Maximum-duration speech was not bounded.'
Assert-NoWakeCapture ($maximum.DurationSeconds -le 18.01) 'Maximum segment exceeded its memory/time bound.'

$queue=New-Object NoWakeSegmenter 44
for($utterance=0;$utterance -lt 3;$utterance++){ Feed $queue 0.20 12; Feed $queue 0 50 }
Assert-NoWakeCapture ($queue.PendingCount -eq 2 -and $queue.DroppedCount -eq 1) 'Segment queue did not apply bounded backpressure.'

$testRoot=Join-Path $Root ('work\tests\no-wake-capture-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$wave=Join-Path $testRoot 'segment.wav'
try {
    [NoWakeCapture]::WriteWave($wave,$segment.Pcm)
    $header=[IO.File]::ReadAllBytes($wave)
    Assert-NoWakeCapture ($header.Length -eq $segment.Pcm.Length+44) 'WAV length is invalid.'
    Assert-NoWakeCapture ([Text.Encoding]::ASCII.GetString($header,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($header,8,4) -eq 'WAVE') 'WAV header is invalid.'
} finally {
    if([IO.File]::Exists($wave)){[IO.File]::Delete($wave)}
    if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$false)}
}

[pscustomobject]@{passed=$true;checks=$checks;boundary='Synthetic PCM and pure segmenter only; no microphone, EchoCapture start, ASR, background recording or network.'} | ConvertTo-Json -Compress
