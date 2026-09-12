param([string]$Root=(Split-Path -Parent $PSScriptRoot),[switch]$CheckModel)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\WakePhrase.ps1')
$checks=0
function Assert-WakePhrase([AllowNull()][AllowEmptyString()][string]$Text,[bool]$Valid,[string]$Phrase='') {
    $results=@(Get-WakePhraseValidation $Text)
    if($results.Count -ne 1){throw ('Expected one validation result for: '+$Text)}
    $result=$results[0]
    if($result.Valid -isnot [bool] -or $result.Valid -ne $Valid){throw ('Wrong validity: '+$Text+' => '+($result|ConvertTo-Json -Compress))}
    if($Valid -and $result.Phrase -cne $Phrase){throw ('Wrong normalized display phrase: '+$Text+' => '+$result.Phrase)}
    if($result.Message -isnot [string] -or (-not $Valid -and $result.Message -notmatch '[\u3400-\u4DBF\u4E00-\u9FFF]')){throw ('Expected a Chinese error message for invalid input: '+$Text)}
    if(-not $Valid -and $result.Phrase -ne ''){throw ('Rejected input must not return a replacement wake phrase: '+$Text)}
    if($Valid){
        $again=Get-WakePhraseValidation $result.Phrase
        if(-not $again.Valid -or $again.Phrase -cne $result.Phrase){throw ('Normalization must be idempotent: '+$Text)}
    }
    $script:checks++
}

# Valid display normalization, including the saved default used by old versions.
Assert-WakePhrase '你好，声伴' $true '你好，声伴'
Assert-WakePhrase '你好,声伴' $true '你好，声伴'
Assert-WakePhrase '你好声伴' $true '你好声伴'
Assert-WakePhrase ' 你好 小伴 ' $true '你好小伴'
Assert-WakePhrase '　你好　小伴　' $true '你好小伴'
Assert-WakePhrase '你好 , 声伴' $true '你好，声伴'
Assert-WakePhrase '　你好，　声伴 ' $true '你好，声伴'
Assert-WakePhrase '，你好，声伴，' $true '你好，声伴'
Assert-WakePhrase ',,,你好，，,声伴,,，' $true '你好，声伴'
Assert-WakePhrase ' ,　,你 好,　,声 伴,　' $true '你好，声伴'
foreach($phrase in @('小伴','你好小伴','小爱同学','你好小助手','你好贾维斯','語音助手','女娲','龘龘')){Assert-WakePhrase $phrase $true $phrase}
Assert-WakePhrase ('声'*16) $true ('声'*16)
Assert-WakePhrase (('声,'*15)+'声') $true (('声，'*15)+'声')
Assert-WakePhrase (([char]0x3400).ToString()+[char]0x4DBF) $true (([char]0x3400).ToString()+[char]0x4DBF)
Assert-WakePhrase (([char]0x4E00).ToString()+[char]0x9FFF) $true (([char]0x4E00).ToString()+[char]0x9FFF)

# Invalid characters must be rejected before removing the allowed separators.
foreach($phrase in @($null,'',' ','　',',， ,','声',' 声 , ，',('声'*17),('声，'*17))) {Assert-WakePhrase $phrase $false}
foreach($phrase in @('hey声伴','你好A声伴','你好Ａ声伴','你好a声伴','你好１２声伴','你好12声伴','1234','声伴２','你好①声伴','你好Ⅰ声伴','你好㊗声伴','你好²声伴','你好K声伴')){Assert-WakePhrase $phrase $false}
foreach($phrase in @('你好，声伴！','你好。声伴','你好、声伴','你好：声伴','你好；声伴','你好？声伴','你好-声伴','你好_声伴','你好/声伴','你好\声伴','你好+声伴','你好=声伴','你好·声伴','你好…声伴','“你好声伴”','「你好声伴」','<你好声伴>','[你好声伴]','{你好声伴}','`你好声伴`','```你好声伴```','#你好声伴')){Assert-WakePhrase $phrase $false}
foreach($phrase in @("你好`t声伴","你好`r声伴","你好`n声伴","你好`r`n声伴",([char]0xA0+'你好声伴'),('你好'+[char]0x200B+'声伴'),('你好'+[char]0xFEFF+'声伴'),('你好'+[char]0+'声伴'),('你好'+[char]0x1B+'声伴'))){Assert-WakePhrase $phrase $false}
foreach($symbol in @([char]0x4DC0,[char]0x4DFF,[char]0x33FF,[char]0xFA11,[char]0x3007,[char]0x3005)){Assert-WakePhrase ('你好'+$symbol+'声伴') $false}
Assert-WakePhrase ('你好'+[char]::ConvertFromUtf32(0x1F600)+'声伴') $false
Assert-WakePhrase ('你好'+[char]::ConvertFromUtf32(0x20BB7)+'声伴') $false
Assert-WakePhrase ('你好'+[char]0xD800+'声伴') $false

$source=Join-Path $Root 'src\WakePhrase.ps1'
$bytes=[IO.File]::ReadAllBytes($source)
if($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw 'WakePhrase.ps1 must use UTF-8 BOM for PowerShell 5.1.'};$checks++
$tokens=$null;$parseErrors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw $parseErrors[0].Message};$checks++

if($CheckModel){
    # ASCII Python source travels intact through PS 5.1 stdin. Paths use Unicode
    # native arguments; no audio capture, waveform playback, downloads, or ASR.
    $pythonCode=@'
import json, sys
from pathlib import Path
root=Path(sys.argv[1]); sys.path.insert(0,str(root/'src'))
from wake_worker import keyword_tokens, Spotter
vocab={row.rsplit(' ',1)[0] for row in (root/'runtime/models/wake/tokens.txt').read_text(encoding='utf-8').splitlines()}
phrases=['\u4f60\u597d\uff0c\u58f0\u4f34','\u4f60\u597d\u5c0f\u4f34','\u5c0f\u7231\u540c\u5b66','\u4f60\u597d\u5c0f\u52a9\u624b','\u4f60\u597d\u8d3e\u7ef4\u65af']
report=[]
for phrase in phrases:
    normalized, keywords=keyword_tokens(phrase)
    tokens=keywords.split(' @')[0].split()
    missing=[token for token in tokens if token not in vocab]
    assert tokens and not missing, (phrase,missing)
    spotter=Spotter(root/'runtime/models/wake',phrase)
    assert spotter.phrase==normalized and spotter.stream is not None
    report.append({'phrase':phrase,'normalized':normalized,'tokens':tokens,'spotterConstructed':True})
    del spotter
print(json.dumps({'modelChecks':len(report),'cases':report},ensure_ascii=True))
'@
    $python=Join-Path $Root 'runtime\python\python.exe'
    $modelOutput=$pythonCode|& $python -B - $Root
    if($LASTEXITCODE -ne 0){throw 'Local model phrase construction test failed.'}
    $report=($modelOutput -join "`n")|ConvertFrom-Json
    if($report.modelChecks -ne 5){throw 'Expected all five local model phrase checks.'}
    $checks += [int]$report.modelChecks
    Write-Output ($report|ConvertTo-Json -Depth 6 -Compress)
}
Write-Output ('PASS '+$checks+' wake phrase checks; '+$(if($CheckModel){'five real local model streams constructed without audio.'}else{'pure validator only.'}))
