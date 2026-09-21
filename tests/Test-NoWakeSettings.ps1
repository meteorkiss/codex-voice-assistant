$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'src\Settings.ps1')

$checks=0
function Assert-NoWakeSettings($Condition,[string]$Message) { $script:checks++; if(-not $Condition){throw $Message} }
$testRoot=Join-Path $Root ('work\tests\no-wake-settings-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$settingsPath=Join-Path $testRoot 'settings.json'

function Reset-State([bool]$Test,[bool]$Preview) {
    $script:TestMode=$Test;$script:PreviewPath=if($Preview){'preview'}else{$null};$script:hasExplicitThreadId=$false
    $script:threadId='';$script:voiceCatalog=@([pscustomobject]@{id='voice'});$script:voiceId='voice';$script:speechRate=0
    $script:autoRead=$true;$script:autoSend=$false;$script:handsFreeEnabled=$false;$script:bargeInEnabled=$true;$script:shortFollowUpEnabled=$false
    $script:noWakeMode='off';$script:wakePhrase='你好，声伴';$script:waveStyle='rays';$script:waveSize=260;$script:pinned=$true
    $script:captionsVisible=$false;$script:floatingVisible=$true;$script:directoryFilter='';$script:savedLeft=$null;$script:savedTop=$null
    $script:window=$null
}

try {
    Reset-State $false $false
    Initialize-AssistantSettings
    Assert-NoWakeSettings ($script:noWakeMode -eq 'off') 'Missing settings did not default no-wake to off.'
    Save-Settings
    $saved=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-NoWakeSettings ($saved.version -eq 8 -and $saved.noWakeMode -eq 'off') 'Saved settings did not include the off default and schema version.'

    @{version=8;noWakeMode='observe'}|ConvertTo-Json|Set-Content -LiteralPath $settingsPath -Encoding UTF8
    Reset-State $false $false;Initialize-AssistantSettings
    Assert-NoWakeSettings ($script:noWakeMode -eq 'observe') 'A persisted explicit observe mode was not restored.'
    Reset-State $true $false;Initialize-AssistantSettings
    Assert-NoWakeSettings ($script:noWakeMode -eq 'off') 'Test mode inherited a live continuous-listening preference.'
    Reset-State $false $true;Initialize-AssistantSettings
    Assert-NoWakeSettings ($script:noWakeMode -eq 'off') 'Preview mode inherited a live continuous-listening preference.'

    @{version=8;noWakeMode='anything'}|ConvertTo-Json|Set-Content -LiteralPath $settingsPath -Encoding UTF8
    Reset-State $false $false;Initialize-AssistantSettings
    Assert-NoWakeSettings ($script:noWakeMode -eq 'off') 'An invalid no-wake mode did not fail closed.'

    [xml]$xaml=Get-Content -LiteralPath (Join-Path $Root 'src\SettingsWindow.xaml') -Raw -Encoding UTF8
    $names=@($xaml.SelectNodes('//*[@Name]')|ForEach-Object{$_.Name})
    Assert-NoWakeSettings ($names -contains 'NoWakeModeCombo' -and $names -contains 'NoWakeStatusLabel') 'No-wake controls are missing from the settings XAML.'
    $launcher=[IO.File]::ReadAllText((Join-Path $Root 'src\Launcher.cs'))
    foreach($file in @('NoWakeCapture.cs','NoWakeDecision.ps1','NoWakeConversation.ps1')) { Assert-NoWakeSettings ($launcher.Contains($file)) ('Launcher dependency is missing: '+$file) }
    $bootstrap=[IO.File]::ReadAllText((Join-Path $Root 'src\AudioBootstrap.ps1'))
    Assert-NoWakeSettings ($bootstrap.Contains('NoWakeCapture.cs')) 'Audio bootstrap does not compile the no-wake capture owner.'
} finally {
    if([IO.File]::Exists($settingsPath)){[IO.File]::Delete($settingsPath)}
    if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$false)}
}

[pscustomobject]@{passed=$true;checks=$checks;boundary='Settings/XAML/source declarations only; no window shown, microphone, audio, task or network.'}|ConvertTo-Json -Compress
