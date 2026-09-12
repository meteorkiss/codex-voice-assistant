param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $Root 'src\Launcher.cs'))
$block=[regex]::Match($source,'(?s)string\[\] required\s*=\s*\{(.*?)\};')
if(-not $block.Success){throw 'Launcher dependency list was not found.'}
$required=@([regex]::Matches($block.Groups[1].Value,'@?"([^"]+)"')|ForEach-Object {$_.Groups[1].Value.Replace('\','/')})
if($required.Count -lt 10 -or @($required|Select-Object -Unique).Count -ne $required.Count){throw 'Invalid or duplicate launcher dependencies.'}
$missing=@()
foreach($relative in $required){
 if($relative -match '^runtime/'){continue}
 if($relative -match '^/|\.\.|:'){throw ('Dependency escapes the source tree: '+$relative)}
 if(-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)){$missing+=$relative}
}
$voices=Get-Content -LiteralPath (Join-Path $Root 'assets\voices.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($voice in $voices){
 if($voice.id -notmatch '\A[a-zA-Z0-9-]+\z'){throw 'Invalid voice resource identifier.'}
 $relative='assets/ack-'+$voice.id+'.mp3'
 if(-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)){$missing+=$relative}
}
if($missing.Count){throw ('Missing source resources: '+($missing -join ', '))}
$parseFailures=@()
foreach($folder in @('src','tests','tools')){
 foreach($file in Get-ChildItem -LiteralPath (Join-Path $Root $folder) -Filter '*.ps1' -File){
  $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
  if($errors.Count){$parseFailures+=$file.Name+': '+$errors[0].Message}
 }
}
if($parseFailures.Count){throw ($parseFailures -join [Environment]::NewLine)}
$trackedChecked=$false
if(Test-Path -LiteralPath (Join-Path $Root '.git')){
 $tracked=@(& git -C $Root -c core.quotePath=false ls-files)
 if($LASTEXITCODE -ne 0){throw 'Cannot inspect the source index.'}
 $private=@($tracked|Where-Object{$_ -match '^(data|runtime|work|outputs)/|(^|/)__pycache__/|\.(exe|dll|sqlite3?|tmp|pyc)$|(^|/)\.env($|\.)'})
 if($private.Count){throw ('Private/generated files in source index: '+($private -join ', '))}
 $trackedChecked=$true
}
@{ok=$true;sourceDependencies=@($required|Where-Object{$_ -notmatch '^runtime/'}).Count;runtimeDependencies=@($required|Where-Object{$_ -match '^runtime/'}).Count;voices=@($voices).Count;trackedFilesChecked=$trackedChecked;devices=0}|ConvertTo-Json -Compress
