# v6 测试说明

更新：2026-09-12。以下命令从项目根目录执行，使用 Windows PowerShell 5.1；WPF 测试带 `-STA`。测试样本在 `tests/fixtures`，运行产物写入 `work/tests` 或 `work/desktop-shell-render`。不应使用个人 `data` 作为测试输出目录。

0.6.17 名称/关键词增量：直接运行独立脚本通过桥接 37、匹配 35、口令 1354、控制器 21 场景、布局 118、免手状态机 340 项及源码布局检查。全部使用生成数据、自有 WPF 控件和桥接/音频替身；未复制源码临时根，未执行真实任务或录音。布局首跑暴露声音页零滚动旧断言，现验证接话新增行后无横向溢出、末项滚动可达，并查看默认/窄连接页及声音页末端渲染。先前被拒的组合集成验证未重试或绕过，仍不能标为本轮全量通过。

0.6.17 故障修正：`Test-VoiceCommands.ps1` 1290 项、`Test-HandsFree.ps1` 330 项、`Test-TranscriptRecovery.ps1` 12 项、`Test-ShortFollowUpCapture.ps1` 3 项通过；已安装 runtime Python `-B tests/test_task_matcher.py` 24 项通过。只用生成记录、真实生产回调和音频/桥接替身，未执行真人采集、播放或真实 Codex 写操作，生成文件已清理。新增切换集成样例未执行：复制源码/三组运行/递归清理的组合命令被审批拒绝，未重试或绕过。统一入口现登记 18 组；历史 17 组全量通过不是本次修正后的结果。

不要把“测试进程能运行”当成声学效果验收。当前已经做过本机组件、界面、任务读取和回声对照测试；真人与答案朗读重叠说话、不同房间和第二台纯净电脑尚未验证。没有公开发布安装包。

## 纯逻辑与离屏界面回归

0.6.8 增加 `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-MicGuardOwners.ps1`：实际编译生产麦克风会话所属核验，注入进程元数据测试退出、编号重用和访问失败，18 项通过，不打开音频设备。结果在 `work/tests/micguard-owners/result.json`。本机加载记录及此次唤醒问题的证据边界见 [排查记录](../docs/唤醒无回应排查-20260909.md)。

