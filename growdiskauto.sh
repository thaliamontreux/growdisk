#!/usr/bin/env bash
# grow-root.sh
# Auto-expand the VM disk space into the partition backing /, then into LVM (if used),
# and finally grow the filesystem mounted at /.
#
# Works well for Ubuntu 24.04 default LVM installs like:
#   /dev/mapper/ubuntu--vg-ubuntu--lv -> PV /dev/sda3 (or nvme0n1p3, vda3, etc.)
#
# Usage:
#   sudo bash grow-root.sh
# Optional:
#   DRYRUN=1 sudo bash grow-root.sh   # show what it would do
set -euo pipefail

DRYRUN="${DRYRUN:-0}"

log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*" >&2; }
die()  { echo -e "[X] $*" >&2; exit 1; }

run() {
  if [[ "$DRYRUN" == "1" ]]; then
    echo "[DRYRUN] $*"
  else
    eval "$@"
  fi
}

require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."; }

ensure_cmds() {
  # growpart lives in cloud-guest-utils
  if ! command -v growpart >/dev/null 2>&1; then
    log "Installing dependency: cloud-guest-utils (provides growpart)..."
    run "apt-get update -y"
    run "apt-get install -y cloud-guest-utils"
  fi

  local cmds=(findmnt lsblk awk grep sed partprobe udevadm)
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
  done
}

root_source() { findmnt -n -o SOURCE /; }
root_fstype() { findmnt -n -o FSTYPE /; }

is_lvm_dev() {
  local dev="$1"
  [[ "$dev" == /dev/mapper/* || "$dev" == /dev/dm-* ]]
}

grow_partition() {
  local partdev="$1"  # e.g. /dev/sda3, /dev/nvme0n1p3
  [[ -b "$partdev" ]] || die "Not a block device: $partdev"

  local ptype parent partnum
  ptype="$(lsblk -no TYPE "$partdev" 2>/dev/null || true)"
  [[ "$ptype" == "part" ]] || die "Expected a partition device, got TYPE=$ptype for $partdev"

  parent="$(lsblk -no PKNAME "$partdev" 2>/dev/null || true)"
  [[ -n "$parent" ]] || die "Could not determine parent disk for $partdev"
  parent="/dev/$parent"

  partnum="$(lsblk -no PARTN "$partdev" 2>/dev/null || true)"
  [[ -n "$partnum" ]] || die "Could not determine partition number for $partdev"

  log "Growing partition to fill disk: growpart $parent $partnum  (partition: $partdev)"
  # growpart may exit non-zero if no change; treat as non-fatal
  set +e
  if [[ "$DRYRUN" == "1" ]]; then
    echo "[DRYRUN] growpart $parent $partnum"
    rc=0
  else
    growpart "$parent" "$partnum"
    rc=$?
  fi
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "growpart returned $rc (often OK if already max size)."
  fi

  log "Refreshing kernel partition table..."
  run "partprobe $parent || true"
  run "udevadm settle || true"
}

grow_fs_non_lvm() {
  local src="$1"
  local fs="$2"

  case "$fs" in
    ext4|ext3|ext2)
      log "Growing ext filesystem on / ($src)..."
      run "resize2fs $src"
      ;;
    xfs)
      log "Growing XFS filesystem on / ..."
      run "xfs_growfs /"
      ;;
    *)
      die "Unsupported filesystem type for auto-grow: $fs"
      ;;
  esac
}

main() {
  require_root
  ensure_cmds

  local src fs
  src="$(root_source)"
  fs="$(root_fstype)"

  log "Root mount source: $src"
  log "Root filesystem type: $fs"

  # --- LVM-backed root ---
  if is_lvm_dev "$src"; then
    command -v lvs >/dev/null 2>&1 || die "LVM tools not found (lvs). Install lvm2."
    command -v pvs >/dev/null 2>&1 || die "LVM tools not found (pvs). Install lvm2."
    command -v vgs >/dev/null 2>&1 || die "LVM tools not found (vgs). Install lvm2."
    command -v pvresize >/dev/null 2>&1 || die "LVM tools not found (pvresize). Install lvm2."
    command -v lvextend >/dev/null 2>&1 || die "LVM tools not found (lvextend). Install lvm2."

    local vg
    vg="$(lvs --noheadings -o vg_name "$src" 2>/dev/null | awk '{$1=$1;print}')"
    [[ -n "$vg" ]] || die "Could not determine VG for root LV ($src)"
    log "Detected VG: $vg"

    local pvlist
    pvlist="$(pvs --noheadings -o pv_name --select "vg_name=$vg" 2>/dev/null | awk '{$1=$1;print}')"
    [[ -n "$pvlist" ]] || die "No PVs found for VG $vg"

    log "PVs backing root VG:"
    echo "$pvlist" | sed 's/^/[+]   - /'

    # Grow partitions underneath PVs (if PV is a partition)
    while IFS= read -r pv; do
      [[ -n "$pv" ]] || continue
      [[ -b "$pv" ]] || die "PV device not found: $pv"

      local ptype
      ptype="$(lsblk -no TYPE "$pv" 2>/dev/null || true)"

      if [[ "$ptype" == "part" ]]; then
        grow_partition "$pv"
      else
        log "PV $pv is TYPE=$ptype (not a partition) — skipping growpart."
      fi

      log "Resizing PV to pick up any new space: pvresize $pv"
      run "pvresize $pv"
    done <<< "$pvlist"

    log "VG free space after pvresize (informational):"
    if [[ "$DRYRUN" == "1" ]]; then
      echo "[DRYRUN] vgs -o vg_name,vg_size,vg_free $vg"
    else
      vgs -o vg_name,vg_size,vg_free "$vg" || true
    fi

    log "Extending root LV to use all free space + grow filesystem: lvextend -l +100%FREE -r $src"
    run "lvextend -l +100%FREE -r $src"

    log "Done. Current / size:"
    run "df -hT /"
    exit 0
  fi

  # --- Non-LVM root on a partition device (/dev/sda2, /dev/nvme0n1p2, etc.) ---
  local srctype
  srctype="$(lsblk -no TYPE "$src" 2>/dev/null || true)"
  if [[ "$src" == /dev/* && "$srctype" == "part" ]]; then
    log "Detected non-LVM root on partition: $src"
    grow_partition "$src"
    grow_fs_non_lvm "$src" "$fs"
    log "Done. Current / size:"
    run "df -hT /"
    exit 0
  fi

  die "Unsupported root layout detected: source=$src type=$srctype
If you paste:  findmnt -no SOURCE,FSTYPE /  and  lsblk -f  I can adapt the script."
}

main "$@"
