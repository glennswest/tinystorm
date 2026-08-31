# Changelog

## [Unreleased]

### 2026-08-30
- **feat:** Initial tinystorm: minimal Fedora 43 cloud image builder (`build.sh`) — dnf5 installroot, GPT ESP+ext4, systemd-boot, kernel-core, systemd-networkd/resolved, cloud-init (networkd renderer), openssh-server, dnf5, no weak deps/docs/firmware.
- **feat:** QEMU/OVMF smoke test with NoCloud seed (`scripts/smoke-test.sh`).
- **docs:** README with full design rationale and package-choice table.