这些测试不向真实 Codex 发消息，不打开真实麦克风，不播放声音。`Test-DesktopController.ps1` 和 `Test-DesktopShell.ps1` 会创建本进程的真实 WPF 控件及窗口句柄，但不显示窗口。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test-reader-core.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-SpokenText.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test_pending_ui.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-StartupSettings.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-DesktopController.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-DesktopShell.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-HandsFree.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-ShortFollowUpCapture.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-PlaybackCancellation.ps1
.\runtime\python\python.exe -B tests/test_bridge.py
.\runtime\python\python.exe -B tests/test_task_matcher.py
.\runtime\python\python.exe -B tests/test_task_creation.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-VoiceCommands.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-LocalCommands.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-TaskCreate.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-TaskCreateIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-TaskSwitch.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-TaskSwitchIntegration.ps1
```

| 脚本 | 检查内容 |
| --- | --- |
| `test-reader-core.ps1` | 完成回答读取、去重、UTF-8 分片和任务记录重建 |
| `Test-SpokenText.ps1` | 使用生产过滤函数去掉预览、代码块、命令、网址、路径和参考链接；保留正文中的语义链接文字，不修改完整答案 |
| `test_pending_ui.ps1` | 生产发送状态函数：派发前保存、重启恢复、任务切换、未知回执、迟到回执和仍运行的派发进程 |
| `Test-StartupSettings.ps1` | 生产设置初始化：有无 BOM、保存／显式任务优先级、正式／测试／预览模式，以及唤醒偏好恢复 |
| `Test-DesktopController.ps1` | 已通过 18 场景：首启不能猜任务、选择后显式绑定、目录筛选不改绑定、每任务未知回执锁、绑定失败不混用目标与记录、同任务复用读取位置、六款样式、七种声音、四档语速、隐藏不断读、自动朗读只控制新答案。还在 `work/tests/desktop-controller` 中调用真实 `Save-Settings` 新建和替换文件，覆盖 PowerShell 5.1 的空备份路径处理 |
| `Test-DesktopShell.ps1` | 六款图形的透明像素与 WPF 命中几何、设置及字幕布局、窗口约束位置、样式尺寸和输入归一化；渲染图在 `work/desktop-shell-render`。PNG 与几何测试不等于穿透其他真实应用的点击测试 |
| `Test-HandsFree.ps1` | 生产免手状态机、计时器和识别结果处理；覆盖唤醒、回应、问题识别、自动派发、短时连续接话、取消、过期结果、资源释放和退出。设备、播放器、ASR 结果及桥接使用替身 |
| `Test-ShortFollowUpCapture.ps1` | 一起编译生产 AEC 与唤醒监听 C#，核对连续接话交接 API 和未启动监听时的拒绝行为；不配置 worker、不打开设备 |
| `Test-PlaybackCancellation.ps1` | 331 项检查：普通桌面操作、外观配置、隐藏窗口和刷新任务不断读；明确停读、录音、发送、换任务及采集状态变化仍执行取消。真实 TaskSwitch 的未找到、多候选、成功绑定反馈在模拟冷 AEC 等待中保留，就绪后只合成一次；外部麦克风与显式停止仍清队列 |
| `test_bridge.py` | 28 项离线单测：没有默认私人任务；list/find 只读本机索引；包含 WAL；坏索引和未知字段报错；过滤归档、子代理与非本机候选；明确目标及宿主校验；并发去重、未知回执、写账失败和重启后禁止重复发送 |
| `test_task_matcher.py` | 21 项标题匹配检查：完整/包含/同音优先级、多个候选、至少三个汉字的同音条件、英文数字边界、C++/C# 与版本号、无效查询 |
| `Test-TaskSwitch.ps1` | 12 场景／206 项，真实 TaskSwitch、Apply-Thread 与隔离设置保存；模拟搜索/读取回执，验证候选、过期、取消、失败回滚、草稿保留和统计 |
| `Test-TaskSwitchIntegration.ps1` | 9 场景／106 项，真实本地口令与主程序回调接线；桥接和音频使用替身，验证下一条发送目标、手动绑定和候选清理；不改变实际任务 |
| `Test-VoiceCommands.ps1` | 332 项：实际单句解析器，含设置、任务切换、创建、当前项目、恢复／放弃；否定、引述、测试语句和复合请求不直接创建 |
| `Test-LocalCommands.ps1` | 434 项：实际本地分派与 Send-Text／Try-AutoDispatch 路由，消费后不清后来草稿、不外发已识别控制口令 |
| `Test-TaskCreate.ps1` | 12 场景／115 项：实际创建模块与隔离 JSON 持久化，重复与未知结果保护、恢复／放弃、读取上限、坏记录、保存失败、迟到坏回执不降级 ready、明确拒绝显示原因 |
| `Test-TaskCreateIntegration.ps1` | 8 场景／109 项：实际解析／执行器／主程序回调，连接前不把问题发旧任务、迟到回执只记账、恢复不重复创建、退出不终止创建进程、当前项目 Scope 透传 |
| `test_task_creation.py` | 33 项：隔离 SQLite 账本、并发互斥、派发前拒绝与派发后未知结果、重复创建抑制、只读状态、独立／当前项目目标验证；Codex 调用使用替身 |

界面控制器结果在 `work/tests/desktop-controller/result.json`。测试期间的保存调用通常使用替身，只有专门的设置文件用例写入该测试目录；不启动 `Assistant.ps1` 的主循环，也不操作已运行的声伴。其中“隐藏后恢复录音入口”场景会短暂显示自己创建的窗口，结果标记 `testWindowsShown=true`；其余控制器场景离屏进行。另覆盖回声开关的停监听／恢复顺序、状态文案以及布尔设置保存。

## 真实窗口调度测试

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-DesktopShellDispatcher.ps1
```

这个脚本会短暂显示它自己创建的声波、设置与字幕窗口，检查显示、展开、移动、隐藏、再次打开和关闭清理等十个步骤。它不启动完整助手、不打开音频设备，也不发送任务。结果为 `work/desktop-shell-render/dispatcher-result.json`；不要把它归类成“无可见窗口”测试。

## 本地唤醒模型与问题衔接

