# Findings log

Worked case: a Windows 2000 Professional SP4 machine image (about 4.3 GB `.GHO`) that blue-screened and hung in
VirtualBox. Identifiers are removed; the causes and fixes are general.

## Result

The VM booted to the Windows 2000 desktop after three separate fixes. No registry edit was needed.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | VirtualBox Guru Meditation -225 at power-on, log: "VT-x is not available" then `WHvSetVirtualProcessorState -> ERROR_HV_INVALID_PARAMETER` | the Windows hypervisor was running (WSL2, Virtualization-Based Security) and VirtualBox 7.1.12 cannot run on top of it | `bcdedit /set hypervisorlaunchtype off`, reboot (restore with `auto`) |
| 2 | frozen on "Starting Windows..." with a progress bar, also in Safe Mode right after `Mup.sys` | the OS uses an ACPI **APIC** HAL; the VM had I/O APIC **off** | `VBoxManage modifyvm <vm> --ioapic on` |
| 3 | STOP `0x0000007B (0x82070950, 0xC0000032, 0, 0)` INACCESSIBLE_BOOT_DEVICE | the NTFS **dirty flag** was set (left by a host-side restore); Windows 2000 cannot replay the log of a volume a modern Windows touched, so the volume "could not mount" | `chkdsk X: /f` on a **copy** of the disk from a modern host, restore the VM snapshot, boot |

## Evidence that mattered

- Reading the SYSTEM hive without `reg load` (`scripts/hive_report.py`): service pack code `0x400` (SP4), `atapi` and
  `pciide` boot-start, `intelide` disabled, and a generic `pci#cc_0101 -> pciide` critical device entry already present,
  so the VM's IDE controller needed no edit. The original hardware (SiS chipset, a PROFIBUS card, a dongle driver) showed
  as "new hardware" in the VM, which is expected.
- Safe Mode lists each boot driver as it loads. `atapi.sys`, `disk.sys` and `Ntfs.sys` appearing ruled out a missing storage
  driver and moved the search to the HAL and the file system.
- The second STOP parameter separates causes: `0xC0000032` file system could not mount (dirty/corrupt), versus zeros or
  `0xC0000034` driver or device not found.
- `fsutil dirty query X:` returned "Volume is Dirty" while the partition table, NTFS boot sector (hidden sectors equal to the
  partition start, 255 heads x 63 sectors) and MFT were all normal. `chkdsk` found no problems and cleared the flag.

## Corrections to earlier assumptions

- PCI IDE devices map to `pciide` or `intelide`, **not** `atapi` (Microsoft KB 314082 `mergeide.reg`): `pci#cc_0101` ->
  `pciide`; Intel PIIX ids -> `intelide`; `primary_ide_channel`, `secondary_ide_channel`, `*pnp0600` -> `atapi`; the three
  services `Start=0`. An earlier recipe in this repo was wrong.
- A predicted 0x7B from "intelide disabled" was wrong in this case: the generic class entry already covered the controller.
  Predictions from the registry are hypotheses until the VM boots.
- Do not flag stock Windows tools such as `ntbackup.exe`, `ntdsutil.exe`, `ntsd.exe`, `ntvdm.exe` as custom kernels: only
  `/Kernel=` switches and `ntos*.exe`/`ntkr*.exe` files are suspicious.

## Tooling notes

- `reg load` failed with "The filename or extension is too long" on this host, even for a plain hive saved by `reg save` and
  on a short path on C:. `hive_report.py` avoids it by parsing the hive file directly.
- Files written by an old Windows keep that machine's ACLs and could not be read in a normal session even from an attached
  volume; `robocopy <dir> <dest> <file> /B` from an elevated shell copies them in backup mode.
- Early `F8` key injection (`VBoxManage controlvm <vm> keyboardputscancode 42 c2`) reaches the Windows 2000 Advanced Options
  menu; pressing keys after the menu appears boots normally.
- An earlier host-side restore had left a complete restored VHD and a half-built VM. Checking for it first would have saved
  hours: attach it read-only and analyse it.
- Ghost on the host wrote a crash dump in its folder; a host-side restore can crash or dirty the volume. A Windows VM running
  Ghost with the blank disk attached avoids this.
