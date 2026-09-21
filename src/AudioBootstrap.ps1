# Local, pinned audio dependencies. Requires Windows PowerShell 5.1 / .NET Framework 4.8.
$audioLibraryDir=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\audio'
$audioReferences=@('System.dll')
$netstandardFacade=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\netstandard.dll'
if(Test-Path -LiteralPath $netstandardFacade) { $audioReferences+=$netstandardFacade }
foreach($audioDll in @('NAudio.Core.dll','NAudio.Wasapi.dll')) {
    $audioDllPath=Join-Path $audioLibraryDir $audioDll
    if(-not(Test-Path -LiteralPath $audioDllPath)) { throw "Missing local audio dependency: $audioDll" }
    [void][Reflection.Assembly]::LoadFrom($audioDllPath)
    $audioReferences+=$audioDllPath
}
if(-not('CodexReader.AudioPlayer' -as [type])) {
    Add-Type -Path @((Join-Path $PSScriptRoot 'AudioPlayer.cs'),(Join-Path $PSScriptRoot 'EchoCapture.cs'),(Join-Path $PSScriptRoot 'WakeListener.cs'),(Join-Path $PSScriptRoot 'NoWakeCapture.cs')) -ReferencedAssemblies $audioReferences
}
