# Changelog

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
