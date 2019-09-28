#!/usr/bin/env bash
set -xeuo pipefail

# Arguments
#
# Required
#   FAI_SYSTEMD_ROOT_PASSWORD
#     Password for root user.
#   FAI_BOOTLDR_BIOS_DEVICES
#     Comma-delimited list of block devices to install bootloader to.
#     Note: Only used on a BIOS system
#
# Optional
#   FAI_INSTALL_ROOT
#     Path to mounted root partition for destination media.
#     Default: '/mnt/arch'
#   FAI_SYSTEMD_LOCALE
#     System locale (eg: 'en_US.UTF-8')
#     Default: '$LANG'
#   FAI_SYSTEMD_KEYMAP
#     System keymap (eg: 'us')
#     Default: ''
#   FAI_SYSTEMD_TIMEZONE
#     System timezone (eg: 'America/Los_Angeles')
#     Default determined by accessing a geoip endpoint.
#   FAI_SYSTEMD_HOSTNAME
#     Default: 'arch'
#   FAI_SYSTEMD_MACHINE_ID
#     System machine id
#     Default determined by running `systemd-firstboot`.
#   FAI_BOOTLDR_EFI_DIRECTORY
#     Default: '/efi'
#     Note: Only used on a UEFI system
#   FAI_BOOTLDR_CMDLINE_LINUX_DEFAULT
#     Custom GRUB default command-line parameters.
#     Default: ''
#     Note: Not used when in recovery mode.
#   FAI_BOOTLDR_CMDLINE_LINUX
#     Custom GRUB command-line parameters.
#     Default: ''
#   FAI_BOOTLDR_PRELOAD_MODULES
#     Custom modules to load before invoking the GRUB command-line.
#     Default: 'part_gpt part_msdos'
#   FAI_BOOTLDR_ENABLE_CRYPTODISK
#     Enable GRUB to decrypt the /boot partition.
#     Default: ''

detect_uefi=
if [ -d /sys/firmware/efi/efivars ]; then
  detect_uefi=yes
fi

install_root="${FAI_INSTALL_ROOT:-/mnt/arch}"
locale="${FAI_SYSTEMD_LOCALE:-"$LANG"}"
keymap="${FAI_SYSTEMD_KEYMAP:-}"
timezone="${FAI_SYSTEMD_TIMEZONE:-}"
hostname="${FAI_SYSTEMD_HOSTNAME:-arch}"
machine_id="${FAI_SYSTEMD_MACHINE_ID:-}"
root_password="$FAI_SYSTEMD_ROOT_PASSWORD"
if [ -z "$detect_uefi" ]; then
  bios_devices="$FAI_BOOTLDR_BIOS_DEVICES"
else
  efi_directory="${FAI_BOOTLDR_EFI_DIRECTORY:-/efi}"
fi
grub_cmdline_linux_default="${FAI_BOOTLDR_CMDLINE_LINUX_DEFAULT:-}"
grub_cmdline_linux="${FAI_BOOTLDR_CMDLINE_LINUX:-}"
grub_preload_modules="${FAI_BOOTLDR_PRELOAD_MODULES:-'part_gpt part_msdos'}"
grub_enable_cryptodisk="${FAI_BOOTLDR_ENABLE_CRYPTODISK:-}"

if [ -z "$timezone" ]; then
  timezone="$(
    echo "$(curl http://ip-api.com/json)" |
      sed --expression 's#.*\"timezone\":\"\([^\"]*\)\".*#\1#'
  )"
fi

function ensure_file() {
  local file
  file="$1"
  readonly file

  mkdir --parents "$(dirname "$file")"
  touch "$file"
}

function populate_file() {
  local file content
  file="$1"
  content="$2"
  readonly file content

  ensure_file "$file"
  echo "$content" >"$file"
}

function replace_lines() {
  local file search replace
  file="$1"
  search="$2"
  replace="$3"
  readonly file search replace

  ensure_file "$file"
  sed --expression="s/$search/$replace/g" --in-place "$file"
}

