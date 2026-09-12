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
    @{ok=$true;checks=2;devices=0;captures=0;boundary='Production C# compile and inactive API guard only; no worker, microphone, playback, or Codex operations.'}|ConvertTo-Json -Compress
} finally {$listener.Dispose()}
