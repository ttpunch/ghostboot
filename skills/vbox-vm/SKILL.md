---
name: vbox-vm
description: Use to create and configure an Oracle VirtualBox VM around a restored Windows VHD (IDE controller, ACPI/APIC/PAE per OS), snapshot it, and clear stale media registry entries.
version: 0.1.0
license: MIT
metadata:
  hermes:
    tags: [virtualbox, vbox, vhd, vm, windows-xp, windows-7]
---

# vbox-vm

Run only after the VHD is detached from the host. `VBoxManage` lives at
`C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`.

## Settings by guest

| Guest | Controller | Firmware | I/O APIC | PAE | ACPI |
|---|---|---|---|---|---|
| Windows 2000 / XP (5.0, 5.1) | IDE `PIIX4` | BIOS | off | off | on |
| Windows 7 32-bit | IDE `PIIX4` (SATA only if drivers are present) | BIOS | on | on | on |
| Windows 7 64-bit | IDE `PIIX4` | BIOS (EFI only if the disk is GPT) | on | on | on |

IDE avoids the AHCI driver problem. A 64-bit guest needs VT-x/AMD-V enabled in the host BIOS.

## Create

```powershell
$VBM = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$Vm  = "ghostboot-test"
$Vhd = "<full path to restored .vhd>"

& $VBM createvm --name $Vm --ostype WindowsXP --register      # use Windows7 or Windows7_64 as needed
& $VBM modifyvm $Vm --memory 2048 --cpus 2 --ioapic off --pae off --acpi on --boot1 disk --boot2 none --boot3 none
& $VBM storagectl $Vm --name IDE --add ide --controller PIIX4
& $VBM storageattach $Vm --storagectl IDE --port 0 --device 0 --type hdd --medium $Vhd
& $VBM snapshot $Vm take "before-first-boot"
& $VBM startvm $Vm
```

Adjust `--ostype`, `--ioapic`, `--pae` from the table. For a GPT disk add `--firmware efi64`.

## Common problems

| Symptom | Cause | Fix |
|---|---|---|
| `VERR_VD_IMAGE_READ_ONLY` | VHD still attached to the host, or read-only flag | detach it; `attrib -R "<vhd>"` |
| `VERR_ALREADY_EXISTS` | target file exists | remove the old file first |
| `Cannot register the hard disk ... UUID already exists` | stale media registry entry | `VBoxManage closemedium disk <UUID>` |
| `Access to a CIM resource was not available` | PowerShell not elevated | reopen as Administrator |
| Boots to black screen | firmware mismatch (GPT versus BIOS) | match firmware to the disk's partition style |

## Rules

- Snapshot before the first boot and before each fix. Roll back instead of stacking fixes.
- One change per attempt, written down with the resulting stop code.
- Remove the VM's storage attachment before touching the VHD on the host again.
