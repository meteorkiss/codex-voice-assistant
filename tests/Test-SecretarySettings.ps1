$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'src\Settings.ps1')
$checks=0
function Assert-SecretarySettings($Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
$testRoot=Join-Path $Root ('work\tests\secretary-settings-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$settingsPath=Join-Path $testRoot 'settings.json'
function Reset-State {
    $script:TestMode=$false;$script:PreviewPath=$null;$script:hasExplicitThreadId=$false;$script:threadId=''
    $script:voiceCatalog=@([pscustomobject]@{id='voice'});$script:voiceId='voice';$script:speechRate=0;$script:autoRead=$true;$script:autoSend=$false
    $script:handsFreeEnabled=$false;$script:bargeInEnabled=$true;$script:shortFollowUpEnabled=$false;$script:noWakeMode='off';$script:continuousConversationEnabled=$false
    $script:modelEndpoint='';$script:modelName='';$script:modelAuthMode='bearer';$script:modelCredentialEnv='';$script:modelDataConsent=$false;$script:conversationTtsConsent=$false
    $script:conversationIdleSeconds=90;$script:conversationMaxSeconds=600;$script:conversationMaxTurns=20;$script:wakePhrase='你好，声伴'
    $script:waveStyle='rays';$script:waveSize=260;$script:pinned=$true;$script:captionsVisible=$false;$script:floatingVisible=$true;$script:directoryFilter='';$script:savedLeft=$null;$script:savedTop=$null;$script:window=$null
}
try {
    @{version=8;noWakeMode='observe';autoRead=$false;modelEndpoint='https://example.invalid/v1/chat/completions';modelName='m';modelAuthMode='bearer';modelCredentialEnv='SHENGBAN_KEY';modelDataConsent=$true;conversationTtsConsent=$false}|ConvertTo-Json|Set-Content -LiteralPath $settingsPath -Encoding UTF8
    Reset-State;Initialize-AssistantSettings
    Assert-SecretarySettings ($script:noWakeMode -eq 'off' -and -not $script:continuousConversationEnabled) 'Legacy observe mode was not migrated safely to off.'
    Assert-SecretarySettings (-not $script:autoRead) 'Legacy autoRead preference was changed during migration.'
    Assert-SecretarySettings ($script:modelEndpoint -like 'https://*' -and $script:modelCredentialEnv -ceq 'SHENGBAN_KEY' -and $script:modelDataConsent -and -not $script:conversationTtsConsent) 'Secretary configuration or separate consents were not restored.'
    Save-Settings
    $saved=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-SecretarySettings ($saved.version -eq 9 -and $saved.noWakeMode -eq 'off' -and -not $saved.continuousConversationEnabled) 'Settings did not persist the v9 safe-off contract.'
    Assert-SecretarySettings ($null -eq $saved.apiKey -and $saved.modelCredentialEnv -ceq 'SHENGBAN_KEY') 'Settings persisted a credential value instead of only its environment variable reference.'
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $Root 'src\SettingsWindow.xaml') -Raw -Encoding UTF8
    $names=@($xaml.SelectNodes('//*[@Name]')|ForEach-Object{$_.Name})
    foreach($name in @('ContinuousConversationToggle','ModelEndpointBox','ModelNameBox','ModelAuthModeCombo','ModelCredentialEnvBox','ModelDataConsentToggle','ConversationTtsConsentToggle','ConversationIdleBox','ConversationMaxTurnsBox')){Assert-SecretarySettings ($names -contains $name) ('Missing conversation setting control: '+$name)}
    $launcher=[IO.File]::ReadAllText((Join-Path $Root 'src\Launcher.cs'))
    foreach($file in @('SecretaryConversation.ps1','secretary_model_client.py')){Assert-SecretarySettings ($launcher.Contains($file)) ('Launcher dependency missing: '+$file)}
} finally {
    if([IO.File]::Exists($settingsPath)){[IO.File]::Delete($settingsPath)}
    if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$false)}
}
[pscustomobject]@{passed=$true;checks=$checks;boundary='Settings/XAML/source declarations only; no UI shown, network, microphone, task or message send.'}|ConvertTo-Json -Compress
