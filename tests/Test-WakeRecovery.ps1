param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type @'
namespace CodexReader {
    public static class AudioPlayer {
        public static string State="closed";
        public static int Stops;
        public static void Stop() { Stops++;State="closed"; }
    }
}
'@
function Import-Function([string]$File,[string]$Name) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $File),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw $errors[0].Message}
    $node=$ast.Find({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $Name},$true)
    if(-not $node){throw "Missing production function $Name"}
    return [scriptblock]::Create($node.Extent.Text)
}
. (Import-Function 'src\Assistant.ps1' 'Stop-Output')
. (Join-Path $Root 'src\AudioOutput.ps1')
. (Import-Function 'src\Assistant.ps1' 'Cancel-Recording')
. (Import-Function 'src\HandsFree.ps1' 'Test-ExternalCapture')
. (Join-Path $Root 'src\WakeRecovery.ps1')
function Remove-OwnedFiles($Paths) { $script:removed+=@($Paths) }
function Close-Job($Job,[switch]$Kill) { $script:closed+=@([pscustomobject]@{Job=$Job;Kill=[bool]$Kill}) }
function Test-WakeRecoveryRouteChanged { $script:routeChecks++;return $script:routeChanged }
function Reset-WakeRecoveryAudioRoute {
    if($script:mic.AnyCaptureActive -or $script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or [CodexReader.AudioPlayer]::State -in @('playing','paused')) {throw 'Route reset overlapped live audio.'}
    $script:routeResets++;$script:routeChanged=$false
    if($script:routeFails){throw 'Fixture route unavailable.'}
    return [pscustomobject]@{CaptureEndpointId='new-mic';RenderEndpointId='new-speaker'}
}
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Health([string]$State,[bool]$Needs=$false,[string]$Reason='') {
    $script:wakeListener.Health=[pscustomobject]@{State=$State;NeedsRecovery=$Needs;Reason=$Reason;HasActivated=$false;CapturedSamples=16000L;ProcessedSamples=16000L;CaptureAgeMs=20;ProgressAgeMs=20}
}
function Snapshot {
    $sessions=@()
    if($script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or $script:recorder.IsRecording -or $script:recorder.IsStopping){$sessions+=@([pscustomobject]@{Active=$true;ProcessId=$PID})}
    if($script:external){$sessions+=@([pscustomobject]@{Active=$true;ProcessId=987654})}
    $script:mic.Sessions=$sessions;$script:mic.AnyCaptureActive=$sessions.Count -gt 0;$script:mic.ScanCount++
}
function Reset-Case {
    $script:now=[DateTime]::SpecifyKind([DateTime]'2026-09-09T02:00:00',[DateTimeKind]::Utc)
    $script:routeChanged=$false;$script:routeFails=$false;$script:routeChecks=0;$script:routeResets=0;$script:external=$false
    $script:closed=@();$script:removed=@();$script:epoch=0;$script:audioPath='';$script:ttsJob=$null
    $script:speechQueue=New-Object 'System.Collections.Generic.Queue[string]'
    $script:voiceGeneration=10L;$script:autoDispatch=$null;$script:asrJob=$null;$script:submitAfterRecognition=$false
    $script:bridgeJob=$null;$script:pendingUncertain=$false;$script:connected=$true;$script:closing=$false;$script:recMode='idle';$script:bindingAvailability='active'
    $script:handsFreeEnabled=$true;$script:bargeInEnabled=$true;$script:handsFreePhase='listening';$script:handsFreeCapture=$false;$script:echoQuestionCapture=$false
    $script:wakeOwnsMicrophone=$true;$script:lastWakeVersion=0L;$script:lastMicVersion=0L;$script:wakePhrase='你好，声伴';$script:TestMode=$false
    $script:notice='';$script:errorText='';$script:recordPath='';$script:recordPrefix=''
    $script:threadId='original-thread';$script:latest='完整答案';$script:AnswerBox=[pscustomobject]@{Text=$script:latest};$script:InputBox=[pscustomobject]@{Text='';IsReadOnly=$false}
    $script:mic=[pscustomobject]@{Ready=$true;LastError='';ScanCount=1L;ActivationVersion=1L;AnyCaptureActive=$true;Sessions=@([pscustomobject]@{Active=$true;ProcessId=$PID})}
    $script:recorder=[pscustomobject]@{IsRecording=$false;IsStopping=$false;Cancels=0}
    $script:recorder|Add-Member ScriptMethod Cancel {$this.Cancels++;$this.IsRecording=$false;$this.IsStopping=$true}
    $script:wakeListener=[pscustomobject]@{IsListening=$true;IsStopping=$false;IsReady=$true;ActivationVersion=0L;HasQuestion=$false;Error='';Health=$null;Stops=0;Starts=0;StartThrows=$false;CaptureEndpointId='old-mic';RenderEndpointId='old-speaker'}
    $script:wakeListener|Add-Member ScriptMethod GetHealthSnapshot {return $this.Health}
    $script:wakeListener|Add-Member ScriptMethod RequestRecoveryStop {$this.Stops++;$this.IsReady=$false;if($this.IsListening){$this.IsStopping=$true};$this.Health.State='stopping';$this.Health.NeedsRecovery=$false}
    $script:wakeListener|Add-Member ScriptMethod StartEcho {
        param($Phrase,$Capture,$Render)
        if($this.IsListening -or $this.IsStopping -or $script:mic.AnyCaptureActive){throw 'Second microphone stream opened.'}
        $this.Starts++;if($this.StartThrows){throw 'Fixture startup failure.'}
        $this.CaptureEndpointId=$Capture;$this.RenderEndpointId=$Render;$this.IsListening=$true;$this.IsStopping=$false;$this.IsReady=$false;$this.Error=''
        Health 'starting';Snapshot
    }
    $script:wakeListener|Add-Member ScriptMethod Start {param($Phrase);$this.StartEcho($Phrase,'default-mic','')}
    Health 'healthy';[CodexReader.AudioPlayer]::State='closed';[CodexReader.AudioPlayer]::Stops=0
    Initialize-WakeRecovery $script:now
}
function Tick([double]$Seconds=0) {$script:now=$script:now.AddSeconds($Seconds);Update-WakeRecovery $script:now}
function Fault {Health 'stalled' $true 'capture_stalled';Tick}
function Released {$script:wakeListener.IsListening=$false;$script:wakeListener.IsStopping=$false;$script:wakeListener.IsReady=$false;Health 'idle';Snapshot}
function Start-Once {Fault;Released;Tick;Tick 3;Assert ($script:wakeRecovery.Phase -eq 'starting') 'Expected one recovery startup.'}
$script:checks=0;$script:cases=@()
function Case([string]$Name,[scriptblock]$Body){Reset-Case;try{&$Body;$script:cases+=@(@{name=$Name;passed=$true})}catch{$script:cases+=@(@{name=$Name;passed=$false;error=$_.Exception.Message})}}

