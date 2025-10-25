#!/usr/bin/env bash
# auto-grow.sh — Safely grow a Linux filesystem (root or non-root) end-to-end.
# Copyright:
#   MIT License. Use at your own risk. Test on non-production before rollout.
#
# Features:
#   - Target by mountpoint  (default /)   via --mount /path
#   - Target by block part  via --target /dev/sdXn (or /dev/nvme0n1pY)
#   - Rescan disk, expand partition (growpart or sgdisk fallback),
#     resize LUKS mapping (if present), resize LVM (if present),
#     grow filesystem (ext4/xfs/btrfs).
#   - Dry-run simulation, confirmation prompt, verbose logging.
#
# Limitations:
#   - Online grow only (requires the filesystem to be mounted).
#   - Only grows the LAST partition of a disk (safe default).
#   - If disk uses MBR and growpart is missing, we abort (sgdisk needs GPT).

set -Eeuo pipefail
umask 022

VERSION="1.3.0"

trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

MOUNT="/"
TARGET_DEV=""     # e.g., /dev/sdb2
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
FORCE_TOOL="auto" # auto|growpart|sgdisk

log(){ echo "[$(date +%H:%M:%S)] $*"; }
vlog(){ [[ $VERBOSE -eq 1 ]] && log "$@"; }

need(){
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command '$1'." >&2; exit 2; }
}

run(){
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    vlog "+ $*"
    eval "$@"
  fi
}

confirm(){
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

usage(){
  cat <<EOF
auto-grow.sh v$VERSION

Usage:
  sudo $0 [options]

Options:
  -m, --mount <path>     Target mount point (default: /). Online grow only.
  -t, --target <dev>     Target block device (e.g., /dev/sdb2 or /dev/nvme0n1p2).
                         We'll locate the mounted filesystem on top of this stack.
  -n, --dry-run          Show what would happen; do not execute.
  -y, --yes              Assume "yes" to the confirmation prompt.
      --use-growpart     Force using growpart for partition resize (if installed).
      --use-sgdisk       Force using sgdisk for partition resize (GPT only).
  -v, --verbose          Verbose output.
  -h, --help             Show help.

Notes:
  - Either --mount or --target may be specified (mutually exclusive).
  - The filesystem must be MOUNTED (online grow). For XFS, this is required.
  - We only grow the LAST partition on a disk (safest).
EOF
}

# ---------- arg parsing ----------
if [[ $# -eq 0 ]]; then :; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mount)   MOUNT="$2"; TARGET_DEV=""; shift 2;;
    -t|--target)  TARGET_DEV="$2"; MOUNT=""; shift 2;;
    -n|--dry-run) DRY_RUN=1; shift;;
    -y|--yes)     ASSUME_YES=1; shift;;
    --use-growpart) FORCE_TOOL="growpart"; shift;;
    --use-sgdisk)   FORCE_TOOL="sgdisk"; shift;;
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -n "$MOUNT" && -n "$TARGET_DEV" ]]; then
  echo "ERROR: --mount and --target are mutually exclusive." >&2
  exit 1
fi

if [[ -z "$MOUNT" && -z "$TARGET_DEV" ]]; then
  # default to root mount
  MOUNT="/"
fi

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  echo "ERROR: please run as root (or use --dry-run for simulation)." >&2
  exit 1
fi

# ---------- required tools (base) ----------
need lsblk
need findmnt
need partprobe

# ---------- helpers ----------
# Normalize a block dev path (strip /dev prefix in some lsblk outputs)
_normdev(){ local d="$1"; d="${d#/dev/}"; echo "/dev/${d}"; }

# Given a node, return its type (part, lvm, crypt, disk, rom, loop, md, raid, ...)
blk_type(){ lsblk -no TYPE "$1" 2>/dev/null || true; }

# For a node, return parent disk (PKNAME)
parent_disk(){ local d; d=$(lsblk -no PKNAME "$1" 2>/dev/null || true); [[ -n "$d" ]] && echo "/dev/$d"; }

# For a node, return partition number (if any)
part_num(){ lsblk -no PARTN "$1" 2>/dev/null | head -n1; }

# Return partition table type of a disk (gpt/dos)
pttype(){ lsblk -no PTTYPE "$1" 2>/dev/null || true; }

# Is partition the last on its disk?
is_last_partition(){
  local part="$1"
  local disk; disk=$(parent_disk "$part")
  [[ -z "$disk" ]] && return 1
  local thisnum maxnum
  thisnum=$(part_num "$part")
  [[ -z "$thisnum" ]] && return 1
  # get max PARTN number on disk
  maxnum=$(lsblk -nr -o NAME,TYPE,PARTN "$disk" | awk '$2=="part" {print $3}' | sort -n | tail -1)
  [[ -n "$maxnum" && "$thisnum" -eq "$maxnum" ]]
}

