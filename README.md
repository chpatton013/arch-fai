# arch-fai

Fully-automated-installer for a new ArchLinux system

## Summary

This is a prototype/WIP attempt at documenting and automating the install of an
ArchLinux system. This project contains no dependencies other than what is
trivially available on the ArchLinux Live Image install media.

To start, I have been running this on a VirtualBox VM with the following specs:
* 8GB storage
* 1 CPU
* 1GB System RAM
* 16MB Video RAM

The disk preparation and installer parameterization have been naively selected
to ease the debugging cycle.

The disk will look like this:
```
/dev/sda
  \_ 1 (begin=1, end=3, name=grub, flags=bios_grub)
  \_ 2 (begin=3, end=131, name=boot, flags=boot)
  \_ 3 (begin=131, end=-1, name=root)
```

### Usage

```
./prepare.sh
FAI_SYSTEMD_ROOT_PASSWORD=password
FAI_BOOTLDR_BOOT_DEVICES=/dev/sda
./install.sh
```

### Future work

Eventually I will build a tool to prepare the destination media according to a
configuration file. This will support:
* disk partitioning
* raid, encryption, and logical volumes
* file system formatting and mounting

That same tool will generate the appropriate tab files needed to automate the
preparation of those volumes and file systems on boot.

## License

`arch-fai` is licensed under the terms of the MIT License, as described in
[LICENSE.md](LICENSE.md)

## Contributing

Contributions are welcome in the form of bug reports, feature requests, or pull
requests.

Contribution to `arch-fai` is organized under the terms of the [Contributor
Covenant](CONTRIBUTOR_COVENANT.md).
