---
name: vbox-mouse
description: Use when the mouse pointer disappears or gets stuck in a VirtualBox guest that has no Guest Additions (Windows 2000/XP restored from a Ghost image): why it happens, the quick workaround, and the PS/2 versus USB tablet choice.
version: 0.1.0
license: MIT
metadata:
  hermes:
    tags: [virtualbox, mouse, pointer, usb-tablet, ps2, guest-additions, windows-2000]
---

# vbox-mouse

## Symptom and cause

The pointer vanishes, or you cannot get the host pointer back, while working inside an old guest. A restored
Windows 2000/XP guest has **no Guest Additions** (`VBoxManage showvminfo <vm>` says `Additions run level: 0`), so
there is no mouse integration. With the default **PS/2 mouse** the guest only gets relative movement: clicking in the
VM window *captures* the mouse, VirtualBox hides the host pointer, and you steer a pointer that exists only in the
guest. Over dialogs and some programs that guest pointer can look invisible.

Check: `VBoxManage showvminfo <vm> | Select-String 'Pointing Device|USB'`.

## Quick workaround (no restart)

- Press the host key (**Right Ctrl** by default) to release the mouse to Windows; click inside the VM to capture again.
- Move the mouse a little or click once if the guest pointer seems hidden after capture.

## Is a PS/2 mouse required?

No. The PS/2 mouse is the default and needs nothing from the guest: a Windows 2000 hive already has `i8042prt` as a
system-start driver, and the guest booted and worked with it. It is also the safe fallback. The cost is the capture
behaviour above. The USB tablet is optional.

| Pointing device | Needs | Result | Status |
|---|---|---|---|
| `ps2` (default) | nothing | works, but captures the mouse | verified: guest booted and the mouse worked |
| `usbtablet` | `--usb-ohci on` plus the guest's built-in USB HID driver | absolute pointer, no capture, host pointer moves freely | **not yet tested** on a restored Windows 2000 image |
| Guest Additions | an Additions build that supports the guest OS | full integration | not verified for Windows 2000 on VirtualBox 7.1; do not assume |

The keyboard stays PS/2 either way. I have not verified whether VirtualBox keeps the PS/2 mouse present when the USB
tablet is selected; if the tablet misbehaves, switch back to `ps2`.

## Switch to the USB tablet

The VM must be powered off **and unlocked** (see below). Take a snapshot first so you can go back.

```powershell
$VBM = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $VBM snapshot "<vm>" take "before-usb-tablet"
& $VBM modifyvm "<vm>" --usb-ohci on --mouse usbtablet
& $VBM startvm "<vm>" --type gui
```

Windows 2000 shows one more "Found New Hardware" prompt for the USB controller and the tablet. Let it install from the
driver cache; if it asks for files, cancel and revert. Revert: `--mouse ps2` (and `--usb-ohci off` if you want).

## "The machine is already locked for a session"

`modifyvm` and `startvm` fail with `VBOX_E_INVALID_OBJECT_STATE` while any process still holds the VM, even when the
machine shows "Powered Off". Typical holders: the VM window, or a leftover window such as `<vm> - Soft Keyboard`
(visible as a `VirtualBoxVM` process whose title names the VM). Close every window of that VM, then retry; retrying
in a loop does not help. Ending the process is a last resort and needs the user's OK.

## Rules

- Snapshot before changing the pointing device or USB; one change per attempt.
- Do not install anything in the guest without asking.
- Say what was verified: PS/2 worked; the tablet is a suggestion until it has been booted and used.
