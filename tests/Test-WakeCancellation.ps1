$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src\AudioBootstrap.ps1')
$wake=New-Object WakeListener
$wake.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
$fixture=Join-Path $PSScriptRoot 'fixtures\wake\positive-taiwan-chen.wav'
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\wake\manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
try {
    for($round=0;$round -lt 3;$round++) {
        $before=$wake.ActivationVersion
        $wake.StartWaveFile($manifest.phrase,$fixture)
        Start-Sleep -Milliseconds 20
        if(-not $wake.StopAndWait(2000)) { throw 'Early cancellation did not finish.' }
        if($wake.ActivationVersion -ne $before) { throw 'Cancelled request activated.' }
        $wake.StartWaveFile($manifest.phrase,$fixture)
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while($wake.IsListening -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        if($wake.IsListening -or $wake.Error -or $wake.ActivationVersion -ne $before+1) { throw 'Restart did not produce exactly one valid activation.' }
    }
    'Wake early-cancel/restart isolation passed: 3 rounds, exactly 3 valid activations.'
} finally { $wake.Dispose() }
