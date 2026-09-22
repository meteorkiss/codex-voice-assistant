$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
if(-not ('CodexReader.AudioPlayer' -as [type])) { Add-Type -TypeDefinition 'namespace CodexReader { public static class AudioPlayer { public static string State="closed"; public static string RenderEndpointId="render-test"; } }' }
. (Join-Path $Root 'src\VoiceCommands.ps1')
. (Join-Path $Root 'src\NoWakeConversation.ps1')

$checks=0;$script:routed=0
function Assert-NoWakeConversation($Condition,[string]$Message) { $script:checks++; if(-not $Condition){throw $Message} }
function Close-Job($Job,[switch]$Kill) {}
function Suspend-WakeListener {}
function Try-LocalAssistantCommand([string]$Text) {
    $script:routed++
    $was=$script:consumingLocalCommand;$script:consumingLocalCommand=$true
    try{$script:InputBox.Text=''}finally{$script:consumingLocalCommand=$was}
    return $true
}

$script:closing=$false;$script:recMode='idle';$script:asrJob=$null;$script:bridgeJob=$null;$script:pendingUncertain='';$script:pendingSends=@{}
$script:threadId='thread-a';$script:connected=$true;$script:bindingAvailability='active';$script:bindingReadError='';$script:bindingGeneration=9
$script:manualTaskBinding=$null;$script:voiceTaskCreate=$null;$script:ttsJob=$null;$script:speechQueue=New-Object 'Collections.Generic.Queue[string]'
$script:InputBox=[pscustomobject]@{Text=''};$script:mic=[pscustomobject]@{Ready=$true;LastError='';Sessions=@();AnyCaptureActive=$false;DefaultCaptureEndpointId='capture-test'}
$script:voiceTaskSwitch=@{Generation=12;Phase='choosing';SourceThreadId='thread-a';ExpiresAt=[DateTime]::UtcNow.AddMinutes(1);Candidates=@(@{title='one'},@{title='two'})}

Assert-NoWakeConversation ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'off') 'No-wake did not default off.'
Set-NoWakeMode observe
Assert-NoWakeConversation ($script:noWakeMode -eq 'observe' -and $script:noWakePhase -eq 'starting') 'Observe mode did not require an explicit mode change.'
Set-NoWakeMode context
$snapshot=Get-NoWakeContextSnapshot '选择第二个'
Assert-NoWakeConversation ($snapshot.Active -and $snapshot.Command.Action -eq 'chooseTask' -and $snapshot.Command.Value -eq 2) 'Live numbered confirmation context was not captured.'

$decision=Get-NoWakeDecision -Text '选择第二个' -Mode context -Context $snapshot
$handled=Invoke-NoWakeContextDecision '选择第二个' $decision $snapshot
Assert-NoWakeConversation ($handled -and $script:routed -eq 1 -and -not $script:InputBox.Text) 'Accepted confirmation did not use the existing local route exactly once.'

$stale=$snapshot.Clone();$script:voiceTaskSwitch.Generation=13
$handled=Invoke-NoWakeContextDecision '选择第二个' $decision $stale
Assert-NoWakeConversation (-not $handled -and $script:routed -eq 1) 'A stale context executed again.'
$script:voiceTaskSwitch.Generation=12

$script:InputBox.Text='用户草稿'
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'draft') 'Draft did not pause no-wake.'
$script:InputBox.Text='';$script:pendingUncertain='unknown-request'
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'pending-send') 'Unknown send did not pause no-wake.'
$script:pendingUncertain='';[CodexReader.AudioPlayer]::State='playing'
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'playback') 'Own playback did not pause no-wake.'
[CodexReader.AudioPlayer]::State='closed';$script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=$PID+1})
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'external-capture') 'External capture did not pause no-wake.'
$script:mic.Sessions=@()
Assert-NoWakeConversation (-not (Get-NoWakeBlockReason)) 'Safe synthetic state stayed blocked.'

