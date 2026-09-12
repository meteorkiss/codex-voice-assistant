function Get-WakePhraseValidation {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $invalid=[pscustomobject]@{Valid=$false;Phrase='';Message='请填写 2—16 个常见汉字，可用空格或逗号分隔。'}
    if (-not $Text -or $Text.Length -gt 100 -or $Text -match '[^\u3400-\u4DBF\u4E00-\u9FFF \u3000,，]') { return $invalid }
    $phrase=($Text -replace '[ \u3000]','') -replace ',','，'
    $phrase=($phrase -replace '，+','，').Trim([char]'，')
    $characters=$phrase -replace '，',''
    if ($characters.Length -lt 2 -or $characters.Length -gt 16) { return $invalid }
    return [pscustomobject]@{Valid=$true;Phrase=$phrase;Message=''}
}

function Set-WakePhraseHint([string]$Message) {
    if ($desktop -and $desktop.Controls.ContainsKey('WakeHintLabel')) { $desktop.Controls.WakeHintLabel.Text=$Message }
}

function Set-AssistantWakePhrase([string]$Text) {
    $validation=Get-WakePhraseValidation $Text
    if (-not $validation.Valid) { Set-WakePhraseHint $validation.Message; return $false }
    if ($script:closing -or $script:recMode -ne 'idle' -or $script:asrJob -or $script:autoDispatch -or
        $script:handsFreePhase -in @('releasing','answering-wake','acknowledging') -or
        ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send')) {
        Set-WakePhraseHint '请等本次录音、识别或发送结束，再保存唤醒词。'
        return $false
    }
    if ([CodexReader.AudioPlayer]::State -in @('playing','paused') -or $script:ttsJob -or $script:speechQueue.Count -gt 0) {
        Set-WakePhraseHint '请等朗读结束，或先停止朗读，再保存唤醒词。'
        return $false
    }
    if ($script:handsFreeEnabled -and $script:wakeListener -and
        ($script:wakeListener.HasQuestion -or $script:wakeListener.ActivationVersion -ne $script:lastWakeVersion)) {
        Set-WakePhraseHint '刚听到唤醒，请结束这次对话后再保存新词。'
        return $false
    }
    $previous=$script:wakePhrase
    $script:wakePhrase=$validation.Phrase
    try { Save-Settings } catch {
        $script:wakePhrase=$previous
        Set-WakePhraseHint '保存没有完成，原唤醒词仍然有效，请重试。'
        return $false
    }
    if ($previous -cne $script:wakePhrase) {
        # Stop only the keyword listener; do not cancel a draft, pending receipt,
        # or an active Codex turn. Waiting ignores any late old-keyword event.
        Suspend-WakeListener
        $script:handsFreePhase=if ($script:handsFreeEnabled) { 'waiting' } else { 'off' }
        if ($script:wakeListener) { $script:lastWakeVersion=$script:wakeListener.ActivationVersion }
    }
    if ($desktop -and $desktop.Controls.ContainsKey('WakePhraseBox')) { $desktop.Controls.WakePhraseBox.Text=$script:wakePhrase }
    Set-WakePhraseHint ('已保存“'+$script:wakePhrase+'”。听到“在”后开始说话。')
    $script:notice='唤醒词已保存。'
    return $true
}
