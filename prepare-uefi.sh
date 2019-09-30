#!/usr/bin/env bash
set -xeuo pipefail

install_root=/mnt/arch
efi_directory=/efi

function parted_command() {
  parted --script --align=optimal -- "$@"
}

function parted_mklabel() {
  local device label
  device="$1"
  label="$2"
  readonly device label

  parted_command "$device" mklabel "$label"
}

function parted_mkpart() {
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

  parted_command "$device" \
    unit mib mkpart "$partition_type" "$begin" "$end" \
    name "$partition_number" "$name" \
    $flag_args
}

function partition_device() {
  local device
  device="$1"
  readonly device

  parted_mklabel "$device" gpt
  parted_mkpart "$device" 1 primary grub 1 3 bios_grub
  parted_mkpart "$device" 2 primary boot 3 131 boot
  parted_mkpart "$device" 3 primary root 131 -1
}

function mount_filesystem() {
  local device mountpoint type
  device="$1"
  mountpoint="$2"
  type="$3"
  readonly device mountpoint type
  shift 3

  mkfs --type="$type" "$@" "$device"
  mkdir --parents "$mountpoint"
  mount "$device" "$mountpoint"
}

partition_device /dev/sda

mount_filesystem /dev/sda3 "$install_root/" ext4 -F
mount_filesystem /dev/sda2 "$install_root$efi_directory" vfat -F 32

genfstab -U "$install_root" >>"./fstab"

cat >./env.sh <<EOF
export FAI_INSTALL_ROOT='$install_root'
export FAI_INSTALL_CONFIGURATION_FILES='./fstab:$install_root/etc/fstab'
export FAI_BOOTLDR_EFI_DIRECTORY='$efi_directory'
export FAI_BOOTLDR_PRELOAD_MODULES='part_gpt'
EOF
