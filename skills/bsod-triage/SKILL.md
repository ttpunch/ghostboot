---
name: bsod-triage
description: Use when a restored Ghost disk hangs, crashes or blue-screens in a VM: find the actual cause by evidence (host hypervisor, APIC/HAL, dirty NTFS, missing IDE entries, BCD, EFI, OEM kernel) and apply the smallest fix.
version: 0.2.0
license: MIT
metadata:
  hermes:
    tags: [bsod, 0x7b, 0xc0000032, 0xc000000e, ntfs, hal, apic, virtualbox, windows-2000, triage]
---

# bsod-triage

Work from evidence, in this order, and change one thing per attempt. Take a snapshot or work on a copy
first. A real case needed three separate fixes in a row, so do not stop at the first plausible cause.

## 0. Read the symptom exactly

| What you see | Go to |
|---|---|
| VirtualBox "Guru Meditation" at power-on, log says "VT-x is not available" | 1 Host |
| Frozen on "Starting Windows..." (text bar, no blue screen) | 2 Hang |
| Blue screen STOP 0x0000007B | 3 STOP 0x7B (read the parameters) |
| `0xc000000e` "required device is inaccessible" (Vista and later) | 4 BCD |
| Black screen / "No bootable medium" on a GPT disk | 5 EFI |
| `/Kernel=` in boot.ini | 6 OEM kernel |

Capture the screen with `scripts/Watch-VmBoot.ps1`; do not guess from memory of an earlier BSOD.

## 1. Host: Guru Meditation -225 at power-on

Log (`<vm folder>\Logs\VBox.log`) shows `HM: HMR3Init: Attempting fall back to NEM: VT-x is not available`
and `WHvSetVirtualProcessorState -> ERROR_HV_INVALID_PARAMETER`. The Windows hypervisor is running
(`(Get-CimInstance Win32_ComputerSystem).HypervisorPresent` is True; WSL2, Docker Desktop, Hyper-V and
Virtualization-Based Security keep it on) and this VirtualBox build cannot run on top of it.

Fix (administrator PowerShell, then **reboot**; WSL2/Docker stop working until restored):

```powershell
bcdedit /set hypervisorlaunchtype off
# restore later:  bcdedit /set hypervisorlaunchtype auto
```

This is a system and security setting: get the user's explicit OK, and never reboot their PC for them.
Alternative: run the VM in VMware Workstation, which can share the hypervisor.

## 2. Hang on "Starting Windows..."

Boot Safe Mode (`Watch-VmBoot.ps1 -SafeMode`): Windows 2000/XP print each boot driver as it loads. If
`atapi.sys`, `disk.sys` and `Ntfs.sys` appear, storage is fine and the hang is later (HAL/APIC or a
third-party boot driver).

- **HAL decides the I/O APIC setting.** An ACPI **APIC** HAL (common on a PC with an APIC chipset) hangs
  silently with I/O APIC **off**; an ACPI **PIC** HAL wants it off. Check `Enum\Root` for the HAL entry
  with `scripts/hive_report.py`, then just test both: `VBoxManage modifyvm <vm> --ioapic on` and `off`,
  restoring the snapshot each time. Screenshot size unchanged across intervals = frozen screen.
- Other cheap, disk-free tests: `--hwvirtex off`, `--nestedpaging off`, `--cpus 1`, PIIX3 versus PIIX4.
- Third-party boot-start drivers (Start=0 in `hive_report.py` output) are the next suspects. They cannot
  find their hardware in a VM; disable one at a time on a copy.

## 3. STOP 0x7B INACCESSIBLE_BOOT_DEVICE: read the parameters

`STOP 0x0000007B (arg1, arg2, arg3, arg4)`:

| arg2 | Meaning | Fix |
|---|---|---|
| `0xC0000032` (STATUS_DISK_CORRUPT_ERROR) | the **file system could not mount**: most often the NTFS **dirty flag** is set | chkdsk /f on a copy, section 3a |
| `0xC0000034` / args 2-4 are 0 | boot device or its driver not found | IDE driver and critical device entries, section 3b |

