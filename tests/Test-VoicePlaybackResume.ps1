param([string]$Root=(Split-Path -Parent $PSScriptRoot),[switch]$LegacyPlayer,[switch]$CompileOnly)
$ErrorActionPreference='Stop'
if ($CompileOnly) {
    . (Join-Path $Root 'src\AudioBootstrap.ps1')
    if ($null -eq [CodexReader.AudioPlayer].GetMethod('PlayFrom',[type[]]@([string],[double]))) { throw 'PlayFrom API missing.' }
    if ([CodexReader.AudioPlayer]::PositionSeconds -ne 0) { throw 'Closed player must have no position.' }
    foreach ($value in @([double]::NaN,[double]::PositiveInfinity,-1.0)) {
        $rejected=$false
        try { [CodexReader.AudioPlayer]::PlayFrom('not-opened.wav',$value) } catch { $rejected=$_.Exception.InnerException -is [ArgumentOutOfRangeException] }
        if (-not $rejected) { throw 'Invalid seek must be rejected before touching a speaker.' }
    }
    Write-Output 'PASS production NAudio compilation and seek validation; no device opened.'
    return
}
$seekMembers=if ($LegacyPlayer) { '' } else { @'
 public static double PositionSeconds {get;set;}
 public static void PlayFrom(string path,double position){Play(path);LastPosition=position;PositionSeconds=position;}
'@ }
Add-Type -TypeDefinition (@'
namespace CodexReader {
 public static class AudioPlayer {
 public static string State="closed",LastPath="";
 public static double LastPosition;
 public static int Plays;
 public static bool FailPlay;
 public static void Play(string path){if(FailPlay)throw new System.Exception("mock playback unavailable");State="playing";LastPath=path;LastPosition=0;Plays++;}
 public static void Pause(){State="paused";}
 public static void Resume(){State="playing";}
 public static void Stop(){State="closed";}
 SEEK_MEMBERS
 }
}
'@).Replace('SEEK_MEMBERS',$seekMembers)
. (Join-Path $Root 'src\PlaybackCommands.ps1')
$script:checks=0
$runtime=Join-Path $Root ('work\tests\voice-playback-resume\'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runtime)
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:checks++ }
function Set-VoiceDesktopActionNotice([string]$Message) { $script:notice=$Message }
function Safe-To-Play { return $script:safePlay }
function Queue-AnswerSpeech([string]$Text) { $script:speechQueue.Enqueue($Text) }
function Toggle-AnswerPlayback {
    if ([CodexReader.AudioPlayer]::State -eq 'playing') { [CodexReader.AudioPlayer]::Pause() }
    elseif ($script:safePlay) { [CodexReader.AudioPlayer]::Resume();$script:notice='continued' }
}
function Stop-Output([string]$Message='',[switch]$PreserveVoiceBookmark) {
    if (-not $PreserveVoiceBookmark) { Clear-VoicePlaybackBookmark }
    [CodexReader.AudioPlayer]::Stop();$script:epoch++
    if (Test-VoicePlaybackOwnedPath $script:audioPath) { Remove-Item -LiteralPath $script:audioPath -Force -ErrorAction SilentlyContinue }
    $script:audioPath='';$script:speechQueue.Clear();$script:ttsJob=$null
}
function Reset-Case {
    Clear-VoicePlaybackBookmark
    if (Test-VoicePlaybackOwnedPath $script:audioPath) { Remove-Item -LiteralPath $script:audioPath -Force -ErrorAction SilentlyContinue }
    $script:closing=$false;$script:connected=$true;$script:threadId='thread-a';$script:latest='answer-a';$script:lastUserVersion=5
    $script:recMode='idle';$script:handsFreePhase='listening';$script:epoch=10;$script:ttsJob=$null;$script:safePlay=$true
    $script:speechQueue=New-Object 'System.Collections.Generic.Queue[string]'
    $script:audioPath=Join-Path $runtime ([Guid]::NewGuid().ToString('N')+'.mp3')
    [IO.File]::WriteAllText($script:audioPath,'fixture-only-no-real-audio')
    [CodexReader.AudioPlayer]::State='playing';[CodexReader.AudioPlayer]::Plays=0;[CodexReader.AudioPlayer]::FailPlay=$false
    if (-not $LegacyPlayer) { [CodexReader.AudioPlayer]::PositionSeconds=12.25 }
    $script:notice=''
}
try {
    Reset-Case;$script:speechQueue.Enqueue('remaining-one');$script:speechQueue.Enqueue('remaining-two')
    $original=$script:audioPath
    Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio
    Assert ($saved -ne $original -and (Test-Path -LiteralPath $saved)) 'Capture must copy audio before Stop removes the original.'
    Assert ($script:voicePlaybackBookmark.Queue.Count -eq 2) 'Remaining queue was lost.'
    Stop-Output -PreserveVoiceBookmark
    Assert (-not (Test-Path -LiteralPath $original) -and (Test-Path -LiteralPath $saved)) 'Capture cleanup removed the retained clip.'
    $script:audioPath=Join-Path $Root 'assets\ack-default.mp3';[CodexReader.AudioPlayer]::State='playing'
    Save-VoicePlaybackBookmark;Stop-Output -PreserveVoiceBookmark
    Assert ($script:voicePlaybackBookmark.Audio -ceq $saved) 'Second capture preparation replaced answer with acknowledgement.'
    [void](Invoke-VoicePlaybackAction 'pause')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 0 -and $script:notice -match '暂停') 'Voice pause restarted audio or failed to acknowledge.'
    [void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::LastPath -ceq $saved) 'Resume did not use the preserved clip.'
    $expectedPosition=if($LegacyPlayer){0.0}else{12.25}
    Assert ([CodexReader.AudioPlayer]::LastPosition -eq $expectedPosition) 'Resume lost its offset or failed legacy fallback.'
    Assert ($script:speechQueue.Dequeue() -ceq 'remaining-one' -and $script:speechQueue.Dequeue() -ceq 'remaining-two') 'Queue order changed.'
    Assert ($null -eq $script:voicePlaybackBookmark -and $script:audioPath -ceq $saved) 'Restored clip cleanup ownership was not transferred.'

    foreach ($invalidate in @('thread','answer','user','epoch','disconnect','stop')) {
        Reset-Case;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio;Stop-Output -PreserveVoiceBookmark
        switch($invalidate) {
            'thread' {$script:threadId='thread-b'}
            'answer' {$script:latest='answer-b'}
            'user' {$script:lastUserVersion++}
            'epoch' {$script:voicePlaybackAnswerEpoch++}
            'disconnect' {$script:connected=$false}
            'stop' {Stop-Output}
        }
        [void](Invoke-VoicePlaybackAction 'resume')
        Assert ([CodexReader.AudioPlayer]::Plays -eq 0) ('Stale playback resumed after '+$invalidate)
        Assert (-not (Test-Path -LiteralPath $saved)) ('Stale bookmark file leaked after '+$invalidate)
    }
    Reset-Case;Save-VoicePlaybackBookmark;Stop-Output -PreserveVoiceBookmark;$script:safePlay=$false
    [void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 0 -and (Test-VoicePlaybackBookmark)) 'Unsafe microphone state must retain bookmark without playback.'
    $script:safePlay=$true;[void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 1) 'Bookmark could not resume after microphone became safe.'

    Reset-Case;Save-VoicePlaybackBookmark;Stop-Output -PreserveVoiceBookmark
    $script:recMode='transcribing';[void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 0) 'Resume played over active transcription.'
    $script:recMode='idle';$script:handsFreePhase='acknowledging';[void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 0) 'Resume played over wake acknowledgement.'

    Reset-Case;Stop-Output -PreserveVoiceBookmark
    $script:ttsJob=@{Text='pending-synthesis'};$script:speechQueue.Enqueue('later')
    [void](Invoke-VoicePlaybackAction 'pause')
    Assert ($script:ttsJob -eq $null -and $script:speechQueue.Count -eq 0 -and (Test-VoicePlaybackBookmark)) 'Pause must retain and stop unfinished synthesis.'
    [void](Invoke-VoicePlaybackAction 'resume')
    Assert ($script:speechQueue.Dequeue() -ceq 'pending-synthesis' -and $script:speechQueue.Dequeue() -ceq 'later') 'Pending synthesis must return before later speech.'

    Reset-Case;Save-VoicePlaybackBookmark;Stop-Output -PreserveVoiceBookmark
    [CodexReader.AudioPlayer]::FailPlay=$true;[void](Invoke-VoicePlaybackAction 'resume')
    Assert ((Test-VoicePlaybackBookmark) -and [CodexReader.AudioPlayer]::Plays -eq 0) 'Playback failure discarded the retryable bookmark.'
    [CodexReader.AudioPlayer]::FailPlay=$false;[void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 1) 'Retry did not resume preserved audio.'

    Reset-Case;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio;Stop-Output -PreserveVoiceBookmark
    Remove-Item -LiteralPath $saved -Force;[void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 0 -and $null -eq $script:voicePlaybackBookmark) 'Missing copied clip should fail without playback.'

    Reset-Case;Save-VoicePlaybackBookmark;Stop-Output -PreserveVoiceBookmark;$script:speechQueue.Enqueue('new-action')
    [void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::Plays -eq 0 -and $script:speechQueue.Dequeue() -ceq 'new-action') 'Old bookmark overwrote newer output.'

    Reset-Case;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio
    [void](Invoke-VoicePlaybackAction 'replay')
    Assert (-not (Test-Path -LiteralPath $saved) -and $script:speechQueue.Dequeue() -ceq 'answer-a') 'Replay retained stale clip or lost full answer.'

    # Execute the actual production transitions, with hardware/process/UI edges
    # replaced by doubles. Never invoke the Assistant startup or timer itself.
    function Read-ProductionAst([string]$Name) {
        $tokens=$null;$parseErrors=$null
        $tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root ('src\'+$Name)),[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count) { throw $parseErrors[0].Message }
        return $tree
    }
    $assistantTree=Read-ProductionAst 'Assistant.ps1';$handsFreeTree=Read-ProductionAst 'HandsFree.ps1'
    foreach ($item in @(@{Tree=$assistantTree;Names=@('Stop-Output','Begin-Recording','Send-Text','Apply-Thread')},
        @{Tree=$handsFreeTree;Names=@('Invoke-WakeActivation','Update-HandsFree')})) {
        foreach ($name in $item.Names) {
            $node=$item.Tree.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
            if (-not $node) { throw ('Missing production function '+$name) }
            . ([scriptblock]::Create($node.Extent.Text))
        }
    }
    $answerNode=$assistantTree.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'answer' -and $n.Condition.Extent.Text -eq '$answers'},$true)
    $userNode=$assistantTree.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$script:tail.UserTurnVersion -ne $script:lastUserVersion'},$true)
    if (-not $answerNode -or -not $userNode) { throw 'Production answer/user transition block missing.' }
    $receiveAnswer=[scriptblock]::Create($answerNode.Extent.Text)
    $receiveUser=[scriptblock]::Create($userNode.Extent.Text)
    function Remove-OwnedFiles([string[]]$Paths) {
        foreach($file in $Paths) { if ((Test-VoicePlaybackOwnedPath $file) -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force } }
    }
    function Close-Job($Job,[switch]$Kill) { $script:closedJobs++ }
    function Suspend-WakeListener { $script:suspends++ }
    function Test-FullDuplexReady { return $true }
    function Test-ExternalCapture { return $false }
    function Test-WakeRecoveryPending { return $false }
    function Try-LocalAssistantCommand([string]$Text) { return $false }
    function Test-VoiceTaskCreateBlocksSend { return $false }
    function Reset-VoiceTaskSwitch {}
    function Start-Bridge($Request,[string]$Purpose) { $script:lastBridgeRequest=$Request;return $true }
    function New-TranscriptTail([string]$Path) { return [pscustomobject]@{Path=$Path;UserTurnVersion=5;Latest='target-answer'} }
    function Reconcile-PendingSends {}
    function Sync-PendingSend {}
    function Save-Settings {}
    function Reset-ProductionCase {
        Reset-Case
        $script:InputBox=[pscustomobject]@{Text='';IsReadOnly=$false}
        $script:AnswerBox=[pscustomobject]@{Text=''}
        $script:AnswerBox | Add-Member ScriptMethod ScrollToHome {}
        $script:TaskLabel=[pscustomobject]@{Text='';ToolTip=''}
        $script:wakeListener=[pscustomobject]@{HasQuestion=$false;Error='';ActivationVersion=0;IsListening=$false;IsStopping=$false}
        $script:mic=[pscustomobject]@{ScanCount=10;AnyCaptureActive=$false}
        $script:tail=[pscustomobject]@{Path='';UserTurnVersion=5;Latest='answer-a'}
        $script:manualRecorder=$null;$script:bridgeJob=$null;$script:asrJob=$null;$script:pendingUncertain=$false
        $script:handsFreeEnabled=$true;$script:wakeOwnsMicrophone=$false;$script:lastWakeVersion=0
        $script:voiceGeneration=1;$script:wakeCount=0;$script:closedJobs=0;$script:suspends=0
        $script:workspace=$Root;$script:voiceId='zh-CN-XiaoxiaoNeural';$script:autoRead=$false
        $script:TestMode=$false;$script:TestTranscriptPath='';$script:lastBridgeRequest=$null
    }

    Reset-ProductionCase;$script:speechQueue.Enqueue('remaining-after-wake');$original=$script:audioPath
    Invoke-WakeActivation;$saved=$script:voicePlaybackBookmark.Audio
    Assert ($script:handsFreePhase -eq 'answering-wake' -and (Test-VoicePlaybackBookmark)) 'Production wake did not retain bookmark before stopping output.'
    Assert (-not (Test-Path -LiteralPath $original) -and (Test-Path -LiteralPath $saved)) 'Production wake removed its only resumable clip.'
    Update-HandsFree ([DateTime]::UtcNow)
    Assert ($script:handsFreePhase -eq 'acknowledging' -and [CodexReader.AudioPlayer]::LastPath -match 'ack-') 'Production wake acknowledgement transition did not run.'
    Assert ($script:voicePlaybackBookmark.Audio -ceq $saved) 'Production acknowledgement replaced bookmark.'
    [CodexReader.AudioPlayer]::State='stopped'
    Update-HandsFree ([DateTime]::UtcNow)
    Assert ($script:recMode -eq 'arming' -and $script:handsFreePhase -eq 'recording') 'Production acknowledgement completion did not prepare recording.'
    Assert ($script:voicePlaybackBookmark.Audio -ceq $saved -and (Test-Path -LiteralPath $saved)) 'Production recording preparation lost bookmark during second Save/Stop.'
    $script:recMode='idle';$script:handsFreePhase='listening'
    [void](Invoke-VoicePlaybackAction 'resume')
    Assert ([CodexReader.AudioPlayer]::LastPath -ceq $saved -and [CodexReader.AudioPlayer]::LastPosition -eq $expectedPosition) 'Production wake-to-recording chain lost resume offset.'
    Assert ($script:speechQueue.Dequeue() -ceq 'remaining-after-wake') 'Production wake-to-recording chain lost remaining queue.'

    Reset-ProductionCase;$original=$script:audioPath
    Begin-Recording $false;$saved=$script:voicePlaybackBookmark.Audio
    Assert ($script:recMode -eq 'arming' -and (Test-VoicePlaybackBookmark) -and -not (Test-Path -LiteralPath $original)) 'Manual production recording did not preserve interrupted playback.'
    Stop-Output
    Assert ($null -eq $script:voicePlaybackBookmark -and -not (Test-Path -LiteralPath $saved)) 'Ordinary production Stop did not dispose bookmark.'

    Reset-ProductionCase;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio;Stop-Output -PreserveVoiceBookmark
    $InputBox.Text='a new user question';Send-Text
    Assert ($script:lastBridgeRequest.action -eq 'send' -and $script:lastBridgeRequest.text -ceq 'a new user question') 'Production send did not reach the mocked bridge.'
    Assert ($null -eq $script:voicePlaybackBookmark -and -not (Test-Path -LiteralPath $saved)) 'Production send retained previous answer bookmark.'

    Reset-ProductionCase;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio;Stop-Output -PreserveVoiceBookmark
    $rollout=Join-Path $runtime 'target.jsonl';[IO.File]::WriteAllText($rollout,'test-only')
    Apply-Thread ([pscustomobject]@{threadId='thread-b';rolloutPath=$rollout;cwd=$runtime;status='idle';title='Target'})
    Assert ($script:threadId -ceq 'thread-b' -and $script:latest -ceq 'target-answer') 'Production task binding did not complete.'
    Assert ($null -eq $script:voicePlaybackBookmark -and -not (Test-Path -LiteralPath $saved)) 'Production task switch retained old task bookmark.'

    Reset-ProductionCase;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio;Stop-Output -PreserveVoiceBookmark
    # Identical text still belongs to a newly completed answer and must expire.
    $answers=@([pscustomobject]@{Text='answer-a';UserTurnVersion=5});& $receiveAnswer
    Assert ($null -eq $script:voicePlaybackBookmark -and -not (Test-Path -LiteralPath $saved)) 'Production completed-answer handling did not expire an identical-text old answer.'
    Assert ($script:speechQueue.Count -eq 0 -and $script:latest -ceq 'answer-a') 'Disabled auto-read still queued audio or lost displayed answer.'

    Reset-ProductionCase;Save-VoicePlaybackBookmark;$saved=$script:voicePlaybackBookmark.Audio;Stop-Output -PreserveVoiceBookmark
    $script:tail.UserTurnVersion=6;& $receiveUser
    Assert ($script:lastUserVersion -eq 6 -and $null -eq $script:voicePlaybackBookmark -and -not (Test-Path -LiteralPath $saved)) 'Production externally received user turn did not invalidate old playback.'
    Write-Output ('PASS '+$script:checks+' voice playback bookmark checks; legacy='+[bool]$LegacyPlayer+'; all audio mocked.')
} finally {
    Stop-Output
    # Remove only this test run's direct fixture files; no recursive deletion.
    Get-ChildItem -LiteralPath $runtime -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $runtime -Force
}