Case 'Stale ready revokes old work, preserves draft and waits for release plus a new mic scan' {
    $InputBox.Text='原来的草稿';$script:autoDispatch=@{Generation=10;Text='原来的草稿'};$script:recMode='listening';$script:recorder.IsRecording=$true
    $script:handsFreeCapture=$true;$script:speechQueue.Enqueue('旧语音');[CodexReader.AudioPlayer]::State='playing'
    $script:wakeListener.ActivationVersion=4L;Fault
    Assert ((Test-WakeRecoveryPending) -and $script:wakeRecovery.Phase -eq 'releasing') 'Fault was not intercepted.'
    Assert ($script:voiceGeneration -gt 10 -and -not $script:autoDispatch -and $script:lastWakeVersion -eq 4) 'Old ASR/KWS generation remained actionable.'
    Assert ($script:recorder.Cancels -eq 1 -and [CodexReader.AudioPlayer]::Stops -eq 1 -and $script:speechQueue.Count -eq 0) 'Failed recording/old output was not cancelled.'
    Assert ($InputBox.Text -eq '原来的草稿' -and $script:latest -eq '完整答案' -and $AnswerBox.Text -eq '完整答案' -and $script:threadId -eq 'original-thread') 'Recovery changed draft, answer or binding.'
    $script:wakeListener.IsListening=$false;$script:wakeListener.IsStopping=$false;$script:recorder.IsStopping=$false;Health 'idle'
    Tick 1;Assert ($script:wakeRecovery.Phase -eq 'releasing') 'Stale MicGuard snapshot was accepted as release.'
    Snapshot;Tick;Assert ($script:wakeRecovery.Phase -eq 'backoff' -and -not $script:wakeOwnsMicrophone) 'Fresh release confirmation was not accepted.'
    Tick 3;Assert ($script:wakeListener.Starts -eq 0) 'Draft did not block rebuilding.'
    $InputBox.Text='';Tick;Assert ($script:wakeListener.Starts -eq 1 -and $script:routeResets -eq 1) 'Safe recovery did not restart exactly once.'
    Assert ($script:wakeListener.CaptureEndpointId -eq 'new-mic' -and $script:wakeListener.RenderEndpointId -eq 'new-speaker') 'New route was not used.'
    Tick 1;Assert ((Test-WakeRecoveryPending)) 'Startup was called recovered before actual health.'
    Health 'healthy';$script:wakeListener.IsReady=$true;Tick
    Assert (-not (Test-WakeRecoveryPending) -and $script:handsFreePhase -eq 'listening' -and $script:handsFreeEnabled -and $script:bargeInEnabled) 'Healthy recovery or original preferences were lost.'
}
Case 'Exactly 3/6/12 backoff attempts and no fourth restart until explicit reset' {
    Fault
    foreach($delay in @(3,6,12)) {
        Released;Tick;$before=$script:wakeListener.Starts
        Tick ($delay-0.1);Assert ($script:wakeListener.Starts -eq $before) 'Backoff restarted early.'
        Tick 0.1;Assert ($script:wakeListener.Starts -eq $before+1) 'Backoff did not make one attempt.'
        Fault
    }
    Released;Tick
    Assert ($script:wakeRecovery.Phase -eq 'blocked' -and $script:wakeRecovery.AttemptCount -eq 3) 'Retry budget was not enforced.'
    Tick 400;Assert ($script:wakeListener.Starts -eq 3) 'Exhausted budget silently restarted forever.'
    Assert ($script:handsFreeEnabled -and $script:bargeInEnabled) 'Retry failure persisted disabled preferences.'
    Initialize-WakeRecovery $script:now;Assert ($script:wakeRecovery.AttemptCount -eq 0 -and -not (Test-WakeRecoveryPending)) 'Explicit user reset did not reset the budget.'
}
Case 'Native release timeout never permits a second stream or forgets stopping ownership' {
    Fault;Tick 7.9;Assert ($script:wakeRecovery.Phase -eq 'releasing') 'Release deadline was too early.'
    Tick 0.1;Assert ($script:wakeRecovery.Phase -eq 'blocked' -and $script:wakeOwnsMicrophone -and $script:wakeListener.Starts -eq 0) 'Stuck device was reopened or falsely marked released.'
    Initialize-WakeRecovery $script:now;Assert ($script:wakeRecovery.Phase -eq 'releasing') 'User toggle forgot an unreleased stream.'
    Tick 8;Assert ($script:wakeRecovery.Phase -eq 'blocked' -and $script:wakeListener.Starts -eq 0) 'Reset bypassed physical release.'
}
Case 'Owned ASR and Codex mutations continue but old recognition loses send permission' {
    $script:recMode='transcribing';$InputBox.Text='不能丢的草稿';$script:asrJob=@{SendAfter=$true;Generation=10;Process=[pscustomobject]@{Id=123}}
    $asr=$script:asrJob;$script:bridgeJob=@{Purpose='voice-create';Process=[pscustomobject]@{Id=456}};$bridge=$script:bridgeJob
    Fault
    Assert ([object]::ReferenceEquals($script:asrJob,$asr) -and -not $asr.SendAfter -and $script:voiceGeneration -ne $asr.Generation -and $script:closed.Count -eq 0) 'Recovery killed ASR or left its result eligible.'
    Assert ([object]::ReferenceEquals($script:bridgeJob,$bridge) -and $InputBox.Text -eq '不能丢的草稿') 'Recovery modified a create worker or draft.'
    Released;Tick;Tick 3;Assert ($script:wakeListener.Starts -eq 0) 'ASR/create/draft permitted capture restart.'
    $script:asrJob=$null;$script:recMode='idle';$InputBox.Text='';$script:bridgeJob=@{Purpose='send'};Tick
    Assert ($script:wakeListener.Starts -eq 0 -and $script:closed.Count -eq 0) 'An active send was interrupted or ignored.'
    $script:bridgeJob=$null;Tick;Assert ($script:wakeListener.Starts -eq 1) 'Safe completion did not unblock recovery.'
}
Case 'External capture and unknown mic state block restart without discarding newly queued answers' {
    Fault;Released;Tick;$script:speechQueue.Enqueue('刚到的新回答');$script:external=$true;Snapshot;Tick 3
    Assert ($script:wakeListener.Starts -eq 0 -and $script:speechQueue.Count -eq 1) 'External capture was ignored or new answer discarded.'
    $script:external=$false;Snapshot;$script:mic.Ready=$false;Tick;Assert ($script:wakeListener.Starts -eq 0) 'Unknown microphone state permitted restart.'
    $script:mic.Ready=$true;Tick;Assert ($script:wakeListener.Starts -eq 1 -and $script:speechQueue.Count -eq 1) 'Queued answer blocked safe reconstruction or was cleared.'
}
Case 'Device change and long timer gap defer during speech and recording' {
    [CodexReader.AudioPlayer]::State='playing';$script:routeChanged=$true;Tick
    Assert ($script:wakeRecovery.Phase -eq 'deferred' -and -not (Test-WakeRecoveryPending) -and [CodexReader.AudioPlayer]::Stops -eq 0) 'Route change interrupted speaking or blocked its normal state machine.'
    $script:routeChanged=$false;$script:recMode='listening';$script:recorder.IsRecording=$true;[CodexReader.AudioPlayer]::State='closed';Tick 20
    Assert ($script:wakeRecovery.Phase -eq 'deferred' -and $script:recorder.Cancels -eq 0) 'Timer gap cancelled the active question.'
    $script:recMode='idle';$script:recorder.IsRecording=$false;$InputBox.Text='识别后的文字';Snapshot;Tick
    Assert ($script:wakeRecovery.Phase -eq 'deferred' -and $InputBox.Text -eq '识别后的文字') 'Deferred refresh removed a completed draft.'
    $InputBox.Text='';Tick;Assert ($script:wakeRecovery.Phase -eq 'releasing' -and $script:wakeListener.Stops -eq 1) 'Idle completion did not run deferred refresh.'
}
Case 'New activity during recovery startup releases only its listener and preserves newer work' {
    foreach($kind in @('draft','external','disconnect','recording','asr','send','create','generation')) {
        Reset-Case;Start-Once;$stops=[CodexReader.AudioPlayer]::Stops;$generation=$script:voiceGeneration
        switch($kind){
            'draft' {$InputBox.Text='新的草稿'}
            'external' {$script:external=$true;Snapshot}
            'disconnect' {$script:connected=$false}
            'recording' {$script:recMode='listening';$script:recorder.IsRecording=$true;Snapshot}
            'asr' {$script:asrJob=@{SendAfter=$true;Generation=$generation}}
            'send' {$script:bridgeJob=@{Purpose='send'}}
            'create' {$script:bridgeJob=@{Purpose='voice-create'}}
            'generation' {$script:voiceGeneration++}
        }
        Tick
        Assert ($script:wakeRecovery.Phase -eq 'releasing' -and $script:wakeListener.Stops -eq 2) ('Startup ignored new '+$kind)
        Assert ($script:closed.Count -eq 0 -and $script:recorder.Cancels -eq 0 -and [CodexReader.AudioPlayer]::Stops -eq $stops) ('Startup recovery cancelled newer '+$kind)
        if($kind -eq 'draft'){Assert ($InputBox.Text -eq '新的草稿') 'New draft was removed.'}
        if($kind -eq 'recording'){Released;Tick 20;Assert ($script:wakeRecovery.Phase -eq 'releasing') 'New manual recording was mistaken for old device release failure.'}
    }
}
Case 'Ordinary stopping stall escalates after 3 seconds then respects the 8 second release deadline' {
    $script:wakeListener.IsStopping=$true;Health 'stopping';Tick;Tick 2.9
    Assert ($script:wakeListener.Stops -eq 0) 'Normal asynchronous stop escalated too soon.'
    Tick 0.1;Assert ($script:wakeRecovery.Phase -eq 'releasing' -and $script:wakeListener.Stops -eq 1 -and $script:wakeRecovery.Reason -eq 'normal_stop_stalled') 'Hung normal Suspend was never recovered.'
    Tick 8;Assert ($script:wakeRecovery.Phase -eq 'blocked' -and $script:wakeListener.Starts -eq 0) 'Stalled normal stop opened another microphone.'
}
Case 'Disabled or closing never restart and missing legacy health interface is inert' {
    Start-Once;$script:handsFreeEnabled=$false;Tick;Assert ($script:wakeListener.Stops -eq 2 -and $script:wakeListener.Starts -eq 1) 'Disabled pending startup was not stopped.'
    Released;Tick 400;Assert ($script:wakeListener.Starts -eq 1 -and -not $script:handsFreeEnabled) 'Disabled wake was restarted.'
    Reset-Case;Fault;Released;Tick;$script:closing=$true;Tick 20;Assert ($script:wakeListener.Starts -eq 0) 'Closing process reopened capture.'
    Reset-Case;$script:wakeListener.PSObject.Members.Remove('GetHealthSnapshot');$script:routeChanged=$true;Tick 60
    Assert ($script:wakeRecovery.Phase -eq 'idle' -and $script:wakeListener.Stops -eq 0 -and $script:routeChecks -eq 0) 'Legacy fake accidentally triggered health or route recovery.'
}
Case 'Rolling budget expires after healthy operation and unrelated errors survive' {
    Start-Once;Health 'healthy';Tick
    $script:wakeRecovery.Attempts=@($script:now.AddMinutes(-6));$script:wakeRecovery.AttemptCount=1;$script:errorText='其它设置错误'
    Fault;Released;Tick;Assert ($script:wakeRecovery.AttemptCount -eq 0) 'Old attempts never expired from the five-minute window.'
    Tick 3;Health 'healthy';Tick
    Assert ($script:wakeRecovery.Phase -eq 'idle' -and $script:errorText -eq '其它设置错误') 'Healthy recovery cleared an unrelated application error.'
}
Case 'Later startup and health failures preserve answers queued after the original fault' {
    Start-Once;$script:speechQueue.Enqueue('第一段新回答');Fault
    Assert ($script:speechQueue.Count -eq 1 -and $script:speechQueue.Peek() -eq '第一段新回答') 'Repeated health failure deleted a newly arrived answer.'
    Released;Tick;$script:speechQueue.Enqueue('第二段新回答');$script:wakeListener.StartThrows=$true;Tick 6
    Assert ($script:wakeRecovery.Phase -eq 'releasing' -and $script:speechQueue.Count -eq 2) 'Worker startup failure discarded queued answers.'
    Assert (($script:speechQueue.ToArray() -join '|') -eq '第一段新回答|第二段新回答') 'Repeated recovery changed speech ordering.'
}
Case 'Deferred checks never consume an activation and old completed activation does not block forever' {
    $script:routeChanged=$true;$script:wakeListener.ActivationVersion=1L;$script:wakeListener.HasQuestion=$true;$script:wakeListener.Health.HasActivated=$true
    Tick
    Assert ($script:wakeRecovery.Phase -eq 'deferred' -and $script:wakeListener.Stops -eq 0 -and $script:lastWakeVersion -eq 0) 'Route check swallowed an unconsumed wake event.'
    $script:lastWakeVersion=1L;$script:handsFreePhase='listening';Tick
    Assert ($script:wakeRecovery.Phase -eq 'deferred' -and $script:wakeListener.Stops -eq 0) 'Pending echo question was mistaken for an idle listener.'
    $script:wakeListener.HasQuestion=$false;$script:wakeListener.IsListening=$false;$script:wakeListener.Health.State='idle';Snapshot;Tick
    Assert ($script:wakeRecovery.Phase -eq 'releasing') 'The last run HasActivated flag blocked deferred recovery forever.'
}
Case 'Turning wake off clears recovery only after physical release and a fresh scan' {
    Fault;$script:handsFreeEnabled=$false;Initialize-WakeRecovery $script:now;Tick
    Assert (Test-WakeRecoveryPending) 'Disable bypassed the live stopping stream.'
    $script:wakeListener.IsListening=$false;$script:wakeListener.IsStopping=$false;Health 'idle';Tick
    Assert (Test-WakeRecoveryPending) 'Disable accepted an old microphone scan.'
    Snapshot;Tick
    Assert (-not (Test-WakeRecoveryPending) -and -not $script:wakeOwnsMicrophone -and $script:wakeListener.Starts -eq 0) 'Disabled recovery stayed stuck or reopened the listener.'
    Assert (-not (Test-ExternalCapture)) 'Released disabled recovery still blocked manual-mode playback.'
}