### 3a. Dirty NTFS volume (verified on a real image)

`fsutil dirty query <X>:` on the attached disk says "Volume is Dirty". A restore done on the host (Ghost
writing to a mounted VHD, then a crash or unclean detach) leaves it so. Windows 2000 cannot replay the log
of a volume a modern Windows has touched, and stops with 0x7B / 0xC0000032. The partition table, boot
sector and MFT may all be fine.

```powershell
# elevated, on a COPY of the disk, attached read-write
chkdsk X: /f          # then:  fsutil dirty query X:   -> "NOT Dirty"
```

Detach, restore the snapshot (the snapshot sits above the disk), boot again. Do this **before** any
registry editing.

### 3b. IDE driver and critical device entries

Correct entries (Microsoft KB 314082 `mergeide.reg`; PCI IDE devices are **not** mapped to `atapi`):

| Key under `...\Control\CriticalDeviceDatabase` | Service |
|---|---|
| `pci#cc_0101` (generic PCI IDE class) | `pciide` |
| `pci#ven_8086&dev_7010`, `7111`, `1222`, `1230`, `2411`, `2421`, `7199` (Intel PIIX family) | `intelide` |
| `primary_ide_channel`, `secondary_ide_channel`, `*pnp0600` | `atapi` |
| all with `ClassGUID` | `{4D36E96A-E325-11CE-BFC1-08002BE10318}` |

And `Services\atapi`, `intelide`, `pciide` with `Start=0`, in every ControlSet (also the Last Known Good).
A stock Windows 2000 hive usually **already** has `pci#cc_0101 -> pciide`, so VirtualBox's PIIX controller works
without edits: check with `python scripts/hive_report.py <hive>` before editing anything.

Editing the hive:
- `reg load` may fail with "The filename or extension is too long" even for a plain test hive; it needs an
  elevated shell. If it fails, do not fight it. Copy the hive out (`robocopy <dir> <dest> system /B`), patch
  the copy, and copy it back with `/B`, or fix the cause elsewhere (3a, section 2).
- Always keep the original hive file (copy it) and unload any loaded hive.

## 4. 0xc000000e (BCD)

The BCD still names the original disk signature. Attach the disk to a repair PC:

```powershell
takeown /f <Sys>:\Boot /r /d y
icacls <Sys>:\Boot /grant "*S-1-5-32-544:(OI)(CI)F" /t       # quote the whole ACE
attrib -s -h -r <Sys>:\Boot\*.* /s /d
Remove-Item <Sys>:\Boot -Recurse -Force
bcdboot <OS>:\Windows /s <Sys>: /f BIOS /v
bcdedit /store <Sys>:\Boot\BCD /enum
```

Drive letters on the repair PC differ from the original; `bcdboot` writes signature and offset. If the source
was BIOS/MBR keep the destination MBR; do not convert to GPT.

## 5. GPT / EFI

```powershell
Set-Partition -DiskNumber <N> -PartitionNumber <ESP> -NewDriveLetter Z
New-Item -ItemType Directory -Path Z:\EFI\BOOT -Force
Copy-Item Z:\EFI\Microsoft\Boot\bootmgfw.efi Z:\EFI\BOOT\BOOTX64.EFI
```

Then set the VM firmware to `efi64`; try `--graphicscontroller vboxsvga`; check the boot order.

## 6. OEM / industrial images

Check `boot.ini` for a `/Kernel=` switch. A replaced kernel (for example `ntos_sin.exe` on older Siemens
Sinumerik units) hooks the storage stack below any registry fix and needs the vendor's virtualization or the
original hardware. Check the actual kernel first: many industrial PCs run a stock kernel and boot fine.

## Reporting

For each attempt write down: symptom (screenshot), change made, result. Say plainly when the evidence points to
a blocker you cannot fix.
