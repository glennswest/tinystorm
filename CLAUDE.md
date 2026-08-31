# tinystorm — project context

Tiniest practical Fedora bootable cloud image. See README.md for the design.

## Version
- Current: 0.1.0 (locations: `VERSION`, `CHANGELOG.md` heading)

## Build
- Build box: `root@dev.g8.lo` (Fedora 43). Never build on the Mac.
- Artifacts: `/build/images/tinystorm/` (raw + qcow2). Working tree: `/root/tinystorm`.
- `./build.sh` builds; `./scripts/smoke-test.sh` boots it under QEMU/OVMF.

## Work plan
- [x] Scaffold repo, build script, overlay, smoke test
- [x] First successful build on dev (437 MB rootfs, 271 MB qcow2)
- [x] Smoke test passes (KVM/OVMF, cloud-init 25.2 done in 13.7 s, login on serial)
- [x] Tag v0.1.0 + GitHub release with qcow2 attached (uploaded from dev via gh)
- Future: locale/doc pruning pass, systemd-timesyncd, aarch64, UKI single-file boot

## Notes / decisions
- UEFI-only via systemd-boot (removable path `EFI/BOOT/BOOTX64.EFI`), no GRUB, no BIOS boot.
- SELinux omitted; kernel cmdline has `selinux=0`.
- `coreutils-single` chosen over full coreutils; revert if some dependency demands full coreutils.
- microdnf is retired in modern Fedora — dnf5 is the smallest maintained package manager.
