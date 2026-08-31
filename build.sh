#!/usr/bin/env bash
# tinystorm — build the tiniest bootable Fedora cloud image.
# Runs as root on the build box (Fedora host matching RELEASEVER).
# Artifacts land in /build/images/tinystorm — never on the SSD root, never /tmp.
#
# Profiles (PROFILE env, default "cloud"):
#   cloud  — cloud-init: works with any cloud-init datasource, full user-data support
#   tinycloudinit — glennswest/tinycloudinit (static musl binary, ~0.6 MiB) +
#            systemd-repart/growfs: no Python; NoCloud cidata drive with a
#            cloud-config subset (users, ssh keys, write_files, runcmd, hostname)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$HERE/VERSION")"
PROFILE="${PROFILE:-cloud}"
RELEASEVER=43
IMG_SIZE=3G          # sparse; grown to the real disk on first boot
ESP_MIB=256
WORK=/build/images/tinystorm
case "$PROFILE" in
  cloud) NAME="tinystorm" ;;
  tinycloudinit) NAME="tinycloudinit" ;;
  *) echo "unknown PROFILE '$PROFILE' (cloud|tinycloudinit)" >&2; exit 1 ;;
esac
IMG="$WORK/${NAME}-${VERSION}.raw"
QCOW="$WORK/${NAME}-${VERSION}.qcow2"
MNT="$WORK/mnt"

PACKAGES=(
  kernel-core
  systemd systemd-udev systemd-networkd systemd-resolved systemd-boot-unsigned
  dracut
  bash coreutils-single util-linux-core glibc-minimal-langpack
  openssh-server
  shadow-utils sudo iproute
  dbus-broker
)
# timesyncd ships inside systemd-udev (already installed): SNTP for free.
# networkd hands it DHCP-provided NTP servers; Fedora pool is the fallback.
UNITS=(systemd-networkd.service systemd-resolved.service systemd-timesyncd.service sshd.service)

# VM-guest module whitelist (TRIM_MODULES=0 keeps the full tree). Derived from a
# probe boot's lsmod under QEMU q35/KVM plus what other hypervisor configs need:
# Proxmox attaches the cidata seed as an IDE/SATA cdrom (ahci/ata_piix + sr_mod)
# and defaults VM disks to virtio-scsi. virtio_blk/virtio_pci/ext4 are built into
# the Fedora vmlinuz. modules.dep closure pulls transitive deps automatically.
VM_MODULES=(
  # storage
  virtio_blk virtio_scsi sd_mod sr_mod cdrom ahci ata_piix ata_generic nvme
  # net (e1000/e1000e: common non-virtio QEMU NIC models)
  virtio_net net_failover failover e1000 e1000e
  # filesystems: seed ISO, ESP vfat (+codepages), virtiofs shares
  isofs vfat fat nls_cp437 nls_iso8859_1 nls_ascii nls_utf8 fuse virtiofs loop
  # guest plumbing
  virtio_console virtio_balloon virtio_rng qemu_fw_cfg
  vsock vmw_vsock_virtio_transport
  # console framebuffer under QEMU VGA / virtio-gpu
  bochs virtio_gpu
  nfnetlink
)
# GPT root-x86-64 type: enables systemd-repart Type=root matching and gpt-auto
ROOT_TYPE=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
KARGS="root_karg_placeholder rw console=tty0 console=ttyS0,115200n8 selinux=0"

if [ "$PROFILE" = cloud ]; then
  # dnf5 only here: cloud-init's packages:/package_update modules need a package
  # manager, and its timezone: module needs tzdata. The tinycloudinit profile is
  # managed container-style from outside (dnf5 --installroot) and runs UTC.
  # libcurl-minimal named explicitly so dnf5's librepo never pulls full libcurl;
  # tinycloudinit has no libcurl consumer at all (the tci binary is static musl).
  PACKAGES+=(dnf5 libcurl-minimal cloud-init cloud-utils-growpart e2fsprogs)
  # cloud-init >= 25 unit names (main/local/network); target ties them together
  UNITS+=(cloud-init-main.service cloud-init-local.service cloud-init-network.service
          cloud-config.service cloud-final.service cloud-init.target)
  GROWFS_OPT=""
else
  TCI_VERSION=v0.1.0
  UNITS+=(tinycloudinit.service systemd-repart.service)
  GROWFS_OPT=",x-systemd.growfs"
fi