```powershell
.\runtime\python\python.exe -B tests/test_wake_worker.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-WakeListener.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-WakeCancellation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-EchoPreRoll.ps1
```

- `test_wake_worker.py`：用已有正负样本评估本地关键词模型和不同阈值。
- `Test-WakeListener.ps1`：文件样本驱动真实 C# 唤醒组件与 Python KWS，验证预期激活。
- `Test-WakeCancellation.ps1`：提前取消和重新启动，防止迟到唤醒事件进入新一轮。
- `Test-EchoPreRoll.ps1`：把“唤醒词后立即跟问题”的文件数据送入生产处理入口，验证只交接一次问题录音、保留问题 PCM、限制唤醒尾音重叠。测试生成的音频在 `work/tests/echo-preroll`，不打开设备；文件注入绝不能使组件宣称真实双向音频已经就绪。

这些是文件样本和数据衔接测试，不证明真人远场发音或真人与朗读重叠时的实际识别率。

## 音频设备与 AEC 对照

以下测试涉及本机音频设备，应由执行测试的人明确安排时间，避免和日常助手、会议或录音同时争用麦克风。脚本不会自动结束正在运行的助手；需要释放设备时，先由使用者从托盘退出。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-EchoCapability.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-EchoMicrophone.ps1 -Seconds 5
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-WakeMicrophone.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-EchoAcoustic.ps1
```

| 脚本 | 真实设备行为 | 能证明什么 |
| --- | --- | --- |
| `Test-EchoCapability.ps1` | 枚举并初始化默认采集／播放设备相关能力，不播放测试声音 | 探测接口与设备可用性；能力探测不能把 `FullDuplexReady` 标成真实声学验证通过 |
| `Test-EchoMicrophone.ps1` | 打开真实麦克风，经 VoiceCaptureDSP 采样后停止；音频不保存 | 参考绑定、产生样本与停止释放能正常完成 |
| `Test-WakeMicrophone.ps1` | 实际开启和释放普通唤醒麦克风 | 采集进程归属与资源释放；不验证朗读中的回声消除 |
| `Test-EchoAcoustic.ps1` | 固定同一播放端点，通过真实扬声器重复播放三次测试唤醒词，分别采集原始与 AEC 处理音频，再送本地 KWS；采集音频仅在内存中处理 | 本机对照中原始路径能触发唤醒，AEC 路径没有误唤醒，验证了自身扬声器回声抑制这一段 |

v6 播放器与 AEC 参考绑定到相同的实际播放端点，并使用 Windows VoiceCaptureDSP。本机自身回声对照已通过，但 **尚未验证真人同时压着答案说话的效果**；上述实验不是“真人随时可打断”的完整验收，也不是所有音量、耳机和房间的保证。

真人重叠语音验收还需记录：唤醒能否被听到、停读延迟、回应与紧跟问题是否丢开头、自身答案多次含唤醒词是否误触发、连续打断是否只发送一次，以及拔插设备后的恢复。测试结果应注明具体设备、播放音量与距离，不能只记录“接口已启用”。

## 任务连接的只读验证

生产 `action=list` 不需要已绑定任务：从本机最新受支持的 `state_*.sqlite` 用 `mode=ro` 读取，包含当前 WAL，返回待校验的候选。选择任务后再调用 `action=read`，验证准确 ID 与本机宿主。目录只筛选列表，不能修改已有任务的 cwd。

本机已经完成“列候选 → 精确选中明确授权的当前任务 → 生产管道只读校验”，没有向其他任务读取更多对话，也没有发测试消息。此前只读片段摘要在 `work/tests/bootstrap-selected-task-probe.json`；不得把其中的本机编号作为公共默认值。

这不证明不同 Codex 版本、无工具上下文的普通安装、多实例或第二台电脑可稳定使用；内部管道仍是实验适配。清空绑定的首启只能展示选择，不得猜最近任务。

## 完整助手的 TestMode 集成

`Test-HandsFreeIntegration.ps1` 与 `test-jarvis-integration.ps1` 需要另起一份明确带 `-TestMode` 的助手，使用自己的状态、命令和测试记录文件。它们会真实使用麦克风和扬声器，并联网合成自拟文本；发送入口在 TestMode 中阻止真实派发。测试命令只应送给本次测试进程，不能复用日常助手的状态路径。

当前 TestMode 保留轮流听说路径，不启用正式运行的 AEC 朗读中唤醒；因此这两项集成不能替代上面的 v6 AEC 与真人重叠验证。已有 v5 成功结果 `work/tests/handsfree-integration/result.json` 属于历史组件链路记录，不能改称 v6 真人语音打断已通过。

以下例子启动免手集成。先由使用者退出日常助手，保持 Codex 运行，并明确选定要只读校验的现有本机任务 ID；助手现已没有私人默认任务。

```powershell
$testProject = (Resolve-Path .).Path
$testThreadId = Read-Host '本次测试明确选择的现有本机 Codex 任务 ID'
[void][Guid]::Parse($testThreadId)
$testRunDir = Join-Path $testProject ('work\tests\handsfree-integration-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRunDir)
$testStatus = Join-Path $testRunDir 'status.json'
$testCommand = Join-Path $testRunDir 'command.json'
$testTranscript = Join-Path $testRunDir 'transcript.jsonl'
[IO.File]::WriteAllText($testTranscript, '', (New-Object Text.UTF8Encoding($false)))
$testPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$assistantArguments = @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + (Join-Path $testProject 'src\Assistant.ps1') + '"'),
    '-TestMode', '-ThreadId', $testThreadId,
    '-StatusPath', ('"' + $testStatus + '"'),
    '-TestCommandPath', ('"' + $testCommand + '"'),
    '-TestTranscriptPath', ('"' + $testTranscript + '"')
)
Start-Process -FilePath $testPowerShell -WindowStyle Hidden -ArgumentList $assistantArguments
& $testPowerShell -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-HandsFreeIntegration.ps1 -RunDir $testRunDir
```

测试会在自己的界面中运行，结束时通过命令文件请求测试助手退出。不要根据“有 test 字样”就省略 `-TestMode`，也不要自动终止正在处理真实任务的进程。

手动集成使用相同原则，给 `src/Assistant.ps1` 另传 `-TestAudioPath tests/fixtures/voice-taiwan.wav`，并将路径与 `test-jarvis-integration.ps1 -RunDir` 对齐：`jarvis-test-status.json`、`jarvis-test-command.json`、`jarvis-test-transcript.jsonl`。运行时用完整绝对路径。每轮创建新目录，避免复用上轮命令。

## 启动器与换电脑

`tools/Build-Launcher.ps1` 只编译根目录 `声伴.exe`，不会启动助手。当前已核对 GUI 子系统、透明多尺寸图标和必要入口及依赖文件；依赖构建说明见 [启动器说明](../tools/README.md)。exe 入口的真实启动应单独人工验收，不能用“编译成功”代替。

第二台纯净 Windows 仍需用使用者自己的 Codex 账号、现有任务和音频设备，完成首启选任务、问答、朗读、明确停止、重启恢复及未知回执保护。测试记录、个人 `data`、录音和账户资料不得放进公共分发包。

测试语音均为自拟文本，`fixtures/voice-taiwan.expected.txt` 保存其中一个识别样本的原文；它们用于可重复验证，不代表真人口音和环境噪声的覆盖。
## 本轮 v6 整机记录

最新结果索引在 `work/tests/desktop-v6-verification.json`。无旧配置的首启实际列出 14 个本机候选，设置窗口可见，目标仍为空，麦克风未开启；独占读取状态文件时界面计时器和命令仍继续，退出正常。

手动整机链路通过 10 组检查；免手链路通过 6 组检查。后者本轮明确使用 `-SkipQuietRoomCheck`：现场采集持续出现能量活动，最初的无人声八秒返回检查未通过，因此第二次使用显式取消验证返回待机，不能把此结果写成空房间超时已验证。默认不传此参数仍会执行原安静房间检查。实际 ASR 准备一次自动发送、真实台湾女声播放、麦克风释放均通过，真实 Codex 发送数为 0。

隔离测试状态可给助手传 `-TestMode -TestStateDir <本轮测试目录下的state目录>`；正式运行忽略该选项。新的 `Test-AudioCoexistence.ps1` 与 `Test-EchoLiveComposition.ps1` 覆盖真实 MicGuard、Windows 回声采集、固定端点播放器共存，以及自身扬声器唤醒词不误触和录音归属当前进程。这两项会实际使用音频设备。
## 0.6.1 视觉更新

三页设置、浅色字幕和新声波共通过 97 项原生界面检查；窗口生命周期验证扩为 16 步，包含绑定对象的任务/声音名称、F4、下拉模板按钮以及切换页面。`Test-DesktopController.ps1` 的 18 场景、免手状态的 184 项及朗读取消的 28 项在新界面下继续通过，使用替身音频，不重新占用实际语音设备。

最终界面截图在 `work/desktop-shell-render`。声波的浅深底、多时刻、6 秒动画及离屏耗时数据在 `work/waveform-redesign/after`；动画展示的是传入音量和状态，不是实测频谱。离屏耗时包含 WPF 位图合成，不能当作桌面实际帧率。
`Test-WaveformView.ps1` 在 Windows PowerShell 5.1 / STA 下通过 59 项，覆盖所有样式的静音运动、整块透明中心、原命中区域、音量起落、相位连续与隐藏/关闭时解除静态 Rendering 事件订阅。结果为 `work/waveform-redesign/after/regression.json`。正式 0.6.1 启动、原偏好保留及回声采集重新就绪的记录在 `work/tests/visual-refresh-live.json`。

## 0.6.2 本地设置口令

`Test-VoiceCommands.ps1` 使用纯解析器，在 Windows PowerShell 5.1 下通过 158 项。`Test-LocalCommands.ps1` 使用实际解析、执行与手动/自动发送入口，17 场景、320 项断言通过；真实设置序列化写入独立测试目录，音频与 Codex 均为替身。

覆盖声线及语速反馈、设置保存和失败回滚、停止不复读、普通设置保留已排队答案、普通问题继续转发、过期意图/录音状态/未知发送回执保护。结果在 `work/tests/local-commands/result.json`。已有免手 184 项、桌面控制 18 场景、朗读取消 28 项继续通过。

正式启动器 0.6.2 已启动，任务和全部原有偏好保留，台湾女声与回声采集就绪；记录在 `work/tests/local-commands-live.json`。尚未把实际用户说出口令后的全过程计时当作已验证。纯解析微测在 `local-command-parser-timing.json`，它使用 PowerShell 7，不包含录音、ASR、磁盘保存、网络合成或播放，不能当作端到端延迟。

## 0.6.3 自定义唤醒词与暂停续播

新增 `Test-WakePhrase.ps1 -CheckModel`：91 项通过，包含严格输入验证和 5 个常见自定义词的真实模型构建，未启用麦克风。`Test-WakePhraseSettings.ps1` 使用实际保存、启动读取和按钮/Enter 绑定，9 场景、249 项断言通过；数据只写入隔离目录。

`Test-PlaybackCancellation.ps1` 扩为 146 项，复现真实 read-only bridgeJob 与 AEC 状态组合，覆盖设置查询不误停、暂停不被 timer 清理、继续保留音频和队列、三处暂停按钮以及外部麦克风保护。原免手 184 项、本地指令 320 项、桌面控制 18 场景继续通过。原生窗口验证为 113 项布局、18 步 Dispatcher。

`Test-AudioPauseResume.ps1` 使用真实生产播放器和全零 PCM，22 项通过，未开麦或播放讲话。暂停保持读取游标 420 ms，恢复后推进到 920 ms，同一个 reader/player/audioPath 保留。测量是读取游标，不代表扬声器样本级无缝；结果在 `work/tests/audio-pause-resume/result.json`。

正式启动器 0.6.3 已重新运行，当前任务、台湾女声、默认唤醒词和偏好保留，回声采集就绪。位置序列化有约 2.3e-13 像素浮点舍入差，验证按小于 1e-6 像素视为不变；原差值保留在 `work/tests/wake-playback-live.json`。本轮未修改录音时长上限或超时自动发送规则。

## 0.6.4 中心按钮与窗口内空格

`Test-CenterPlaybackButton.ps1` 通过 572 项：六种声波、三种尺寸、播放/暂停两态的圆形命中、透明边界和渲染。截图在 `work/center-playback-render`。这是 WPF 几何与离屏像素验证，未用系统鼠标点击其他桌面窗口。

`Test-PlaybackCancellation.ps1` 扩为 211 项，覆盖真实中心按钮 Click、重读去重、暂停/继续状态和不可读答案禁用。`Test-PlaybackKeyboard.ps1` 通过 51 项，使用本程序 WPF 窗口内合成事件验证单次/重复Space、输入与控件保护、失焦清理以及避免双触发；没有全局按键注册或系统级模拟按键。

原有 UI 114 项、Dispatcher 18 步、免手 184 项、桌面控制 18 场景通过。正式 0.6.4 已启动，偏好与任务保留、回声采集就绪，记录为 `work/tests/center-keyboard-live.json`。以上为历史验收；0.6.5 按用户要求撤下空格模块与旧键盘测试，备份位于 `work/backups/before-meter-stop-topmost-20260908-164854`。

## 0.6.5 结束按钮、真实音量与置顶恢复

`Test-CenterPlaybackButton.ps1` 957 项、`Test-WaveformView.ps1` 77 项、桌面 UI 116 项、Dispatcher 18 步通过。六种样式在固定相位下均验证：音量变化带来的形状差异明显大于待机微动；零音量的 speak/listen 与 idle 相同。图片在 `work/center-playback-render` 和 `work/waveform-redesign/after/audio-levels-light.png`。这些图片使用受控音量，不冒充真实频谱。

`Test-AudioLevel.ps1` 98 项通过，包括静音/低/高音量、PCM 与 float 格式、过期归零和计量线程不等待播放器控制锁。真实缓存台湾女声 MP3 用 MediaFoundationReader 解码成 24 kHz 单声道 PCM16，67 个音频块测得 17 个不同音量，范围 0—0.80844；只解码，未播放讲话。`-SilentPlayback` 另通过 5 项真实全零 WASAPI 生命周期检查；`Test-AudioPauseResume.ps1` 用新播放器重跑 22 项通过，同一个 reader/player/path 在暂停后保留，恢复后继续推进。结果在 `work/tests/audio-level/result.json` 和 `work/tests/audio-pause-resume/result.json`。

`Test-PlaybackCancellation.ps1` 扩为 250 项，新增真实结束按钮 Click、取消合成与待播段落、不改答案/草稿/任务、录音状态保护，以及麦克风/播放音量优先级。免手 184 项、桌面控制 18 场景继续通过。上述业务测试使用音频与麦克风替身，没有发送 Codex 消息。

`Test-DesktopTopmost.ps1` 原生层级验证 60 项通过，覆盖真实 WS_EX_TOPMOST、普通/另一置顶测试窗的层级、显示/隐藏、取消置顶、每次外部前景变化只提升一次、菜单延迟以及关闭后停止计时器。仅改变测试自身窗口，操作前后真实前景 HWND 不变。系统没有允许后台测试进程激活其普通测试窗，因此 `normalForegroundVerified=false`；外部进程变化用注入的只读快照验证分类策略，实际原生提升使用自家窗口验证，没有模拟操作其它软件。

正式 0.6.5 已启动，PID 28820，任务连接与回声采集就绪，悬浮窗可见且原生置顶为真；任务、台湾女声、语速及其它偏好保留。记录在 `work/tests/meter-stop-topmost-live.json`。完整设备上的后续听感与跨软件切换由实际使用继续观察，未声称覆盖独占全屏或安全桌面。

## 0.6.7 任务创建、低音量声波与唤醒门槛

创建模块 12 场景／115 项、完整接线 8 场景／109 项通过。测试导入真实生产函数，写入 `work/tests` 下的 GUID 隔离目录，并用替身返回创建、状态与读取回执；结果在 `work/tests/task-create/result.json` 和 `work/tests/task-create-integration/result.json`。默认独立任务和显式当前项目均有覆盖，未知状态与临时编号都不能重派创建。`ready` 之后的缺失或错误回执保留真实编号；保存失败可恢复，不把问题发给旧任务。全过程没有真实创建、发送、切换任务或打开音频设备。

同轮解析 332 项、本地分派 434 项、任务切换 206 项、切换集成 106 项、播放取消 331 项、免手 184 项、桌面控制 18 场景、启动设置 12 场景及发送账本回归通过。Python 创建 33、桥接 28、标题匹配 21，共 82 项通过。旧版本章节中的计数和启动记录保留为历史结果。

`Test-WaveformView.ps1` 重跑 77 项通过。视觉能量曲线指数从 0.8 改为 0.55，流光环形变量由 17 调为 20，并调整基础外扩以保持边界，增强低音量下的可见形变；不改变播放器输出音量。受控静音／音量对比仍区分真实幅度与待机微动，图片在 `work/waveform-redesign/after/`。

唤醒默认门槛 0.35 的文件回归 11 条通过，取消／重启 3 轮通过，`Test-EchoPreRoll.ps1` 保留完整 307118 字节／9.597 秒问句，前缀重叠约 70.75 毫秒。阈值对照的 453 次判定使用已有合成样本的内存变体，没有真人录音、麦克风或外放；方法、完整结果和未解决的准备空窗见 [唤醒漏检排查](../docs/唤醒漏检排查.md)。这些结果不证明真人远场或朗读重叠条件下的唤醒准确率。

本机于 2026-09-08 19:00:32 本地时间加载 0.6.7：原任务与全部偏好保留，连接、回声采集、原生置顶均就绪，运行时唤醒门槛为 0.35，无错误。记录为 `work/tests/voice-create-live.json`。这次启动健康确认没有实际创建任务或发送测试消息；创建功能的真实操作验收仍与上述隔离回归区分。

## 0.6.12 本地管理与续读

新增管理解析、接口、生产路由与唤醒续读检查，结果及整机验证边界见 [本版验证](../docs/本地管理实现与验证-0.6.12.md)。以下测试不打开真实音频设备、不操作真实 Codex：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-DesktopActionCommands.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-DesktopActions.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-VoicePlaybackResume.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-VoicePlaybackResume.ps1 -LegacyPlayer
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-VoicePlaybackResume.ps1 -CompileOnly
.\runtime\python\python.exe -B tests/test_desktop_actions.py
```

