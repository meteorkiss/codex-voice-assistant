. (Join-Path $PSScriptRoot 'Persistence.ps1')

function Initialize-AssistantSettings {
    $script:settingsWarning=''
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $hasExplicitThreadId -and $settings.threadId) { $script:threadId = $settings.threadId }
            if ($settings.voice -in @($script:voiceCatalog.id) -or $settings.voice -in @('zh-TW-HsiaoChenNeural','zh-TW-HsiaoYuNeural')) { $script:voiceId = $settings.voice }
            if ($null -ne $settings.autoSend) { $script:autoSend = [bool]$settings.autoSend }
            if ($null -ne $settings.handsFreeEnabled -and -not $TestMode -and -not $PreviewPath) { $script:handsFreeEnabled=[bool]$settings.handsFreeEnabled }
            if ($null -ne $settings.bargeInEnabled) { $script:bargeInEnabled=[bool]$settings.bargeInEnabled }
            if ($null -ne $settings.shortFollowUpEnabled -and -not $TestMode -and -not $PreviewPath) { $script:shortFollowUpEnabled=[bool]$settings.shortFollowUpEnabled }
            # 0.7.0 intentionally does not restore the old observe/context
            # experiments. A continuous conversation always requires a fresh,
            # visible user start after launch.
            $script:noWakeMode='off'
            $script:continuousConversationEnabled=$false
            if ($settings.modelEndpoint -is [string] -and $settings.modelEndpoint.Length -le 2048) { $script:modelEndpoint=[string]$settings.modelEndpoint }
            if ($settings.modelName -is [string] -and $settings.modelName.Length -le 200) { $script:modelName=[string]$settings.modelName }
            if ($settings.modelAuthMode -in @('bearer','none')) { $script:modelAuthMode=[string]$settings.modelAuthMode }
            if ($settings.modelCredentialEnv -is [string] -and $settings.modelCredentialEnv -cmatch '\A[A-Za-z_][A-Za-z0-9_]{0,127}\z') { $script:modelCredentialEnv=[string]$settings.modelCredentialEnv }
            if ($null -ne $settings.modelDataConsent) { $script:modelDataConsent=[bool]$settings.modelDataConsent }
            if ($null -ne $settings.conversationTtsConsent) { $script:conversationTtsConsent=[bool]$settings.conversationTtsConsent }
            if ($null -ne $settings.conversationIdleSeconds) { $script:conversationIdleSeconds=[Math]::Max(30,[Math]::Min(600,[int]$settings.conversationIdleSeconds)) }
            if ($null -ne $settings.conversationMaxSeconds) { $script:conversationMaxSeconds=[Math]::Max(60,[Math]::Min(3600,[int]$settings.conversationMaxSeconds)) }
            if ($null -ne $settings.conversationMaxTurns) { $script:conversationMaxTurns=[Math]::Max(1,[Math]::Min(100,[int]$settings.conversationMaxTurns)) }
            if ($settings.wakePhrase) {
                $wakeValidation=Get-WakePhraseValidation ([string]$settings.wakePhrase)
                if ($wakeValidation.Valid) { $script:wakePhrase=$wakeValidation.Phrase }
            }
            if ($null -ne $settings.speechRate -and [int]$settings.speechRate -in @(-20,0,20,50)) { $script:speechRate=[int]$settings.speechRate }
            if ($null -ne $settings.autoRead) { $script:autoRead=[bool]$settings.autoRead }
            if ($settings.waveStyle -in @('rays','halo','particles','minimal','bars','flow')) { $script:waveStyle=[string]$settings.waveStyle }
            if ($null -ne $settings.waveSize) { $script:waveSize=[Math]::Max(180,[Math]::Min(360,[int]$settings.waveSize)) }
            if ($null -ne $settings.pinned) { $script:pinned=[bool]$settings.pinned }
            if ($null -ne $settings.captionsVisible) { $script:captionsVisible=[bool]$settings.captionsVisible }
            if ($null -ne $settings.floatingVisible) { $script:floatingVisible=[bool]$settings.floatingVisible }
            if ($settings.directoryFilter) { $script:directoryFilter=[string]$settings.directoryFilter }
            if ($null -ne $settings.left -and $null -ne $settings.top) { $script:savedLeft=[double]$settings.left; $script:savedTop=[double]$settings.top }
        } catch { $script:settingsWarning='设置文件未能完整读取，保留可用配置与默认值。' }
    }
}

function Save-Settings {
    $preferences=@{version=9;threadId=$script:threadId;voice=$script:voiceId;speechRate=$script:speechRate;autoRead=$script:autoRead;autoSend=$script:autoSend;handsFreeEnabled=$script:handsFreeEnabled;bargeInEnabled=$script:bargeInEnabled;shortFollowUpEnabled=$script:shortFollowUpEnabled;noWakeMode='off';continuousConversationEnabled=$false;modelEndpoint=$script:modelEndpoint;modelName=$script:modelName;modelAuthMode=$script:modelAuthMode;modelCredentialEnv=$script:modelCredentialEnv;modelDataConsent=[bool]$script:modelDataConsent;conversationTtsConsent=[bool]$script:conversationTtsConsent;conversationIdleSeconds=[int]$script:conversationIdleSeconds;conversationMaxSeconds=[int]$script:conversationMaxSeconds;conversationMaxTurns=[int]$script:conversationMaxTurns;wakePhrase=$script:wakePhrase;waveStyle=$script:waveStyle;waveSize=$script:waveSize;pinned=$script:pinned;captionsVisible=$script:captionsVisible;floatingVisible=$script:floatingVisible;directoryFilter=$script:directoryFilter}
    if ($window -and -not [double]::IsNaN($window.Left) -and -not [double]::IsNaN($window.Top)) { $preferences.left=$window.Left; $preferences.top=$window.Top }
    Write-AtomicJson -Path $settingsPath -Value $preferences -Depth 4
}
