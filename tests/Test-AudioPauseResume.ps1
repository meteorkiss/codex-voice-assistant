param([string]$Root=(Split-Path -Parent $PSScriptRoot))

# Run in a separate, hidden Windows PowerShell 5.1 STA process. This plays only
# an all-zero PCM fixture through the production shared WASAPI output. No mic.
$ErrorActionPreference='Stop'
$watch=[Diagnostics.Stopwatch]::StartNew()
. (Join-Path $Root 'src\AudioBootstrap.ps1')
$outDir=Join-Path $Root 'work\tests\audio-pause-resume'
[void][IO.Directory]::CreateDirectory($outDir)
$audioPath=Join-Path $outDir ('silence-'+[Guid]::NewGuid().ToString('N')+'.wav')
$checks=[Collections.Generic.List[string]]::new()
function Assert-AudioPause([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw $Message};$checks.Add($Message)
}
function Get-AudioReader { return $readerField.GetValue($null) }
function Get-ReaderPath($Reader) {
    $fields=$Reader.GetType().GetFields([Reflection.BindingFlags]'Instance,Public,NonPublic')
    foreach($field in $fields){if($field.FieldType -eq [string] -and $field.GetValue($Reader) -ceq $audioPath){return [string]$field.GetValue($Reader)}}
    return ''
}
$readerField=[CodexReader.AudioPlayer].GetField('reader',[Reflection.BindingFlags]'Static,NonPublic')
$playerField=[CodexReader.AudioPlayer].GetField('player',[Reflection.BindingFlags]'Static,NonPublic')
$sampleRate=16000;$durationSeconds=6;$sampleBytes=$sampleRate*$durationSeconds*2
$stream=[IO.File]::Create($audioPath);$writer=[IO.BinaryWriter]::new($stream)
try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](36+$sampleBytes));$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $writer.Write([int]16);$writer.Write([int16]1);$writer.Write([int16]1);$writer.Write([int]$sampleRate);$writer.Write([int]($sampleRate*2));$writer.Write([int16]2);$writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int]$sampleBytes);$writer.Write((New-Object byte[] $sampleBytes))
}finally{$writer.Dispose()}
$report=$null
try {
    Assert-AudioPause ($null -ne $readerField -and $null -ne $playerField) 'production private reader and player are available for observation'
    Assert-AudioPause ([CodexReader.AudioPlayer]::State -eq 'closed') 'test process starts with its own closed player'
    [CodexReader.AudioPlayer]::Play($audioPath)
    Start-Sleep -Milliseconds 320
    Assert-AudioPause ([CodexReader.AudioPlayer]::State -eq 'playing') 'Play enters playing state on the shared output'
    $originalReader=Get-AudioReader;$originalPlayer=$playerField.GetValue($null)
    Assert-AudioPause ($null -ne $originalReader) 'Play creates the real MediaFoundationReader'
    Assert-AudioPause ((Get-ReaderPath $originalReader) -ceq $audioPath) 'reader refers to the generated silent WAV path'
    $beforePause=$originalReader.CurrentTime.TotalMilliseconds
    Assert-AudioPause ($beforePause -gt 80 -and $beforePause -lt 5000) 'playback consumed data without reaching the six-second end'
    [CodexReader.AudioPlayer]::Pause()
    Assert-AudioPause ([CodexReader.AudioPlayer]::State -eq 'paused') 'Pause enters paused state'
    $pauseImmediate=$originalReader.CurrentTime.TotalMilliseconds
    # Allow the last shared-buffer read to settle before measuring the pause.
    Start-Sleep -Milliseconds 130
    $pausedStart=$originalReader.CurrentTime.TotalMilliseconds
    Start-Sleep -Milliseconds 420
    $pausedEnd=$originalReader.CurrentTime.TotalMilliseconds
    Assert-AudioPause ([object]::ReferenceEquals($originalReader,(Get-AudioReader))) 'Pause preserves the same reader object'
    Assert-AudioPause ([object]::ReferenceEquals($originalPlayer,$playerField.GetValue($null))) 'Pause preserves the same WASAPI player object'
    Assert-AudioPause ([CodexReader.AudioPlayer]::State -eq 'paused') 'state remains paused throughout the wait'
    Assert-AudioPause ([Math]::Abs($pausedEnd-$pausedStart) -le 60) 'reader position does not materially advance during a 420 ms pause'
    Assert-AudioPause ($pausedEnd -ge $beforePause) 'Pause does not rewind the reader'
    Assert-AudioPause ((Get-ReaderPath $originalReader) -ceq $audioPath) 'paused reader keeps the same audio path'
    [CodexReader.AudioPlayer]::Resume()
    Assert-AudioPause ([CodexReader.AudioPlayer]::State -eq 'playing') 'Resume returns to playing state'
    Assert-AudioPause ([object]::ReferenceEquals($originalReader,(Get-AudioReader))) 'Resume reuses the reader instead of reloading audio'
    Assert-AudioPause ([object]::ReferenceEquals($originalPlayer,$playerField.GetValue($null))) 'Resume reuses the WASAPI player'
    Assert-AudioPause ((Get-ReaderPath $originalReader) -ceq $audioPath) 'Resume retains the original audio path'
    $resumeImmediate=$originalReader.CurrentTime.TotalMilliseconds
    Assert-AudioPause ($resumeImmediate -ge $pausedEnd) 'Resume begins at the retained reader position'
    Start-Sleep -Milliseconds 440
    $resumedEnd=$originalReader.CurrentTime.TotalMilliseconds
    Assert-AudioPause ($resumedEnd-$pausedEnd -gt 180) 'reader position advances again after Resume'
    [CodexReader.AudioPlayer]::Stop()
    Assert-AudioPause ([CodexReader.AudioPlayer]::State -eq 'closed') 'Stop closes the player'
    Assert-AudioPause ($null -eq (Get-AudioReader) -and $null -eq $playerField.GetValue($null)) 'Stop releases both playback objects'
    $watch.Stop()
    Assert-AudioPause ($watch.Elapsed.TotalSeconds -lt 10) 'complete test finishes within ten seconds'
    $report=[ordered]@{
        passed=$checks.Count;processId=$PID;elapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3)
        pcmSamples=($sampleRate*$durationSeconds);pcmPeak=0;durationSeconds=$durationSeconds
        beforePauseMs=$beforePause;pauseImmediateMs=$pauseImmediate;pausedStartMs=$pausedStart;pausedEndMs=$pausedEnd
        pausedAdvanceMs=($pausedEnd-$pausedStart);resumeImmediateMs=$resumeImmediate;resumedEndMs=$resumedEnd
        resumedAdvanceMs=($resumedEnd-$pausedEnd);sameReader=$true;samePlayer=$true;sameAudioPath=$true;finalState='closed'
        boundary='Shared WASAPI output with zero-valued PCM only; observed reader consumption, not sample-accurate speaker presentation; no microphone, speech, or existing app process interaction.'
    }
    $report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $outDir 'result.json') -Encoding UTF8
    Write-Output ($report|ConvertTo-Json -Depth 5 -Compress)
    Write-Output ('PASS '+$checks.Count+' real silent Pause/Resume checks')
}finally{
    [CodexReader.AudioPlayer]::Stop()
    if(Test-Path -LiteralPath $audioPath){Remove-Item -LiteralPath $audioPath -Force}
}