`Test-HandsFreeIntegration.ps1` 依赖另行启动的 TestMode 进程，不能直接读取默认历史目录运行。此次误调用超时并覆盖了旧 `work/tests/handsfree-integration/result.json`，不计入本版通过结果，也不能再将该路径当作 v5 成功原始凭据；失败记录和清理情况见本版验证。

## 0.6.13 连接保护与自动清理

建议在项目根目录运行：

```powershell
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File tests/Invoke-BindingChecks.ps1
```

0.6.13 时固定执行十组离线回归：任务切换、切换完整接线、创建、创建完整接线、桌面控制、本地指令、播放取消、免手状态机、管理指令和唤醒续读。测试复制必要源码与固定资源到 `work/tests/binding-suite-<随机编号>`，不加载个人 data 或 runtime；成功和失败均在 finally 中核验目录范围并删除此次副本及生成文件。控制台保留摘要，必要的回归测试源码继续保留。0.6.14 扩充项目见下文。

本批通过：任务切换 206 项，含手动绑定的完整接线 236 项，创建 115 项，创建完整接线 121 项，播放取消 344 项，免手状态机 184 项；其余四组均通过。新增场景使用生产回调与 WPF 文本／选择事件，验证草稿保护、输入删空和选择返回、迟到结果、错误目标与回执类型、保存失败回退、启动恢复、一次提交及后续投递。没有打开真实音频设备或操作真实 Codex 任务。

