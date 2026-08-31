# tinystorm

The tiniest practical Fedora bootable image for cloud use. One raw/qcow2 disk
image with exactly what a cloud guest needs and nothing else: bash, systemd,
sshd, cloud provisioning, and the smallest maintained package manager.

Two profiles:

| Profile | Image | Rootfs | Provisioning | Use when |
|---|---|---|---|---|
| `cloud` (default) | `tinystorm-*` | ~437 MB | cloud-init 25.2 | You need full user-data support (runcmd, packages, arbitrary datasources) |
| `tinycloudinit` | `tinycloudinit-*` | ~340 MB | afterburn + systemd | Proxmox VE / NoCloud-style cidata drive; ssh keys + hostname + growfs + DHCP is enough |

## tinycloudinit — the cloud-init replacement

cloud-init is the one thing that forces Python into the image (~90 MiB across
48 packages). The `tinycloudinit` profile replaces it with pieces that are
either already in the image or tiny:

- **afterburn** (6.8 MiB, Rust, in Fedora repos — Fedora CoreOS's metadata
  agent): reads the Proxmox VE cloud-init drive (ISO9660 labeled `cidata`,
  the standard Proxmox format with `user-data`/`meta-data`/`vendor-data`/
  `network-config`), injects `ssh_authorized_keys` for the baked `fedora`
  user, and provides hostname + static network config.
  `afterburn-sshkeys@fedora.service` is gated on `ignition.platform.id=proxmoxve`,
  which the image bakes into its kernel cmdline. An sshd drop-in points
  `AuthorizedKeysFile` at `~/.ssh/authorized_keys.d/afterburn`.
- **tinycloudinit.service**: small oneshot that applies the hostname and drops
  afterburn-rendered networkd units into `/run/systemd/network` before
  networking starts. Best-effort — a missing drive never fails the boot.
- **systemd-repart + x-systemd.growfs**: first-boot disk growth with zero
  extra packages (replaces cloud-utils-growpart + e2fsprogs). The root
  partition carries the root-x86-64 GPT type GUID so `Type=root` matching works.
- The `fedora` user (wheel, NOPASSWD sudo, locked password) is created at
  build time instead of by cloud-init at first boot.

What you give up vs cloud-init: arbitrary user-data modules (runcmd, packages,
write_files, ...) and non-Proxmox datasources (EC2/GCE/Azure metadata would
need the platform id changed and afterburn units adjusted).

## Design

The image is built with `dnf5 --installroot` into a loop-mounted GPT disk —
no anaconda, no kickstart, no osbuild. Everything that makes stock Fedora
Cloud ~400 MB is left out deliberately.

### What's actually needed, and the smallest way to get it

| Need | Choice | Why it's the smallest |
|---|---|---|
| Kernel | `kernel-core` | Full `kernel` drags `linux-firmware` (hundreds of MB). Cloud VMs use virtio — no firmware needed. Weak deps disabled so the split GPU firmware packages stay out too. |
| Init | `systemd`, `systemd-udev` | Required by everything; no way around it and no reason to want one. |
| Networking | `systemd-networkd` + `systemd-resolved` | Replaces NetworkManager (+ its Python/glib pile). One `.network` file does DHCP on `en*`/`eth*`. |
| Bootloader | `systemd-boot-unsigned` | GRUB2 is ~30 MB across packages and needs os-prober/config machinery. systemd-boot is one EFI binary copied to `ESP/EFI/BOOT/BOOTX64.EFI` plus a 5-line loader entry. UEFI-only, which every current cloud supports. |
| Shell/userland | `bash`, `coreutils-single`, `util-linux-core`, `glibc-minimal-langpack` | `coreutils-single` is the single-multicall-binary build (~1 MB vs ~6 MB). `glibc-minimal-langpack` avoids `glibc-all-langpacks` (~220 MB). `libcurl-minimal` picked explicitly so nothing pulls full libcurl. |
| Package manager | `dnf5` | `microdnf` is retired in modern Fedora; dnf5 is the successor and is C++ with no Python dependency of its own — the smallest maintained option. (The only thing smaller is bare `rpm`, which is not a package manager.) |
| SSH | `openssh-server` | Host keys generated on first boot. Root login off; access via cloud-init-provisioned keys for the `fedora` user. |
| Cloud provisioning | `cloud-init`, `cloud-utils-growpart`, `e2fsprogs`, `sudo`, `shadow-utils` | cloud-init is the one unavoidable Python consumer (~60 MB with python3-libs); every cloud speaks it. `growpart` + `resize2fs` grow the root partition to the flavor's disk on first boot. Renderer pinned to `networkd` so it doesn't look for NetworkManager. **Or use the `tinycloudinit` profile above and drop all of this.** |
| IPC | `dbus-broker` | hostnamectl/logind/resolvectl need a bus; dbus-broker is the small one. |
| Initramfs | `dracut` (build-time), `--no-hostonly` minus network/lvm/raid/crypt/plymouth modules, virtio drivers added | Host-only detection inside a chroot lies; an explicit trimmed module list is both correct and small. |

### What's deliberately absent

NetworkManager, GRUB2, plymouth, linux-firmware, audit, polkit, sssd, tuned,
chrony (systemd-timesyncd territory — not even that in v0.1), vim, less, man
pages (`tsflags=nodocs`), docs, weak dependencies globally
(`install_weak_deps=False`), SELinux policy (booted with `selinux=0`).

### Image layout

```
GPT
 ├─ p1  256 MiB  vfat   ESP, mounted at /boot (systemd-boot, vmlinuz, initramfs, loader entries)
 └─ p2  rest     ext4   / (grown to full disk by cloud-init on first boot)
```

Console on `ttyS0` and `tty0`. Machine-id empty → regenerated first boot.

## Building

Builds run on the build box (`root@dev.g8.lo`), never on the Mac:

```bash
git pull && ./build.sh                        # cloud profile
PROFILE=tinycloudinit ./build.sh              # afterburn profile
# artifacts land in /build/images/tinystorm/
```

Produces `tinystorm-<version>.raw` (sparse) and `tinystorm-<version>.qcow2`
(compressed). Requires: Fedora host matching `RELEASEVER`, root, `qemu-img`.

## Smoke test

```bash
./scripts/smoke-test.sh                       # cloud: cloud-init finishes, login on serial
PROFILE=tinycloudinit ./scripts/smoke-test.sh # ssh in with the injected key; checks sudo + growfs
```

## Using it

Boot UEFI. `cloud`: attach any cloud-init datasource (NoCloud, OpenStack,
Proxmox cloudinit drive...). `tinycloudinit`: attach a Proxmox cloudinit
drive (or any ISO9660 `cidata` volume with all four files). Log in as
`fedora` with your provisioned key. Install more packages with `dnf5 install`.
