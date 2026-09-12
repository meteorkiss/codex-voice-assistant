$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\reader-core.ps1')
$script:passed = 0
function Assert-Speech([string]$source, [string]$expected, [string]$name) {
    $actual = ConvertTo-SpokenText $source
    if ($actual -cne $expected) { throw "$name expected=[$expected] actual=[$actual]" }
    $script:passed++
    Write-Output "PASS $name"
}

$preview = @'
朗读设置已经保存。
visualize{"path":"C:/Users/TestUser/.codex/visualizations/2026/09/07/demo/ring-proposal.html","mode":"wide"}
你可以继续说话。
'@
Assert-Speech $preview "朗读设置已经保存。`n`n你可以继续说话。" 'real preview marker and JSON are silent'
Assert-Speech '已经完成。visualize{"path":"C:/demo' '已经完成。' 'unfinished display marker is silent'
Assert-Speech @'
第一步完成。
```powershell
$abc = Get-Content "C:/test/example.json"
Write-Output $abc
```
可以继续。
'@ "第一步完成。`n`n可以继续。" 'whole fenced command block is silent'
Assert-Speech @'
````markdown
```js
const abc = 1;
```
abc remains code until the long fence closes
````
只读这句。
'@ '只读这句。' 'short nested fence does not resume speech'
Assert-Speech @'
~~~python
print("ABC")
~~~
完成。
'@ '完成。' 'tilde fence is silent'
Assert-Speech @'
完成。
```json
{"ABC": "do not speak"}
'@ '完成。' 'unfinished code block is silent'
Assert-Speech @'
```js
const abc = 1;
```
'@ '' 'code-only answer is empty for speech'
Assert-Speech @'
[打开使用说明](<C:/Users/TestUser/Desktop/My Folder (v2)/说明.md:12>)。
'@ '' 'standalone artifact link is display-only, including a spaced path with parentheses'
Assert-Speech '请打开[使用说明](<C:/Users/TestUser/Desktop/My Folder (v2)/说明.md:12>)，再继续。' '请打开使用说明，再继续。' 'semantic local link inside a sentence remains speech'
Assert-Speech '[官方文档](https://example.org/docs(a(b))) 已更新。' '官方文档 已更新。' 'balanced URL destination does not leak a suffix'
Assert-Speech '用户不需要安装训练用的环境。[训练与导出说明](https://example.org/train)' '用户不需要安装训练用的环境。' 'training reference label after sentence is silent'
Assert-Speech '声音模型约一百 MB。[体积示例](https://example.org/sizes)' '声音模型约一百 MB。' 'user reported size example label is silent'
Assert-Speech '已经完成。 [官方文档](https://example.org/a) · [价格说明](https://example.org/b)' '已经完成。' 'multiple trailing citations are silent'
Assert-Speech '模型体积已经核对。（[体积示例](https://example.org/sizes)）' '模型体积已经核对。' 'parenthesized trailing reference is silent'
Assert-Speech '模型体积已经核对（[体积示例](https://example.org/sizes)）。' '模型体积已经核对。' 'citation inside parentheses before sentence punctuation is silent'
Assert-Speech 'The size is verified ([size reference](https://example.org/sizes)).' 'The size is verified.' 'ASCII parenthetical citation is silent'
Assert-Speech '体积已经核对（[体积示例](https://example.org/sizes)、[训练说明](https://example.org/train)）！' '体积已经核对！' 'all links in one trailing parenthetical citation are silent'
Assert-Speech '请先看（[训练与导出说明](https://example.org/train)）。' '请先看（训练与导出说明）。' 'explicit instruction retains its parenthesized linked object'
Assert-Speech '请**阅读**（[训练与导出说明](https://example.org/train)）。' '请阅读（训练与导出说明）。' 'bold instruction retains its parenthesized linked object'
Assert-Speech 'Read ([the setup guide](https://example.org/setup)).' 'Read (the setup guide).' 'English explicit instruction retains its linked object'
Assert-Speech '当前模型是（[GPT-6](https://example.org/model)）。' '当前模型是（GPT-6）。' 'parenthesized linked predicate stays meaningful'
Assert-Speech '请看（[训练与导出说明](https://example.org/train)），然后开始。' '请看（训练与导出说明），然后开始。' 'semantic link before more prose is not a trailing citation'
Assert-Speech '体积已经核对（详细说明见[体积示例](https://example.org/sizes)）。' '体积已经核对（详细说明见体积示例）。' 'parenthetical prose is retained when not composed only of links'
Assert-Speech '[GPT-6](https://example.org/model) 负责回答，打开[声音设置](https://example.org/settings)可以换声音。' 'GPT-6 负责回答，打开声音设置可以换声音。' 'linked subjects and objects retain meaningful prose'
Assert-Speech @'
正文保留。

参考资料：
- [体积示例](https://example.org/sizes)
- [训练与导出说明](https://example.org/train)
'@ '正文保留。' 'reference heading and links-only list are silent'
Assert-Speech @'
正文保留。

**参考资料：**
- [体积示例](https://example.org/sizes)
'@ '正文保留。' 'bold reference heading with colon inside formatting is silent'
Assert-Speech @'
正文保留。

### **参考资料**：
- [训练说明](https://example.org/train)
'@ '正文保留。' 'bold reference heading with colon outside formatting is silent'
Assert-Speech @'
正文保留。

__Sources__:
- [Source](https://example.org/source)
'@ '正文保留。' 'underscore bold English reference heading is silent'
Assert-Speech '**参考资料包含操作步骤**，请认真阅读。' '参考资料包含操作步骤，请认真阅读。' 'ordinary bold prose starting with reference words is preserved'
Assert-Speech @'
正文保留。 [训练说明][training]
[training]: https://example.org/train
'@ '正文保留。' 'trailing reference-style citations are silent'
Assert-Speech @'
正文保留。[训练与导出说明]

[训练与导出说明]: https://example.org/train
'@ '正文保留。' 'defined shortcut reference is silent after a sentence'
Assert-Speech @'
正文保留。[1]

[1]: https://example.org/train
'@ '正文保留。' 'defined numeric shortcut reference is silent after a sentence'
Assert-Speech @'
[训练与导出说明]

[训练与导出说明]: https://example.org/train
'@ '' 'standalone defined shortcut reference is silent'
Assert-Speech @'
请先看[训练与导出说明]，再继续。

[训练与导出说明]: https://example.org/train
'@ '请先看训练与导出说明，再继续。' 'defined shortcut reference retains its semantic object'
Assert-Speech @'
[SETUP GUIDE] 已经更新。

[setup   guide]: https://example.org/setup
'@ 'SETUP GUIDE 已经更新。' 'shortcut reference IDs normalize case and whitespace without changing labels'
Assert-Speech '状态为[待确认]，编号[1]也要保留。' '状态为[待确认]，编号[1]也要保留。' 'undefined bracketed prose is never treated as a reference'
Assert-Speech @'
正文保留。[^1]
[^1]: 来源信息。
'@ '正文保留。' 'footnote marker and definition are silent'
Assert-Speech '[训练与导出说明](https://example.org/train)' '' 'citation-only answer is silent'
Assert-Speech '[C:/My Folder/speech.html](C:/My%20Folder/speech.html) 已保存。' '已保存。' 'absolute path link label with spaces is silent'
Assert-Speech '![音频](C:/work/voice.mp3) 已保存。' '已保存。' 'media reference is not read'
Assert-Speech @'
[说明][guide] 已更新。
[guide]: https://example.org/guide
'@ '说明 已更新。' 'reference link uses its human label'
Assert-Speech '详见 https://example.org/path?abc=1。完成。' '详见 。完成。' 'bare URL omitted without swallowing Chinese sentence'
Assert-Speech '<https://example.org/path> <file:///C:/Program Files/test.html>' '' 'autolink URLs including spaces are silent'
Assert-Speech '参考这个[https://example.org](https://example.org)继续操作。' '参考这个继续操作。' 'URL label does not consume following Chinese prose'
Assert-Speech '参考这个[**HTTPS://example.org**](https://example.org)继续操作。' '参考这个继续操作。' 'formatted URL label does not consume following prose'
Assert-Speech '[www.example.org](https://example.org)已经更新。' '已经更新。' 'WWW link label is removed within its known boundary'
Assert-Speech @'
请访问[https://example.org]继续操作。

[https://example.org]: https://example.org
'@ '请访问继续操作。' 'URL shortcut reference label is removed within its boundary'
Assert-Speech '路径：C:\Users\TestUser\Desktop\test.txt。已保存。' '路径：。已保存。' 'bare Windows path is silent'
Assert-Speech '保存到 "C:\My Folder (v2)\说明.txt" 完成。' '保存到 完成。' 'quoted Windows path with spaces is silent'
Assert-Speech '路径：/tmp/project/output.html。' '路径：。' 'Unix artifact path is silent'
Assert-Speech '由 `GPT-6`、`Codex` 和 API 处理。' '由 GPT-6、Codex 和 API 处理。' 'useful English labels remain audible'
Assert-Speech '使用 GPT‑6 回答，声音为台湾女声。' '使用 GPT‑6 回答，声音为台湾女声。' 'natural answer preserved exactly'
Assert-Speech '命令：`git status`。路径：`C:/My Folder (v2)/app.py`。' '命令：。路径：。' 'inline commands and paths are silent'
Assert-Speech @'
## 已完成
- **可以继续**。
'@ "已完成`n可以继续。" 'ordinary Markdown prose is readable'
Assert-Speech @'
已经完成。
::code-comment{title="ABC" file="C:/test.py" body="private display data"}
'@ '已经完成。' 'app UI directive line is silent'
Assert-Speech '' '' 'empty answer stays empty'
Assert-Speech @'
说明：
> ```json
> {"token":"should not speak"}
> ```
已完成。
'@ "说明：`n`n已完成。" 'quoted fenced code is silent'
Assert-Speech @'
- 先完成这一步。
    ```json
    {"token":"should not speak"}
    ```