function link_file() {
  local source destination
  source="$1"
  destination="$2"
  readonly source destination

  mkdir --parents "$(dirname "$destination")"
  ln --symbolic --force "$source" "$destination"
}

echo Update system clock
timedatectl set-ntp true

echo Install base system
pacstrap "$install_root" base

echo Fstab
genfstab -U "$install_root" >>"$install_root/etc/fstab"

echo Configure systemd
systemd_firstboot_args=
if [ -z "$locale" ]; then
  systemd_firstboot_args+=' --copy-locale'
else
  systemd_firstboot_args+=" --locale=$locale"
fi
if [ -z "$keymap" ]; then
  systemd_firstboot_args+=' --copy-keymap'
else
  systemd_firstboot_args+=" --keymap=$keymap"
fi
if [ -z "$machine_id" ]; then
  systemd_firstboot_args+=' --setup-machine-id'
else
  systemd_firstboot_args+=" --machine-id=$machine_id"
fi
systemd-firstboot \
  $systemd_firstboot_args \
  --timezone="$timezone" \
  --hostname="$hostname" \
  --root-password="$root_password" \
  --root="$install_root"

echo Time zone
link_file "/usr/share/zoneinfo/$timezone" "$install_root/etc/localtime"
arch-chroot "$install_root" hwclock --systohc

echo Localization
replace_lines "$install_root/etc/locale.gen" "^#\\($locale.*\\)$" '\1'
arch-chroot "$install_root" locale-gen
populate_file "$install_root/etc/locale.conf" "LANG=$locale"
if [ ! -z "$keymap" ]; then
  populate_file "$install_root/etc/vconsole.conf" "KEYMAP=$keymap"
fi

echo Network configuration
hosts="$(
  cat <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $hostname.localdomain $hostname
EOF
)"
populate_file "$install_root/etc/hostname" "$hostname"
populate_file "$install_root/etc/hosts" "$hosts"

echo Initramfs
replace_lines \
  "$install_root/etc/mkinitcpio.conf" \
  '^HOOKS=(.*)$' \
  'HOOKS=(base udev autodetect keyboard keymap consolefont modconf block lvm2 mdadm_udev encrypt filesystems fsck)'
arch-chroot "$install_root" mkinitcpio -p linux

echo Microcode
if grep --quiet Intel /proc/cpuinfo; then
  pacstrap "$install_root" intel-ucode
fi
if grep --quiet AMD /proc/cpuinfo; then
  pacstrap "$install_root" amd-ucode
fi

echo Bootloader
if [ -z "$detect_uefi" ]; then
  pacstrap "$install_root" grub
  (
    IFS=,
    for device in $bios_devices; do
      arch-chroot "$install_root" grub-install --target=i386-pc "$device"
    done
  )
else
  pacstrap "$install_root" grub efibootmgr
  arch-chroot "$install_root" grub-install \
    --target=x86_64-efi \
    --efi-directory="$efi_directory" \
    --bootloader-id=GRUB
fi
replace_lines \
  "$install_root/etc/default/grub" \
  '^GRUB_CMDLINE_LINUX_DEFAULT=".*"$' \
  "GRUB_CMDLINE_LINUX_DEFAULT=\"$grub_cmdline_linux_default\""
replace_lines \
  "$install_root/etc/default/grub" \
  '^GRUB_CMDLINE_LINUX=".*"$' \
  "GRUB_CMDLINE_LINUX=\"$grub_cmdline_linux\""
replace_lines \
  "$install_root/etc/default/grub" \
  '^GRUB_PRELOAD_MODULES=".*"$' \
  "GRUB_PRELOAD_MODULES=\"$grub_preload_modules\""
if [ ! -z "$grub_enable_cryptodisk" ]; then
  replace_lines \
    "$install_root/etc/default/grub" \
    '^#GRUB_ENABLE_CRYPTODISK=y$' \
    'GRUB_ENABLE_CRYPTODISK=y'
fi
arch-chroot "$install_root" grub-mkconfig -o /boot/grub/grub.cfg
