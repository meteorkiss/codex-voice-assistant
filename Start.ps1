$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'src\Assistant.ps1')
} catch {
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show(('无法启动语音助手：' + $_.Exception.Message), '声伴')
}
