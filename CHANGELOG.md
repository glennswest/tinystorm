# Changelog

## [v0.1.0] — 2026-08-30

### Added
- **feat:** Initial tinystorm: minimal Fedora 43 cloud image builder (`build.sh`) — dnf5 installroot, GPT ESP+ext4, systemd-boot, kernel-core, systemd-networkd/resolved, cloud-init (networkd renderer), openssh-server, dnf5, no weak deps/docs/firmware.
- **feat:** QEMU/OVMF smoke test with NoCloud seed (`scripts/smoke-test.sh`).
- **docs:** README with full design rationale and package-choice table.

### Fixed
- **fix:** Enable cloud-init 25.x unit names (`cloud-init-main`/`-local`/`-network` + `cloud-init.target`).
- **fix:** fstrim the ESP as well as the root fs before qcow2 conversion (~170 MB smaller image: 271 MB vs 440 MB).

## [Unreleased]
