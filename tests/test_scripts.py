"""Tests for the PowerShell scripts: syntax check and a functional run on a synthetic disk tree.

Needs Windows PowerShell 5.1 (powershell.exe). Skipped elsewhere.
"""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
POWERSHELL = shutil.which("powershell")


def run_ps(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", *args],
        capture_output=True, text=True, timeout=120,
    )


@unittest.skipUnless(POWERSHELL, "powershell.exe not available")
class ScriptSyntaxTest(unittest.TestCase):
    def test_every_script_parses(self):
        scripts = sorted(SCRIPTS.glob("*.ps1"))
        self.assertTrue(scripts)
        for script in scripts:
            cmd = (
                "$e=$null;$t=$null;"
                f"[void][System.Management.Automation.Language.Parser]::ParseFile('{script}',[ref]$t,[ref]$e);"
                "if($e.Count){$e|ForEach-Object{$_.Message};exit 1}"
            )
            res = run_ps("-Command", cmd)
            self.assertEqual(res.returncode, 0, f"{script.name}: {res.stdout}{res.stderr}")


@unittest.skipUnless(POWERSHELL, "powershell.exe not available")
class AnalysisTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def analyse(self, *extra: str) -> dict:
        res = run_ps("-File", str(SCRIPTS / "Get-GhostDiskAnalysis.ps1"), "-Root", str(self.root), *extra)
        out = res.stdout.strip()
        self.assertTrue(out, res.stderr)
        return json.loads(out)

    def test_no_windows_is_reported(self):
        report = self.analyse()
        ids = {f["Id"] for f in report["Findings"]}
        self.assertIn("NO-WINDOWS", ids)

    def test_boot_ini_with_custom_kernel(self):
        (self.root / "WINDOWS" / "System32").mkdir(parents=True)
        (self.root / "WINDOWS" / "System32" / "ntoskrnl.exe").write_bytes(b"MZ" + b"\x00" * 200)
        (self.root / "WINDOWS" / "System32" / "ntos_vendor.exe").write_bytes(b"MZ")
        (self.root / "boot.ini").write_text(
            "[boot loader]\ntimeout=5\n[operating systems]\n"
            "multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS=\"XP\" /Kernel=ntos_vendor.exe\n",
            encoding="ascii",
        )
        report = self.analyse()
        self.assertTrue(report["Boot"]["BootIniPresent"])
        self.assertEqual(report["Boot"]["KernelSwitch"], "ntos_vendor.exe")
        self.assertIn("ntos_vendor.exe", report["Boot"]["CustomKernelFiles"])
        ids = {f["Id"] for f in report["Findings"]}
        self.assertIn("OEM-KERNEL", ids)

    def test_winnt_folder_is_found(self):
        (self.root / "WINNT" / "System32").mkdir(parents=True)
        (self.root / "WINNT" / "System32" / "ntoskrnl.exe").write_bytes(b"MZ" + b"\x00" * 200)
        report = self.analyse()
        self.assertTrue(report["Os"]["WindowsDir"].lower().endswith("winnt"))


if __name__ == "__main__":
    unittest.main()