- 再继续。
'@ "先完成这一步。`n`n再继续。" 'list-nested fenced code is silent'
Assert-Speech @'
- ```json
  {"token":"should not speak"}
  ```
已完成。
'@ '已完成。' 'fence beginning on a list marker is silent'
Assert-Speech @'
请查看屏幕上的命令。

    git status
    Write-Output "ABC"

完成。
'@ "请查看屏幕上的命令。`n`n完成。" 'indented code is silent'
Assert-Speech @'
- 第一步。
    这段说明仍然要读。
    - 第二步。
        嵌套说明也要读。
'@ "第一步。`n这段说明仍然要读。`n第二步。`n嵌套说明也要读。" 'list continuation prose is retained'
Assert-Speech @'
1. 第一步。

    等到状态显示正在聆听，再开始说话。

2. 第二步。
'@ "1. 第一步。`n`n等到状态显示正在聆听，再开始说话。`n`n2. 第二步。" 'indented ordered-list continuation is prose'
Assert-Speech '再选 `GPT 6`，状态会显示 `正在识别，请稍候`。' '再选 GPT 6，状态会显示 正在识别，请稍候。' 'natural inline status and model names are retained'
Assert-Speech '已保存到C:\Users\TestUser\Desktop\demo.txt，直接打开即可。' '已保存到，直接打开即可。' 'Windows path adjacent to Chinese is silent'
Assert-Speech '请打开https://example.org/abc，然后继续。' '请打开，然后继续。' 'URL adjacent to Chinese is silent'
Assert-Speech '文件在/tmp/project/demo.txt，已完成。' '文件在，已完成。' 'Unix path adjacent to Chinese is silent'
Assert-Speech @'
已完成。::code-comment{title="ABC"
body="包含 } 字符" file="C:/demo.py"}继续。
'@ '已完成。继续。' 'multiline inline display directive with quoted brace is silent'

