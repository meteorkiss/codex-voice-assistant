$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
if(-not ('CodexReader.AudioPlayer' -as [type])){Add-Type -TypeDefinition 'namespace CodexReader { public static class AudioPlayer { public static string State="closed"; public static string RenderEndpointId="render-test"; } }'}
. (Join-Path $Root 'src\VoiceCommands.ps1')
. (Join-Path $Root 'src\NoWakeConversation.ps1')
$checks=0
function Assert-NoWakeConversation($Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
function Close-Job($Job,[switch]$Kill){}
function Suspend-WakeListener{}
function Set-SecretaryPhase([string]$Phase,[string]$Message=''){$script:secretaryPhase=$Phase}
function Handle-SecretaryTranscript([string]$Text,[DateTime]$Now){$script:routedText=$Text;return $true}

$script:closing=$false;$script:recMode='idle';$script:asrJob=$null;$script:bridgeJob=$null;$script:pendingUncertain='';$script:pendingSends=@{}
$script:threadId='thread-a';$script:connected=$false;$script:bindingAvailability='missing';$script:bindingReadError='';$script:bindingGeneration=9
$script:manualTaskBinding=$null;$script:voiceTaskCreate=$null;$script:ttsJob=$null;$script:speechQueue=New-Object 'Collections.Generic.Queue[string]'
$script:InputBox=[pscustomobject]@{Text='保留的旧工作草稿'};$script:mic=[pscustomobject]@{Ready=$true;LastError='';Sessions=@();AnyCaptureActive=$false;DefaultCaptureEndpointId='capture-test'}
$script:continuousConversationEnabled=$true;$script:secretaryPhase='listening';$script:secretaryGeneration=4;$script:secretarySessionId='session-a';$script:routedText=''

Assert-NoWakeConversation ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'off') 'Capture owner did not default off.'
Set-NoWakeMode conversation
Assert-NoWakeConversation ($script:noWakeMode -eq 'conversation' -and $script:noWakePhase -eq 'starting') 'Conversation capture did not require explicit start.'
Assert-NoWakeConversation (-not (Get-NoWakeBlockReason)) 'Codex binding or old work draft incorrectly blocked the independent secretary conversation.'
$script:ttsJob=[pscustomobject]@{}
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'playback') 'Own playback did not pause conversation capture.'
$script:ttsJob=$null;$script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=$PID+1})
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'external-capture') 'External capture did not pause conversation capture.'
$script:mic.Sessions=@();$script:secretaryPhase='thinking'
Assert-NoWakeConversation ((Get-NoWakeBlockReason) -eq 'secretary-busy') 'Thinking phase did not suspend additional capture.'
$script:secretaryPhase='listening'

$staleSegment=[pscustomobject]@{Generation=($script:noWakeGeneration-1);Pcm=[byte[]](1,2);StartedAt=[DateTime]::UtcNow;EndedAt=[DateTime]::UtcNow;Reason='silence'}
Start-NoWakeTranscription $staleSegment
Assert-NoWakeConversation ($null -eq $script:noWakeAsrJob) 'A stale capture segment started transcription.'

$stuckCapture=[pscustomobject]@{Released=$false;StopCalls=0;Disposed=$false}
$stuckCapture|Add-Member ScriptMethod Stop{$this.StopCalls++}
$stuckCapture|Add-Member ScriptMethod StopAndWait{param([int]$TimeoutMs)return $this.Released}
$stuckCapture|Add-Member ScriptMethod Dispose{$this.Disposed=$true}
$script:noWakeCapture=$stuckCapture;$script:noWakeMode='conversation';$script:noWakePhase='listening'
Set-NoWakeMode off
Assert-NoWakeConversation ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'stopping' -and $stuckCapture.StopCalls -eq 1 -and -not $stuckCapture.Disposed) 'Failed capture release did not fail closed.'
$stuckCapture.Released=$true
Update-NoWakeConversation
Assert-NoWakeConversation ($null -eq $script:noWakeCapture -and $script:noWakePhase -eq 'off' -and $stuckCapture.Disposed) 'Off-mode retry did not finish capture release.'

$legacyRejected=$false
try{Set-NoWakeMode context}catch{$legacyRejected=$true}
Assert-NoWakeConversation $legacyRejected 'Legacy context mode was still accepted after the safe migration.'
[pscustomobject]@{passed=$true;checks=$checks;boundary='Synthetic capture state only; no microphone, ASR, HTTP, Codex task or message send.'}|ConvertTo-Json -Compress