# ---------- resolve target chain ----------
# We aim to set:
#   MNT       -> mountpoint of the filesystem to grow (must exist)
#   MNT_SRC   -> block device mounted at MNT (LV or crypt or part)
#   PART_DEV  -> the partition node we will grow (TYPE=part)
#   DISK_DEV  -> whole disk of PART_DEV
#   CRYPT_DEV -> if a crypt mapping sits between PART_DEV and MNT_SRC
#   LVM_LV    -> if LVM LV is the mounted source

MNT=""
MNT_SRC=""
PART_DEV=""
DISK_DEV=""
CRYPT_DEV=""
LVM_LV=""

if [[ -n "$TARGET_DEV" ]]; then
  # Ensure target exists
  [[ -b "$TARGET_DEV" ]] || { echo "ERROR: target $TARGET_DEV is not a block device."; exit 1; }
  TARGET_DEV=$(_normdev "$TARGET_DEV")

  # Find the top-most mounted FS that sits on top of this target chain
  # We check if this target or any of its *children* is the mounted source.
  MNT=$(findmnt -no TARGET -S "$TARGET_DEV" || true)
  if [[ -z "$MNT" ]]; then
    # maybe filesystem is on a child (e.g., crypt or LV above partition)
    # find any mount whose SOURCE is a descendant of TARGET_DEV
    # list descendants via lsblk and test findmnt on each
    while read -r child; do
      MNT=$(findmnt -no TARGET -S "$child" || true)
      [[ -n "$MNT" ]] && { MNT_SRC="$child"; break; }
    done < <(lsblk -nr -o NAME "$TARGET_DEV" | sed 's|^|/dev/|')
  else
    MNT_SRC=$(findmnt -no SOURCE -S "$TARGET_DEV")
  fi

  # If still not found, try brute list
  if [[ -z "$MNT" ]]; then
    # list all /dev/ nodes in the stack below target
    mapfile -t nodes < <(lsblk -nr -o NAME "$TARGET_DEV" | sed 's|^|/dev/|')
    for n in "${nodes[@]}"; do
      mp=$(findmnt -no TARGET -S "$n" || true)
      if [[ -n "$mp" ]]; then MNT="$mp"; MNT_SRC=$(findmnt -no SOURCE -S "$n"); break; fi
    done
  fi

  [[ -n "$MNT" && -n "$MNT_SRC" ]] || { echo "ERROR: could not find a mounted filesystem on top of $TARGET_DEV (online grow only)."; exit 1; }
else
  # Mount-based path
  [[ -n "$MOUNT" ]] || { echo "ERROR: empty --mount?"; exit 1; }
  MNT="$MOUNT"
  MNT_SRC=$(findmnt -no SOURCE "$MNT") || { echo "ERROR: mount $MNT not found."; exit 1; }
fi

# Identify LVM/LUKS status of MNT_SRC and walk up to the partition
t=$(blk_type "$MNT_SRC")
if [[ "$t" == "lvm" ]]; then LVM_LV="$MNT_SRC"; fi
current="$MNT_SRC"

for _ in {1..12}; do
  typ=$(blk_type "$current")
  pk=$(parent_disk "$current")
  name=$(lsblk -no NAME "$current" 2>/dev/null || true)

  [[ -z "$typ" ]] && break

  if [[ "$typ" == "crypt" && -z "$CRYPT_DEV" ]]; then
    CRYPT_DEV="$current"
  fi

  if [[ "$typ" == "part" ]]; then
    PART_DEV="$current"
    if [[ -n "$pk" ]]; then DISK_DEV="$pk"; else DISK_DEV=$(dirname "$PART_DEV"); fi
    break
  fi

  if [[ -n "$pk" ]]; then
    current="$pk"
  else
    break
  fi
done

[[ -n "$PART_DEV" && -n "$DISK_DEV" ]] || { echo "ERROR: could not resolve underlying partition/disk for $MNT_SRC"; lsblk -a >&2; exit 1; }

PNUM=$(part_num "$PART_DEV")
[[ -n "$PNUM" ]] || { echo "ERROR: could not determine partition number for $PART_DEV"; exit 1; }

# Safety: ensure it's the last partition
if ! is_last_partition "$PART_DEV"; then
  echo "ERROR: $PART_DEV is not the last partition on $DISK_DEV. Growing non-last partitions is unsafe."
  echo "       Rearrange partitions or move data, then retry. Aborting."
  exit 1
fi

# Choose partition grow tool
HAVE_GROWPART=0
if command -v growpart >/dev/null 2>&1; then HAVE_GROWPART=1; fi
case "$FORCE_TOOL" in
  auto)
    if [[ $HAVE_GROWPART -eq 1 ]]; then TOOL="growpart"; else TOOL="sgdisk"; fi
    ;;
  growpart)
    if [[ $HAVE_GROWPART -eq 1 ]]; then TOOL="growpart"; else echo "ERROR: --use-growpart given but growpart not found." >&2; exit 1; fi
    ;;
  sgdisk)
    TOOL="sgdisk"
    ;;
  *) echo "ERROR: invalid tool mode $FORCE_TOOL"; exit 1;;
esac

