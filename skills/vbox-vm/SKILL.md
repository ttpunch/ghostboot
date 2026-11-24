---
name: vbox-vm
description: Use to create, configure, snapshot and watch an Oracle VirtualBox VM around a restored Windows VHD: IDE controller, ACPI/APIC/PAE per OS and HAL, host hypervisor conflict, boot screenshots.
version: 0.2.0
license: MIT
metadata:
  hermes:
    tags: [virtualbox, vbox, vhd, vm, windows-2000, windows-xp, windows-7, hypervisor]
---

# vbox-vm

Run only after the VHD is detached from the host. `VBoxManage` is at
`C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`.

## Check the host first

VirtualBox needs VT-x. If the Windows hypervisor is running (`HypervisorPresent` True because of WSL2,
Docker Desktop, Hyper-V or Virtualization-Based Security) some VirtualBox builds crash at power-on with
Guru Meditation -225. See `bsod-triage` section 1 for the fix (`bcdedit /set hypervisorlaunchtype off`,
reboot). Confirm after the reboot: `VBox.log` should say `HMR3Init: VT-x w/ nested paging`.

## Settings by guest

| Guest | Controller | I/O APIC | PAE | ACPI |
|---|---|---|---|---|
| Windows 2000 / XP, ACPI **PIC** HAL | IDE `PIIX4` | **off** | off | on |
| Windows 2000 / XP, ACPI **APIC** HAL | IDE `PIIX4` | **on** | off | on |
| Windows 7 | IDE `PIIX4` (SATA only if drivers are present) | on | on | on |

The HAL decides the I/O APIC setting, not the Windows version. An APIC HAL with I/O APIC off hangs forever on
"Starting Windows..."; find the HAL with `scripts/hive_report.py` (Enum\Root) or just test both settings from a
clean snapshot. Use IDE, not SATA, for old guests. Other defaults that worked: 512 MB, 1 CPU, VRAM 16,
`--hpet off`, `--nic1 none`, `--audio-enabled off`, `--usb off`.

## Create

```powershell
$VBM = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$Vm  = "ghostboot-test"
$Vhd = "<full path to the restored COPY .vhd>"       # never boot the only copy

& $VBM createvm --name $Vm --ostype Windows2000 --basefolder "<folder>" --register
& $VBM modifyvm $Vm --memory 512 --vram 16 --cpus 1 --chipset piix3 --ioapic on --pae off --acpi on --hpet off `
    --boot1 disk --boot2 none --boot3 none --boot4 none --nic1 none --audio-enabled off --usb off --graphicscontroller vboxvga
& $VBM storagectl $Vm --name "IDE Controller" --add ide --controller PIIX4
& $VBM storageattach $Vm --storagectl "IDE Controller" --port 0 --device 0 --type hdd --medium $Vhd
& $VBM snapshot $Vm take "before-first-boot"
```

Use `--ostype WindowsXP` or `Windows7`/`Windows7_64` as needed; for a GPT disk add `--firmware efi64`.
`VBoxManage clonemedium disk <src> <dst> --format VHD` makes the copy without needing admin or the
hypervisor.

## Watch the boot

```powershell
.\scripts\Watch-VmBoot.ps1 -VmName $Vm -OutDir .\shots -Seconds 90 -RestoreSnapshot "before-first-boot"
.\scripts\Watch-VmBoot.ps1 -VmName $Vm -OutDir .\shots -SafeMode -Seconds 120    # lists drivers as they load
```

Look at the PNGs (screenshot bytes unchanged across intervals = frozen screen). Early `F8` key injection
(`controlvm keyboardputscancode 42 c2`) reaches the Windows 2000/XP Advanced Options menu; stop pressing once the
menu is up, or extra key presses boot normally.

## Snapshots

- A snapshot sits above the disk: restoring it resets all guest changes since. Restore between experiments.
- If you repair the base disk (for example chkdsk on the copy) while a snapshot exists, restore the snapshot
  afterwards so the new differencing disk starts clean over the repaired base; this worked in practice.
- Take a new snapshot of a working state (`booted-ok`) before changing anything inside the guest.

## Common problems

| Symptom | Cause | Fix |
|---|---|---|
| Guru Meditation -225 at power-on | Windows hypervisor conflict | `bsod-triage` section 1 |
| Frozen on "Starting Windows..." | I/O APIC off with an APIC HAL | `--ioapic on` |
| `VERR_VD_IMAGE_READ_ONLY` | VHD still attached to the host, or read-only flag | detach it; `attrib -R "<vhd>"` |
| `VERR_ALREADY_EXISTS` | target file exists | remove the old file first |
| `UUID already exists` on register | stale media registry entry | `VBoxManage closemedium disk <UUID>` |
| `Access to a CIM resource was not available` | not elevated | reopen as Administrator |
| Black screen | firmware mismatch (GPT versus BIOS) | match firmware to the disk's partition style |
| `screenshotpng` "aWidth is invalid" | the VM already crashed | read the log; power off |
| Mouse pointer vanishes or is stuck in the guest | no Guest Additions: PS/2 mouse is captured | `vbox-mouse` (Right Ctrl; optional USB tablet) |
| `modifyvm`/`startvm`: "already locked for a session" | a VM window (even "Soft Keyboard") still holds the VM | close every window of that VM, then retry (`vbox-mouse`) |

## Rules

- Snapshot before the first boot and before each fix. One change per attempt, written down with the result.
- Remove the VM's storage attachment (or power it off) before touching the VHD on the host again.
