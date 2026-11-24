"""Read-only report from an offline Windows NT/2000/XP SYSTEM registry hive (standard library only).

Why this exists: `reg load` can fail on some hosts ("The filename or extension is too long") and needs
an elevated shell. This reads the hive file directly and never writes to it. Copy the hive out of the
restored disk first (for example with `robocopy <dir> <dest> system /B` from an elevated shell).

    python hive_report.py <path to SYSTEM hive> [--json]

Reports: ControlSet selection, storage driver start values, critical device entries, the HAL entry
and PCI hardware recorded by the original machine, and boot-start (0) / system-start (1) drivers.
Start values: 0 boot, 1 system, 2 auto, 3 manual, 4 disabled.
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

STORAGE_SERVICES = (
    "atapi", "intelide", "pciide", "viaide", "aliide", "cmdide", "toside",
    "disk", "ftdisk", "mountmgr", "partmgr", "pci", "acpi", "isapnp",
    "storahci", "msahci", "iastorv", "iastor", "lsi_scsi", "vmscsi",
)


class HiveError(Exception):
    pass


class Hive:
    def __init__(self, path: str | Path):
        self.d = Path(path).read_bytes()
        if self.d[:4] != b"regf":
            raise HiveError("not a registry hive (missing 'regf' signature)")
        if len(self.d) < 0x1000:
            raise HiveError("hive too small")
        self.root = 0x1000 + struct.unpack_from("<I", self.d, 0x24)[0] + 4

    def _cell(self, off: int) -> int:
        return 0x1000 + off + 4

    def _nk(self, pos: int) -> dict:
        d = self.d
        if d[pos:pos + 2] != b"nk":
            raise HiveError("bad key node")
        flags = struct.unpack_from("<H", d, pos + 2)[0]
        nlen = struct.unpack_from("<H", d, pos + 0x48)[0]
        raw = d[pos + 0x4C:pos + 0x4C + nlen]
        return {
            "name": raw.decode("latin1" if flags & 0x20 else "utf-16le", errors="replace"),
            "nsub": struct.unpack_from("<I", d, pos + 0x14)[0],
            "sublist": struct.unpack_from("<I", d, pos + 0x1C)[0],
            "nval": struct.unpack_from("<I", d, pos + 0x24)[0],
            "vlist": struct.unpack_from("<I", d, pos + 0x28)[0],
        }

    def subkeys(self, k: dict) -> list[dict]:
        if k["nsub"] == 0 or k["sublist"] == 0xFFFFFFFF:
            return []
        d = self.d
        out: list[int] = []

        def walk(off: int, depth: int = 0) -> None:
            if depth > 4:
                return
            p = self._cell(off)
            sig = d[p:p + 2]
            n = struct.unpack_from("<H", d, p + 2)[0]
            if sig in (b"lf", b"lh"):
                for i in range(n):
                    out.append(self._cell(struct.unpack_from("<I", d, p + 4 + i * 8)[0]))
            elif sig == b"li":
                for i in range(n):
                    out.append(self._cell(struct.unpack_from("<I", d, p + 4 + i * 4)[0]))
            elif sig == b"ri":
                for i in range(n):
                    walk(struct.unpack_from("<I", d, p + 4 + i * 4)[0], depth + 1)

        walk(k["sublist"])
        return [self._nk(p) for p in out]

    def child(self, k: dict, name: str) -> dict | None:
        for c in self.subkeys(k):
            if c["name"].lower() == name.lower():
                return c
        return None

    def path(self, *names: str) -> dict | None:
        k = self._nk(self.root)
        for n in names:
            k = self.child(k, n)
            if k is None:
                return None
        return k

    def values(self, k: dict) -> dict:
        out: dict = {}
        if k["nval"] == 0 or k["vlist"] == 0xFFFFFFFF:
            return out
        d = self.d
        p = self._cell(k["vlist"])
        for i in range(k["nval"]):
            vo = self._cell(struct.unpack_from("<I", d, p + i * 4)[0])
            nlen = struct.unpack_from("<H", d, vo + 2)[0]
            dlen = struct.unpack_from("<I", d, vo + 4)[0]
            doff = struct.unpack_from("<I", d, vo + 8)[0]
            typ = struct.unpack_from("<I", d, vo + 0xC)[0]
            flags = struct.unpack_from("<H", d, vo + 0x10)[0]
            name = d[vo + 0x14:vo + 0x14 + nlen].decode("latin1" if flags & 1 else "utf-16le", errors="replace")
            if dlen & 0x80000000:
                data = struct.pack("<I", doff)[: dlen & 0x7FFFFFFF]
            else:
                dp = self._cell(doff)
                data = d[dp:dp + dlen]
            if typ == 4 and len(data) >= 4:
                val: object = struct.unpack("<I", data[:4])[0]
            elif typ in (1, 2):
                val = data.decode("utf-16le", errors="replace").rstrip("\x00")
            elif typ == 7:
                val = data.decode("utf-16le", errors="replace").rstrip("\x00").split("\x00")
            else:
                val = data[:24].hex()
            out[name or "(default)"] = val
        return out


def report(path: str | Path) -> dict:
    h = Hive(path)
    sel = h.path("Select")
    if sel is None:
        raise HiveError("no Select key: this is not a SYSTEM hive")
    selv = h.values(sel)
    current = int(selv.get("Current", 1))
    cs = f"ControlSet{current:03d}"
    svc = h.path(cs, "Services")
    if svc is None:
        raise HiveError(f"{cs} has no Services key")
    services = {c["name"].lower(): c for c in h.subkeys(svc)}

    storage = {}
    for n in STORAGE_SERVICES:
        if n in services:
            v = h.values(services[n])
            storage[n] = {"Start": v.get("Start"), "Group": v.get("Group")}
        else:
            storage[n] = None

    early = []
    for n, c in sorted(services.items()):
        v = h.values(c)
        if v.get("Start") in (0, 1) and v.get("Type") in (1, 2, 4, 8):
            early.append({"name": n, "Start": v["Start"], "Group": v.get("Group"), "ImagePath": v.get("ImagePath")})

    cdd = {}
    cddk = h.path(cs, "Control", "CriticalDeviceDatabase")
    if cddk is not None:
        for c in h.subkeys(cddk):
            v = h.values(c)
            cdd[c["name"].lower()] = v.get("Service")

    pci = []
    pk = h.path(cs, "Enum", "PCI")
    if pk is not None:
        for c in h.subkeys(pk):
            for inst in h.subkeys(c):
                v = h.values(inst)
                pci.append({"id": c["name"], "service": v.get("Service"), "class": v.get("Class"),
                            "desc": str(v.get("DeviceDesc", ""))[:60]})

    root_devices: list[str] = []
    rk = h.path(cs, "Enum", "Root")
    if rk is not None:
        root_devices = [c["name"] for c in h.subkeys(rk) if not c["name"].upper().startswith("LEGACY_")]
    hal = [n for n in root_devices if "HAL" in n.upper()]

    win = h.path(cs, "Control", "Windows")
    csd = h.values(win).get("CSDVersion") if win is not None else None
    po = h.path(cs, "Control", "ProductOptions")
    product = h.values(po).get("ProductType") if po is not None else None

    findings = []
    ide_off = [n for n in ("atapi", "pciide") if storage.get(n) and storage[n]["Start"] != 0]
    if ide_off:
        findings.append(f"boot-critical IDE service not boot-start: {', '.join(ide_off)}")
    if "pci#cc_0101" not in cdd:
        findings.append("no generic PCI IDE entry (pci#cc_0101) in CriticalDeviceDatabase: a different IDE controller may give STOP 0x7B")
    else:
        findings.append(f"generic PCI IDE entry present: pci#cc_0101 -> {cdd['pci#cc_0101']}")
    if hal:
        findings.append(f"HAL device(s) recorded: {', '.join(hal)} (check ACPI/APIC: the APIC HAL needs I/O APIC on in the VM)")

    return {
        "select": selv, "controlset": cs, "service_pack_code": csd, "product_type": product,
        "storage_services": storage, "critical_devices": cdd, "pci_hardware": pci,
        "root_devices": root_devices, "early_start_drivers": early, "findings": findings,
    }


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    try:
        r = report(argv[0])
    except (HiveError, OSError, struct.error) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if "--json" in argv:
        print(json.dumps(r, indent=2))
        return 0
    print(f"ControlSet: {r['controlset']}  Select: {r['select']}")
    print(f"ProductType: {r['product_type']}  CSDVersion code: {r['service_pack_code']} (0x{(r['service_pack_code'] or 0):X}; 0x400 = SP4)")
    print("Storage services (Start 0 boot, 1 system, 2 auto, 3 manual, 4 disabled):")
    for n, v in r["storage_services"].items():
        print(f"  {n:10} {'absent' if v is None else 'Start=' + str(v['Start'])}")
    print(f"CriticalDeviceDatabase entries: {len(r['critical_devices'])}")
    for k, s in sorted(r["critical_devices"].items()):
        if "ide" in k or k.startswith(("pci#", "gendisk")):
            print(f"  {k} -> {s}")
    print("Original PCI hardware:")
    for p in r["pci_hardware"]:
        print(f"  {p['id']} svc={p['service']} {p['desc']}")
    print("Findings:")
    for f in r["findings"]:
        print(f"  - {f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
