$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\AudioBootstrap.ps1')
& (Join-Path $project 'runtime\python\python.exe') (Join-Path $PSScriptRoot 'make_echo_preroll_fixture.py')
if($LASTEXITCODE -ne 0) { throw 'Fixture creation failed.' }
$testRoot=Join-Path $project 'work\tests\echo-preroll'
$output=Join-Path $testRoot 'captured-question.wav'
$wake=New-Object WakeListener
$phrase=([char]0x4f60).ToString()+[char]0x597d+[char]0x58f0+[char]0x4f34
try {
    $wake.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
    $wake.StartProcessedWaveForTest($phrase,[IO.File]::ReadAllBytes((Join-Path $testRoot 'combined.wav')))
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not $wake.FixtureInputComplete -and $wake.IsListening -and $clock.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 20 }
    if($wake.FullDuplexReady) { throw 'An injected fixture must not grant real duplex playback permission.' }
    if($wake.Error) { throw $wake.Error }
    if(-not $wake.FixtureInputComplete -or -not $wake.HasQuestion -or $wake.ActivationVersion -ne 1) { throw 'Real local KWS did not hand off the fixture question.' }
    $recorder=$wake.TakeQuestionRecorder()
    if($null -eq $recorder -or $wake.HasQuestion) { throw 'Question recorder must be handed off exactly once.' }
    $recorder.Start()
    if($recorder.LastVoiceUtc -le $recorder.StartedUtc) { throw 'Pre-recorded speech must count as voice activity for automatic send.' }
    $recorder.StopToFileAsync($output)
    if(-not $wake.StopAndWait(3000)) { throw 'Processed fixture did not stop.' }
    if($recorder.Error -or $recorder.IsRecording -or $recorder.IsStopping) { throw "Question did not finish: $($recorder.Error)" }
    if($recorder.LastFile -ne $output) { throw 'Question recorder did not publish its output.' }
    $expected=[IO.File]::ReadAllBytes((Join-Path $testRoot 'question.wav'))
    $actual=[IO.File]::ReadAllBytes($output)
    # Both helper and recorder write standard 44-byte PCM WAV headers.
    $expectedPcm=$expected[44..($expected.Length-1)]
    if($actual.Length -lt $expectedPcm.Length+44) { throw 'The beginning of the immediate question was truncated.' }
    $tail=$actual[($actual.Length-$expectedPcm.Length)..($actual.Length-1)]
    if([Convert]::ToBase64String($tail) -cne [Convert]::ToBase64String($expectedPcm)) { throw 'Question PCM changed across the wake transition.' }
    if($actual.Length -gt $expectedPcm.Length+32000+44) { throw 'More than one second of wake audio leaked into the question.' }
    [pscustomobject]@{WakeCount=$wake.ActivationVersion;QuestionSeconds=$expectedPcm.Length/32000;PreservedQuestionBytes=$expectedPcm.Length;PrefixOverlapSeconds=($actual.Length-$expectedPcm.Length-44)/32000;DevicesOpened=$false;Passed=$true} | ConvertTo-Json
} finally { $wake.Dispose() }
