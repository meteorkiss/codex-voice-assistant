# Voice capture closes playback. Keep one local bookmark until the command is
# known; a new question/answer/task or explicit Stop invalidates it.
$script:voicePlaybackBookmark=$null
$script:voicePlaybackAnswerEpoch=0L
. (Join-Path $PSScriptRoot 'AudioOutput.ps1')

function Test-VoicePlaybackOwnedPath([string]$Path) {
    return (Test-AssistantAudioPath $Path)
}

function Clear-VoicePlaybackBookmark {
    $bookmark=$script:voicePlaybackBookmark
    $script:voicePlaybackBookmark=$null
    $script:voicePlaybackAnswerEpoch++
    if ($bookmark -and $bookmark.Audio -and (Test-VoicePlaybackOwnedPath $bookmark.Audio)) {
        try { [IO.File]::Delete($bookmark.Audio) } catch {}
    }
}

function Test-VoicePlaybackBookmark {
    $bookmark=$script:voicePlaybackBookmark
    if (-not $bookmark) { return $false }
    return ($script:connected -and $bookmark.ThreadId -ceq [string]$script:threadId -and
        $bookmark.AnswerEpoch -eq $script:voicePlaybackAnswerEpoch -and
        $bookmark.AnswerText -ceq [string]$script:latest -and
        $bookmark.UserVersion -eq $script:lastUserVersion)
}

function Save-VoicePlaybackBookmark {
    if ($script:closing -or -not $script:connected) { return }
    if ($script:voicePlaybackBookmark -and -not (Test-VoicePlaybackBookmark)) { Clear-VoicePlaybackBookmark }
    $state=[CodexReader.AudioPlayer]::State
    $hasClip=($state -in @('playing','paused') -and (Test-VoicePlaybackOwnedPath $script:audioPath) -and
        (Test-Path -LiteralPath $script:audioPath -PathType Leaf))
    $pending=New-Object 'System.Collections.Generic.List[string]'
    if ($script:ttsJob -and $script:ttsJob.Text) { $pending.Add([string]$script:ttsJob.Text) }
    foreach ($text in @($script:speechQueue)) { if ($text) { $pending.Add([string]$text) } }
    # A second capture preparation sees the acknowledgement asset, not the old
    # answer. It must preserve the first bookmark, including its original offset.
    if (-not $hasClip -and $pending.Count -eq 0) { return }
    $audio='';$position=0.0;$canSeek=$false
    if ($hasClip) {
        try {
            $property=[CodexReader.AudioPlayer].GetProperty('PositionSeconds')
            $canSeek=($null -ne $property -and $null -ne [CodexReader.AudioPlayer].GetMethod('PlayFrom',[type[]]@([string],[double])))
            if ($canSeek) { $position=[double]$property.GetValue($null,$null) }
            $audio=Join-Path $runtime ('voice-bookmark-'+[Guid]::NewGuid().ToString('N')+[IO.Path]::GetExtension($script:audioPath))
            [IO.File]::Copy($script:audioPath,$audio,$false)
        } catch {
            if ($audio -and (Test-VoicePlaybackOwnedPath $audio)) { Remove-Item -LiteralPath $audio -Force -ErrorAction SilentlyContinue }
            return
        }
    }
    Clear-VoicePlaybackBookmark
    $script:voicePlaybackBookmark=@{Audio=$audio;Position=$position;CanSeek=$canSeek;Queue=$pending.ToArray();
        ThreadId=[string]$script:threadId;AnswerEpoch=$script:voicePlaybackAnswerEpoch;
        AnswerText=[string]$script:latest;UserVersion=$script:lastUserVersion}
}

function Resume-VoicePlaybackBookmark {
    if (-not (Test-VoicePlaybackBookmark)) {
        if ($script:voicePlaybackBookmark) { Clear-VoicePlaybackBookmark }
        return $false
    }
    if (-not (Safe-To-Play)) {
        Set-VoiceDesktopActionNotice '麦克风或回声处理尚未就绪，请稍后继续朗读。'
        return $true
    }
    $bookmark=$script:voicePlaybackBookmark
    if ($bookmark.Audio -and (-not (Test-VoicePlaybackOwnedPath $bookmark.Audio) -or -not (Test-Path -LiteralPath $bookmark.Audio -PathType Leaf))) {
        Clear-VoicePlaybackBookmark
        return $false
    }
    # Other pending output belongs to a newer local action; never append old
    # answer audio behind it or overwrite it.
    if ($script:ttsJob -or $script:speechQueue.Count -gt 0) {
        Clear-VoicePlaybackBookmark
        return $false
    }
    try {
        if ($bookmark.Audio) {
            if ($bookmark.CanSeek) { [CodexReader.AudioPlayer]::PlayFrom($bookmark.Audio,[double]$bookmark.Position) }
            else { [CodexReader.AudioPlayer]::Play($bookmark.Audio) }
            $script:audioPath=$bookmark.Audio
        }
        foreach ($text in $bookmark.Queue) { $script:speechQueue.Enqueue([string]$text) }
        # Ownership of the copied clip now belongs to ordinary playback cleanup.
        $script:voicePlaybackBookmark=$null
        $script:playbackNotice=''
        Set-VoiceDesktopActionNotice $(if ($bookmark.Audio -and -not $bookmark.CanSeek) { '已从当前语音段开头继续朗读。' } else { '已继续朗读。' })
        return $true
    } catch {
        Set-VoiceDesktopActionNotice '暂时无法继续播放，可以稍后重试。'
        return $true
    }
}

function Invoke-VoicePlaybackAction([string]$Action) {
    if ($script:closing -or $script:recMode -ne 'idle' -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { return $true }
    $state=[CodexReader.AudioPlayer]::State
    switch ($Action) {
        'pause' {
            if ($state -eq 'playing') { Toggle-AnswerPlayback; Set-VoiceDesktopActionNotice '已暂停朗读。' }
            elseif ($state -eq 'paused') { Set-VoiceDesktopActionNotice '朗读已经暂停。' }
            else {
                Save-VoicePlaybackBookmark
                if (Test-VoicePlaybackBookmark) {
                    if ($script:ttsJob -or $script:speechQueue.Count -gt 0) { Stop-Output -PreserveVoiceBookmark }
                    Set-VoiceDesktopActionNotice '已暂停朗读，可以说继续朗读。'
                } else { Set-VoiceDesktopActionNotice '当前没有正在播放的朗读。' }
            }
        }
        'resume' {
            if ($state -eq 'paused') { Toggle-AnswerPlayback; Set-VoiceDesktopActionNotice ([string]$script:notice) }
            elseif ($state -eq 'playing') { Set-VoiceDesktopActionNotice '正在朗读。' }
            elseif (-not (Resume-VoicePlaybackBookmark)) { Set-VoiceDesktopActionNotice '当前没有暂停的朗读，可以说重读上一条回答。' }
        }
        'replay' {
            if ([string]::IsNullOrWhiteSpace($script:latest)) { Set-VoiceDesktopActionNotice '当前任务还没有可以重读的回答。'; return $true }
            Clear-VoicePlaybackBookmark
            Stop-Output
            Queue-AnswerSpeech $script:latest
            Set-VoiceDesktopActionNotice '正在重读上一条回答。'
        }
        default { throw 'Unsupported playback action.' }
    }
    return $true
}
