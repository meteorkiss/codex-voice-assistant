function Get-AssistantVersion {
    param([string]$Root=(Split-Path $PSScriptRoot -Parent))
    $value=[IO.File]::ReadAllText((Join-Path $Root 'VERSION')).Trim()
    if ($value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'VERSION 必须是三段数字版本号，例如 0.6.14。'
    }
    foreach ($part in $value.Split('.')) {
        $number=0
        if (-not [int]::TryParse($part,[ref]$number) -or $number -gt 65534) { throw 'VERSION 数字超出启动器支持范围。' }
    }
    return $value
}
