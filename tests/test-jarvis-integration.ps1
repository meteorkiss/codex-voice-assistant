param([string]$RunDir = '')
$ErrorActionPreference='Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$base = if ($RunDir) { [IO.Path]::GetFullPath($RunDir) } else { Join-Path $projectRoot 'work\tests\integration' }
[void][IO.Directory]::CreateDirectory($base)
$fixture = Join-Path $PSScriptRoot 'fixtures\voice-taiwan.wav'
$status=Join-Path $base 'jarvis-test-status.json'
$command=Join-Path $base 'jarvis-test-command.json'
$transcript=Join-Path $base 'jarvis-test-transcript.jsonl'
$checks=New-Object 'System.Collections.Generic.List[string]'
function Get-State { try { Get-Content -LiteralPath $status -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Wait-State($Predicate,[int]$Seconds=30) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do { $s=Get-State; if ($s -and (& $Predicate $s)) { return $s }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    throw ('Timed out: '+($s | ConvertTo-Json -Compress))
}
function Send-TestCommand([string]$Action,[string]$Path='') {
    $id=[Guid]::NewGuid().ToString()
    $payload=@{id=$id;action=$Action;path=$Path}|ConvertTo-Json -Compress
    $temp=$command+'.tmp'
    [IO.File]::WriteAllText($temp,$payload,(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $command -Force
    [void](Wait-State {param($s) $s.testCommand -eq $id})
}
function Add-Answer([string]$Text) {
    $tid=[Guid]::NewGuid().ToString()
    $started=@{type='event_msg';payload=@{type='task_started';turn_id=$tid}}|ConvertTo-Json -Compress
    $complete=@{type='event_msg';payload=@{type='task_complete';turn_id=$tid;last_agent_message=$Text}}|ConvertTo-Json -Compress
    [IO.File]::AppendAllText($transcript,$started+"`n"+$complete+"`n",(New-Object Text.UTF8Encoding($false)))
}
try {
    $s=Wait-State {param($s) $s.connected -and $s.recordingMode -eq 'idle' -and $s.inputText -like '*请帮我把今天的工作整理一下*'}
    if ($s.error -or $s.sent -ne 0) { throw 'Startup/ASR error' }
    $checks.Add('Real native bridge read + local ASR fixture displayed correctly; no real send')
    $lockedStatus=[IO.File]::Open($status,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $probeId=[Guid]::NewGuid().ToString()
    try {
        [IO.File]::WriteAllText($command,(@{id=$probeId;action='hide'}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
        Start-Sleep -Milliseconds 1100
    } finally { $lockedStatus.Dispose() }
    [void](Wait-State {param($s) $s.testCommand -eq $probeId -and -not $s.windowVisible})
    Send-TestCommand 'show'
    [void](Wait-State {param($s) $s.windowVisible})
    $checks.Add('A held status-file reader cannot stop the dispatcher; commands and telemetry recover')
    Add-Answer '你好，我是你的语音助手。这是一段朗读中断测试。现在开始录音时，我会先停止朗读，再打开麦克风。'
    $s=Wait-State {param($s) $s.spoken -ge 1 -and $s.playerState -eq 'playing'} 40
    $checks.Add('Final completion displayed and Microsoft Taiwan voice played')
    Send-TestCommand 'record'
    $s=Wait-State {param($s) $s.recordingMode -eq 'listening' -and $s.micActive} 10
    if ($s.playerState -ne 'closed') { throw 'Output still active during recording' }
    $checks.Add('Start speech closes output before actual microphone capture')
    Send-TestCommand 'cancel'
    $s=Wait-State {param($s) $s.recordingMode -eq 'idle' -and -not $s.micActive} 10
    if ($s.playerState -ne 'closed') { throw 'Old output resumed after cancellation' }
    $checks.Add('Cancel releases microphone and does not resume old answer')
    $beforeCompact=[bool]$s.compact
    Send-TestCommand 'compact'
    [void](Wait-State {param($s) [bool]$s.compact -ne $beforeCompact})
    Send-TestCommand 'compact'
    [void](Wait-State {param($s) [bool]$s.compact -eq $beforeCompact})
    $checks.Add('Caption visibility toggles and restores its initial state')
    Send-TestCommand 'hide'
    [void](Wait-State {param($s) -not $s.windowVisible})
    Send-TestCommand 'show'
    [void](Wait-State {param($s) $s.windowVisible})
    $checks.Add('Minimize preserves message loop; tray restore remains functional')
    Send-TestCommand 'send'
    $s=Get-State
    if ($s.sent -ne 0) { throw 'Test mode sent to real task' }
    $checks.Add('Test-mode send guard prevents real Codex messages')
    Add-Answer '中断测试已经完成，后续回答仍然可以正常朗读。'
    [void](Wait-State {param($s) $s.spoken -ge 2 -and $s.playerState -eq 'playing'} 40)
    Send-TestCommand 'stop'
    [void](Wait-State {param($s) $s.playerState -eq 'closed'})
    $checks.Add('Next completion plays; Stop closes playback')
    Send-TestCommand 'transcribe' $fixture
    Send-TestCommand 'cancel'
    Start-Sleep -Milliseconds 700
    $s=Get-State
    if ($s.recordingMode -ne 'idle' -or $s.sent -ne 0 -or $s.error) { throw 'ASR cancellation failed' }
    $checks.Add('Cancelled ASR cannot produce a late send')
    @{ok=$true;checks=$checks.ToArray();state=$s}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $base 'jarvis-integration-result.json') -Encoding UTF8
    $checks
} catch {
    @{ok=$false;error=$_.Exception.Message;checks=$checks.ToArray();state=(Get-State)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $base 'jarvis-integration-result.json') -Encoding UTF8
    throw
} finally {
    $payload=@{id=[Guid]::NewGuid().ToString();action='exit'}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText($command,$payload,(New-Object Text.UTF8Encoding($false)))
}
