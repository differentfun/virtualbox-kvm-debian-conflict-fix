#!/usr/bin/env bash
# fix-virtualbox-vtx.sh
# Unblocks VirtualBox from the error "VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE)"
# Options:
#   --persist  : blacklist KVM at boot (use if you want to run VirtualBox exclusively)
#   --revert   : remove the KVM blacklist
#   --no-vbox  : do not load VirtualBox modules (only unload KVM)
#   --no-stop  : do not stop services (use if you know they are already stopped)
#   --quiet    : minimal output

set -uo pipefail

QUIET=0
DO_PERSIST=0
DO_REVERT=0
LOAD_VBOX=1
STOP_SERVICES=1

log()  { [[ $QUIET -eq 0 ]] && echo -e "$*"; }
warn() { echo -e "\e[33m$*\e[0m" >&2; }
err()  { echo -e "\e[31m$*\e[0m" >&2; }

for arg in "$@"; do
  case "$arg" in
    --persist) DO_PERSIST=1 ;;
    --revert)  DO_REVERT=1 ;;
    --no-vbox) LOAD_VBOX=0 ;;
    --no-stop) STOP_SERVICES=0 ;;
    --quiet)   QUIET=1 ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [--persist|--revert] [--no-vbox] [--no-stop] [--quiet]
  --persist   Blacklist kvm/kvm_intel or kvm_amd to prevent loading at boot.
  --revert    Remove the previously created blacklist.
  --no-vbox   Do not attempt to load VirtualBox modules.
  --no-stop   Do not stop services using KVM (libvirtd, qemu, multipass, etc.).
  --quiet     Reduce output.
EOF
      exit 0
      ;;
    *)
      err "Unknown argument: $arg"; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "Please run as root (use sudo)."; exit 1
fi

# CPU detection
CPU_VENDOR="$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2}')"
IS_INTEL=0; IS_AMD=0
[[ "$CPU_VENDOR" == "GenuineIntel" ]] && IS_INTEL=1
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && IS_AMD=1

# Services to stop if present
SERVICES=(
  libvirtd virtqemud virtxend virtlxcd
  multipassd
  qemu-kvm qemud
  docker-desktop
)
# Processes that may keep KVM busy
PROCS=( qemu-system-x86_64 qemu-kvm qemu-system-aarch64 virtqemud virtlxcd multipass )

stop_services() {
  if [[ $STOP_SERVICES -eq 0 ]]; then
    log "➤ Skipping service stop (--no-stop)."
    return
  fi
  log "➤ Stopping services that may use KVM (ignore 'Unit not found' if shown)…"
  for s in "${SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
  done
  # Terminate any lingering processes
  for p in "${PROCS[@]}"; do
    if pgrep -x "$p" >/dev/null 2>&1; then
      warn "   Found process $p — attempting to terminate…"
      pkill -15 -x "$p" 2>/dev/null || true
      sleep 1
      pgrep -x "$p" >/dev/null 2>&1 && pkill -9 -x "$p" 2>/dev/null || true
    fi
  done
}

unload_kvm() {
  log "➤ Unloading KVM modules…"
  # Try AMD and Intel regardless; missing ones will fail harmlessly.
  modprobe -r kvm_amd 2>/dev/null || true
  modprobe -r kvm_intel 2>/dev/null || true
  modprobe -r kvm 2>/dev/null || true

  if lsmod | grep -q '^kvm'; then
    warn "   Warning: KVM modules are still loaded. A process may be holding them."
    lsmod | awk '/^kvm/ {print "   • " $1 " (" $3 " deps)"}'
  else
    log "   KVM successfully unloaded."
  fi
}

load_virtualbox_modules() {
  if [[ $LOAD_VBOX -eq 0 ]]; then
    log "➤ Skipping VirtualBox module load (--no-vbox)."
    return
  fi
  log "➤ Loading VirtualBox modules (vboxdrv, vboxnetflt, vboxnetadp, vboxpci)…"
  if ! modprobe vboxdrv 2>/dev/null; then
    err "   Failed to load vboxdrv."
    warn "   Possible causes: DKMS modules not built or Secure Boot blocking unsigned modules."
    warn "   Suggestions:"
    warn "     • Reinstall modules: apt install --reinstall virtualbox-dkms virtualbox"
    warn "     • If Secure Boot is enabled: disable it or sign the DKMS modules."
  else
    modprobe vboxnetflt 2>/dev/null || true
    modprobe vboxnetadp 2>/dev/null || true
    modprobe vboxpci 2>/dev/null || true
    log "   VirtualBox modules loaded."
  fi
}

persist_blacklist() {
  local file="/etc/modprobe.d/blacklist-kvm.conf"
  log "➤ Configuring KVM blacklist in $file …"
  cat > "$file" <<EOF
# Created by fix-virtualbox-vtx.sh — prevents KVM from loading at boot
blacklist kvm
blacklist kvm_intel
blacklist kvm_amd
EOF
  log "   Blacklist written. Reboot to make it effective."
}

revert_blacklist() {
  local file="/etc/modprobe.d/blacklist-kvm.conf"
  if [[ -f "$file" ]]; then
    log "➤ Removing $file …"
    rm -f "$file"
    log "   Done. Reboot to allow KVM to load again at boot."
  else
    warn "➤ No KVM blacklist found to remove ($file does not exist)."
  fi
}

ensure_vboxusers() {
  if getent group vboxusers >/dev/null; then
    if id -nG "${SUDO_USER:-$USER}" | tr ' ' '\n' | grep -qx "vboxusers"; then
      log "➤ User ${SUDO_USER:-$USER} is already in the vboxusers group."
    else
      log "➤ Adding ${SUDO_USER:-$USER} to the vboxusers group…"
      usermod -aG vboxusers "${SUDO_USER:-$USER}"
      warn "   Log out/in for the vboxusers membership to apply."
    fi
  else
    warn "➤ The vboxusers group does not exist. VirtualBox may not be installed."
  fi
}

summary() {
  echo
  log "✅ Operation completed."
  if [[ $DO_PERSIST -eq 1 ]]; then
    warn "   You enabled the KVM blacklist. To re-enable KVM in the future run:"
    warn "     sudo $0 --revert"
  fi
  log "   Now try starting VirtualBox and your VM."
  log "   (The Qt/TGA warnings you saw are harmless.)"
}

# Main flow
if [[ $DO_REVERT -eq 1 ]]; then
  revert_blacklist
fi

stop_services
unload_kvm
load_virtualbox_modules
ensure_vboxusers

if [[ $DO_PERSIST -eq 1 ]]; then
  persist_blacklist
fi

summary