首次隔离运行发现副本未包含唤醒回应音频，播放取消测试因此失败；已补齐复制所需固定音频，再运行十组全部通过。两次运行产生的临时数据均已清理，不将失败首次运行计为通过。

本机于 2026-09-10 12:47（北京时间）加载 0.6.13：原绑定和全部偏好保留，窗口及置顶正常、回声采集就绪、监听 healthy，模型处理量从 160 增长至 40160，无启动错误。重载检查仅在内存与控制台保留结果，没有新增临时脚本或验证文件；运行健康不替代真人声学验收。

## 0.6.14 基础服务与版本一致性

2026-09-10，Windows PowerShell 5.1 / STA，继续使用上述 `Invoke-BindingChecks.ps1` 命令。最终十五组全部通过：原十组加启动设置、发送回执、基础服务、唤醒词设置和版本构建。提取模块后的测试仍调用真实生产函数和界面回调，外部进程、音频及 Codex 写操作使用替身。

- `Test-Infrastructure.ps1`：63 项，包含 UTF-8 原子写入、锁定目标失败保留旧值和清理临时文件、越界清理拒绝、退出/取消/超时/终止失败的文件保留、写操作不可强制终止、版本格式、派发前失败与派发后进程信息保存失败。没有打开音频设备或调用真实 Codex。
- `Test-VersionBuild.ps1`：16 项，在临时副本中用真实编译器检查文件/程序集版本来自 VERSION、覆盖构建，以及 README/CHANGELOG/版本格式/编译错误时保住原 exe 并清理生成文件。没有启动测试 exe。
- 原任务切换 206 项、切换完整接线 236 项、创建 115 项、创建完整接线 121 项、播放取消 344 项、免手状态机 184 项继续通过，其余各组均通过。

