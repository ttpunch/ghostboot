"""Tests for the scripts: PowerShell syntax, the disk analysis on a synthetic tree, and the hive reader
on a small synthetic registry hive.

PowerShell tests need Windows PowerShell 5.1 (powershell.exe) and are skipped elsewhere.
"""
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
POWERSHELL = shutil.which("powershell")

import hive_report  # noqa: E402


def run_ps(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", *args],
        capture_output=True, text=True, timeout=120,
    )


class HiveBuilder:
    """Builds a tiny, valid-enough 'regf' hive: header plus cells, enough for hive_report."""

    def __init__(self):
        self.cells = bytearray(b"hbin" + b"\x00" * 28)          # hbin header, 0x20 bytes
        self.cells[8:12] = struct.pack("<I", 0x1000)

    def _add(self, data: bytes) -> int:
        off = len(self.cells)
        size = (len(data) + 4 + 7) & ~7
        self.cells += struct.pack("<i", -size) + data + b"\x00" * (size - 4 - len(data))
        return off

    def value(self, name: str, kind: str, v) -> int:
        nb = name.encode("ascii")
        if kind == "dword":
            vk = struct.pack("<2sHIIIHH", b"vk", len(nb), 4 | 0x80000000, v, 4, 1, 0) + nb
        else:  # sz
            data = (v + "\x00").encode("utf-16le")
            doff = self._add(data)
            vk = struct.pack("<2sHIIIHH", b"vk", len(nb), len(data), doff, 1, 1, 0) + nb
        return self._add(vk)

    def key(self, name: str, values=(), children=()) -> int:
        nb = name.encode("ascii")
        vlist = 0xFFFFFFFF
        if values:
            vlist = self._add(b"".join(struct.pack("<I", o) for o in values))
        sublist = 0xFFFFFFFF
        if children:
            sublist = self._add(b"lf" + struct.pack("<H", len(children))
                                + b"".join(struct.pack("<II", o, 0) for o in children))
        nk = bytearray(0x4C + len(nb))
        nk[0:2] = b"nk"
        struct.pack_into("<H", nk, 2, 0x20)                       # ASCII name flag
        struct.pack_into("<I", nk, 0x14, len(children))
        struct.pack_into("<I", nk, 0x1C, sublist)
        struct.pack_into("<I", nk, 0x24, len(values))
        struct.pack_into("<I", nk, 0x28, vlist)
        struct.pack_into("<H", nk, 0x48, len(nb))
        nk[0x4C:] = nb
        return self._add(bytes(nk))

    def build(self, root_off: int) -> bytes:
        body = bytes(self.cells)
        body += b"\x00" * (-len(body) % 0x1000)
        header = bytearray(0x1000)
        header[0:4] = b"regf"
        struct.pack_into("<I", header, 0x24, root_off)              # relative to the first hbin
        struct.pack_into("<I", header, 0x28, len(body))
        return bytes(header) + body


def make_system_hive() -> bytes:
    b = HiveBuilder()
    sel = b.key("Select", values=[b.value("Current", "dword", 1)])
    svc = b.key("Services", children=[
        b.key("atapi", values=[b.value("Start", "dword", 0), b.value("Group", "sz", "SCSI miniport")]),
        b.key("pciide", values=[b.value("Start", "dword", 0)]),
        b.key("intelide", values=[b.value("Start", "dword", 4)]),
    ])
    cdd = b.key("CriticalDeviceDatabase", children=[
        b.key("pci#cc_0101", values=[b.value("Service", "sz", "pciide")]),
    ])
    ctl = b.key("Control", children=[cdd])
    cs1 = b.key("ControlSet001", children=[svc, ctl])
    root = b.key("ROOT", children=[sel, cs1])
    return b.build(root)


class HiveReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_report_on_synthetic_hive(self):
        p = self.dir / "system"
        p.write_bytes(make_system_hive())
        r = hive_report.report(p)
        self.assertEqual(r["controlset"], "ControlSet001")
        self.assertEqual(r["storage_services"]["atapi"]["Start"], 0)
        self.assertEqual(r["storage_services"]["intelide"]["Start"], 4)
        self.assertIsNone(r["storage_services"]["viaide"])
        self.assertEqual(r["critical_devices"]["pci#cc_0101"], "pciide")
        self.assertTrue(any("pci#cc_0101 -> pciide" in f for f in r["findings"]))

    def test_rejects_non_hive(self):
        p = self.dir / "junk"
        p.write_bytes(b"not a hive" * 500)
        with self.assertRaises(hive_report.HiveError):
            hive_report.report(p)
        self.assertEqual(hive_report.main([str(p)]), 1)

    def test_cli_json(self):
        p = self.dir / "system"
        p.write_bytes(make_system_hive())
        res = subprocess.run([sys.executable, str(SCRIPTS / "hive_report.py"), str(p), "--json"],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["controlset"], "ControlSet001")


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
        self.assertIn("NO-WINDOWS", {f["Id"] for f in report["Findings"]})

    def test_boot_ini_with_custom_kernel(self):
        sys32 = self.root / "WINDOWS" / "System32"
        sys32.mkdir(parents=True)
        (sys32 / "ntoskrnl.exe").write_bytes(b"MZ" + b"\x00" * 200)
        (sys32 / "ntos_vendor.exe").write_bytes(b"MZ")
        (self.root / "boot.ini").write_text(
            "[boot loader]\ntimeout=5\n[operating systems]\n"
            "multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS=\"XP\" /Kernel=ntos_vendor.exe\n",
            encoding="ascii",
        )
        report = self.analyse()
        self.assertTrue(report["Boot"]["BootIniPresent"])
        self.assertEqual(report["Boot"]["KernelSwitch"], "ntos_vendor.exe")
        self.assertIn("ntos_vendor.exe", report["Boot"]["CustomKernelFiles"])
        self.assertIn("OEM-KERNEL", {f["Id"] for f in report["Findings"]})

    def test_stock_tools_are_not_custom_kernels(self):
        sys32 = self.root / "WINNT" / "System32"
        sys32.mkdir(parents=True)
        (sys32 / "ntoskrnl.exe").write_bytes(b"MZ" + b"\x00" * 200)
        for name in ("NTBACKUP.EXE", "ntdsutil.exe", "ntsd.exe", "NTVDM.EXE"):
            (sys32 / name).write_bytes(b"MZ")
        report = self.analyse()
        self.assertEqual(list(report["Boot"]["CustomKernelFiles"]), [])
        self.assertTrue(report["Os"]["WindowsDir"].lower().endswith("winnt"))


if __name__ == "__main__":
    unittest.main()
