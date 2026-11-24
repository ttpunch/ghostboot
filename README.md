# ghostboot

Boot a Symantec Ghost `.GHO` machine backup in Oracle VirtualBox, and find out why it hangs or blue-screens.

This repo holds agent skills and PowerShell/Python scripts. The Ghost restore itself builds on the
`ghost-image-mount` skill; this repo adds a preflight, analysis of the restored disk before first boot, a VirtualBox
recipe, and evidence-based BSOD triage. A worked case is in [docs/FINDINGS.md](docs/FINDINGS.md).

## Pipeline

1. Ask for the two paths (the `.GHO` and the VHD drive/folder) and run the preflight
2. Look for an existing restore first; otherwise create an expandable VHD on a separate drive (MBR, no partition)
3. Restore the `.GHO` with Ghost (prefer Ghost inside a Windows VM; host-side Ghost can crash the host or leave NTFS dirty)
4. Detach, make a working **copy**, attach it and analyse it (hive, dirty flag, boot files, HAL)
5. Fix in the order the evidence gives, one change per attempt
6. Create the VM on the copy, snapshot, boot and watch the screen
7. Triage any stop code by its parameters

## Skills

| Skill | Purpose |
|---|---|
| `skills/ghostboot` | orchestrator for the whole run |
| `skills/ghost-analyse` | analyse the restored Windows before booting |
| `skills/vbox-vm` | VirtualBox settings per guest, host hypervisor conflict, boot screenshots |
| `skills/bsod-triage` | symptom to cause to fix: hypervisor, APIC/HAL, dirty NTFS, IDE entries, BCD, EFI, OEM kernel |

## Scripts

| Script | Needs | Changes anything? |
|---|---|---|
| `Test-GhostbootPreflight.ps1` | Windows PowerShell 5.1 | no |
| `Get-GhostDiskAnalysis.ps1` | elevated for `-CheckDirty` and `-CheckRegistry` | no (registry check works on a copy of the hive) |
| `hive_report.py` | Python 3.9+, no elevation | no (reads a copied SYSTEM hive; no `reg load`) |
| `Invoke-ElevatedLogged.ps1` | a person to click Yes on one UAC prompt | runs the script you give it as administrator |
| `Watch-VmBoot.ps1` | VirtualBox | starts the VM and saves screenshots; can restore a snapshot first |

## Tests

```powershell
python -m unittest discover -s tests -v
```

## Safety

- Never modify the source `.GHO` or the only restored disk. Work on a copy and attach read-only when you only read.
- Ghost on the host can crash the host or leave the volume dirty. Prefer Ghost in a VM.
- System-level changes (`bcdedit`, hypervisor, registry on a live host) need the user's explicit OK; never reboot their PC.
- No binaries, images or machine data in this repo (see `.gitignore`). You supply `ghost32.exe`.
- Status: tested end to end on one Windows 2000 image (see FINDINGS). The VHD create/attach scripts and a VM builder script
  are not written; the skills document the commands.
