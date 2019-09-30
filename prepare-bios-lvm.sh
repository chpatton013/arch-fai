#!/usr/bin/env bash
set -euo pipefail

install_root=/mnt/arch
keystore_directory=/tmp/keystore
boot_directory=/boot

boot_raid_name=boot
boot_raid_device="/dev/md/$boot_raid_name"

root_raid_name=root
root_raid_device="/dev/md/$root_raid_name"
root_crypt_name=cryptroot
root_crypt_device="/dev/mapper/$root_crypt_name"
root_crypt_keyfile="/root/keys/$root_crypt_name.bin"
root_crypt_passphrase="$FAI_PREPARE_ROOT_CRYPT_PASSPHRASE"

function _chmod() {
  (
    set -x
    chmod "$@"
  )
}

function _cryptsetup() {
  (
    set -x
    cryptsetup --batch-mode "$@"
  )
}

function _dd() {
  (
    set -x
    dd status=progress "$@"
  )
}

function _mdadm_create() {
  (
    set -x
    mdadm --create --run "$@"
  )
}

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

function _randomize_device() {
  local device crypt_name crypt_device
  device="$1"
  crypt_name="randomize_${device//\//_}"
  crypt_device="/dev/mapper/$crypt_name"
  readonly device crypt_name crypt_device

  _cryptsetup --key-file /dev/random open "$device" "$crypt_name" --type plain

  local crypt_size_b write_count_mb write_count_b write_seek_b
  crypt_size_b="$(blockdev --getsize64 "$crypt_device")"
  write_count_mb="$((crypt_size_b / (1024 * 1024)))"
  write_count_b="$((crypt_size_b % (1024 * 1024)))"
  write_seek_b="$((write_count_mb * (1024 * 1024)))"
  readonly crypt_size_b write_count_mb write_count_b write_seek_b

  _dd if=/dev/zero of="$crypt_device" bs=1M count="$write_count_mb"
  if [ "$write_count_b" != '0' ]; then
    _dd \
      if=/dev/zero \
      of="$crypt_device" \
      oflag=seek_bytes \
      bs="$write_count_b" \
      count=1 \
      seek="$write_seek_b"
  fi

  _cryptsetup close "$crypt_name"
}

function _create_keyfile() {
  local keyfile size
  keyfile="$1"
  size="$2"
  readonly keyfile size

  _mkdir "$(dirname "$keyfile")"
  _dd if=/dev/random of="$keyfile" iflag=fullblock bs="$size" count=1
  _chmod 0000 "$keyfile"
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

function create_raid_device() {
  local level metadata device
  level="$1"
  metadata="$2"
  device="$3"
  readonly level metadata device
  shift 3

  _mdadm_create \
    --level="$level" \
    --metadata="$metadata" \
    --raid-devices="$#" \
    "$device" \
    "$@"
}

function create_crypt_device() {
  local crypt type name keyfile passphrase
  crypt="$1"
  type="$2"
  name="$3"
  keyfile="$4"
  passphrase="${5:-}"
  readonly crypt type name keyfile passphrase

  _randomize_device "$crypt"
  _create_keyfile "$keyfile" 2048
  _cryptsetup --key-file "$keyfile" luksFormat --type "$type" "$crypt"
  if [ ! -z "$passphrase" ]; then
    echo $passphrase | _cryptsetup --key-file "$keyfile" luksAddKey "$crypt"
  fi
  _cryptsetup --key-file "$keyfile" open "$crypt" "$name"
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
partition_device /dev/sdb

create_raid_device 1 1.0 "$boot_raid_device" /dev/sda2 /dev/sdb2
create_raid_device 0 1.2 "$root_raid_device" /dev/sda3 /dev/sdb3

create_crypt_device \
  "$root_raid_device" \
  luks1 \
  "$root_crypt_name" \
  "$keystore_directory/$root_crypt_name.bin" \
  "$root_crypt_passphrase"

mount_filesystem "$root_crypt_device" "$install_root/" ext4 -F
mount_filesystem "$boot_raid_device" "$install_root$boot_directory" vfat -F 32

(
  mdadm --detail --scan >./mdadm.conf

  cat >./crypttab <<EOF
$root_crypt_name $root_raid_device $root_crypt_keyfile
EOF

  genfstab -U "$install_root" >./fstab

  configuration_files=
  configuration_files+="$keystore_directory/$root_crypt_name.bin"
  configuration_files+=":$install_root$root_crypt_keyfile"
  configuration_files+=",./mdadm.conf:$install_root/etc/mdadm.conf"
  configuration_files+=",./crypttab:$install_root/etc/crypttab"
  configuration_files+=",./fstab:$install_root/etc/fstab"

  mkinitcpio_hooks=
  mkinitcpio_hooks+='base udev autodetect'
  mkinitcpio_hooks+=' keyboard keymap'
  mkinitcpio_hooks+=' consolefont modconf block'
  mkinitcpio_hooks+=' lvm2 mdadm_udev encrypt'
  mkinitcpio_hooks+=' filesystems fsck'

  cmdline_linux=
  cmdline_linux+="cryptdevice=$root_raid_device:$root_crypt_name"
  cmdline_linux+=" cryptkey=$root_crypt_name:ext4:$root_crypt_keyfile"

  cat >./env.sh <<EOF
export FAI_INSTALL_ROOT='$install_root'
export FAI_INSTALL_CONFIGURATION_FILES='$configuration_files'
export FAI_BOOTLDR_MKINITCPIO_HOOKS='$mkinitcpio_hooks'
export FAI_BOOTLDR_BIOS_DEVICES='/dev/sda,/dev/sdb'
export FAI_BOOTLDR_CMDLINE_LINUX='$cmdline_linux'
export FAI_BOOTLDR_PRELOAD_MODULES='part_gpt'
export FAI_BOOTLDR_ENABLE_CRYPTODISK='yes'
EOF
)
