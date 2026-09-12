# GitHub 同类项目调研

查阅日期：2026-09-08。以下结论来自实际打开的项目仓库、架构文档和发布说明；本次未安装、运行或测试这些项目。项目自述的“支持”不等于已在这台 Windows 电脑验证。GitHub 部分提交时间未完整显示，因此不据此编造最近更新时间，也不以星数判断稳定性。

**结论：确实有很接近的项目。对目前“保留原 Codex 任务和高级模型，答完显示文字并朗读”的需求，最直接的是保留现有任务桥接，再借鉴独立语音控制和悬浮界面。原生实时语音方案更像连续通话，但不等于逐字朗读某个高级文字模型的完整回答。**

## 五个项目对照

| 项目与证据 | 怎么实现 | Windows 与成熟度 | 模型、账号及费用路径 | 对本项目的采用判断 |
|---|---|---|---|---|
| [Talking Pets](https://github.com/arata-ai-daisuki/talking-pets) | 读取 Codex 本地 SQLite/rollout，交给 VOICEVOX、Kokoro 或系统语音，给现有 Codex Pet/回答加声音。 | 作者把 macOS Swift 版列为稳定；Windows Node/PowerShell 路线明确为 experimental。 | 默认不再调用外部 LLM；使用 Codex 已生成的文本，默认没有额外 OpenAI API 调用。 | **最接近我们的回读部分。** 借鉴日志兼容性检查、跳过旧消息、TTS 提供商可替换。它本身不能替代完整语音输入与发送。 |
| [Codex Voice Input](https://github.com/A3Boy/codex-voice-input) | C#/WinUI 3：全局录音键、悬浮胶囊、真实音量波形、转写预览，再用 SendInput 写入有焦点的输入框。 | 明确支持 Windows x64；提供自包含包。是非官方项目。 | 读取现有 Codex 登录，调用逆向得到的转写流程，无需单独 API key；不保证接口稳定或无限额度。 | **借鉴 Windows 界面与录音交互。** 保留我们本地 SenseVoice；不采用它的认证读取和私有转写端点，也不把“当前输入焦点”当作目标任务。 |
| [Voice Relay](https://github.com/hyungchulc/voice-relay) | macOS 原生悬浮球/刘海界面；Realtime 负责语音，实质请求转交同一持久 Codex 桌面任务，返回进度与答案。允许明确填写现有 Session ID。 | 公共 alpha，macOS；当前不能直接装到 Windows。 | 使用已登录桌面会话和短期 Realtime 凭据，项目不要求 API key；任务执行仍交给桌面 Codex。 | **最接近完整产品结构。** 借鉴固定任务、可见状态、迟到结果丢弃、独立界面。暂不整体移植：其 Mac 音频栈和 Realtime 路径与我们不同。 |
| [Jarvis × Codex](https://github.com/Big-Guan/jarvis-codex) | Tauri/Rust 悬浮角色＋Swift 本地唤醒，接 Codex app-server V3 WebRTC；每个工作目录保存线程，语音、文本、工具共用。 | 文档为 v0.2.0；作者验证环境是 Apple Silicon/macOS 26，发布包面向 Mac。 | 复用本地 Codex 登录和 app-server；走实验性 Codex Voice，非普通“文字回答完成后 TTS”。 | **借鉴外观与状态驱动动画。** 不直接替换现有 Windows 助手；它管理自己的 workspace 线程/runtime，也不能据此保证沿用用户当前桌面任务的全部状态。 |
| [VoiceMode](https://github.com/mbailey/voicemode) | 给 Claude Code 等 MCP 客户端增加双向语音；STT/TTS 可用本地 Whisper/Kokoro 或 OpenAI 兼容服务。独立控制通道可停读、重播、交还麦克风。 | README 支持原生 Windows/WSL；[发布说明](https://github.com/mbailey/voicemode/releases)明确记录 Windows 11 支持和取消录音修复。 | 本地语音可不调用付费语音 API；云语音用对应服务。底层 LLM 由所接入的客户端决定；本次没有核实“直接复用本机现有 Codex 桌面任务”的完整接入。 | **最值得借鉴打断设计。** 引入明确的“停读”“开始说话”“重播”动作。无需为了这些控制，把整个程序改成 MCP。 |

## 与现有实现怎么对应

目前的主路线可以继续保持：

```text
麦克风 → 本地 SenseVoice → 用户检查/明确发送
       → 已绑定的原 Codex 任务及其现选模型
       → 完成的最终回答 → 悬浮文字 + edge-tts 台湾女声
```

这是产品选择：用户已接受高级模型思考等待，核心是原任务能力与答案一致性。Talking Pets 证明“直接给 Codex 已有回答加 TTS”是一条独立可行的开源路线；Voice Relay 则提供“明确绑定持久任务”的参考。两者的共同可借鉴点是让语音界面服务于任务连续性。[Talking Pets 说明](https://github.com/arata-ai-daisuki/talking-pets#safety-model)、[Voice Relay 架构](https://github.com/hyungchulc/voice-relay/blob/main/ARCHITECTURE.md)

不直接采用两个 Mac 成品的原因是：平台适配成本、实验语音协议依赖，以及实时语音输出与原文 TTS 的行为差异。它们的界面可以参考；没有证据表明安装后就能在 Windows 保留我们目前已绑定的任务、设置与完整原文朗读。

## “普通点击不应该取消”的具体启示

1. **界面操作与语音命令分开。** 点击、拖动、复制文字、切到别的普通窗口，只是界面操作；不应默认解释为“我不想听了”。这是基于显式控制设计的产品建议，并非断言所有仓库的鼠标处理都相同。
2. **开始录音才先停读，再开麦。** VoiceMode 的 `skip-forward` 明确执行“切断当前朗读并交麦”；Jarvis 的唤醒监听器先释放麦克风，Voice 才获取设备。我们可沿用同样清晰的资源交接顺序。[VoiceMode 控制通道发布说明](https://github.com/mbailey/voicemode/releases)、[Jarvis 麦克风生命周期](https://github.com/Big-Guan/jarvis-codex/blob/main/docs/ARCHITECTURE.md)
3. **停读、取消录音、取消 Codex 工作应是不同动作。** 本用户只是不想继续听时，应该清掉 TTS 播放和待播队列，不应顺带取消模型正在执行的任务。VoiceMode 的 stop 可让助手继续以文字工作；Jarvis 的 STOP 则会同时中断语音和任务，后者不应原样照搬。[VoiceMode 控制说明](https://github.com/mbailey/voicemode/releases)、[Jarvis STOP 定义](https://github.com/Big-Guan/jarvis-codex/blob/main/docs/ARCHITECTURE.md)
4. **声音大不等于用户在说话。** 真正的免按键边听边说需要回声消除；单靠音量阈值可能把扬声器回读当成用户。Pipecat 官方传输说明把 WebRTC 的回声消除与普通 WebSocket 区分开。我们目前更适合采用“明确开始录音→立即停读”的顺序，再独立评估 AEC；不能把现有 WAV 录音流程称作已经具备全双工回声消除。[Pipecat 官方传输说明](https://docs.pipecat.ai/client/concepts/choosing-a-transport)

## 当前建议

- **采用：** Talking Pets 的最终答案监控思想，Voice Relay 的明确任务绑定，VoiceMode 的独立播放控制，Windows 悬浮胶囊的录音反馈。
- **暂不采用：** 为了外观重写成跨平台框架；把普通鼠标点击当作停读；把停止朗读连带变成取消任务；用私有转写端点替代已可用的本地中文识别。
- **后续可评估：** 本地唤醒词、经实测的 AEC、真正连续对话。它们应作为独立升级，保留现有文字输入、手动录音及完整回答回读的回退方式。

本次只完成资料核对与对比，没有安装这些项目，也没有迁入其源代码。两个 Mac 项目标注 GPLv3，其余上述三个仓库标注 MIT；若后续实际复制代码，应按对应许可证处理。当前建议以借鉴交互和架构为主。
