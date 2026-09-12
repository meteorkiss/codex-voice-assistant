param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
foreach($name in @('WorkerLifecycle.ps1','AudioOutput.ps1')){. (Join-Path $Root ('src\'+$name))}
Add-Type @'
namespace CodexReader { public static class AudioPlayer {
 public static bool FailPlay,FailStop; public static int Plays,Stops; public static string State="closed";
 public static void Play(string path){State="playing";if(FailPlay)throw new System.Exception("fixture playback failure");Plays++;}
 public static void Stop(){Stops++;if(FailStop)throw new System.Exception("fixture stop failure");State="closed";}
}}
'@
$run=Join-Path $Root ('work\tests\audio-output-'+[Guid]::NewGuid().ToString('N'))
$script:runtime=Join-Path $run 'runtime';[void][IO.Directory]::CreateDirectory($runtime)
$script:checks=0;$script:starts=0;$script:bookmarkClears=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Safe-To-Play{return $script:safe}
function Clear-VoicePlaybackBookmark{$script:bookmarkClears++}
function Start-Worker($Interpreter,$Script,$Arguments){
 $script:starts++
 if($script:failLaunch){[IO.File]::WriteAllText(($Arguments[1] -replace '\.mp3$','.partial.mp3'),'fixture');throw 'fixture launch failure'}
 $p=[pscustomobject]@{HasExited=$false;ExitCode=0;Disposed=$false}
 $p|Add-Member ScriptMethod Kill {$this.HasExited=$true}
 $p|Add-Member ScriptMethod WaitForExit {param($Timeout) return $this.HasExited}
 $p|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
 return $p
}
function Reset-Case {
 $script:ttsJob=$null;$script:audioPath='';$script:epoch=1;$script:ttsEpoch=1;$script:threadId='fixture-a'
 $script:voiceId='fixture-voice';$script:speechRate=0;$script:spoken=0;$script:latest='original answer'
 $script:speechQueue=New-Object 'Collections.Generic.Queue[string]';$script:safe=$true;$script:failLaunch=$false
 [CodexReader.AudioPlayer]::FailPlay=$false;[CodexReader.AudioPlayer]::FailStop=$false;[CodexReader.AudioPlayer]::State='closed';[CodexReader.AudioPlayer]::Plays=0
}
try {
 Reset-Case;$script:failLaunch=$true;Start-AssistantSpeech '合成失败样例'
 Assert (-not $script:ttsJob -and @(Get-ChildItem -LiteralPath $runtime -File).Count -eq 0 -and $script:latest -ceq 'original answer') 'Launch failure leaked files or changed the answer.'
 foreach($kind in @('success','epoch','thread','unsafe','exitFailure','playFailure','outside')){
  Reset-Case;Start-AssistantSpeech '合成样例';$job=$script:ttsJob;$starts=$script:starts
  Start-AssistantSpeech 'must not replace active worker'
  Assert ([object]::ReferenceEquals($job,$script:ttsJob) -and $script:starts -eq $starts) 'Active synthesis was replaced.'
  [IO.File]::WriteAllText($job.Audio,'fixture audio');$job.Process.HasExited=$true
  switch($kind){
   'epoch' {$script:epoch++}
   'thread' {$script:threadId='fixture-b'}
   'unsafe' {$script:safe=$false}
   'exitFailure' {$job.Process.ExitCode=1}
   'playFailure' {[CodexReader.AudioPlayer]::FailPlay=$true}
   'outside' {Remove-OwnedFiles @($job.Audio);$job.Audio=Join-Path $run 'outside.mp3';[IO.File]::WriteAllText($job.Audio,'preserve')}
  }
  Complete-AssistantSpeech;Complete-AssistantSpeech
  Assert (-not $script:ttsJob -and $job.Process.Disposed) 'Completed synthesis did not release its process.'
  Assert ([CodexReader.AudioPlayer]::Plays -eq $(if($kind -eq 'success'){1}else{0})) ('Wrong playback count: '+$kind)
  if($kind -eq 'success'){
   Assert ($script:audioPath -ceq $job.Audio -and (Test-Path -LiteralPath $job.Audio) -and $script:spoken -eq 1) 'Successful clip ownership was not transferred.'
   Stop-AssistantOutput
  } elseif($kind -eq 'outside') {Assert (Test-Path -LiteralPath $job.Audio) 'Cleanup deleted an unowned clip.'}
  else {Assert (-not (Test-Path -LiteralPath $job.Audio)) ('Rejected audio leaked: '+$kind)}
  Assert (@(Get-ChildItem -LiteralPath $runtime -File).Count -eq 0) ('Synthesis files leaked: '+$kind)
 }
 Reset-Case;Start-AssistantSpeech 'cancel fixture';$job=$script:ttsJob
 [IO.File]::WriteAllText($job.Audio,'fixture');$script:speechQueue.Enqueue('queued')
 Stop-AssistantOutput -PreserveVoiceBookmark
 Assert ($job.Process.HasExited -and $job.Process.Disposed -and -not $script:ttsJob -and $script:speechQueue.Count -eq 0 -and $script:epoch -eq 2) 'Stop did not invalidate and cancel output.'
 Assert (@(Get-ChildItem -LiteralPath $runtime -File).Count -eq 0) 'Cancelled synthesis leaked audio.'
 Reset-Case;$script:audioPath=Join-Path $runtime 'in-use.mp3';[IO.File]::WriteAllText($script:audioPath,'fixture')
 $script:speechQueue.Enqueue('queued');[CodexReader.AudioPlayer]::FailStop=$true;Stop-AssistantOutput
 Assert ($script:epoch -eq 2 -and $script:speechQueue.Count -eq 0 -and (Test-Path -LiteralPath $script:audioPath)) 'Stop failure discarded an in-use clip or left queued output.'
 [CodexReader.AudioPlayer]::FailStop=$false;Stop-AssistantOutput
 Assert (-not $script:audioPath -and @(Get-ChildItem -LiteralPath $runtime -File).Count -eq 0) 'Stop retry did not release the retained clip.'
 Reset-Case;Start-AssistantSpeech 'partial playback';$job=$script:ttsJob
 [IO.File]::WriteAllText($job.Audio,'fixture');$job.Process.HasExited=$true
 [CodexReader.AudioPlayer]::FailPlay=$true;[CodexReader.AudioPlayer]::FailStop=$true;Complete-AssistantSpeech
 Assert ($script:audioPath -ceq $job.Audio -and (Test-Path -LiteralPath $job.Audio)) 'Failed playback/stop lost cleanup ownership.'
 [CodexReader.AudioPlayer]::FailStop=$false;Stop-AssistantOutput
 Assert (-not (Test-Path -LiteralPath $job.Audio)) 'Retained partial playback could not be released.'
 Assert (-not (Test-AssistantAudioPath (Join-Path $runtime '..\outside.mp3')) -and -not (Test-AssistantAudioPath $runtime)) 'Audio path check accepted traversal or directory.'
 $outsideDir=Join-Path $run 'outside';[void][IO.Directory]::CreateDirectory($outsideDir)
 $outsideClip=Join-Path $outsideDir 'keep.mp3';[IO.File]::WriteAllText($outsideClip,'preserve')
 $link=Join-Path $runtime 'linked'
 [void](New-Item -ItemType Junction -Path $link -Value $outsideDir)
 try {Assert (-not (Test-AssistantAudioPath (Join-Path $link 'keep.mp3')) -and (Test-Path -LiteralPath $outsideClip)) 'Audio path followed a directory junction.'}
 finally {[IO.Directory]::Delete($link)}
 @{ok=$true;checks=$script:checks;devices=0;codexRequests=0}|ConvertTo-Json -Compress
} finally {
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $run).Path)
 $allowed=[IO.Path]::GetFullPath((Join-Path $Root 'work\tests')).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^audio-output-[0-9a-f]{32}$'){throw 'Invalid audio test cleanup path.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
