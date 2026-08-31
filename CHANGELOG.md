# Changelog

## [Unreleased]

### 2026-08-30
- **feat:** Locale prune (both profiles): `/usr/share/locale` translations deleted (~45 MiB);
  C.UTF-8 from glibc-minimal-langpack remains.
- **feat:** tinycloudinit profile drops the dnf5 stack (~35 MiB: dnf5/libdnf5/librepo/libsolv/
  glib2/gnutls/libxml2). The image is managed from outside via `dnf5 --installroot`
  (container-style); the rpmdb is kept for inventory. Cloud profile keeps dnf5 for
  cloud-init `packages:`/`package_update`.
- **feat:** tinycloudinit profile strips `/usr/share/zoneinfo` to UTC and points
  `/etc/localtime` at it. Cloud profile keeps tzdata (cloud-init `timezone:` module).

## [v0.4.0] — 2026-08-31

### Added
- **feat:** VM-only kernel module prune (default on, `TRIM_MODULES=0` to skip): keep a
  QEMU/KVM/Proxmox guest whitelist (virtio*, ahci/ata, nvme, sd/sr, isofs/vfat/nls,
  fuse/virtiofs, vsock, e1000/e1000e, bochs/virtio_gpu, nfnetlink) plus its modules.dep
  closure, delete the rest of the ~115 MiB module tree, depmod, then build the initramfs.
  Also drops the duplicate vmlinuz from /lib/modules (the ESP copy is the one that boots).
- **docs:** Size audit of the v0.3.0 image recorded in CLAUDE.md (354 MiB installed:
  kernel ~174, dnf5 stack ~33, locale 45, systemd ~33).

## [v0.3.0] — 2026-08-31

### Changed
- **feat:** `tinycloudinit` profile now uses the glennswest/tinycloudinit static musl binary
  (682 KB) instead of afterburn (6.8 MiB): full cloud-config subset (users/sudo/keys/
  write_files/runcmd/hostname), plain authorized_keys (sshd drop-in removed), no baked user,
  no `ignition.platform.id` kernel arg, works with any iso9660/vfat `cidata` volume.
- **refactor:** Smoke seed is a single cloud-config valid for both profiles (seed-defined
  `fedora` user with NOPASSWD sudo and ssh key).


## [v0.2.0] — 2026-08-31

### Added
- **feat:** `tinycloudinit` profile — replaces cloud-init with afterburn 5.10 + systemd-repart/growfs.
  No Python in the image: rootfs 340 MB vs 437 MB (48 packages / ~90 MiB dropped). Baked `fedora`
  user (wheel, NOPASSWD sudo); ssh keys/hostname/network from the Proxmox VE cidata drive;
  `ignition.platform.id=proxmoxve` baked into the kernel cmdline; sshd reads
  `~/.ssh/authorized_keys.d/afterburn`.
- **feat:** Smoke test for tinycloudinit: real SSH login with the injected key, passwordless sudo
  check, and verification that systemd-repart + growfs expanded the root fs to the test disk.

### Fixed
- **fix:** Correct root-x86-64 GPT type GUID (was invalid; systemd-repart created a second root
  partition instead of growing the existing one).
- **fix:** Enable template instance units correctly (afterburn-sshkeys@fedora).
- **fix:** Smoke seed is now a true ISO9660 `cidata` volume with all four Proxmox files
  (afterburn mounts iso9660 explicitly and requires vendor-data + network-config to exist).
- **fix:** Smoke test kills stale VMs from aborted runs.


## [v0.1.0] — 2026-08-30

### Added
- **feat:** Initial tinystorm: minimal Fedora 43 cloud image builder (`build.sh`) — dnf5 installroot, GPT ESP+ext4, systemd-boot, kernel-core, systemd-networkd/resolved, cloud-init (networkd renderer), openssh-server, dnf5, no weak deps/docs/firmware.
- **feat:** QEMU/OVMF smoke test with NoCloud seed (`scripts/smoke-test.sh`).
- **docs:** README with full design rationale and package-choice table.

### Fixed
- **fix:** Enable cloud-init 25.x unit names (`cloud-init-main`/`-local`/`-network` + `cloud-init.target`).
- **fix:** fstrim the ESP as well as the root fs before qcow2 conversion (~170 MB smaller image: 271 MB vs 440 MB).

## [Unreleased]
