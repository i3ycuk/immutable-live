[Русский](README.ru.md)
# immutable-live

**immutable-live** protects the persistence partition of Live Linux systems (Live USB/ISO with data preserved across reboots) from corruption or data loss when the ISO image or distro changes.

## Problem

Normally, the persistence partition on a Live USB is tightly bound to a specific ISO image: its structure, UUID, format, or expected paths are tied to a particular distro build. As soon as you:

- update the ISO to a new version,
- switch to a different distro on the same Live USB,
- rebuild the image,

the partition with your data either stops mounting or is lost entirely.

## Solution

immutable-live decouples the persistence partition from any specific ISO/distro, making it portable and resilient to such changes — your data stays accessible regardless of which Live image is booted on top of it.

## License

This project is distributed under the [MIT](LICENSE) license.