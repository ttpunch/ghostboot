---
name: bsod-triage
description: Use when a restored Ghost disk blue-screens or fails to boot in a VM: map the stop code to a cause and apply the smallest fix (0x7B, 0xc000000e, GPT/EFI, replaced OEM kernel).
version: 0.1.0
license: MIT
metadata:
  hermes:
    tags: [bsod, 0x7b, 0xc000000e, bcdboot, windows, boot, triage]
---

# bsod-triage

Start from evidence: the exact stop code (ask for a screenshot), the `ghost-analyse` report, and the
VM settings. Change one thing per attempt. Take a snapshot or backup first.

## Map

| Symptom | Likely cause | Fix |
|---|---|---|
| STOP `0x0000007B` INACCESSIBLE_BOOT_DEVICE (2000/XP/early 7) | OS lacks drivers for the VM's storage controller | enable IDE drivers + critical device entries (below), use IDE `PIIX4` |
| `0xc000000e` "required device is inaccessible" (Vista and later) | BCD still points at the original disk signature | rebuild boot files with `bcdboot` |
| Black screen, "No bootable medium" on a GPT disk | no EFI fallback file, wrong VM firmware | create `BOOTX64.EFI`, set `--firmware efi64` |
| Reboots in a loop right after the logo | automatic restart hides the stop code | set `AutoReboot=0` in the offline SYSTEM hive to see it |
| Hang with a black screen on 2000/XP | ACPI/APIC or HAL mismatch | try `--ioapic off --pae off`, then compare HAL |
| `/Kernel=` in boot.ini names a custom kernel | replaced OEM kernel | registry fixes will not help; see the OEM section |

## 0x7B fix (offline registry)

Run elevated, on a snapshotted or backed-up disk, with the Windows volume at `<L>:`.

```powershell
reg load HKLM\OFFSYS "<L>:\WINDOWS\system32\config\system"     # WINNT\ on Windows 2000
reg query HKLM\OFFSYS\Select     # note Default and Current: fix whichever ControlSet each names

$hdc = "{4D36E96A-E325-11CE-BFC1-08002BE10318}"
$devices = "PCI#VEN_8086&DEV_7111", "PCI#VEN_8086&DEV_7010", "PCI#VEN_8086&DEV_7000", "*PNP0600"
foreach ($cs in "ControlSet001", "ControlSet002", "ControlSet003") {
    "atapi", "intelide", "pciide", "viaide", "aliide", "cmdide", "toside" | ForEach-Object {
        reg add "HKLM\OFFSYS\$cs\Services\$_" /v Start /t REG_DWORD /d 0 /f 2>$null
    }
    foreach ($d in $devices) {
        reg add "HKLM\OFFSYS\$cs\Control\CriticalDeviceDatabase\$d" /v Service /t REG_SZ /d atapi /f 2>$null
        reg add "HKLM\OFFSYS\$cs\Control\CriticalDeviceDatabase\$d" /v ClassGUID /t REG_SZ /d $hdc /f 2>$null
    }
}
[gc]::Collect()
reg unload HKLM\OFFSYS
```

Re-run `ghost-analyse` afterwards and confirm the findings cleared. Always unload the hive.

## 0xc000000e fix (BCD)

Attach the disk to a repair machine. Identify the System Reserved partition (has `bootmgr` and `Boot\BCD`) and the OS
partition (has `Windows\System32\ntoskrnl.exe`).

```powershell
takeown /f <Sys>:\Boot /r /d y
icacls <Sys>:\Boot /grant "*S-1-5-32-544:(OI)(CI)F" /t       # quote the whole ACE or PowerShell drops it
attrib -s -h -r <Sys>:\Boot\*.* /s /d
Remove-Item <Sys>:\Boot -Recurse -Force
bcdboot <OS>:\Windows /s <Sys>: /f BIOS /v
bcdedit /store <Sys>:\Boot\BCD /enum                          # entries should name the two partitions
```

Drive letters on the repair machine will differ from the original; `bcdboot` writes disk signature and offset,
not letters. If the source was BIOS/MBR, keep the destination MBR; do not convert to GPT.

## GPT / EFI fix

```powershell
Get-Partition -DiskNumber <N> | Select-Object PartitionNumber, DriveLetter, Type, GptType
Set-Partition -DiskNumber <N> -PartitionNumber <ESP> -NewDriveLetter Z
New-Item -ItemType Directory -Path Z:\EFI\BOOT -Force
Copy-Item Z:\EFI\Microsoft\Boot\bootmgfw.efi Z:\EFI\BOOT\BOOTX64.EFI
```

Then set the VM firmware to `efi64`. If it still fails, check `Z:\EFI\Microsoft\Boot\BCD`, try
`--graphicscontroller vboxsvga`, and confirm the boot order.

## OEM / industrial images

Check `boot.ini` for `/Kernel=`. A replaced kernel (for example `ntos_sin.exe` on older Siemens Sinumerik units) hooks the
storage stack below any registry fix; it needs the vendor's virtualization or the original hardware. Check the actual kernel
first: a unit with a standard unmodified kernel does boot on other hardware once the BCD is rebuilt. The label "industrial machine" alone is
not a blocker.

## Reporting

Write down for each attempt: stop code, change made, result. Say plainly when the evidence points to a blocker you cannot fix.
