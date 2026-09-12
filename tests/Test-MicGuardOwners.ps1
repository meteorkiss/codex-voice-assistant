param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $Root 'src\MicGuard.cs'))
$fixture=@'
namespace CodexReader.Audio {
    public static class CaptureOwnerPolicyFixture {
        private sealed class Owner : ICaptureProcessOwner {
            internal bool Exited, Disposed;
            internal string Name="fixture";
            internal Exception ExitFailure, NameFailure;
            public bool HasExited { get { if(ExitFailure!=null) throw ExitFailure; return Exited; } }
            public string ProcessName { get { if(NameFailure!=null) throw NameFailure; return Name; } }
            public void Dispose() { Disposed=true; }
        }
        private static int checks;
        private static void Check(bool value,string message) { if(!value) throw new InvalidOperationException(message); checks++; }
        public static int Run() {
            checks=0; string name; int calls=0;
            Func<int,ICaptureProcessOwner> forbidden=delegate(int id) { calls++; throw new Exception("Must not query unknown/system owner"); };
            Check(MicGuard.TryGetCaptureOwnerName(0,forbidden,out name) && name=="System", "PID zero lost conservative protection");
            Check(MicGuard.TryGetCaptureOwnerName(-1,forbidden,out name) && name=="Unknown", "Non-positive unknown owner lost protection");
            Check(calls==0,"Unknown PIDs queried a process");
            var alive=new Owner {Name="MeetingApp"};
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { return alive; },out name) && name=="MeetingApp", "Live owner was filtered or misnamed");
            Check(alive.Disposed,"Live metadata handle was not released");
            Check(!MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { throw new ArgumentException("No process"); },out name),"Confirmed absent PID was retained");
            var exited=new Owner {Exited=true};
            Check(!MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { return exited; },out name),"Confirmed exited owner was retained");
            Check(exited.Disposed,"Exited metadata handle was not released");
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { throw new System.ComponentModel.Win32Exception(5); },out name) && name=="Unknown","Access denied was treated as dead");
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { throw new InvalidOperationException("Query failed"); },out name) && name=="Unknown","Uncertain opening failure was treated as dead");
            var denied=new Owner {ExitFailure=new System.ComponentModel.Win32Exception(5)};
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { return denied; },out name) && name=="Unknown" && denied.Disposed,"Unreadable HasExited removed an uncertain owner");
            var nameFailure=new Owner {NameFailure=new ArgumentException("Name lookup failure is not absent PID")};
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { return nameFailure; },out name) && name=="Unknown" && nameFailure.Disposed,"Name ArgumentException was mistaken for GetProcessById absence");
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { return null; },out name) && name=="Unknown","Missing metadata was treated as confirmed dead");
            Check(MicGuard.TryGetCaptureOwnerName(42,delegate(int id) { return new Owner {Name=""}; },out name) && name=="Unknown","Empty process name removed a live owner");
            // The same PID becomes valid later: never cache a dead-PID decision.
            calls=0;
            Func<int,ICaptureProcessOwner> reused=delegate(int id) { calls++; if(calls==1) throw new ArgumentException("Old owner exited"); return new Owner {Name="NewOwner"}; };
            Check(!MicGuard.TryGetCaptureOwnerName(42,reused,out name),"First absent observation was retained");
            Check(MicGuard.TryGetCaptureOwnerName(42,reused,out name) && name=="NewOwner" && calls==2,"Reused PID inherited a cached dead decision");
            calls=0;
            Func<int,ICaptureProcessOwner> changed=delegate(int id) { calls++; return new Owner {Name=calls==1?"OldName":"ReusedName"}; };
            Check(MicGuard.TryGetCaptureOwnerName(42,changed,out name) && name=="OldName","Initial name fixture failed");
            Check(MicGuard.TryGetCaptureOwnerName(42,changed,out name) && name=="ReusedName" && calls==2,"Process name was permanently cached across PID reuse");
            return checks;
        }
    }
}
'@
Add-Type -TypeDefinition ($source+[Environment]::NewLine+$fixture)
$checks=[CodexReader.Audio.CaptureOwnerPolicyFixture]::Run()
$result=@{passed=$true;checks=$checks;powershell=$PSVersionTable.PSVersion.ToString();boundaries='Production MicGuard owner policy with injected process metadata. No endpoint enumeration, microphone, playback, process termination or changes to real capture sessions.'}
$output=Join-Path $Root 'work\tests\micguard-owners'
[void][IO.Directory]::CreateDirectory($output)
[IO.File]::WriteAllText((Join-Path $output 'result.json'),($result|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json -Depth 4
