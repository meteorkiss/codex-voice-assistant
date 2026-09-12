# Parse the real composition without running Assistant startup, audio or workers.
# The migrated modules are fixed here; do not discover or execute arbitrary code.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Persistence.ps1')
function Read-TestProductionAst([string]$Path) {
    $content=[IO.File]::ReadAllText($Path)
    if ([IO.Path]::GetFileName($Path) -eq 'Assistant.ps1') {
        foreach ($name in @('Settings.ps1','PendingSends.ps1','WorkerLifecycle.ps1','CodexAdapter.ps1')) {
            $content+="`n"+[IO.File]::ReadAllText((Join-Path (Split-Path $Path -Parent) $name))
        }
    }
    $tokens=$null; $errors=$null
    $tree=[Management.Automation.Language.Parser]::ParseInput($content,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($Path+': '+$errors[0].Message) }
    return $tree
}
