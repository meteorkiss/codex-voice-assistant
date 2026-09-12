param([Nullable[float]]$MinimumConfidence = $null)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$fixtures=Join-Path $PSScriptRoot 'fixtures\wake'
$output=Join-Path $project 'work\tests\wake'
[void][IO.Directory]::CreateDirectory($output)
. (Join-Path $project 'src\AudioBootstrap.ps1')
$manifest=Get-Content -LiteralPath (Join-Path $fixtures 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$wake=New-Object WakeListener
$wake.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
if ($PSBoundParameters.ContainsKey('MinimumConfidence')) { $wake.MinimumConfidence=$MinimumConfidence }
$effectiveThreshold=$wake.MinimumConfidence
if (-not $PSBoundParameters.ContainsKey('MinimumConfidence') -and [Math]::Abs($effectiveThreshold-0.35) -gt 0.00001) { throw 'Production wake default must be 0.35.' }
$cases=@()
try {
    foreach($case in $manifest.cases) {
        $before=$wake.ActivationVersion
        $elapsed=[Diagnostics.Stopwatch]::StartNew()
        $wake.StartWaveFile($manifest.phrase,(Join-Path $fixtures ($case.name+'.wav')))
        while(($wake.IsListening -or $wake.IsStopping) -and $elapsed.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 20 }
        $snapshot=$wake.GetSnapshot()
        if($wake.IsListening -or $snapshot.Error) { throw ('Wake engine did not complete: '+$snapshot.Error) }
        $actual=$snapshot.ActivationVersion -eq ($before+1)
        $cases += [pscustomobject]@{Name=$case.name;Expected=[bool]$case.expected;Actual=$actual;Passed=($actual -eq [bool]$case.expected);Keyword=$snapshot.LastKeyword;ElapsedMs=$elapsed.ElapsedMilliseconds}
    }
    $report=[pscustomobject]@{Phrase=$manifest.phrase;MinimumConfidence=$effectiveThreshold;UsedProductionDefault=(-not $PSBoundParameters.ContainsKey('MinimumConfidence'));Cases=$cases;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object {-not $_.Passed}).Count}
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'wake-listener-result.json') -Encoding UTF8
    $thresholdName=$effectiveThreshold.ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output ('wake-listener-threshold-'+$thresholdName+'.json')) -Encoding UTF8
    $report | ConvertTo-Json -Depth 6
    if($report.Failed) { exit 1 }
} finally { $wake.Dispose() }
