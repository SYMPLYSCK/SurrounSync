"""Builds tools/test-voice.cs with the bridge's sources and runs it (voice loudness by distance, the walkie radio sound).
Uses the csc.exe that ships with Windows (.NET Framework 4). Works in a temp folder only."""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSC = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), r"Microsoft.NET\Framework64\v4.0.30319\csc.exe")

work = tempfile.mkdtemp(prefix="test-voice-")
try:
    stub = os.path.join(work, "ReportTarget.cs")
    with open(stub, "w") as f:
        f.write('namespace SurrounSyncShared { static class ReportTarget { public const string Webhook = ""; } }\n')
    exe = os.path.join(work, "test-voice.exe")
    cmd = [CSC, "/nologo", "/platform:x64", "/target:exe", "/main:TestVoice", "/out:" + exe,
           "/r:System.IO.Compression.dll", "/r:System.IO.Compression.FileSystem.dll", "/r:Microsoft.VisualBasic.dll",
           "/r:System.Web.Extensions.dll", os.path.join(REPO, "tools", "test-voice.cs")]
    cmd += [os.path.join(REPO, "bridge", n) for n in ("SurrounSyncBridge.cs", "Common.cs", "Diagnose.cs", "Realms.cs")]
    cmd.append(stub)
    b = subprocess.run(cmd, capture_output=True, text=True)
    if b.returncode != 0:
        print(b.stdout, b.stderr)
        print("BUILD FAILED")
        sys.exit(1)
    sys.exit(subprocess.run([exe]).returncode)
finally:
    shutil.rmtree(work, ignore_errors=True)
