---
name: ghostboot
description: Use to take a Symantec Ghost .GHO machine backup and get it booting in Oracle VirtualBox: reuse or make a restore on a separate drive, analyse the restored Windows before first boot, build the VM, and triage hangs and BSODs.
version: 0.2.0
license: MIT
metadata:
  hermes:
    tags: [ghost, gho, virtualbox, vhd, p2v, bsod, windows, restore]
---

# ghostboot

Orchestrates the whole run. It **builds on the `ghost-image-mount` skill** for the Ghost restore and mount
mechanics (Paths B and C there) and adds what that skill lacks: a preflight, analysis of the restored disk before
first boot, a VirtualBox recipe, and BSOD triage. Do not rewrite the restore steps here; load `ghost-image-mount`.

Companion skills in this repo: `ghost-analyse`, `vbox-vm`, `bsod-triage`. A worked case is in `docs/FINDINGS.md`.

## Step 0 - ask for the two paths first (required)

Before running anything, reading files or planning disk work, ask the user for exactly these two paths. Do not
guess them, do not search the machine for them, and do not fall back to defaults. If the user gave only one, ask for
the other. Do not continue until you have both.

1. **Ghost image path:** the full path to the `.GHO` file. Its `.GHS` / `.001` spans must sit in the same folder.
   Example: `D:\Backups\machine.GHO`
2. **VHD drive or folder path:** the drive (portable or PC drive) and folder where the virtual disk and VM will live.
   Example: `E:\GhostVhd\`

Then echo both back, run `scripts/Test-GhostbootPreflight.ps1` with them, and wait for the user to confirm before any
disk is created or written. If the drive is portable, remind them USB is slow and the VHD must be on NTFS or exFAT.

## Rules

- A `.GHO` is not a raw disk image. `qemu-img`, `VBoxManage convertfromraw` and `Mount-DiskImage` cannot read it.
- Never modify, move or delete the source `.GHO` or its spans, or the only restored disk. Work on a **copy**
  (`VBoxManage clonemedium disk <src> <dst> --format VHD`).
- Verify the target disk number and size immediately before any raw-disk write. Disk numbers change between
  sessions, and Ghost's own numbering differs from `Get-Disk`.
- Ghost on the host writes raw sectors through the Windows storage stack and has crashed hosts mid-restore, and a
  host-side restore can leave the NTFS volume dirty. Prefer Ghost **inside a Windows VM** with the blank disk
  attached as a second disk. Use host-side Ghost only as a fallback, and stop after the first host reboot.
- Always detach a VHD from the host when finished. Attach read-only (`attach vdisk readonly`) whenever you only read.
- Snapshot the VM before the first boot and before each fix attempt.
- Never handle or guess passwords. Do not commit binaries (Ghost, ISOs, images, hives).
- System-level changes (`bcdedit`, disabling the hypervisor, registry edits on a live host) need the user's explicit OK,
  and you never reboot their PC.
- An agent without admin rights uses `scripts/Invoke-ElevatedLogged.ps1`: the person clicks Yes on one UAC prompt per
  elevated step, and the script's output comes back as a log.

## Phases

1. **Inputs.** The two paths from Step 0 must be in hand. Then ask: machine type and Windows version if known, original
   disk size, and the BSOD stop code or a screenshot if the user saw one.
2. **Preflight.** `scripts/Test-GhostbootPreflight.ps1 -SourceGho <gho> -VhdFolder <folder> -GhostPath <ghost32.exe>`.
   Fix every failed check (elevation, free space, filesystem, stale virtual disks, VirtualBox).
3. **Look for an existing restore first.** Earlier attempts often left a restored VHD/VDI and a half-built VM. Attach it
   read-only and analyse it (`ghost-analyse` section 0). A complete restore saves hours.
4. **Pre-analysis without restoring (optional).** Ghost Explorer (`ghostexp.exe`) opens the `.GHO` like an archive,
   read-only. Extract `boot.ini`, `WINNT\system32\config\system` (or `Windows\...`) and `ntoskrnl.exe` into a folder, then
   run `python scripts/hive_report.py <system hive>` and read `boot.ini`: Windows version, HAL, drivers, kernel switch.
5. **Restore (only if needed).** Create an expandable VHD, attach it, initialize **MBR**, no partition; Ghost restores
   onto it (`ghost-image-mount` Path B). Prefer Ghost in a Windows VM. Detach afterwards.
6. **Copy and analyse.** Clone the restored disk to a working copy. Attach the copy, run `ghost-analyse`
   (`Get-GhostDiskAnalysis.ps1 -CheckDirty`, `hive_report.py`). Read the findings.
7. **Fix, in the order the evidence gives:** host hypervisor (`bsod-triage` 1) -> I/O APIC versus HAL (2) -> dirty NTFS
   (3a) -> IDE entries only if the hive lacks them (3b). One change per attempt.
8. **VM.** Create it per `vbox-vm` on the copy, snapshot, boot with `scripts/Watch-VmBoot.ps1`, read the screenshots.
9. **Triage.** If it fails, record the stop code (all four parameters) and use `bsod-triage`.

## Output to the user

Report: what was checked, what was found (evidence), what was changed, and what was not verified. Say plainly when an
image is probably not bootable in a VM (for example a replaced OEM kernel) instead of trying fixes forever.
