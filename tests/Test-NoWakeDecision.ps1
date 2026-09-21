$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'src\NoWakeDecision.ps1')

$checks=0
function Assert-NoWake($Condition,[string]$Message) { $script:checks++; if(-not $Condition){throw $Message} }
function Context($command,$count=1) { return @{Active=$true;ContextId='ctx-1';SourceThreadId='thread-a';CurrentThreadId='thread-a';ExpiresUtc=[DateTime]::UtcNow.AddMinutes(1);CandidateCount=$count;Command=$command} }

$off=Get-NoWakeDecision -Text '是的' -Mode off
Assert-NoWake ($off.Disposition -eq 'ignore' -and $off.ReasonCodes -contains 'mode-off') 'Off mode evaluated speech.'

$ordinary=Get-NoWakeDecision -Text '帮我打开设置' -Mode context -Evidence @{DurationSeconds=1;EndReason='silence'}
Assert-NoWake ($ordinary.Disposition -eq 'uncertain' -and $ordinary.Route -eq 'none') 'A keyword-like utterance was authorized without addressing evidence.'
Assert-NoWake ($ordinary.ReasonCodes -contains 'no-addressing-model') 'The missing addressing model was hidden.'

$yes=[pscustomobject]@{Action='chooseTask';Value=1}
$observe=Get-NoWakeDecision -Text '是的' -Mode observe -Context (Context $yes)
Assert-NoWake ($observe.Disposition -eq 'accept' -and $observe.Route -eq 'none' -and $observe.ReasonCodes -contains 'observe-only') 'Observe mode did not remain side-effect free.'

$accept=Get-NoWakeDecision -Text '是的' -Mode context -Context (Context $yes)
Assert-NoWake ($accept.Disposition -eq 'accept' -and $accept.Route -eq 'context-confirmation' -and $accept.ContextId -eq 'ctx-1') 'A valid live confirmation was not accepted.'

$cancel=Get-NoWakeDecision -Text '取消' -Mode context -Context (Context ([pscustomobject]@{Action='cancelTaskSwitch';Value=$true}) 3)
Assert-NoWake ($cancel.Disposition -eq 'accept' -and $cancel.Route -eq 'context-confirmation') 'A valid cancellation was not accepted.'

$badNumber=Get-NoWakeDecision -Text '选择第五个' -Mode context -Context (Context ([pscustomobject]@{Action='chooseTask';Value=5}) 2)
Assert-NoWake ($badNumber.Disposition -eq 'uncertain' -and $badNumber.Route -eq 'none') 'An out-of-range candidate number was accepted.'

$expired=Context $yes
$expired.ExpiresUtc=[DateTime]::UtcNow.AddSeconds(-1)
$expiredResult=Get-NoWakeDecision -Text '是的' -Mode context -Context $expired
Assert-NoWake ($expiredResult.Disposition -eq 'uncertain') 'An expired context was accepted.'

$cross=Context $yes
$cross.CurrentThreadId='thread-b'
$crossResult=Get-NoWakeDecision -Text '是的' -Mode context -Context $cross
Assert-NoWake ($crossResult.Disposition -eq 'uncertain') 'A cross-task context was accepted.'

$stale=Get-NoWakeDecision -Text '是的' -Mode context -Evidence @{Stale=$true} -Context (Context $yes)
Assert-NoWake ($stale.Disposition -eq 'ignore' -and $stale.ReasonCodes -contains 'stale-generation') 'A stale result was not ignored.'

$playback=Get-NoWakeDecision -Text '是的' -Mode context -Evidence @{SelfPlayback=$true} -Context (Context $yes)
Assert-NoWake ($playback.Disposition -eq 'ignore' -and $playback.ReasonCodes -contains 'self-playback') 'Assistant playback could confirm a context.'

$external=Get-NoWakeDecision -Text '是的' -Mode context -Evidence @{ExternalCapture=$true} -Context (Context $yes)
Assert-NoWake ($external.Disposition -eq 'ignore' -and $external.ReasonCodes -contains 'external-capture') 'External capture could confirm a context.'

$long=Get-NoWakeDecision -Text '一段很长的背景对白' -Mode context -Evidence @{DurationSeconds=18;EndReason='maximum-duration'}
Assert-NoWake ($long.Disposition -eq 'uncertain' -and $long.ReasonCodes -contains 'maximum-duration') 'A maximum-duration segment was authorized.'

$empty=Get-NoWakeDecision -Text '' -Mode context
Assert-NoWake ($empty.Disposition -eq 'ignore' -and $empty.ReasonCodes -contains 'empty-transcript') 'Empty ASR was not ignored.'

[pscustomobject]@{passed=$true;checks=$checks;boundary='Pure target-decision policy only; no microphone, ASR, UI, task mutation or message send.'} | ConvertTo-Json -Compress
