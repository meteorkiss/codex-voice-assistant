# Output owns synthesis jobs and playable clips; acquisition stays in HandsFree.
function Test-AssistantAudioPath([string]$Path) {
    if (-not $Path -or -not $runtime) { return $false }
    try {
        $base=[IO.Path]::GetFullPath($runtime).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
        $full=[IO.Path]::GetFullPath($Path)
        if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $full -PathType Container)) { return $false }
        $cursor=$full
        while ($cursor -and $cursor.Length -ge $base.TrimEnd([char[]]'\/').Length) {
            if ((Test-Path -LiteralPath $cursor) -and ([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint)) { return $false }
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
        return $true
    } catch { return $false }
}

function Stop-AssistantOutput([string]$Message='', [switch]$PreserveVoiceBookmark) {
    if (-not $PreserveVoiceBookmark -and (Get-Command Clear-VoicePlaybackBookmark -ErrorAction SilentlyContinue)) { Clear-VoicePlaybackBookmark }
    $script:playbackNotice=''
    $script:epoch++
    if ($script:ttsJob) { Close-Job $script:ttsJob -Kill; $script:ttsJob=$null }
    $script:speechQueue.Clear()
    try { [CodexReader.AudioPlayer]::Stop() }
    catch { $script:notice='朗读停止未完成，已取消待播内容，保留音频供后续释放。'; return }
    Remove-OwnedFiles @($script:audioPath)
    $script:audioPath=''
    if ($Message) { $script:notice=$Message }
}

function Start-AssistantSpeech([string]$Text) {
    if ($script:ttsJob -or -not (Safe-To-Play) -or [string]::IsNullOrWhiteSpace($Text)) { return }
    $id=[Guid]::NewGuid().ToString('N')
    $inputPath=Join-Path $runtime ($id+'.tts.json');$audio=Join-Path $runtime ($id+'.mp3')
    $files=@($inputPath,($audio -replace '\.mp3$','.partial.mp3'),($audio -replace '\.mp3$','.error.json'))
    try {
        @{text=$Text;voice=$script:voiceId;rate=$script:speechRate} | ConvertTo-Json -Compress | Set-Content -LiteralPath $inputPath -Encoding UTF8
        $proc=Start-Worker $python (Join-Path $PSScriptRoot 'synthesize.py') @($inputPath,$audio)
    } catch {
        Remove-OwnedFiles ($files+@($audio))
        $script:notice='文字已保留，语音准备失败，可稍后重读。'
        return
    }
    $script:ttsEpoch=$script:epoch
    $script:ttsJob=@{Process=$proc;Audio=$audio;Text=$Text;Files=$files;Started=[DateTime]::UtcNow;Epoch=$script:epoch;ThreadId=$script:threadId}
}

function Complete-AssistantSpeech {
    if (-not $script:ttsJob -or -not $script:ttsJob.Process.HasExited) { return }
    $job=$script:ttsJob;$script:ttsJob=$null;$audio=$job.Audio
    try {
        $code=$job.Process.ExitCode
        Close-Job $job
        $fresh=($script:ttsEpoch -eq $script:epoch -and
            (-not $job.ContainsKey('Epoch') -or $job.Epoch -eq $script:epoch) -and
            (-not $job.ContainsKey('ThreadId') -or $job.ThreadId -ceq $script:threadId))
        if ($code -eq 0 -and $fresh -and (Test-AssistantAudioPath $audio) -and (Test-Path -LiteralPath $audio -PathType Leaf) -and (Safe-To-Play)) {
            [CodexReader.AudioPlayer]::Play($audio)
            $script:audioPath=$audio;$script:spoken++
            return
        }
        if ($code -ne 0) { $script:notice='文字已显示，语音暂时不可用。' }
    } catch {
        try { [CodexReader.AudioPlayer]::Stop() }
        catch {
            if (Test-AssistantAudioPath $audio) { $script:audioPath=$audio }
            $script:notice='语音播放未完成，音频仍在释放，可稍后停止朗读。'
            return
        }
        $script:notice='文字已保留，语音播放失败，可稍后重读。'
    }
    Remove-OwnedFiles @($audio)
}