# If we will use sgdisk, ensure GPT
if [[ "$TOOL" == "sgdisk" ]]; then
  pt=$(pttype "$DISK_DEV")
  if [[ "$pt" != "gpt" ]]; then
    echo "ERROR: Disk $DISK_DEV uses '$pt' (likely MBR). sgdisk requires GPT."
    echo "       Install/use 'growpart' instead (cloud-utils-growpart) or convert to GPT."
    exit 1
  fi
fi

# Filesystem on mount
MNT_FSTYPE=$(findmnt -no FSTYPE "$MNT" || true)
[[ -n "$MNT_FSTYPE" ]] || { echo "ERROR: could not detect filesystem type on $MNT"; exit 1; }

log "Target mount: $MNT  (fs=$MNT_FSTYPE  source=$MNT_SRC)"
log "Resolved: PART=$PART_DEV (part#$PNUM)  DISK=$DISK_DEV  CRYPT=${CRYPT_DEV:-none}  LV=${LVM_LV:-none}"
log "Partition grow tool: $TOOL"

# ---------- Execution plan ----------
echo
echo "=== EXECUTION PLAN ==="
echo "1) Rescan disk: $DISK_DEV"
echo "2) Expand partition $PNUM on $DISK_DEV to end (tool: $TOOL)"
if [[ -n "$CRYPT_DEV" ]]; then
  echo "3) Resize LUKS mapping: $CRYPT_DEV"
fi
if [[ "$(blk_type "$MNT_SRC")" == "lvm" ]]; then
  echo "4) LVM: pvresize (on correct PV) and lvextend -r to grow $MNT_SRC"
else
  echo "4) No LVM: grow filesystem on $MNT (fs=$MNT_FSTYPE)"
fi
echo "======================"
echo

confirm || { echo "Aborted."; exit 0; }

# ---------- Step 1: rescan ----------
RESCAN="/sys/class/block/$(basename "$DISK_DEV")/device/rescan"
if [[ -e "$RESCAN" ]]; then
  run "echo 1 > '$RESCAN'"
fi
run "partprobe '$DISK_DEV' || true"

# ---------- Step 2: expand partition ----------
if [[ "$TOOL" == "growpart" ]]; then
  need growpart
  run "growpart '$DISK_DEV' '$PNUM'"
else
  need sgdisk
  run "sgdisk -e '$DISK_DEV'"   # ensure backup GPT is placed at end
  START_SECT=$(cat "/sys/class/block/$(basename "$PART_DEV")/start")
  [[ -n "$START_SECT" ]] || { echo "ERROR: cannot read start sector for $PART_DEV"; exit 1; }
  run "sgdisk -d '$PNUM' '$DISK_DEV'"
  run "sgdisk -n '$PNUM':'$START_SECT':0 '$DISK_DEV'"
  run "partprobe '$DISK_DEV' || true"
fi

# ---------- Step 3: LUKS (if present) ----------
if [[ -n "$CRYPT_DEV" ]]; then
  need cryptsetup
  run "cryptsetup resize '$CRYPT_DEV'"
fi

# ---------- Step 4: LVM or plain FS ----------
if [[ "$(blk_type "$MNT_SRC")" == "lvm" ]]; then
  need pvresize
  need lvextend
  # Determine correct PV to resize:
  # Prefer PV directly on top of CRYPT_DEV when present, else on PART_DEV.
  mapfile -t PVS < <(pvs --noheadings -o pv_name 2>/dev/null | awk '{$1=$1;print}')
  PV_TO_USE=""
  if [[ -n "$CRYPT_DEV" ]] && printf '%s\n' "${PVS[@]}" | grep -qx "$CRYPT_DEV"; then
    PV_TO_USE="$CRYPT_DEV"
  elif printf '%s\n' "${PVS[@]}" | grep -qx "$PART_DEV"; then
    PV_TO_USE="$PART_DEV"
  elif [[ ${#PVS[@]} -eq 1 ]]; then
    PV_TO_USE="${PVS[0]}"
  else
    echo "ERROR: could not determine PV to resize. Found: ${PVS[*]}" >&2
    exit 1
  fi
  log "Resizing PV: $PV_TO_USE"
  run "pvresize '$PV_TO_USE'"

  log "Extending LV to consume all free space: $MNT_SRC"
  # -r grows filesystem (ext4/xfs) online. For btrfs-on-LV, it still works if the LV grows.
  run "lvextend -r -l +100%FREE '$MNT_SRC'"

else
  # No LVM: grow filesystem directly on MNT
  case "$MNT_FSTYPE" in
    ext4|ext3)
      need resize2fs
      # ext can grow online; operate on the mounted source device (LV/crypt/part)
      run "resize2fs '$MNT_SRC'"
      ;;
    xfs)
      need xfs_growfs
      # xfs requires the mount point
      run "xfs_growfs '$MNT'"
      ;;
    btrfs)
      need btrfs
      run "btrfs filesystem resize max '$MNT'"
      ;;
    *)
      echo "ERROR: unsupported filesystem for direct grow: '$MNT_FSTYPE' (handle manually)" >&2
      exit 1
      ;;
  esac
fi

echo
log "Growth complete."
lsblk -f
df -h "$MNT"
