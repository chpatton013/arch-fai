#!/usr/bin/env bash
set -euo pipefail

# Prepare destination media prior to install.
#
# This script will format the destination media with a volume layout that looks
# like the following diagram:
#
# /dev/sda
#   \_ partition 1: 2MB, flag=bios_grub
#   \_ partition 2: 128MB, flag=boot
#       \_ fs: type vfat, mountpoint /boot
#   \_ partition 3: 100%
#       \_ fs: type ext4, mountpoint /
#
# Create the following files (necessary for the subsequent install phase):
# * fstab
# * env.sh
#
# After running this, source `env.sh`, set any other required environment
# variables, and invoke `install.sh`.

install_root=/mnt/arch
boot_directory=/boot

function _mkdir() {
  (
    set -x
    mkdir --parents "$@"
  )
}

function _mkfs() {
  (
    set -x
    mkfs "$@"
  )
}

function _mount() {
  (
    set -x
    mount "$@"
  )
}

function _parted() {
  (
    set -x
    parted --script --align=optimal -- "$@"
  )
}

function _parted_mklabel() {
  local device label
  device="$1"
  label="$2"
  readonly device label

  _parted "$device" mklabel "$label"
}

function _parted_mkpart() {
  local device partition_number partition_type begin end name
  device="$1"
  partition_number="$2"
  partition_type="$3"
  name="$4"
  begin="$5"
  end="$6"
  readonly device partition_number partition_type begin end name
  shift 6

  flag_args=
  for flag in "$@"; do
    flag_args+=" set $partition_number $flag on"
  done

  _parted "$device" \
    unit mib mkpart "$partition_type" "$begin" "$end" \
    name "$partition_number" "$name" \
    $flag_args
}

function partition_device() {
  local device
  device="$1"
  readonly device

  _parted_mklabel "$device" gpt
  _parted_mkpart "$device" 1 primary grub 1 3 bios_grub
  _parted_mkpart "$device" 2 primary boot 3 131 boot
  _parted_mkpart "$device" 3 primary root 131 -1
}

function mount_filesystem() {
  local device mountpoint type
  device="$1"
  mountpoint="$2"
  type="$3"
  readonly device mountpoint type
  shift 3

  _mkfs --type="$type" "$@" "$device"
  _mkdir "$mountpoint"
  _mount "$device" "$mountpoint"
}

partition_device /dev/sda

mount_filesystem /dev/sda3 "$install_root/" ext4 -F
mount_filesystem /dev/sda2 "$install_root$boot_directory" vfat -F 32

(
  genfstab -U "$install_root" >>./fstab

  cat >./env.sh <<EOF
export FAI_INSTALL_ROOT='$install_root'
export FAI_INSTALL_CONFIGURATION_FILES='./fstab:$install_root/etc/fstab'
export FAI_BOOTLDR_BIOS_DEVICES='/dev/sda'
export FAI_BOOTLDR_PRELOAD_MODULES='part_gpt'
EOF
)
