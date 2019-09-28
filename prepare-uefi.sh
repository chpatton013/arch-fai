#!/usr/bin/env bash
set -xeuo pipefail

install_root=/mnt/arch

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

function mount_partition() {
  local device mountpoint
  device="$1"
  mountpoint="$2"
  readonly device mountpoint

  mkdir --parents "$mountpoint"
  mount "$device" "$mountpoint"
}

parted_mklabel /dev/sda gpt
parted_mkpart /dev/sda 1 primary grub 1 3 bios_grub
parted_mkpart /dev/sda 2 primary esp 3 131 esp
parted_mkpart /dev/sda 3 primary root 131 -1

mkfs --type=vfat -F 32 /dev/sda2
mkfs --type=ext4 -F /dev/sda3

mount_partition /dev/sda3 "$install_root/"
mount_partition /dev/sda2 "$install_root/efi"
