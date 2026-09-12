param([string]$RunDir='', [switch]$SkipQuietRoomCheck)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$run=if($RunDir){[IO.Path]::GetFullPath($RunDir)}else{Join-Path $root 'work\tests\handsfree-integration'}
$status=Join-Path $run 'status.json'; $command=Join-Path $run 'command.json'; $log=Join-Path $run 'transcript.jsonl'
$checks=New-Object 'System.Collections.Generic.List[string]'
function Read-State { try { Get-Content -LiteralPath $status -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Wait-State($Check,[int]$Seconds=20) {
    $due=[DateTime]::UtcNow.AddSeconds($Seconds)
    do { $s=Read-State; if($s -and (& $Check $s)){return $s}; Start-Sleep -Milliseconds 80 } while([DateTime]::UtcNow -lt $due)
    throw ('Timed out: '+($s | ConvertTo-Json -Compress))
}
function Command([string]$Action,[string]$Path='') {
    $id=[Guid]::NewGuid().ToString()
    $body=@{id=$id;action=$Action;path=$Path}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText(($command+'.tmp'),$body,(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($command+'.tmp') -Destination $command -Force
    [void](Wait-State {param($s) $s.testCommand -eq $id})
}
function Add-Answer {
    $id=[Guid]::NewGuid().ToString()
    $rows=@(@{type='event_msg';payload=@{type='task_started';turn_id=$id}},@{type='event_msg';payload=@{type='task_complete';turn_id=$id;last_agent_message='这是免点击朗读测试。你好，声伴。在。读出唤醒词也不会让助手自己唤醒。'}})
    foreach($row in $rows){[IO.File]::AppendAllText($log,($row|ConvertTo-Json -Compress)+"`n",(New-Object Text.UTF8Encoding($false)))}
}
try {
    [void](Wait-State {param($s) $s.connected -and $s.recordingMode -eq 'idle'})
    Command 'wake-file' (Join-Path $PSScriptRoot 'fixtures\wake\positive-taiwan-chen.wav')
    $s=Wait-State {param($s) $s.wakeCount -eq 1 -and $s.recordingMode -eq 'listening' -and $s.micActive}
    if($s.playerState -ne 'closed' -or $s.wakeListening){throw 'Question recording overlapped wake capture or acknowledgement'}
    $checks.Add('Real local keyword model -> acknowledgement -> released audio -> actual microphone question capture')
    if ($SkipQuietRoomCheck) {
        Command 'cancel'
        [void](Wait-State {param($s) $s.recordingMode -eq 'idle' -and $s.wakeReady -and $s.wakeListening -and $s.wakeCount -eq 1} 25)
        $checks.Add('Explicit cancellation returns to wake standby; quiet-room timeout was skipped')
    } else {
        [void](Wait-State {param($s) $s.recordingMode -eq 'idle' -and $s.wakeReady -and $s.wakeListening -and $s.wakeCount -eq 1} 25)
        $checks.Add('No question returns to actual microphone wake standby without sending')
    }
    Command 'wake-file' (Join-Path $PSScriptRoot 'fixtures\wake\positive-taiwan-chen.wav')
    [void](Wait-State {param($s) $s.wakeCount -eq 2 -and $s.recordingMode -eq 'listening'})
    Command 'question-file' (Join-Path $PSScriptRoot 'fixtures\voice-taiwan.wav')
    $s=Wait-State {param($s) $s.autoSendPrepared -eq 1 -and $s.inputText -like '*请帮我把今天的工作整理一下*' -and $s.recordingMode -eq 'idle'}
    if($s.sent -ne 0 -or $s.error){throw 'Auto-dispatch test guard or ASR failed'}
    $checks.Add('Actual local ASR prepares exactly one automatic dispatch; test mode blocks real send')
    Command 'clear-input'
    [void](Wait-State {param($s) $s.wakeReady -and $s.wakeListening})
    Add-Answer
    $s=Wait-State {param($s) $s.playerState -eq 'playing' -and $s.spoken -ge 1} 35
    if($s.micActive -or $s.wakeListening){throw 'Answer playback overlapped wake microphone'}
    $checks.Add('Answer arrival suspends wake capture, retains queue, and plays Taiwan TTS')
    $s=Wait-State {param($s) $s.playerState -eq 'closed' -and $s.wakeReady -and $s.wakeListening} 25
    if($s.wakeCount -ne 2 -or $s.autoSendPrepared -ne 1){throw 'TTS triggered another wake or automatic send'}
    $checks.Add('Answer containing wake phrase cannot self-activate; standby resumes after playback')
    Command 'handsfree-off'
    $s=Wait-State {param($s) -not $s.handsFreeEnabled -and -not $s.wakeListening -and -not $s.micActive}
    $checks.Add('Disabling hands-free releases actual microphone')
    @{ok=$true;quietRoomTimeoutVerified=(-not $SkipQuietRoomCheck);checks=$checks.ToArray();state=$s}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
    $checks
} catch {
    @{ok=$false;error=$_.Exception.Message;checks=$checks.ToArray();state=(Read-State)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
    throw
} finally {
    $body=@{id=[Guid]::NewGuid().ToString();action='exit'}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText($command,$body,(New-Object Text.UTF8Encoding($false)))
}
