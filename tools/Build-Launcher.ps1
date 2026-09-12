param([switch]$RefreshIcon)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\Version.ps1')
$version=Get-AssistantVersion -Root $projectRoot
$readme=[IO.File]::ReadAllText((Join-Path $projectRoot 'README.md'))
$changes=[IO.File]::ReadAllText((Join-Path $projectRoot 'CHANGELOG.md'))
if ($readme -notmatch ('当前开发版 \*\*v6 / '+[regex]::Escape($version)+'\*\*') -or
    [regex]::Match($changes,'(?m)^## ([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value -ne $version) {
    throw 'README 当前版本或 CHANGELOG 最新条目与 VERSION 不一致，请先更新版本说明。'
}
$sourcePath = Join-Path $projectRoot 'src\Launcher.cs'
$iconPath = Join-Path $projectRoot 'assets\shengban.ico'
$outputPath = Join-Path $projectRoot '声伴.exe'

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw '找不到 src\Launcher.cs，请在完整项目中运行构建脚本。'
}
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) {
    throw '未找到 .NET Framework C# 编译器。请安装或启用 .NET Framework 4.x 开发组件后重试。'
}

if ($RefreshIcon -or -not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    Add-Type -AssemblyName System.Drawing
    [void][IO.Directory]::CreateDirectory((Split-Path $iconPath -Parent))
    $frames = New-Object 'Collections.Generic.List[byte[]]'
    $sizes = @(16,32,48,64,128,256)
    foreach ($size in $sizes) {
        $bitmap = New-Object Drawing.Bitmap($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.Clear([Drawing.Color]::Transparent)
            $center = $size / 2.0
            $innerRadius = $size * 0.27
            $segments = if ($size -le 32) { 28 } else { 64 }
            for ($i=0; $i -lt $segments; $i++) {
                $phase = 2.0 * [Math]::PI * $i / $segments
                $outerRadius = $size * (0.37 + 0.055 * (0.5 + 0.5 * [Math]::Sin(3.0 * $phase)))
                $red = [int](146 + 91 * [Math]::Sin($phase + 0.3))
                $green = [int](140 + 93 * [Math]::Sin($phase + 2.4))
                $blue = [int](161 + 82 * [Math]::Sin($phase + 4.5))
                $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,$red,$green,$blue),[single][Math]::Max(1.0,$size*0.013))
                try {
                    $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
                    $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
                    $graphics.DrawLine($pen,
                        [single]($center+[Math]::Cos($phase)*$innerRadius),
                        [single]($center+[Math]::Sin($phase)*$innerRadius),
                        [single]($center+[Math]::Cos($phase)*$outerRadius),
                        [single]($center+[Math]::Sin($phase)*$outerRadius))
                } finally { $pen.Dispose() }
            }
            $memory = New-Object IO.MemoryStream
            try {
                $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
                $frames.Add($memory.ToArray())
            } finally { $memory.Dispose() }
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    $stream = [IO.File]::Create($iconPath)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i=0; $i -lt $sizes.Count; $i++) {
            $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
            $offset += $frames[$i].Length
        }
        foreach ($frame in $frames) { $writer.Write([byte[]]$frame) }
    } finally { $writer.Dispose(); $stream.Dispose() }
}

# Generate assembly metadata from VERSION; compile to a candidate first so a
# failed build cannot replace the working launcher. No generated source is kept.
$buildRoot=Join-Path $projectRoot 'work\build'
[void][IO.Directory]::CreateDirectory($buildRoot)
$token=[Guid]::NewGuid().ToString('N')
$metadataPath=Join-Path $buildRoot ($token+'.version.cs')
$candidatePath=Join-Path $buildRoot ($token+'.exe')
try {
    $metadata='[assembly: System.Reflection.AssemblyVersion("'+$version+'.0")]'+[Environment]::NewLine+
        '[assembly: System.Reflection.AssemblyFileVersion("'+$version+'.0")]'
    [IO.File]::WriteAllText($metadataPath,$metadata,(New-Object Text.UTF8Encoding($false)))
    & $compiler '/nologo' '/target:winexe' '/platform:anycpu' '/optimize+' '/codepage:65001' "/win32icon:$iconPath" "/out:$candidatePath" '/reference:System.Windows.Forms.dll' $sourcePath $metadataPath
    if ($LASTEXITCODE -ne 0) { throw ('启动器编译失败，退出码：'+$LASTEXITCODE) }
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo($candidatePath).FileVersion -ne ($version+'.0')) { throw '生成的启动器版本不一致。' }
    if (Test-Path -LiteralPath $outputPath) { [IO.File]::Replace($candidatePath,$outputPath,[NullString]::Value) }
    else { [IO.File]::Move($candidatePath,$outputPath) }
} finally {
    foreach ($generated in @($metadataPath,$candidatePath)) {
        if ([IO.File]::Exists($generated)) { [IO.File]::Delete($generated) }
    }
}
Write-Output ('已生成声伴 '+$version+'：'+$outputPath)
Write-Output '临时构建文件已清理；构建未启动助手，也未修改任务绑定或个人设置。'
