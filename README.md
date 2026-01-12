Got it 👍 — here is the **same README content as a plain document**, **no code block**, so you can **copy-paste directly** into a file or editor and save it as `README.md` (or any document format you want).

---

# grow-root.sh

## Automatic Root Disk Expansion Script for Ubuntu 24.04

grow-root.sh is a safe, automated Bash script that expands newly added virtual disk space into the Linux root filesystem (`/`) without requiring a reboot.

It is designed specifically for Ubuntu 24.04 and works out-of-the-box with:

* Default Ubuntu LVM-based installs
* Minimal / autoinstall server images
* VMware, Proxmox, Hyper-V, KVM, and other hypervisors

---

## What This Script Does

When a VM disk is expanded at the hypervisor level, Linux does not automatically grow partitions, LVM volumes, or filesystems.

This script fixes that by performing the full resize chain automatically:

Disk → Partition → LVM PV → LVM VG → LVM LV → Filesystem (/)

Specifically, it will:

1. Detect what device is mounted at `/`
2. Grow the partition backing `/` to fill the disk
3. Resize the LVM Physical Volume (if LVM is used)
4. Extend the Logical Volume to use all free space
5. Grow the filesystem (ext4 or XFS)
6. Perform all actions online (no reboot required)

---

## Supported Layouts

LVM Root (Default Ubuntu Install)
/dev/mapper/ubuntu--vg-ubuntu--lv → /

Non-LVM Root
/dev/sda2 → /
/dev/nvme0n1p2 → /

Supported filesystems:

* ext4
* xfs

---

## Not Supported (By Design)

* RAID (mdadm)
* Btrfs subvolumes
* LUKS without LVM
* ZFS

These layouts can be added later if needed.

---

## Dependencies

The script automatically installs required dependencies if missing:

* cloud-guest-utils (provides growpart)
* parted (provides partprobe)
* lvm2 (LVM management tools)

No reboot is required after installation.

---

## Usage

Make the script executable:
chmod +x grow-root.sh

Recommended: Dry-run mode (no changes, shows actions):
DRYRUN=1 sudo ./grow-root.sh

Run for real:
sudo ./grow-root.sh

---

## Common Problem This Solves

You expanded a VM disk from 25 GB to 100 GB, but Linux still reports:

df -h /
25G

This happens because:

* The disk grew ✔
* The partition did not ❌
* LVM never saw the new space ❌

Running this script resolves the issue completely.

---

## How It Works Internally

For LVM-backed roots, the script performs:

1. Detect root device using findmnt
2. Identify the Volume Group using lvs
3. Enumerate Physical Volumes using pvs
4. Grow the partition with growpart
5. Refresh kernel partition table with partprobe
6. Resize the Physical Volume using pvresize
7. Extend the Logical Volume with lvextend -l +100%FREE
8. Grow the filesystem using resize2fs or xfs_growfs

All steps are safe, idempotent, and can be re-run without harm.

---

## Safety Notes

* Online operation (no downtime)
* Safe for ext4 and XFS
* Does not shrink anything
* Only expands into available free space
* Designed for automation on servers

---

## Verification After Running

Use the following commands to verify success:

lsblk
pvs
vgs
lvs
df -h /

---

## Troubleshooting

If the script reports:
“missing command partprobe”

Install manually:
sudo apt install -y parted

If disk was expanded but nothing changed:
lsblk
sudo parted /dev/sda print free

---

## License

MIT License
Free to use, modify, and distribute.

---

## Author / Notes

Created to solve a very common Ubuntu VM issue where disk space is added but never reaches `/`.

Designed for reuse across multiple hosts and environments.

---

If you want next steps, I can:

* Turn this into a systemd one-shot service
* Add logging and JSON output
* Add command-line flags
* Package it as a .deb for fleet deployment

Just say the word 🚀
