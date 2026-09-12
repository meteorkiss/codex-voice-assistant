param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\reader-core.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'src\Assistant.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
foreach($name in @('Read-BoundTaskAnswers','Send-Text')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
$fixture=Join-Path $Root ('work\tests\transcript-recovery-'+[Guid]::NewGuid().ToString('N'))
$activeDir=Join-Path $fixture 'sessions\2026\09\12'
$archiveDir=Join-Path $fixture 'archived_sessions'
$name='rollout-2026-09-12T01-02-03-11111111-1111-4111-8111-111111111111.jsonl'
$active=Join-Path $activeDir $name
$archived=Join-Path $archiveDir $name
$unrelated=Join-Path $archiveDir 'rollout-2026-09-12T01-02-03-22222222-2222-4222-8222-222222222222.jsonl'
$utf8=New-Object Text.UTF8Encoding($false)
function EventLine([string]$Id){return ((@{type='event_msg';payload=@{type='task_complete';turn_id=$Id;last_agent_message=$Id}}|ConvertTo-Json -Compress)+"`n")}
function Move-Fixture([string]$From,[string]$To){
    $allowed=[IO.Path]::GetFullPath($fixture).TrimEnd('\')+'\'
    foreach($path in @($From,$To)){if(-not [IO.Path]::GetFullPath($path).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture move escaped test root.'}}
    Move-Item -LiteralPath $From -Destination $To
}
try{
    [void][IO.Directory]::CreateDirectory($activeDir)
    [void][IO.Directory]::CreateDirectory($archiveDir)
    [IO.File]::WriteAllText($active,(EventLine 'history'),$utf8)
    $script:tail=New-TranscriptTail $active
    $offset=$tail.Offset
    Move-Fixture $active $archived
    Assert (@(Read-NewCompletedAnswers $tail).Count -eq 0) 'Archive move replayed history.'
    Assert ($tail.Path -ceq $archived -and $tail.Offset -eq $offset -and $tail.Seen.Contains('history')) 'Archive move lost exact path/cursor/deduplication.'
    [IO.File]::AppendAllText($archived,(EventLine 'new-answer'),$utf8)
    $answers=@(Read-NewCompletedAnswers $tail)
    Assert ($answers.Count -eq 1 -and $answers[0].Text -ceq 'new-answer') 'New answer after relocation was lost.'
    Move-Fixture $archived $active
    Assert (@(Read-NewCompletedAnswers $tail).Count -eq 0 -and $tail.Path -ceq $active) 'Restore move replayed answers or kept stale path.'
    Move-Fixture $active $unrelated
    Assert (-not (Find-RelocatedTranscript $active)) 'Recovery selected another task.'
    $script:bindingReadError='';$script:closeCount=0;$script:cancelCount=0;$script:stopCount=0
    function Close-ShortFollowUp {param([string]$Message,[switch]$CancelCapture)$script:closeCount++}
    function Stop-Output {$script:stopCount++}
    function Cancel-Recording {$script:cancelCount++}
    $script:recMode='listening';$script:connected=$true
    $InputBox=[pscustomobject]@{Text='preserved draft';IsReadOnly=$false}
    $now=[DateTime]::UtcNow
    Assert (@(Read-BoundTaskAnswers $now).Count -eq 0) 'Missing transcript emitted data.'
    Assert ($script:bindingReadError -and $script:lastTailRead -eq $now) 'Failed read did not expose binding error or throttle.'
    [void](Read-BoundTaskAnswers ($now.AddMilliseconds(600)))
    Assert ($script:closeCount -eq 1 -and $script:cancelCount -eq 0 -and $script:stopCount -eq 0) 'Repeated transcript errors interrupted ordinary audio.'
    Assert ($script:recMode -eq 'listening' -and $InputBox.Text -ceq 'preserved draft') 'Transcript failure changed recording or draft.'
    $script:recMode='idle';$script:autoDispatch=$null;$script:localHandled=$false;$script:sendCalls=0
    function Try-LocalAssistantCommand([string]$Text){$script:localHandled=($Text -ceq 'local-switch');return $script:localHandled}
    function Test-VoiceTaskCreateBlocksSend{return $false}
    function Start-Bridge {$script:sendCalls++;return $true}
    Send-Text
    Assert ($script:sendCalls -eq 0 -and $InputBox.Text -ceq 'preserved draft') 'Disconnected message was sent or discarded.'
    $InputBox.Text='local-switch';Send-Text
    Assert ($script:localHandled -and $script:sendCalls -eq 0) 'Binding failure blocked local routing or forwarded command to chat.'
    Move-Fixture $unrelated $active
    Assert (@(Read-BoundTaskAnswers ($now.AddSeconds(2))).Count -eq 0 -and -not $script:bindingReadError) 'Same-task recovery did not clear error without history replay.'
    @{ok=$true;checks=$script:checks;boundary='Generated transcript moves and extracted production read/send functions only; no real task, capture or playback.'}|ConvertTo-Json -Compress
}finally{
    # Remove only this test's exact files, then its empty directories.
    foreach($path in @($active,$archived,$unrelated)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
    foreach($path in @($activeDir,(Split-Path $activeDir),(Split-Path (Split-Path $activeDir)),(Join-Path $fixture 'sessions'),$archiveDir,$fixture)){
        if([IO.Directory]::Exists($path) -and [IO.Directory]::GetFileSystemEntries($path).Count -eq 0){[IO.Directory]::Delete($path)}
    }
}
