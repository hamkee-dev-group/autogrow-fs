# auto-grow — Automated Filesystem Growth for Linux Block Devices

A bash script that safely automates the complete workflow for growing filesystems after VM disk expansion. Handles the entire stack from disk rescan through partition expansion, encryption layer resize, volume manager operations, and filesystem growth.

Developed by [Hamkee](https://hamkee.net/) — Unix infrastructure specialists with over 25 years of experience in systems optimization.

## Problem Statement

When you expand a virtual disk in your hypervisor or cloud provider console, the guest OS doesn't automatically consume the new space. You're left with a multi-step manual process:

1. Rescan the SCSI/NVMe bus to detect new disk size
2. Expand the partition table to use available space
3. Resize LUKS encryption mapping (if dm-crypt is in use)
4. Resize LVM physical volume, then extend logical volume (if LVM is in use)
5. Grow the filesystem itself

`auto-grow.sh` automates this entire sequence with safety guardrails for production systems.

## Architecture

Our script resolves the block device stack from mountpoint to physical disk:

```
Mountpoint (/) → Block device (/dev/mapper/vg-lv or /dev/sda2)
                      ↓
             Filesystem (ext4/XFS/Btrfs)
                      ↓
             LVM Logical Volume (optional)
                      ↓
             LUKS/dm-crypt mapping (optional)
                      ↓
             Partition (/dev/sda2, /dev/nvme0n1p2)
                      ↓
             Physical/Virtual Disk (/dev/sda, /dev/nvme0n1)
```

Uses `lsblk`, `findmnt`, and sysfs to walk this hierarchy, then applies operations in the correct order from disk up to filesystem.

## Supported Configurations

### Filesystems
- **ext4/ext3**: Online grow via `resize2fs`
- **XFS**: Online grow via `xfs_growfs` (mount point required)
- **Btrfs**: Online grow via `btrfs filesystem resize`

### Volume Layers
- Plain partition directly formatted
- LUKS/dm-crypt encrypted partition
- LVM (physical volume → volume group → logical volume)
- LVM on LUKS (PV on top of dm-crypt device)

### Partition Tables
- **GPT**: Full support via `sgdisk` (gdisk package)
- **MBR/DOS**: Requires `growpart` (cloud-utils-growpart package)

### Device Types
- SCSI/SATA disks (`/dev/sda`, `/dev/sdb`, etc.)
- NVMe devices (`/dev/nvme0n1`, `/dev/nvme1n1`, etc.) with `p` suffix partitions
- Virtio block devices (`/dev/vda`, `/dev/vdb`, etc.)

## Installation

### Dependencies

Install required utilities for your distribution:

**RHEL/Rocky/Alma Linux**:
```bash
sudo dnf install -y cloud-utils-growpart gdisk util-linux e2fsprogs xfsprogs lvm2 cryptsetup btrfs-progs
```

**Debian/Ubuntu**:
```bash
sudo apt install -y cloud-guest-utils gdisk util-linux e2fsprogs xfsprogs lvm2 cryptsetup-bin btrfs-progs
```

**SUSE/OpenSUSE**:
```bash
sudo zypper install -y growpart gdisk util-linux e2fsprogs xfsprogs lvm2 cryptsetup btrfsprogs
```

### Script Deployment

```bash
# Download the script
curl -O https://raw.githubusercontent.com/hamkee-dev-group/autogrowfs/main/auto-grow.sh
chmod +x auto-grow.sh

# Or clone the repository
git clone https://github.com/hamkee-dev-group/autogrowfs.git
cd autogrowfs
```

## Usage

### Basic Operations

**Grow root filesystem** (default behavior):
```bash
sudo ./auto-grow.sh
```

**Grow specific mountpoint**:
```bash
sudo ./auto-grow.sh --mount /data
sudo ./auto-grow.sh --mount /var/lib/postgresql
```

**Target specific block device** (useful when automatic detection fails):
```bash
sudo ./auto-grow.sh --target /dev/sdb2
sudo ./auto-grow.sh --target /dev/nvme0n1p2
```

### Safety and Testing

**Dry-run simulation** (shows execution plan without making changes):
```bash
sudo ./auto-grow.sh --dry-run
sudo ./auto-grow.sh --mount /data --dry-run --verbose
```

**Non-interactive mode** (for automation/scripts):
```bash
sudo ./auto-grow.sh --yes
sudo ./auto-grow.sh --mount /data --yes
```

### Advanced Options

**Force specific partition resize tool**:
```bash
# Use growpart (MBR and GPT compatible)
sudo ./auto-grow.sh --use-growpart

# Use sgdisk (GPT only, more reliable for complex layouts)
sudo ./auto-grow.sh --use-sgdisk
```

**Verbose logging** (for troubleshooting):
```bash
sudo ./auto-grow.sh --verbose
sudo ./auto-grow.sh -v --dry-run
```

### Full Command Reference

```
Options:
  -m, --mount <path>     Target mount point (default: /). Online grow only.
  -t, --target <dev>     Target block device (e.g., /dev/sdb2 or /dev/nvme0n1p2).
                         Script will locate the mounted filesystem on this device.
  -n, --dry-run          Show what would happen; do not execute any commands.
  -y, --yes              Assume "yes" to confirmation prompt (automation mode).
      --use-growpart     Force using growpart for partition resize (if installed).
      --use-sgdisk       Force using sgdisk for partition resize (GPT only).
  -v, --verbose          Verbose output with command tracing.
  -h, --help             Show help message and exit.
```

## Workflow Details

### Execution Sequence

1. **Device Resolution**
   - Parse mount table to find source block device
   - Walk up the block device hierarchy (LVM → LUKS → partition → disk)
   - Validate target is the last partition on disk (safety check)

2. **Disk Rescan**
   - Trigger SCSI/NVMe bus rescan via sysfs
   - Run `partprobe` to update kernel partition table

3. **Partition Expansion**
   - **GPT disks**: Use `sgdisk` to delete and recreate partition with same start sector, extending to end
   - **MBR disks**: Use `growpart` utility
   - Partition number and start sector are preserved

4. **LUKS Resize** (if applicable)
   - Expand dm-crypt mapping to use full partition via `cryptsetup resize`

5. **LVM Operations** (if applicable)
   - Resize physical volume: `pvresize /dev/mapper/luks-xyz` or `pvresize /dev/sda2`
   - Extend logical volume to consume all free space: `lvextend -r -l +100%FREE`

6. **Filesystem Growth**
   - **ext4/ext3**: `resize2fs /dev/mapper/vg-lv`
   - **XFS**: `xfs_growfs /mountpoint`
   - **Btrfs**: `btrfs filesystem resize max /mountpoint`

### Safety Mechanisms

- **Last partition only**: Refuses to grow non-last partitions (prevents destroying subsequent partition data)
- **Online operations**: All operations work on mounted filesystems (no downtime required)
- **Dry-run mode**: Simulates all operations without executing
- **Execution plan**: Shows complete operation sequence before proceeding
- **Confirmation prompt**: Requires explicit approval (unless `--yes` is used)
- **Fail-fast**: Script exits immediately on any error (`set -Eeuo pipefail`)
- **Tool validation**: Checks for required utilities before starting
- **Partition table validation**: Verifies GPT when using sgdisk

## Use Cases

### Cloud VM Disk Expansion

**AWS EC2**:
1. Stop instance or detach volume
2. Modify volume size in AWS console
3. Reattach/start instance
4. Run: `sudo ./auto-grow.sh`

**Google Cloud**:
1. Resize persistent disk in GCP console
2. SSH into instance
3. Run: `sudo ./auto-grow.sh`

**Azure**:
1. Deallocate VM or expand disk in Azure portal
2. Start VM
3. Run: `sudo ./auto-grow.sh`

### Hypervisor VM Expansion

**VMware ESXi/vSphere**:
1. Expand virtual disk in VM settings
2. Power on or hot-add if supported
3. Run: `sudo ./auto-grow.sh`

**Proxmox VE**:
1. Resize disk in Proxmox web UI
2. Run inside VM: `sudo ./auto-grow.sh`

**VirtualBox/KVM**:
1. Use `VBoxManage modifyhd` or `qemu-img resize`
2. Boot VM
3. Run: `sudo ./auto-grow.sh`

### Automation Integration

**Ansible playbook**:
```yaml
- name: Grow filesystem after disk expansion
  command: /usr/local/bin/auto-grow.sh --yes
  become: yes
  register: grow_result
  failed_when: grow_result.rc != 0
```

**Terraform user_data** (cloud-init):
```bash
#!/bin/bash
curl -sL https://raw.githubusercontent.com/hamkee-dev-group/autogrowfs/main/auto-grow.sh -o /tmp/auto-grow.sh
chmod +x /tmp/auto-grow.sh
/tmp/auto-grow.sh --yes
```

**Shell script wrapper**:
```bash
#!/bin/bash
set -e

# Expand disk in hypervisor/cloud API
expand_disk_via_api

# Wait for device to be recognized
sleep 5

# Grow filesystem
/usr/local/bin/auto-grow.sh --yes --verbose
```

## Limitations and Constraints

### What This Script Does NOT Handle

1. **Non-last partitions**: Will not grow a partition that has other partitions after it on the same disk (enforced safety check at line 234-238)
2. **Shrinking**: Only grows filesystems, never shrinks
3. **RAID/mdadm**: Does not handle software RAID arrays (md devices)
4. **Multi-disk scenarios**: Operates on single disk at a time, no spanned volumes
5. **Offline filesystems**: Requires filesystem to be mounted - all operations are online only
6. **Unsupported filesystems**: No support for:
   - ZFS (requires `zpool online -e` and `zfs set`)
   - bcachefs, F2FS, ReiserFS
   - NTFS, FAT, exFAT (Windows filesystems)
   - Proprietary filesystems (VMFS, etc.)
7. **Complex device scenarios**: Does not handle:
   - Thin provisioning (LVM thin pools)
   - Device mapper targets beyond crypt and LVM
   - bcache, dm-cache, lvmcache
   - Stratis storage

### Partition Table Constraints

- **MBR + sgdisk**: Script will abort with error (MBR requires `growpart` tool)
- **GPT without tools**: Will fail if neither `growpart` nor `sgdisk` (gdisk package) is installed
- **Hybrid partition tables**: Not tested, behavior unpredictable
- **Non-standard sector sizes**: Assumes 512-byte or 4096-byte sectors

### Device-Specific Constraints

- **Loop devices**: Rescan via sysfs may not work (no `/sys/class/block/loopX/device/rescan`)
- **USB/removable media**: Not tested, rescan behavior may differ
- **iSCSI/FC devices**: Should work but rescan may require additional tools (`iscsiadm`, etc.)
- **Virtual block devices without rescan interface**: Script attempts rescan but continues if path doesn't exist (line 294)

### LVM Specifics

**What works:**
- Single PV on the target partition/LUKS device
- Single LV expansion (consumes 100% of new free space in VG)
- PV on plain partition or PV on LUKS device

**What may fail:**
- **Multiple PVs in same VG**: Script only resizes the PV on the target disk. If your VG spans multiple physical disks, only one PV is grown. The script will error if it cannot determine which PV to resize (line 334).
- **Multiple LVs in VG**: Script extends only the mounted LV to consume all free space. If you have other LVs that should also grow, manual intervention is required.
- **VG with complex layout**: Striped, mirrored, or RAID LVs may behave unexpectedly

### Filesystem-Specific Limitations

**ext4/ext3:**
- Maximum filesystem size: 1 EiB (ext4), 16 TiB (ext3)
- Requires `resize2fs` from e2fsprogs package

**XFS:**
- Cannot be shrunk (grow-only filesystem by design)
- Requires filesystem to be mounted (line 355)
- Requires `xfs_growfs` from xfsprogs package

**Btrfs:**
- Multi-device Btrfs filesystems not supported
- Requires `btrfs` tool from btrfs-progs package

### Failure and Recovery

**What happens if the script fails mid-execution?**

The script uses `set -Eeuo pipefail` (line 19), which means it exits immediately on any error. Operations are executed sequentially, so if a step fails, subsequent steps are not attempted.

**Recovery scenarios:**

1. **Failure during partition expansion** (step 2):
   - Partition table may be partially modified
   - Run `partprobe` manually, then rerun the script
   - In worst case, use `gdisk` or `parted` to manually fix partition table

2. **Failure after partition expansion, before LUKS/LVM resize**:
   - Partition is expanded but LUKS/LVM/filesystem are not
   - **Safe to rerun the script** - `growpart` and `sgdisk` are idempotent for already-grown partitions
   - Or manually run: `cryptsetup resize`, `pvresize`, `lvextend`, `resize2fs`/`xfs_growfs`

3. **Failure after LUKS resize, before filesystem resize**:
   - Partition and LUKS are expanded, but filesystem is not
   - **Safe to rerun the script** - earlier steps will succeed again
   - Or manually resize filesystem: `resize2fs /dev/mapper/vg-lv` or `xfs_growfs /mountpoint`

**Important:** The script does NOT have rollback capability. Operations are not transactional. However, all operations are grow-only (never shrink), so partial completion is generally safe. The data itself remains intact.

## Troubleshooting

### Common Issues

**"ERROR: please run as root"**
- Solution: Use `sudo` or run as root user

**"ERROR: could not find a mounted filesystem"**
- Check that filesystem is actually mounted: `findmnt /mountpoint`
- Try explicit `--target` with block device path

**"ERROR: not the last partition on disk"**
- Script refuses to grow non-last partitions by design
- You must manually rearrange partitions or migrate data

**"ERROR: Disk uses 'dos' (likely MBR). sgdisk requires GPT"**
- Install `growpart`: `sudo apt install cloud-guest-utils` or `sudo dnf install cloud-utils-growpart`
- Or convert to GPT (requires backup and migration)

**"ERROR: missing required command 'growpart'"**
- Install cloud-utils-growpart package (see Installation section)

**"ERROR: could not resolve underlying partition/disk"**
- The script cannot walk the device hierarchy to find the partition
- Check device stack: `lsblk -f` and `findmnt /mountpoint`
- May occur with exotic device mapper setups not supported by the script

**"ERROR: could not determine PV to resize. Found: ..."**
- Multiple PVs exist and script cannot determine which one to resize
- Occurs when VG spans multiple disks or has complex topology
- Solution: Manually run `pvresize /dev/correct-pv` then `lvextend -r -l +100%FREE /dev/vg/lv`

### Debugging

**Enable verbose logging**:
```bash
sudo ./auto-grow.sh --verbose --dry-run
```

**Check block device hierarchy**:
```bash
lsblk -f
findmnt /mountpoint
```

**Verify partition is last on disk**:
```bash
sudo parted /dev/sda print
```

**Check available space**:
```bash
# Before running script
df -h /mountpoint
lsblk /dev/sda

# After running script
df -h /mountpoint
lsblk /dev/sda
```

## Security Considerations

### Permissions
- Requires root/sudo (accesses raw block devices and modifies partition tables)
- No privilege escalation or setuid mechanisms
- Runs all commands with inherited environment

### Data Safety
- All operations are designed to be non-destructive (grow only, never shrink)
- Uses standard Linux utilities (no custom partition table modification)
- Preserves partition start sectors and UUIDs
- LUKS encryption remains intact (only mapping is resized)

### Audit Trail
- All commands are logged with timestamps
- Dry-run mode for verification before execution
- Execution plan clearly shows operations before proceeding

## Contributing

This is a single-file bash script designed for simplicity and portability. When contributing:

1. Maintain zero external dependencies beyond standard Linux utilities
2. Test on multiple distributions (RHEL, Debian, SUSE families)
3. Test with various configurations (plain, LUKS, LVM, combinations)
4. Preserve idempotent behavior (safe to run multiple times)
5. Keep fail-fast error handling
6. Update version number (line 22) following semantic versioning

## License

MIT License. Use at your own risk. Always test on non-production systems before deploying to critical infrastructure.

## Support

This tool is developed and maintained for [Hamkee](https://hamkee.net/), specialists in Unix infrastructure and systems optimization with over 25 years of experience.

For technical support, bug reports, or feature requests related to this script, contact Hamkee through their website at [https://hamkee.net/](https://hamkee.net/)

Hamkee provides professional services including:
- Unix/Linux system administration and optimization (GNU/Linux, OpenBSD)
- Virtualization solutions (KVM, VMware ESXi)
- Custom software development optimized for Unix environments
- Infrastructure advisory and security consulting
