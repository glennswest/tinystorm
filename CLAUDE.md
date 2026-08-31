# tinystorm — project context

Tiniest practical Fedora bootable cloud image. See README.md for the design.

## Version
- Current: 0.7.1 (locations: `VERSION`, `CHANGELOG.md` heading)

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
- [x] v0.4.0: VM-only kernel module prune — keep lsmod-derived whitelist
      (virtio*, ahci/ata, nvme, sd/sr, isofs/vfat/nls, fuse/virtiofs, vsock, e1000/e1000e)
      + modules.dep closure, delete the rest, depmod, then dracut; drop the duplicate
      vmlinuz from /lib/modules. TRIM_MODULES=0 to skip. Expected ≥100 MiB off the rootfs.
- [x] v0.5.0: locale prune (45 MiB of /usr/share/locale, both profiles;
      C.UTF-8 from glibc-minimal-langpack stays) + drop dnf5 stack from tinycloudinit
      profile (~35 MiB: dnf5/libdnf5/librepo/libsolv/glib2/gnutls/libxml2; container-style
      — image managed from outside via dnf5 --installroot; rpmdb kept for inventory).
      Cloud profile keeps dnf5: cloud-init `packages:`/package_update needs it.
      Also tinycloudinit-only: /usr/share/zoneinfo stripped to UTC (cloud profile keeps
      tzdata for cloud-init's `timezone:` module).
- [x] v0.6.0: rpmdb compaction, hwdb deletion, libcurl-minimal/dracut/cpio dropped from
      tinycloudinit, kbd data + terminfo trim, -o discard mount (deterministic qcow2 size)
- [x] v0.7.0: systemd-timesyncd enabled (lives in systemd-udev — zero added bytes)
- Future: tztiny binary for timezone support without tzdata (../tztiny is complete, v0.1.0),
      sudo-rs evaluation, no-initramfs boot via root=PARTUUID (virtio_blk+ext4 built into
      the vmlinuz), tinycloudinit v1.1.0 growpart (replace systemd-repart path), aarch64,
      UKI single-file boot

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

## Size audit (v0.3.0 tinycloudinit image, measured 2026-08-30)
- 354 MiB installed / 146 packages. Kernel ~174 MiB (kernel-core 100.6 + kernel-modules-core 73;
  modules tree 115 MiB: drivers 54, net 14). dnf5 stack ~33 MiB and is the sole consumer of
  glib2 (15), gnutls (3.8), libxml2, sqlite-libs. /usr/share/locale 45 MiB. systemd ~33 MiB.
- Probe boot lsmod (QEMU q35/KVM): virtio_net+failover, isofs, vfat/fat, fuse+virtiofs,
  vsock+vmw_vsock_virtio_transport, loop, nfnetlink, qemu_fw_cfg, bochs; junk: parport*/ppdev,
  joydev, serio_raw, i2c_i801/smbus. virtio_blk/virtio_pci/ext4 are built into the vmlinuz
  (absent from lsmod, ext4 in /proc/filesystems).
- dnf5 is already the C++ rewrite (no Python); microdnf is retired. Smaller = rpm-only or no
  package manager (container-style: manage via dnf5 --installroot from outside, as build.sh does).

## Notes / decisions
- UEFI-only via systemd-boot (removable path `EFI/BOOT/BOOTX64.EFI`), no GRUB, no BIOS boot.
- SELinux omitted; kernel cmdline has `selinux=0`.
- `coreutils-single` chosen over full coreutils; revert if some dependency demands full coreutils.
- microdnf is retired in modern Fedora — dnf5 is the smallest maintained package manager.
