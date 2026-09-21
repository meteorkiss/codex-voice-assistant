param(
    [Parameter(Mandatory=$true)][string]$PythonPath,
    [Parameter(Mandatory=$true)][string]$ModelDir,
    [string]$Root
)
$ErrorActionPreference='Stop'
if(-not $Root){$Root=Split-Path $PSScriptRoot -Parent}
if(-not(Test-Path -LiteralPath $PythonPath -PathType Leaf)){throw 'PythonPath is missing.'}
if(-not(Test-Path -LiteralPath (Join-Path $ModelDir 'model.int8.onnx') -PathType Leaf)){throw 'SenseVoice model is missing.'}
. (Join-Path $Root 'src\NoWakeDecision.ps1')
$testRoot=Join-Path $Root ('work\tests\no-wake-pipeline-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$resultPath=Join-Path $testRoot 'result.json'
try {
    $fixture=Join-Path $Root 'tests\fixtures\voice-taiwan.wav'
    & $PythonPath -B (Join-Path $Root 'src\transcribe.py') --input $fixture --output $resultPath --model-dir $ModelDir
    if($LASTEXITCODE -ne 0){throw 'Local ASR worker failed.'}
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $result.ok -or $result.engine -notlike 'SenseVoiceSmall*'){throw 'Local ASR result is incomplete.'}
    $decision=Get-NoWakeDecision -Text ([string]$result.text) -Mode observe -Evidence @{DurationSeconds=[double]$result.duration;EndReason='silence'}
    if($decision.Route -ne 'none'){throw 'Observe pipeline produced an executable route.'}
    [pscustomobject]@{passed=$true;textLength=([string]$result.text).Length;duration=$result.duration;decision=$decision.Disposition;route=$decision.Route;boundary='Bundled synthetic WAV through installed local ASR and pure observe policy; no microphone, task, send or network.'}|ConvertTo-Json -Compress
} finally {
    if([IO.File]::Exists($resultPath)){[IO.File]::Delete($resultPath)}
    if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$false)}
}