前两轮分别发现唤醒词恢复测试仍寻找旧顶层代码、播放取消替身尚未表达音频清理责任迁移；更新测试接线后复跑全部通过。失败轮次不计为通过，各轮临时源码、回执与生成文件均已删除。生产构建成功，文件版本和产品版本均为 0.6.14.0；`work/build` 无本轮生成文件残留。

本机于 2026-09-10 13:31（北京时间）通过真实 exe 重载到 0.6.14：原任务绑定及全部偏好保留，窗口和原生置顶正常，回声采集就绪、监听 healthy，模型处理量从 8160 增长至 40160，启动及模块警告为空。重载检查只在内存和控制台保存摘要，不生成一次性脚本、截图或报告；本次未做真人重叠说话验收。

## 0.6.15 设置事务、口令与连接适配

2026-09-10，Windows PowerShell 5.1 / STA，使用同一隔离入口，十五组最终全部通过。新增覆盖：真实 WPF 置顶和语速控件保存失败后的回退、失效声音选项的恢复、组合设置锁盘失败时内存与磁盘均保持原值、设置完成保留新的草稿/发送意图、活动候选的处理器返回未处理时不转聊天、字符串/数字布尔回执和重复成功回执。

`Test-Infrastructure.ps1` 扩至 91 项，覆盖所有当前请求用途组合及无效用途、操作大小写、带换行的任务编号、缺失请求编号和空消息拒绝；构建检查 16 项继续通过。原任务切换、创建、免手、播放取消等回归继续通过。首次新增候选故障样例使用了当前不支持的“第二个”简写，改为既有完整口令“选择第二个任务”后全部通过，没有因此扩展解析语法。最后补充无效选项的控件同步后，单独重跑桌面控制套件也通过。

