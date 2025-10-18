# Make VirtualBox Work on Debian When KVM Auto‑Starts

VirtualBox may fail to start VMs on Debian (and derivatives) with the error:

> VT‑x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE)

This happens because the Linux KVM hypervisor (kernel modules `kvm`, `kvm_intel` or `kvm_amd`) is automatically loaded at boot. Once KVM is loaded and in use (e.g., by libvirt/QEMU, Multipass, Docker Desktop’s VM, GNOME Boxes, etc.), it owns the CPU virtualization extensions (VT‑x/AMD‑V) and VirtualBox cannot use them.

This script disables KVM for the current session (and optionally at boot), then loads the required VirtualBox kernel modules so VirtualBox can run VMs.

The script is safe to run multiple times and provides an option to revert any persistent change.

## What the Script Does (and Why)

In order, the script:

1. Stops services that commonly use KVM so the kernel modules can be unloaded:
   - `libvirtd`, `virtqemud`, `virtxend`, `virtlxcd`
   - `multipassd`
   - `qemu-kvm`, `qemud`
   - `docker-desktop`
   It also terminates lingering QEMU/Multipass processes if needed. This is required because loaded/active modules cannot be removed while in use.

2. Unloads KVM kernel modules:
   - Attempts to remove `kvm_amd`, `kvm_intel`, and `kvm` (harmless if some are not present). This frees the VT‑x/AMD‑V extensions so VirtualBox can take control.

3. Loads VirtualBox kernel modules:
   - Loads `vboxdrv`, then `vboxnetflt`, `vboxnetadp`, and `vboxpci`. These are necessary for VirtualBox VMs and networking to work.
   - If `vboxdrv` fails to load, it provides hints (reinstall DKMS modules or address Secure Boot).

4. Ensures your user is in the `vboxusers` group:
   - Creates the group if it’s missing (e.g., VirtualBox packages were installed manually).
   - Adds the invoking user to `vboxusers` if missing. You’ll need to log out and back in once for group membership to apply.

5. Optionally prevents KVM from auto‑loading at boot:
   - With `--persist`, it writes `/etc/modprobe.d/blacklist-kvm.conf` to blacklist `kvm`, `kvm_intel`, and `kvm_amd`. This is only necessary if you want to use VirtualBox exclusively across reboots. You can undo with `--revert`.

Why this works: VirtualBox and KVM both require exclusive access to the CPU virtualization extensions. Unloading KVM (and keeping it from auto‑loading) ensures VirtualBox’s modules load first and can claim VT‑x/AMD‑V.

## Usage

Run the script as root (use `sudo`). In this repository the file is named `script.sh`:

```
sudo ./script.sh
```

This will stop KVM users, unload KVM, load VirtualBox modules, and check your `vboxusers` membership for the current session.

### Common options

- `--persist`: Persistently disable KVM by blacklisting its modules at boot.
  - Creates `/etc/modprobe.d/blacklist-kvm.conf`.
  - Requires a reboot to take effect.
  - Use only if you don’t need KVM/libvirt at all.

- `--revert`: Remove the KVM blacklist so KVM can load again on future boots.

- `--no-vbox`: Don’t load VirtualBox modules (only stop services and unload KVM).

- `--no-stop`: Don’t stop services; only attempt to unload modules. Use this only if you’re sure nothing is using KVM.

- `--quiet`: Minimal output.

- `-h`, `--help`: Show inline help.

### Examples

- One‑shot fix for current session:
  ```
  sudo ./script.sh
  ```

- Make it persistent (disable KVM at every boot):
  ```
  sudo ./script.sh --persist
  # Reboot afterwards
  ```

- Undo persistence (re‑enable KVM on future boots):
  ```
  sudo ./script.sh --revert
  ```

- Only unload KVM without touching VirtualBox modules:
  ```
  sudo ./script.sh --no-vbox
  ```

## Requirements

- Debian or a Debian‑based system with `systemd`.
- `sudo`/root privileges.
- VirtualBox installed (`virtualbox`, `virtualbox-dkms`).

If Secure Boot is enabled, the kernel may refuse to load unsigned DKMS modules. Either disable Secure Boot or sign/enroll the modules. The script will point this out if `vboxdrv` fails to load.

## Side Effects and Safety

- Any running libvirt/QEMU/Multipass VMs will be stopped. Save your work before running.
- `--persist` modifies `/etc/modprobe.d/blacklist-kvm.conf`. You can remove it with `--revert`.
- The script does not start KVM services again; after a reboot (and without the blacklist) KVM will auto‑load as usual.

## Troubleshooting

- “`vboxdrv` failed to load”:
  - Reinstall DKMS modules: `sudo apt install --reinstall virtualbox-dkms virtualbox`
  - Ensure kernel headers are installed for your running kernel.
  - Address Secure Boot (disable or sign modules).

- “KVM is still loaded” after running:
  - Check who is using it: `lsmod | grep '^kvm'`, `systemctl status libvirtd`, `pgrep -a qemu`
  - Stop/kill processes or re‑run without `--no-stop`.

- VirtualBox starts but networking is missing:
  - Ensure `vboxnetflt` and `vboxnetadp` are loaded: `lsmod | grep -E 'vboxnetflt|vboxnetadp'`.

## Why Not Use Both KVM and VirtualBox Together?

They can be installed together, but they cannot use VT‑x/AMD‑V concurrently. You must choose which hypervisor you want active at any one time. This script helps you switch to VirtualBox by temporarily (or persistently) disabling KVM.

---

If you prefer a different filename, you can rename `script.sh` to `fix-virtualbox-vtx.sh`; the script adjusts its help based on the invoked name.
