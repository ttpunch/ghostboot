# ghostboot

Boot a Symantec Ghost `.GHO` machine backup in Oracle VirtualBox, and find out why it blue-screens.

This repo holds agent skills and PowerShell scripts. The Ghost restore itself builds on the
`ghost-image-mount` skill; this repo adds a preflight, analysis of the restored disk before first boot,
a VirtualBox recipe, and BSOD triage.

## Pipeline

1. Preflight (`scripts/Test-GhostbootPreflight.ps1`)
2. Create an expandable VHD on a separate drive and attach it (MBR, no partition)
3. Restore the `.GHO` onto it with Ghost (prefer Ghost inside a VM from boot media)
4. Detach, then re-attach and analyse (`scripts/Get-GhostDiskAnalysis.ps1`)
5. Apply only the fixes the analysis calls for
6. Detach, create the VM, snapshot, boot
7. Triage any stop code

## Skills

| Skill | Purpose |
|---|---|
| `skills/ghostboot` | orchestrator for the whole run |
| `skills/ghost-analyse` | analyse the restored Windows before booting |
| `skills/vbox-vm` | VirtualBox settings per guest OS |
| `skills/bsod-triage` | stop code to cause to fix |

## Scripts

| Script | Needs | Changes anything? |
|---|---|---|
| `Test-GhostbootPreflight.ps1` | Windows PowerShell 5.1 | no |
| `Get-GhostDiskAnalysis.ps1` | elevated PowerShell for `-CheckRegistry` | no (works on a copy of the hive) |

## Tests

```powershell
python -m unittest discover -s tests -v
```

## Safety

- Never modify the source `.GHO`. Never run raw-disk commands without confirming the disk number and size.
- Ghost on the host can blue-screen the host. Prefer Ghost in a VM.
- No binaries, images or machine data in this repo (see `.gitignore`). You supply `ghost32.exe`.
- Status: milestone 1-3 (skeleton, preflight, analysis, skills). VHD create/attach scripts and a VM
  builder script are not written yet; the skills document the commands. Nothing here has been run
  against a real `.GHO` yet.
