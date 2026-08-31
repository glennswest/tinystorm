# tinystorm

The tiniest practical Fedora-based bootable image for cloud use. One raw/qcow2
disk image with exactly what a cloud guest needs and nothing else: bash,
systemd, sshd, time sync, and seed-driven cloud provisioning. The build scripts
(`build.sh`, `scripts/smoke-test.sh`) are the whole product — every image is
reproducible from this repo on a stock Fedora build host.

Two profiles:

| Profile | Image | qcow2 | Rootfs | Provisioning | Use when |
|---|---|---|---|---|---|
| `cloud` (default) | `tinystorm-*` | **159 MB** | 284 MiB | cloud-init 25.2 | You need full user-data support (runcmd, packages, arbitrary datasources) |
| `tinycloudinit` | `tinycloudinit-*` | **97 MB** | 125 MiB | [tinycloudinit](https://github.com/glennswest/tinycloudinit) + systemd | NoCloud cidata drive; users/keys/sudo/write_files/runcmd/hostname/growfs/DHCP |

(v0.7.1, measured on the built images. The v0.1.0 baseline was 271 MB / 437 MiB;
the drop comes from a VM-only kernel module prune, removing the package manager
and all TLS/locale/tzdata/hwdb userland from the tinycloudinit profile, and
trim-correct image conversion. Both profiles boot to sshd in ~10-16 s under
QEMU/KVM and are smoke-tested on every build: real ssh login, sudo, first-boot
disk growth.)

## tinycloudinit — the cloud-init replacement

cloud-init is the one thing that forces Python into the image (~90 MiB across
48 packages, python3-libs alone is 43 MB). The `tinycloudinit` profile replaces
it with a **682 KB static musl binary**:

- **[tinycloudinit](https://github.com/glennswest/tinycloudinit)** (Rust,
  installed from its GitHub release, cached in `/build/cache`): NoCloud
  datasource (iso9660/vfat `cidata` volume or seed dir) with the useful
  cloud-config subset — `users` (incl. `sudo`, `ssh_authorized_keys`,
  `passwd`), top-level `ssh_authorized_keys` (root), `hostname`/`fqdn`/
  `manage_etc_hosts`, `write_files`, `runcmd`, shell-script user-data, and
  run-once-per-instance-id semantics. Writes plain `~/.ssh/authorized_keys`,
  so stock sshd just works. Nothing is baked into the image — users come from
  the seed, like cloud-init.
- **systemd-repart + x-systemd.growfs**: first-boot disk growth with zero
  extra packages (replaces cloud-utils-growpart + e2fsprogs). The root
  partition carries the root-x86-64 GPT type GUID so `Type=root` matching works.
- DHCP networking is already handled by the baked systemd-networkd config.

What you give up vs cloud-init: package installation, network-config
rendering (use DHCP or write networkd units via `write_files`), multi-part
MIME, and network datasources (EC2 IMDS is planned in tinycloudinit v0.2).

## Design

The image is built with `dnf5 --installroot` into a loop-mounted GPT disk —
no anaconda, no kickstart, no osbuild. Everything that makes stock Fedora
Cloud ~400 MB is left out deliberately.

### What's actually needed, and the smallest way to get it

| Need | Choice | Why it's the smallest |
|---|---|---|
| Kernel | `kernel-core` | Full `kernel` drags `linux-firmware` (hundreds of MB). Cloud VMs use virtio — no firmware needed. Weak deps disabled so the split GPU firmware packages stay out too. |
| Kernel modules | VM-guest whitelist prune (`TRIM_MODULES=0` to skip) | `kernel-core`+`kernel-modules-core` ship a ~115 MiB module tree; a KVM/Proxmox guest loads ~20. The build keeps a whitelist (virtio*, ahci/ata, nvme, sd/sr, isofs/vfat, fuse/virtiofs, vsock, e1000/e1000e, framebuffer) plus its `modules.dep` closure, deletes the rest, and re-runs depmod before dracut. The duplicate `vmlinuz` under `/lib/modules` is dropped too — the ESP copy boots. |
| Init | `systemd`, `systemd-udev` | Required by everything; no way around it and no reason to want one. |
| Networking | `systemd-networkd` + `systemd-resolved` | Replaces NetworkManager (+ its Python/glib pile). One `.network` file does DHCP on `en*`/`eth*`. |
| Bootloader | `systemd-boot-unsigned` | GRUB2 is ~30 MB across packages and needs os-prober/config machinery. systemd-boot is one EFI binary copied to `ESP/EFI/BOOT/BOOTX64.EFI` plus a 5-line loader entry. UEFI-only, which every current cloud supports. |
| Shell/userland | `bash`, `coreutils-single`, `util-linux-core`, `glibc-minimal-langpack` | `coreutils-single` is the single-multicall-binary build (~1 MB vs ~6 MB). `glibc-minimal-langpack` avoids `glibc-all-langpacks` (~220 MB). `libcurl-minimal` named explicitly in the cloud profile so dnf5 never pulls full libcurl; the tinycloudinit profile ships no libcurl at all (nothing consumes it — the tci binary is static musl), which also drops libidn2/libunistring/libnghttp2. |
| 
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

## Sister projects

- **[tinycloudinit](https://github.com/glennswest/tinycloudinit)** — the 682 KB
  static musl Rust cloud-init replacement that powers the `tinycloudinit`
  profile: NoCloud cidata seeds (users, ssh keys, sudo, write_files, runcmd,
  hostname), run-once-per-instance semantics, native partition growth in v1.1.
- **[tztiny](https://github.com/glennswest/tztiny)** — a 463 KB static Rust
  binary embedding the entire IANA timezone database. These images ship
  UTC-only (no tzdata); drop tztiny in and `tztiny set America/Edmonton`
  writes `/etc/localtime` directly — no zoneinfo tree needed.

## License & Fedora compliance

The build scripts and configuration in this repository are MIT-licensed (see
`LICENSE`).

The **built images** contain unmodified binary packages from
[Fedora Linux](https://fedoraproject.org/) 43 and are subject to those
packages' own licenses:

- Every package's license text ships **inside the image** at
  `/usr/share/licenses/` — this directory is deliberately never pruned,
  precisely so redistributed images stay self-documenting.
- The exact package set is recorded in the image's rpmdb
  (`/usr/lib/sysimage/rpm`, query from outside with
  `rpm --root=<mnt> -qa --qf '%{NAME} %{LICENSE}\n'`).
- Corresponding sources for every package are the Fedora SRPMs, available
  from the [Fedora mirrors](https://dl.fedoraproject.org/pub/fedora/linux/)
  and package sources at [src.fedoraproject.org](https://src.fedoraproject.org/).
  Nothing here modifies any Fedora package.
- Fedora is a trademark of Red Hat, Inc. This is an independent, unofficial
  build assembled from Fedora Linux packages; it is not produced, endorsed, or
  supported by the Fedora Project, and the images install no Fedora logo or
  branding packages. If you redistribute modified variants, review the
  [Fedora trademark guidelines](https://fedoraproject.org/wiki/Legal:Trademark_guidelines).
