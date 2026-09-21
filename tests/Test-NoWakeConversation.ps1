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

Set-NoWakeMode off
Assert-NoWakeConversation ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'off') 'Turning no-wake off did not restore the off state.'
[pscustomobject]@{passed=$true;checks=$checks;routed=$script:routed;boundary='Synthetic state and existing local confirmation parser only; no microphone, ASR, Codex, task mutation or message send.'} | ConvertTo-Json -Compress
