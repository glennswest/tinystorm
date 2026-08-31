# tinystorm — project context

Tiniest practical Fedora bootable cloud image. See README.md for the design.

## Version
- Current: 0.3.0 (locations: `VERSION`, `CHANGELOG.md` heading)

## Build
- Build box: `root@dev.g8.lo` (Fedora 43). Never build on the Mac.
- Artifacts: `/build/images/tinystorm/` (raw + qcow2). Working tree: `/root/tinystorm`.
- `./build.sh` builds; `./scripts/smoke-test.sh` boots it under QEMU/OVMF.

## Work plan
- [x] Scaffold repo, build script, overlay, smoke test
- [x] First successful build on dev (437 MB rootfs, 271 MB qcow2)
- [x] Smoke test passes (KVM/OVMF, cloud-init 25.2 done in 13.7 s, login on serial)
- [x] Tag v0.1.0 + GitHub release with qcow2 attached (uploaded from dev via gh)
- [x] v0.2.0: `tinycloudinit` profile — cloud-init replaced by afterburn + systemd-repart/growfs;
      rootfs 340 MB (vs 437 MB); smoke test does real ssh login + sudo + growfs verification
- [x] v0.3.0: afterburn replaced by the glennswest/tinycloudinit static binary (682 KB);
      seed-driven users, no baked account, no sshd drop-in, no platform-id karg
- Future: locale/doc pruning pass, systemd-timesyncd, aarch64, UKI single-file boot

## tinycloudinit profile decisions
- v0.3.0: uses glennswest/tinycloudinit release binary (static musl, /usr/local/sbin) + its
  systemd unit, fetched via gh into /build/cache/tinycloudinit and verified against SHA256SUMS.
  It writes plain ~/.ssh/authorized_keys and its own /etc/sudoers.d rules; supports existing
  users. afterburn notes below kept for history (v0.2.0).

## afterburn-era decisions (v0.2.0, superseded; measured 2026-08-30)
- Removing cloud-init+python3+growpart+e2fsprogs frees 90 MiB / 48 packages (dnf5 dry run on image).
- afterburn 5.10 proxmoxve provider: finds drive via `blkid -L cidata` (lowercase label!), mounts it
  explicitly as iso9660 (vfat seeds do NOT work), requires user-data+meta-data+vendor-data+
  network-config to all exist, parses NoCloud-style user-data (`#cloud-config` header required), meta-data, network-config; writes
  networkd units; afterburn writes only ~/.ssh/authorized_keys.d/afterburn — sshd needs an AuthorizedKeysFile drop-in (overlay-tinycloudinit).
- afterburn-sshkeys@.service gates on `ignition.platform.id=<platform>` kernel cmdline; micro bakes
  `ignition.platform.id=proxmoxve` in the loader entry.
- Root partition GPT type must be root-x86-64 (4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709) for systemd-repart `Type=root` matching.
- fsck passno 0 (no e2fsprogs/dosfstools in image); growth = systemd-repart + x-systemd.growfs.

## Notes / decisions
- UEFI-only via systemd-boot (removable path `EFI/BOOT/BOOTX64.EFI`), no GRUB, no BIOS boot.
- SELinux omitted; kernel cmdline has `selinux=0`.
- `coreutils-single` chosen over full coreutils; revert if some dependency demands full coreutils.
- microdnf is retired in modern Fedora — dnf5 is the smallest maintained package manager.
