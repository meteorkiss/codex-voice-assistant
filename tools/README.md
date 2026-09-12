# 声伴启动器

完整的[依赖与源码交付说明](../docs/依赖与源码交付.md)区分克隆源码、构建启动器和安装运行环境；[运行依赖清单](runtime-inventory.json)记录本机模型及音频文件校验值和 Python 包版本，尚不是发行下载锁文件。

在 Windows 项目根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Launcher.ps1
```

启动器版本读取根目录 `VERSION`，生成根目录 `声伴.exe`。首次构建会程序化绘制透明彩色声波环图标到 `assets/shengban.ico`，包含 16、32、48、64、128、256 像素尺寸；需要重画时加 `-RefreshIcon`。构建本身不启动助手，不修改快捷方式或个人数据。

修改 `VERSION` 后，同步 README 的“当前开发版”和 CHANGELOG 的首条版本说明，再运行构建。脚本校验三者一致，从 VERSION 临时生成程序集版本，编译并核对候选 exe 后才替换现有启动器。编译失败保留原 exe；本次生成的元数据与候选文件在成功或失败后清理。启动器还会拒绝源码 VERSION 与自身版本不一致的目录，提示重新构建。

构建依赖 Windows 的 .NET Framework 4.x C# 编译器，脚本先检测 Framework64，再检测 Framework。此启动器不依赖额外的 NuGet 包或 .NET SDK，使用 Windows GUI 子系统，双击不会显示终端窗口。

启动时以 exe 自身目录定位 `Start.ps1`、`src`、`assets`、`runtime`；检查必要入口、Python 解释器和 SenseVoice 模型是否存在。随后通过 Windows PowerShell 5.1，以 `-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass` 和隐藏窗口方式启动入口。缺少文件或无法启动进程会显示中文提示。不会透传外部命令参数、写入默认任务编号、登录账号或自动发送测试消息。

完整运行环境还需要 `runtime/python` 中安装根目录 `requirements.txt` 的依赖，以及 `runtime/models/sensevoice` 与 `runtime/models/wake` 的语音模型。启动器同时检查唤醒模型的 encoder／decoder／joiner、词表及空关键词文件，并检查 `src/AudioBootstrap.ps1`、`src/EchoCapture.cs` 和 `runtime/audio` 内的 NAudio.Core／NAudio.Wasapi 动态库。0.6.7 还检查任务切换与创建所需的 `TaskSwitch.ps1`、`TaskCreate.ps1`、`task_matcher.py` 和 `task_creation.py`。启动器检查文件存在，不替代 Python 包兼容性、模型加载、音频设备、Codex 连接或网络语音服务的实际验证；这些失败由助手界面报告。现有桌面 Codex 管道连接仍是实验适配。

`声伴.exe` 是小型入口，不是独立安装包。仅复制 exe 无法运行助手；发布打包应另行准备源码、依赖与模型，不能把当前 `data`（包括创建状态、创建历史及 SQLite 创建／发送账本）、聊天记录、录音或账户资料装进公共包。当前构建也没有代码签名或创建公开安装包。

构建或启动不会触发新建任务。只有之后明确的新建口令才进入创建流程，默认独立聊天，显式当前项目需通过精确项目验证；重启仅恢复已记录请求并进行有限只读查询，不重发创建。操作与恢复边界见 [使用说明](../docs/使用说明.md)。
