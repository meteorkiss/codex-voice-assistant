$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$references=@('System.dll',(Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\netstandard.dll'))
foreach($name in @('NAudio.Core.dll','NAudio.Wasapi.dll')) { $dll=Join-Path $project "runtime\audio\$name"; [void][Reflection.Assembly]::LoadFrom($dll); $references+=$dll }
$sources=@('src\AudioPlayer.cs','src\EchoCapture.cs','src\WakeListener.cs','tests\EchoAcousticHarness.cs') | ForEach-Object { Join-Path $project $_ }
Add-Type -Path $sources -ReferencedAssemblies $references
$cap=[EchoCapture]::ProbeDefault()
if($cap.Error) { throw $cap.Error }
foreach($useEcho in @($false,$true)) {
    $record=[EchoAcousticHarness]::RecordPlayback($cap.CaptureEndpointId,$cap.RenderEndpointId,(Join-Path $project 'tests\fixtures\wake\positive-taiwan-chen.wav'),$useEcho,3)
    $wake=New-Object WakeListener
    try {
        $wake.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
        $wake.StartWaveBytes('你好声伴',$record.Wave)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while($wake.IsListening -and $clock.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20 }
        if($wake.Error) { throw $wake.Error }
        [pscustomobject]@{Aec=$useEcho;Seconds=$record.Seconds;Rms=$record.Rms;WakeDetected=($wake.ActivationVersion -gt 0);AudioSaved=$false;Error=$wake.Error} | ConvertTo-Json -Compress
    } finally { $wake.Dispose(); $record=$null }
}