本机于 2026-09-10 20:27（北京时间）经真实 exe 加载 0.6.15，当前用户绑定及全部偏好保留，窗口、置顶、回声采集正常，监听 healthy，模型处理量从 8160 增长至 40160，错误和模块警告为空。各轮测试副本、生成文件和构建临时文件已清理，重载检查仅在内存中执行。本次没有真实测试消息或管理写操作，也没有把运行健康当作真人声学验收。

## 0.6.16 音频输出与晨间准备

2026-09-10，Windows PowerShell 5.1 / STA：隔离入口扩展至 16 组并全部通过。最后针对播放与停止同时失败的修正，复验 `Test-AudioOutput.ps1` 44 项、播放取消 344 项及续读套件通过。输出检查包含启动失败、部分文件、旧代次/任务、重复启动、播放失败、停止失败后重试、越界路径和真实目录连接拒绝；所有音频与进程使用替身。

实际 NAudio 组件使用 `Test-VoicePlaybackResume.ps1 -CompileOnly` 编译及校验位置参数通过，没有打开音频设备。`tools/Test-SourceLayout.ps1` 核对源码依赖和声音资源，解析 PowerShell，并检查 Git 索引中的私人/生成文件；`.github/workflows/offline-checks.yml` 配置 Windows 上的源码检查与隔离回归，远端尚未运行。

0.6.16 于 20:42 本机重载成功，原偏好保留，窗口、置顶、回声和监听健康正常；模型处理量从 160 增长至 40160，随后观察继续增长。各轮临时副本和构建生成物已清理，另删除一份已确认未占用、9 月 8 日遗留的设置临时文件。夜间结果持续汇总到[晨间验收](../docs/晨间验收.md)。