# Creation lifecycle and current-task voice ownership are distinct. A valid
# explicit abandon releases the current destination even while an unresolved
# creation receipt remains queryable and duplicate-safe. Inconsistent records
# remain fail-closed and are never deleted to make the test pass.
foreach($state in @(
    @{phase=$null;creation=$null;send=$false;abandoned=$false;auto=$false;blocked=$false},
    @{phase='bound';creation='ready';send=$false;abandoned=$false;auto=$false;blocked=$false},
    @{phase='rejected';creation='rejected';send=$false;abandoned=$false;auto=$false;blocked=$false},
    @{phase='rejected';creation='rejected';send=$false;abandoned=$true;auto=$false;blocked=$false},
    @{phase='not_found';creation='not_found';send=$false;abandoned=$false;auto=$false;blocked=$false},
    @{phase='abandoned';creation='ready';send=$false;abandoned=$true;auto=$false;blocked=$false},
    @{phase='unknown';creation='unknown';send=$false;abandoned=$true;auto=$false;blocked=$false},
    @{phase='creating';creation='dispatching';send=$true;abandoned=$false;auto=$true;blocked=$true},
    @{phase='checking';creation='pending';send=$true;abandoned=$false;auto=$true;blocked=$true},
    @{phase='unknown';creation='unknown';send=$true;abandoned=$false;auto=$false;blocked=$true},
    @{phase='unavailable';creation=$null;send=$true;abandoned=$false;auto=$false;blocked=$true},
    @{phase='abandoned';creation='ready';send=$true;abandoned=$true;auto=$false;blocked=$true},
    @{phase='abandoned';creation='ready';send=$false;abandoned=$false;auto=$false;blocked=$true},
    @{phase='unknown';creation='unknown';send=$false;abandoned=$true;auto=$true;blocked=$true},
    @{phase='bound';creation='unknown';send=$false;abandoned=$false;auto=$false;blocked=$true}
)) {
    $script:voiceTaskCreate=if($null -eq $state.phase){$null}else{@{Phase=$state.phase;CreationState=$state.creation;SendBlocked=$state.send;ConnectionAbandoned=$state.abandoned;AutoBindAllowed=$state.auto}}
    $reason=Get-NoWakeBlockReason
    Assert-NoWakeConversation (($reason -eq 'create-pending') -eq $state.blocked) ('Creation phase '+[string]$state.phase+' produced the wrong no-wake ownership decision.')
}
$script:voiceTaskCreate=@{Phase='abandoned';CreationState='ready';SendBlocked=$false;ConnectionAbandoned=$true;AutoBindAllowed=$false}
$boundSnapshot=Get-NoWakeContextSnapshot '选择第二个'
$boundDecision=Get-NoWakeDecision -Text '选择第二个' -Mode context -Context $boundSnapshot
$handled=Invoke-NoWakeContextDecision '选择第二个' $boundDecision $boundSnapshot
Assert-NoWakeConversation ($handled -and $script:routed -eq 2 -and (Test-VoiceTaskCreatePending)) 'An explicitly abandoned created-task receipt blocked the current contextual route or lost its recoverable ledger.'
$script:voiceTaskCreate=@{Phase='unknown';CreationState='unknown';SendBlocked=$true;ConnectionAbandoned=$false;AutoBindAllowed=$false}
$unknownSnapshot=Get-NoWakeContextSnapshot '选择第二个'
$unknownDecision=Get-NoWakeDecision -Text '选择第二个' -Mode context -Context $unknownSnapshot
$handled=Invoke-NoWakeContextDecision '选择第二个' $unknownDecision $unknownSnapshot
Assert-NoWakeConversation (-not $handled -and $script:routed -eq 2) 'An unknown creation receipt was allowed to route.'
$script:noWakePhase='observing';Suspend-NoWakeConversation (Get-NoWakeBlockReason)
Assert-NoWakeConversation ($script:noWakePhase -eq 'paused' -and $script:notice.Contains('新建请求仍待核对')) 'The creation-specific no-wake block reason was not visible.'
$script:voiceTaskCreate=$null

$script:pendingSends=@{'thread-a'=[pscustomobject]@{Text='queued'}}
$handled=Invoke-NoWakeContextDecision '选择第二个' $decision (Get-NoWakeContextSnapshot '选择第二个')
Assert-NoWakeConversation (-not $handled -and $script:routed -eq 2) 'A pending send did not block contextual execution.'
$script:pendingSends=@{}

$staleSegment=[pscustomobject]@{Generation=($script:noWakeGeneration-1);Pcm=[byte[]](1,2);StartedAt=[DateTime]::UtcNow;EndedAt=[DateTime]::UtcNow;Reason='silence'}
Start-NoWakeTranscription $staleSegment
Assert-NoWakeConversation ($null -eq $script:noWakeAsrJob) 'A stale capture segment started transcription.'

$stuckCapture=[pscustomobject]@{Released=$false;StopCalls=0;Disposed=$false}
$stuckCapture | Add-Member ScriptMethod Stop { $this.StopCalls++ }
$stuckCapture | Add-Member ScriptMethod StopAndWait { param([int]$TimeoutMs) return $this.Released }
$stuckCapture | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
$script:noWakeCapture=$stuckCapture;$script:noWakeMode='observe';$script:noWakePhase='observing'
Set-NoWakeMode context
Assert-NoWakeConversation ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'stopping' -and $stuckCapture.StopCalls -eq 1 -and -not $stuckCapture.Disposed) 'Failed capture release did not fail closed.'
$stuckCapture.Released=$true
Update-NoWakeConversation
Assert-NoWakeConversation ($null -eq $script:noWakeCapture -and $script:noWakePhase -eq 'off' -and $stuckCapture.Disposed) 'Off-mode retry did not finish capture release.'

Set-NoWakeMode off
Assert-NoWakeConversation ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'off') 'Turning no-wake off did not restore the off state.'
[pscustomobject]@{passed=$true;checks=$checks;routed=$script:routed;boundary='Synthetic state and existing local confirmation parser only; no microphone, ASR, Codex, task mutation or message send.'} | ConvertTo-Json -Compress
