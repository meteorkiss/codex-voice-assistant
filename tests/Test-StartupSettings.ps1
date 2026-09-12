$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Assistant.ps1'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\WakePhrase.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Settings.ps1')
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }
$nodes=@($ast.EndBlock.Statements | Where-Object {
    ($_.Extent.Text -match '^\$(hasExplicitThreadId|script:threadId)\s*=') -or
    ($_.Extent.Text -match '^Initialize-AssistantSettings$')
})
if ($nodes.Count -ne 3) { throw 'Could not identify production settings initialization.' }
$initializer=[scriptblock]::Create(($nodes.Extent.Text -join "`n"))
$runDir=Join-Path (Split-Path $PSScriptRoot -Parent) 'work\tests\startup-settings'
[void][IO.Directory]::CreateDirectory($runDir)
$settingsPath=Join-Path $runDir 'settings.json'
$savedThread='11111111-1111-4111-8111-111111111111'
$explicitThread='22222222-2222-4222-8222-222222222222'
$phrase=([char]0x4f60).ToString()+[char]0x597d+[char]0xff0c+[char]0x58f0+[char]0x4f34
$json=@{threadId=$savedThread;voice='zh-TW-HsiaoYuNeural';autoSend=$true;handsFreeEnabled=$true;wakePhrase=$phrase} | ConvertTo-Json
$checks=0
foreach ($withBom in @($false,$true)) {
    [IO.File]::WriteAllText($settingsPath,$json,(New-Object Text.UTF8Encoding($withBom)))
    foreach ($explicit in @($false,$true)) {
        foreach ($isolated in @('live','test','preview')) {
            $ThreadId=if ($explicit) {$explicitThread} else {''}
            $TestMode=($isolated -eq 'test'); $PreviewPath=if ($isolated -eq 'preview') {'preview.png'} else {''}
            $script:handsFreeEnabled=$false; $script:wakePhrase='default'; $script:autoSend=$false; $script:voiceId='default'
            . $initializer
            $expectedThread=if ($explicit) {$explicitThread} else {$savedThread}
            if ($script:threadId -ne $expectedThread) { throw "Wrong restored task: BOM=$withBom explicit=$explicit mode=$isolated" }
            if ($script:handsFreeEnabled -ne ($isolated -eq 'live')) { throw "Wrong wake opt-in: BOM=$withBom mode=$isolated" }
            if ($script:wakePhrase -cne $phrase -or $script:voiceId -ne 'zh-TW-HsiaoYuNeural' -or -not $script:autoSend) { throw 'UTF-8 preferences not restored.' }
            $checks++
        }
    }
}
Write-Output "$checks startup settings scenarios passed (UTF-8 with/without BOM, saved/explicit task, live/test/preview)."
