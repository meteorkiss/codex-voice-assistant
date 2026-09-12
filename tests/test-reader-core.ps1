$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\reader-core.ps1')
$testRoot = Join-Path $projectRoot 'work\tests\reader-core-cases'
[void][IO.Directory]::CreateDirectory($testRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0
$script:failed = 0
function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -ceq $expected) { $script:passed++; Write-Output "PASS $name" }
    else { $script:failed++; Write-Output "FAIL $name expected=[$expected] actual=[$actual]" }
}
function Event-Line([string]$id, [string]$answer, [string]$kind = 'task_complete') {
    return ((@{type='event_msg'; payload=@{type=$kind;turn_id=$id;last_agent_message=$answer}} | ConvertTo-Json -Compress) + "`n")
}
function Append-Bytes([string]$path, [byte[]]$bytes) {
    $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}
function Append-Text([string]$path, [string]$text) { Append-Bytes $path $utf8.GetBytes($text) }
$path = Join-Path $testRoot 'append.jsonl'
[IO.File]::WriteAllText($path, (Event-Line 'history' '这是历史答案。'), $utf8)
$tail = New-TranscriptTail $path
Assert-Equal $tail.Latest '这是历史答案。' 'history available for replay'
Assert-Equal @(Read-NewCompletedAnswers $tail).Count 0 'startup never emits history'
Append-Text $path (Event-Line 'turn1' '正常回答。')
$answers = @(Read-NewCompletedAnswers $tail)
Assert-Equal $answers.Count 1 'appended completion emits once'
Assert-Equal $answers[0].Text '正常回答。' 'appended Chinese answer exact'
Append-Text $path (Event-Line 'turn1' '正常回答。')
Assert-Equal @(Read-NewCompletedAnswers $tail).Count 0 'duplicate turn suppressed'
Append-Text $path (Event-Line 'commentary' 'task_complete 字样也不应该朗读' 'agent_message')
Assert-Equal @(Read-NewCompletedAnswers $tail).Count 0 'commentary never emits'
$line = Event-Line 'turn2' '中文拆分测试，GPT-6。'
$bytes = $utf8.GetBytes($line)
$split = [Array]::IndexOf($bytes, [byte]0xe4) + 1
if ($split -lt 1) { throw 'Could not find first Chinese codepoint' }
Append-Bytes $path $bytes[0..($split - 1)]
Assert-Equal @(Read-NewCompletedAnswers $tail).Count 0 'split UTF8 codepoint retained'
Append-Bytes $path $bytes[$split..($bytes.Length - 2)]
Assert-Equal @(Read-NewCompletedAnswers $tail).Count 0 'complete JSON without newline retained'
Append-Bytes $path @([byte]10)
$answers = @(Read-NewCompletedAnswers $tail)
Assert-Equal $answers.Count 1 'split JSON emitted on newline'
Assert-Equal $answers[0].Text '中文拆分测试，GPT-6。' 'split Chinese codepoint survives exactly'
Append-Text $path ((Event-Line 'turn3' '三。') + (Event-Line 'turn4' '四。'))
$answers = @(Read-NewCompletedAnswers $tail)
Assert-Equal $answers.Count 2 'two completion lines emitted'
Assert-Equal ($answers.Text -join '|') '三。|四。' 'multiple completions ordered'
Assert-Equal $tail.Latest '四。' 'latest follows last completion'
[IO.File]::WriteAllText($path, (Event-Line 'replacement' '重建历史。'), $utf8)
Assert-Equal @(Read-NewCompletedAnswers $tail).Count 0 'shorter truncate ignores replacement history'
Assert-Equal $tail.Latest '重建历史。' 'replacement updates replay text'
Append-Text $path (Event-Line 'after-truncate' '重建后的新答案。')
$answers = @(Read-NewCompletedAnswers $tail)
Assert-Equal $answers.Count 1 'new completion after truncate emitted'
Assert-Equal $answers[0].Text '重建后的新答案。' 'new completion after truncate exact'
$partialPath = Join-Path $testRoot 'startup-partial.jsonl'
$partial = Event-Line 'startup-partial' '启动前已经有半条记录。'
[IO.File]::WriteAllText($partialPath, $partial.Substring(0, 10), $utf8)
$partialTail = New-TranscriptTail $partialPath
Append-Text $partialPath ($partial.Substring(10) + (Event-Line 'startup-next' '之后的新记录。'))
$answers = @(Read-NewCompletedAnswers $partialTail)
Assert-Equal $answers.Count 1 'startup partial discarded but next line accepted'
Assert-Equal $answers[0].TurnId 'startup-next' 'startup partial does not contaminate next event'

# Simulate rewrite/truncate + regrow between polls, preserving ordinary same-file creation timestamp.
$regrowPath = Join-Path $testRoot 'regrow.jsonl'
$oldLine = Event-Line 'original' '原来的历史。'
[IO.File]::WriteAllText($regrowPath, $oldLine, $utf8)
$regrowTail = New-TranscriptTail $regrowPath
$creation = [IO.File]::GetCreationTimeUtc($regrowPath)
$replacedHistory = (Event-Line 'rewritten-first' '这个重建历史比原来的记录更长一些。') + (Event-Line 'rewritten-second' '不应自动朗读的旧记录。')
[IO.File]::WriteAllText($regrowPath, $replacedHistory, $utf8)
[IO.File]::SetCreationTimeUtc($regrowPath, $creation)
$answers = @(Read-NewCompletedAnswers $regrowTail)
Assert-Equal $answers.Count 0 'truncate and regrow between polls never emits replacement history'
if ($answers.Count) { Write-Output ('DETAIL regrow emitted: ' + ($answers.Text -join '|')) }
Write-Output "TOTAL passed=$script:passed failed=$script:failed"
if ($script:failed) { exit 1 }
