$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $project 'src\EchoCapture.cs')
$capability=[EchoCapture]::ProbeDefault()
$capability | ConvertTo-Json -Depth 5
if ($capability.Error) { throw $capability.Error }
if (-not $capability.Initialized) { throw 'WASAPI stream was not initialized.' }
if ($capability.FullDuplexReady) { throw 'A capability probe must never claim acoustic validation.' }
