"""Builds tools/test-report.cs with the bridge's report code (Common.cs + Diagnose.cs) and runs it.
Uses the csc.exe that ships with Windows (.NET Framework 4). No network: the report address is left empty."""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSC = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), r"Microsoft.NET\Framework64\v4.0.30319\csc.exe")

work = tempfile.mkdtemp(prefix="test-report-")
stub = os.path.join(work, "ReportTarget.cs")
with open(stub, "w") as f:
    f.write('namespace SurrounSyncShared { static class ReportTarget { public const string Webhook = ""; } }\n')
exe = os.path.join(work, "test-report.exe")
cmd = [CSC, "/nologo", "/target:exe", "/out:" + exe,
       "/r:System.IO.Compression.dll", "/r:System.IO.Compression.FileSystem.dll", "/r:Microsoft.VisualBasic.dll", "/r:System.Core.dll", "/r:System.Windows.Forms.dll",
       os.path.join(REPO, "tools", "test-report.cs"), os.path.join(REPO, "bridge", "Common.cs"),
       os.path.join(REPO, "bridge", "Diagnose.cs"), stub]
b = subprocess.run(cmd, capture_output=True, text=True)
if b.returncode != 0:
    print(b.stdout, b.stderr)
    print("BUILD FAILED")
    sys.exit(1)
sys.exit(subprocess.run([exe]).returncode)
