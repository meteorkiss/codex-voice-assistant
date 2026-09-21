using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("声伴")]
[assembly: AssemblyDescription("声伴桌面语音助手启动器")]
[assembly: AssemblyProduct("声伴")]

internal static class Launcher
{
    [STAThread]
    private static int Main()
    {
        try
        {
            // Resolve everything from this executable, never the caller's cwd
            // or a developer account's absolute path. No task ID is supplied.
            string root = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory);
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
            {
                return ShowError("未找到 Windows PowerShell。请启用或修复 Windows PowerShell 5.1 后重试。");
            }

            string[] required = {
                "VERSION", @"src\Version.ps1", @"src\Settings.ps1", @"src\Persistence.ps1",
                @"src\PendingSends.ps1", @"src\WorkerLifecycle.ps1",
                @"src\CodexAdapter.ps1", @"src\PreferenceActions.ps1",
                @"src\AudioOutput.ps1",
                @"src\DraftRecovery.ps1", @"src\BindingRecovery.ps1",
                "Start.ps1", @"src\Assistant.ps1", @"src\reader-core.ps1",
                @"src\AudioPlayer.cs", @"src\AudioBootstrap.ps1", @"src\EchoCapture.cs",
                @"src\MicGuard.cs", @"src\JarvisRecorder.cs",
                @"src\WakeListener.cs", @"src\HandsFree.ps1", @"src\WakeRecovery.ps1",
                @"src\NoWakeCapture.cs", @"src\NoWakeDecision.ps1", @"src\NoWakeConversation.ps1",
                @"src\DesktopShell.ps1", @"src\DesktopController.ps1", @"src\WaveformView.cs",
                @"src\DesktopTopmost.ps1", @"src\DesktopTopmost.cs",
                @"src\VoiceCommands.ps1", @"src\LocalCommands.ps1",
                @"src\TaskSwitch.ps1", @"src\task_matcher.py",
                @"src\TaskCreate.ps1", @"src\TaskBinding.ps1",
                @"src\DesktopActionCommands.ps1", @"src\DesktopActions.ps1", @"src\PlaybackCommands.ps1",
                @"src\desktop_actions.py",
                @"src\task_creation.py",
                @"src\WakePhrase.ps1",
                @"src\SettingsWindow.xaml", @"src\CaptionWindow.xaml",
                @"src\codex_bridge.py", @"src\transcribe.py", @"src\synthesize.py", @"src\wake_worker.py",
                @"assets\voices.json", @"runtime\python\python.exe",
                @"runtime\audio\NAudio.Core.dll", @"runtime\audio\NAudio.Wasapi.dll",
                @"runtime\models\sensevoice\model.int8.onnx",
                @"runtime\models\sensevoice\tokens.txt", @"runtime\models\sensevoice\silero_vad.onnx",
                @"runtime\models\wake\encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                @"runtime\models\wake\decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                @"runtime\models\wake\joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                @"runtime\models\wake\tokens.txt", @"runtime\models\wake\empty-keywords.txt"
            };
            List<string> missing = new List<string>();
            foreach (string relativePath in required)
            {
                if (!File.Exists(Path.Combine(root, relativePath)))
                {
                    missing.Add(relativePath);
                }
            }
            if (missing.Count != 0)
            {
                return ShowError("声伴的组件尚未准备完整：\r\n\r\n" +
                    String.Join("\r\n", missing.ToArray()) +
                    "\r\n\r\n请将启动器与 src、assets、runtime 放在同一程序目录，按 tools\\README.md 补齐依赖后重试。" +
                    "\r\n仅复制这个 exe 无法运行完整助手。");
            }

            string sourceVersion = File.ReadAllText(Path.Combine(root, "VERSION")).Trim();
            string builtVersion = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
            if (sourceVersion != builtVersion)
            {
                return ShowError("程序版本与源码不一致，请先运行 tools\\Build-Launcher.ps1 重新构建。");
            }

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = powershell;
            // -File consumes a literal script path. Do not use -Command or pass
            // through command-line arguments into a shell expression.
            info.Arguments = "-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass " +
                             "-WindowStyle Hidden -File \"" + Path.Combine(root, "Start.ps1") + "\"";
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process process = Process.Start(info))
            {
                if (process == null)
                {
                    return ShowError("Windows 未能启动声伴。请检查程序目录的访问权限后重试。");
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            return ShowError("无法启动声伴：\r\n" + error.Message);
        }
    }

    private static int ShowError(string message)
    {
        MessageBox.Show(message, "声伴", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return 1;
    }
}