LOOP=""
cleanup() {
  set +e
  mountpoint -q "$MNT/boot" && umount "$MNT/boot"
  for d in dev proc sys; do mountpoint -q "$MNT/$d" && umount -R "$MNT/$d"; done
  mountpoint -q "$MNT" && umount "$MNT"
  [ -n "$LOOP" ] && losetup -d "$LOOP"
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v qemu-img >/dev/null || dnf5 -y install qemu-img

mkdir -p "$WORK" "$MNT"
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"

# ---- partition: GPT, ESP + root -------------------------------------------
sfdisk "$IMG" <<EOF
label: gpt
size=${ESP_MIB}MiB, type=uefi, name=esp
type=$ROOT_TYPE, name=root
EOF

LOOP="$(losetup --show -Pf "$IMG")"
# partition nodes appear asynchronously via udev; other builds on the box churn
# loop devices, so wait for them explicitly instead of racing mkfs
udevadm settle 2>/dev/null || true
for _ in $(seq 50); do
  [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && break
  sleep 0.2
done
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || { echo "loop partitions for $LOOP never appeared" >&2; exit 1; }
mkfs.fat -F32 -n ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L root "${LOOP}p2"
ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
ESP_UUID="$(blkid -s UUID -o value "${LOOP}p1")"

# -o discard: deletions punch holes in the backing file immediately, so the
# final qcow2 doesn't depend on how much of the freed space fstrim reaches
mount -o discard "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot"
mount -o discard "${LOOP}p1" "$MNT/boot"

# scriptlets (kernel, systemd) want these
mkdir -p "$MNT"/{dev,proc,sys}
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --rbind /dev "$MNT/dev"

# ---- install ---------------------------------------------------------------
dnf5 -y --use-host-config --installroot="$MNT" --releasever="$RELEASEVER" \
  --setopt=install_weak_deps=0 --setopt=tsflags=nodocs \
  --exclude='linux-firmware*' \
  install "${PACKAGES[@]}"

KVER="$(basename "$(ls -d "$MNT"/lib/modules/* | tail -1)")"

# ---- rootfs configuration --------------------------------------------------
cp -a "$HERE/overlay/." "$MNT/"
[ -d "$HERE/overlay-$PROFILE" ] && cp -a "$HERE/overlay-$PROFILE/." "$MNT/"

# no fsck tools in the image: passno 0
cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID  /      ext4  defaults,noatime$GROWFS_OPT  0 0
UUID=$ESP_UUID   /boot  vfat  umask=0077,shortname=lower   0 0
EOF

# resolved owns /etc/resolv.conf
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

# empty machine-id -> first-boot semantics, regenerated per instance
: > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"

if [ "$PROFILE" = tinycloudinit ]; then
  # static musl binary + unit from the tinycloudinit release (cached in /build/cache);
  # users/keys/sudo come from the seed at first boot, nothing baked
  TCI_CACHE=/build/cache/tinycloudinit
  TCI_TAR="$TCI_CACHE/tinycloudinit-$TCI_VERSION-x86_64-linux-musl.tar.gz"
  if [ ! -f "$TCI_TAR" ]; then
    mkdir -p "$TCI_CACHE"
    (cd "$TCI_CACHE" && gh release download "$TCI_VERSION" --repo glennswest/tinycloudinit \
       --pattern '*x86_64*' --pattern SHA256SUMS \
     && sha256sum -c --ignore-missing SHA256SUMS)
  fi
  tar xzf "$TCI_TAR" -C "$WORK"
  install -m0755 "$WORK/tinycloudinit-$TCI_VERSION/tinycloudinit" "$MNT/usr/local/sbin/tinycloudinit"
  install -m0644 "$WORK/tinycloudinit-$TCI_VERSION/systemd/tinycloudinit.service" \
                 "$MNT/etc/systemd/system/tinycloudinit.service"
  rm -rf "$WORK/tinycloudinit-$TCI_VERSION"
fi

for unit in "${UNITS[@]}"; do
  # instance units (foo@bar.service) are backed by their template file (foo@.service)
  file="$unit"
  case "$unit" in *@*.*) file="${unit%@*}@.${unit##*.}" ;; esac
  if [ -e "$MNT/usr/lib/systemd/system/$file" ] || [ -e "$MNT/etc/systemd/system/$file" ]; then
    systemctl --root="$MNT" enable "$unit"
  else
    echo "WARN: unit $unit not present, skipping" >&2
  fi
done

# ---- kernel, initramfs, bootloader ----------------------------------------
# kernel-install usually skips in a chroot (no machine-id); place files ourselves.
rm -rf "$MNT"/boot/loader "$MNT"/boot/[0-9a-f]*[0-9a-f] 2>/dev/null || true
cp "$MNT/lib/modules/$KVER/vmlinuz" "$MNT/boot/vmlinuz-$KVER"
# the ESP copy above is the one that boots; the rootfs duplicate is dead weight
rm -f "$MNT/lib/modules/$KVER/vmlinuz"

# ---- VM module prune (before dracut, so the initramfs uses the pruned tree) --
if [ "${TRIM_MODULES:-1}" = 1 ]; then
  MODDIR="$MNT/lib/modules/$KVER"
  BEFORE_MIB="$(du -sm "$MODDIR" | cut -f1)"
  declare -A KEEP
  for name in "${VM_MODULES[@]}"; do
    # module filenames use - and _ interchangeably
    pat="${name//_/[_-]}"
    while IFS= read -r line; do
      KEEP["${line%%:*}"]=1
      for dep in ${line#*:}; do KEEP["$dep"]=1; done   # modules.dep deps are transitive
    done < <(grep -E "(^|/)${pat}\.ko(\.xz|\.zst|\.gz)?:" "$MODDIR/modules.dep" || true)
  done
  while IFS= read -r -d '' f; do
    rel="${f#"$MODDIR"/}"
    [ -n "${KEEP[$rel]:-}" ] || rm -f "$f"
  done < <(find "$MODDIR" -name '*.ko*' -type f -print0)
  find "$MODDIR" -type d -empty -delete
  chroot "$MNT" depmod -a "$KVER"
  echo "== module prune: ${BEFORE_MIB} MiB -> $(du -sm "$MODDIR" | cut -f1) MiB, $(find "$MODDIR" -name '*.ko*' | wc -l) modules kept =="
fi

chroot "$MNT" dracut --force --reproducible --no-hostonly \
  --omit "network network-legacy network-manager nfs iscsi lvm mdraid dm crypt multipath resume plymouth i18n" \
  --add-drivers "virtio_blk virtio_scsi virtio_pci virtio_net sd_mod ext4 nvme ahci" \
  "/boot/initramfs-$KVER.img" "$KVER"

mkdir -p "$MNT/boot/EFI/BOOT" "$MNT/boot/loader/entries"
cp "$MNT/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "$MNT/boot/EFI/BOOT/BOOTX64.EFI"
cat > "$MNT/boot/loader/loader.conf" <<EOF
default tinystorm.conf
timeout 0
editor no
EOF
cat > "$MNT/boot/loader/entries/tinystorm.conf" <<EOF
title $NAME $VERSION
linux /vmlinuz-$KVER
initrd /initramfs-$KVER.img
options ${KARGS/root_karg_placeholder/root=UUID=$ROOT_UUID}
EOF

# ---- shrink ----------------------------------------------------------------
if [ "$PROFILE" = tinycloudinit ]; then
  # the initramfs is built; the tool to rebuild it is dead weight in an image
  # that gets updated by rebuilding (cpio is dracut's, nothing else needs it)
  dnf5 -y --use-host-config --installroot="$MNT" --releasever="$RELEASEVER" \
    remove dracut cpio
fi
dnf5 -y --use-host-config --installroot="$MNT" --releasever="$RELEASEVER" clean all
rm -rf "$MNT"/var/cache/* "$MNT"/var/log/*.log "$MNT"/root/.bash_history

# console keymaps/fonts (kbd-misc): serial+ssh image, the console stays US
rm -rf "$MNT"/usr/lib/kbd

# terminfo: keep the terminals a VM console/ssh session actually presents
find "$MNT/usr/share/terminfo" -type f \
  ! -name 'linux*' ! -name 'vt10*' ! -name 'vt22*' ! -name 'xterm*' \
  ! -name 'screen*' ! -name 'tmux*' ! -name 'dumb' ! -name 'ansi*' -delete
find "$MNT/usr/share/terminfo" -type d -empty -delete

# the install transaction leaves the sqlite rpmdb full of free pages; a rebuild
# rewrites it compactly. dnf history/state is build-time noise either way.
RPMDB_BEFORE="$(du -sk "$MNT/usr/lib/sysimage/rpm" | cut -f1)"
rpm --root="$MNT" --rebuilddb
rm -rf "$MNT"/var/lib/dnf
echo "== rpmdb: $((RPMDB_BEFORE/1024)) MiB -> $(($(du -sk "$MNT/usr/lib/sysimage/rpm" | cut -f1)/1024)) MiB =="

# translations: ~45 MiB nothing in a headless image reads; C.UTF-8 lives in
# /usr/lib/locale (glibc-minimal-langpack) and stays
[ -d "$MNT/usr/share/locale" ] && find "$MNT/usr/share/locale" -mindepth 1 -delete

# udev hardware database: ~10 MiB of USB/PCI IDs and physical-hardware quirk
# tables (keyboards, mice, sensors). Virtio devices need none of it; udevd just
# logs that hwdb.bin is absent and carries on.
rm -rf "$MNT"/usr/lib/udev/hwdb.d "$MNT"/usr/lib/udev/hwdb.bin "$MNT"/etc/udev/hwdb.bin

if [ "$PROFILE" = tinycloudinit ] && [ -d "$MNT/usr/share/zoneinfo" ]; then
  # UTC-only: keep UTC (and Etc/UTC, whose parent dir then can't be removed —
  # find -delete complains about the non-empty dir, hence the || true)
  find "$MNT/usr/share/zoneinfo" -mindepth 1 ! -name UTC -delete 2>/dev/null || true
  ln -sf ../usr/share/zoneinfo/UTC "$MNT/etc/localtime"
fi

umount -R "$MNT/dev" "$MNT/proc" "$MNT/sys"
fstrim -v "$MNT/boot" || true
fstrim -v "$MNT" || true
df -h "$MNT" "$MNT/boot"
umount "$MNT/boot" "$MNT"
losetup -d "$LOOP"; LOOP=""

qemu-img convert -O qcow2 -c "$IMG" "$QCOW"
echo "== artifacts ($PROFILE) =="
ls -lhs "$IMG" "$QCOW"
