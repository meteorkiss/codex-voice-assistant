param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'

# Compile the production AEC/listener pair together and inspect the idle API.
# The listener is never configured or started, so this cannot open a device.
Add-Type -Path @((Join-Path $Root 'src\EchoCapture.cs'),(Join-Path $Root 'src\WakeListener.cs'))
$listener=New-Object WakeListener
try {
    $method=$listener.PSObject.Methods['BeginFollowUpQuestion']
    if(-not $method){throw 'Missing short follow-up capture API.'}
    if($listener.BeginFollowUpQuestion()){throw 'An inactive listener granted follow-up capture.'}
    # Simulate an already-owned follow-up without starting capture or a worker.
    $flags=[Reflection.BindingFlags]'Instance,NonPublic'
    $type=$listener.GetType()
    $type.GetField('listening',$flags).SetValue($listener,$true)
    $type.GetField('echoDetected',$flags).SetValue($listener,$true)
    $type.GetField('normalizedPhrase',$flags).SetValue($listener,'test')
    $handler=$type.GetMethod('HandleWorkerLine',$flags)
    $run=$type.GetField('runVersion',$flags).GetValue($listener)
    $handler.Invoke($listener,@($run,('WAKE'+[char]9+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('test')))))
    if($listener.ActivationVersion -ne 0){throw 'A late wake event displaced active follow-up ownership.'}
    $type.GetField('listening',$flags).SetValue($listener,$false)
    $type.GetField('echoDetected',$flags).SetValue($listener,$false)
    @{ok=$true;checks=3;devices=0;captures=0;boundary='Production C# compile, inactive API guard and late wake ownership; no worker, microphone, playback, or Codex operations.'}|ConvertTo-Json -Compress
} finally {$listener.Dispose()}