foreach ($recoveryState in @('archived','missing')) {
    Case ('Local-only '+$recoveryState+' context can rebuild listening without enabling sends') {
        $script:connected=$false;$script:bindingAvailability=$recoveryState
        Start-Once
        Health 'healthy';Tick
        Assert ($script:wakeRecovery.Phase -eq 'idle' -and $script:handsFreePhase -eq 'listening') 'Local-only recovery remained blocked.'
        Assert (-not $script:connected) 'Microphone recovery enabled an invalid send destination.'
    }
}
Case 'Unknown disconnected context cannot invent permission to reopen capture' {
    $script:connected=$false;$script:bindingAvailability='unknown'
    Fault;Released;Tick;Tick 3
    Assert ($script:wakeListener.Starts -eq 0) 'Unknown disconnected context reopened the microphone.'
}
$result=@{passed=@($script:cases|Where-Object{$_.passed}).Count;failed=@($script:cases|Where-Object{-not $_.passed}).Count;checks=$script:checks;cases=$script:cases;powershell=$PSVersionTable.PSVersion.ToString();boundaries='Real WakeRecovery plus production cancellation/external-capture functions; injected clock, listener health, endpoint routes, sessions, processes and audio. No devices, playback, live worker control or Codex operations.'}
$output=Join-Path $Root 'work\tests\wake-recovery';[void][IO.Directory]::CreateDirectory($output)
[IO.File]::WriteAllText((Join-Path $output 'result.json'),($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json -Depth 6
if($result.failed){exit 1}
