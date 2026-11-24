---
name: ghostboot
description: Use to take a Symantec Ghost .GHO machine backup and get it booting in Oracle VirtualBox: prepare a VHD on a separate drive, restore, analyse the restored Windows before first boot, build the VM, and triage BSODs.
version: 0.1.0
license: MIT
metadata:
  hermes:
    tags: [ghost, gho, virtualbox, vhd, p2v, bsod, windows, restore]
---

# ghostboot

Orchestrates the whole run. It **builds on the `ghost-image-mount` skill** for the Ghost restore
and mount mechanics (Paths B and C there) and adds what that skill lacks: a preflight, an analysis of
the restored disk before first boot, a VirtualBox VM recipe, and BSOD triage. Do not rewrite the
restore steps here; load `ghost-image-mount` for them.

Companion skills in this repo: `ghost-analyse`, `vbox-vm`, `bsod-triage`.

## Step 0 - ask for the two paths first (required)

Before running anything, read files, or planning disk work, ask the user for exactly these two
paths. Do not guess them, do not search the machine for them, and do not fall back to defaults.
If the user gave only one, ask for the other. Do not continue until you have both.

1. **Ghost image path:** the full path to the `.GHO` file. Its `.GHS` / `.001` spans must sit in the same
   folder. Example: `D:\Backups\machine.GHO`
2. **VHD drive or folder path:** the drive (portable or PC drive) and folder where the virtual disk will be
   created. Example: `E:\GhostVhd\`

Then echo both back, run `scripts/Test-GhostbootPreflight.ps1` with them, and wait for the user to
confirm before any disk is created or written. Also note the user's reply when they say the drive is
portable: USB drives are slow, and the VHD must be on NTFS or exFAT (not FAT32).

## Rules

- A `.GHO` is not a raw disk image. `qemu-img`, `VBoxManage convertfromraw` and `Mount-DiskImage` cannot
  read it. Only Ghost's own tools can.
- Never modify, move or delete the source `.GHO` or its spans. It may be the only copy.
- Confirm the **source path** and the **destination path** with the user before any step. Do not guess either.
- Verify the target disk number and size immediately before any raw-disk write. Disk numbers change
  between sessions, and Ghost's own numbering differs from `Get-Disk`.
- Ghost on the host writes raw sectors through the Windows storage stack and has blue-screened hosts
  mid-restore. Prefer running Ghost **inside a VM from boot media** with the blank disk attached. Use host-side
  Ghost only as a fallback, and stop after the first host reboot.
- Always detach a VHD from the host when finished. A leftover attached VHD causes most later failures.
- Snapshot the VM before the first boot and before each fix attempt.
- Never handle or guess passwords. Do not commit binaries (Ghost, ISOs, images, hives).
- Offline registry work happens on a copy of the hive, or on a VHD you have a snapshot or backup of.

## Phases

1. **Inputs.** The two paths from Step 0 must already be in hand. Then also ask for: the machine type and
   Windows version if known, the original disk size, and the BSOD stop code and screenshot if the user saw one.
2. **Preflight.** Run `scripts/Test-GhostbootPreflight.ps1 -SourceGho <gho> -VhdFolder <folder> -GhostPath <ghost32.exe>`.
   Fix every failed check before continuing (elevation, free space, filesystem, stale virtual disks, VirtualBox).
3. **VHD.** Create an expandable VHD on the separate drive, sized from the original disk (100-150 GB if unknown),
   attach it, initialize it **MBR**, and do not create a partition. Details: `ghost-image-mount` Path B1.
4. **Restore.** Ghost restores the image onto the virtual disk. Prefer Ghost in a VM from boot media (see Rules).
   Details: `ghost-image-mount` Path B2. Never choose "Reset Computer" on the host.
5. **Mount and analyse.** Attach the VHD, find the Windows volume, and run
   `scripts/Get-GhostDiskAnalysis.ps1 -Root <letter>:\ -CheckRegistry -OutFile report.json`. Read the findings with
   the `ghost-analyse` skill. This is the step that predicts the BSOD.
6. **Fix.** Apply only the fixes the findings call for, from `bsod-triage`. Take a backup or snapshot first.
7. **Detach.** Detach the VHD from the host.
8. **VM.** Create and configure the VM per `vbox-vm`, attach the VHD, snapshot, boot.
9. **Triage.** If it fails, record the stop code and use `bsod-triage`. Change one thing at a time and log it.

## Output to the user

Always report: what was checked, what was found (evidence), what was changed, and what was not
verified. Say plainly when an image is probably not bootable in a VM (for example a replaced OEM
kernel) instead of trying fixes forever.