# The same full answer still reaches the transcript and answer box/replay path.
$source = $preview
$tail = @{ Seen = New-Object 'System.Collections.Generic.HashSet[string]'; UserTurnVersion = 0 }
$event = @{ type='event_msg'; payload=@{type='task_complete'; turn_id='speech-markup'; last_agent_message=$source} } | ConvertTo-Json -Depth 5 -Compress
$answer = Get-CompletedAnswer $tail $event
[void](ConvertTo-SpokenText $answer.Text)
if ($answer.Text -cne $source) { throw 'Full answer was modified by speech cleaning' }
$script:passed++
Write-Output 'PASS full completed answer retains the preview and original text'
# Exercise the real queue entry point with device boundaries stubbed. This
# verifies that silent answers never launch speech and prose is queued cleanly.
$tokens = $null; $parseErrors = $null
$handsFreePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\HandsFree.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($handsFreePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'HandsFree source failed to parse' }
$queueFunction = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Queue-AnswerSpeech'}, $true)
. ([scriptblock]::Create($queueFunction.Extent.Text))
function Test-ExternalCapture { return $false }
function Test-FullDuplexReady { return $false }
function Suspend-WakeListener { }
$script:recMode = 'idle'
$script:handsFreePhase = 'off'
$script:handsFreeEnabled = $false
$script:speechQueue = New-Object 'System.Collections.Generic.Queue[string]'
Queue-AnswerSpeech ('```' + "`nABC`n" + '```')
if ($script:speechQueue.Count -ne 0) { throw 'Code-only answer entered the speech queue' }
$script:passed++
Write-Output 'PASS production queue skips code-only answers'
Queue-AnswerSpeech $preview
if ($script:speechQueue.Count -ne 1 -or $script:speechQueue.Dequeue() -cne "朗读设置已经保存。`n`n你可以继续说话。") { throw 'Production queue did not receive the cleaned answer' }
$script:passed++
Write-Output 'PASS production queue receives prose without display metadata'
Write-Output "TOTAL passed=$script:passed failed=0"
