#!/usr/bin/env bash
# tinystorm — build the tiniest bootable Fedora cloud image.
# Runs as root on the build box (Fedora host matching RELEASEVER).
# Artifacts land in /build/images/tinystorm — never on the SSD root, never /tmp.
#
# Profiles (PROFILE env, default "cloud"):
#   cloud  — cloud-init: works with any cloud-init datasource, full user-data support
#   micro  — afterburn + systemd-repart/growfs: no Python, ~90 MiB smaller;
#            ssh keys/hostname/network from the Proxmox VE / NoCloud cidata drive,
#            baked `fedora` user, platform pinned via ignition.platform.id=proxmoxve
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
  micro) NAME="tinystorm-micro" ;;
  *) echo "unknown PROFILE '$PROFILE' (cloud|micro)" >&2; exit 1 ;;
esac
IMG="$WORK/${NAME}-${VERSION}.raw"
QCOW="$WORK/${NAME}-${VERSION}.qcow2"
MNT="$WORK/mnt"

PACKAGES=(
  kernel-core
  systemd systemd-udev systemd-networkd systemd-resolved systemd-boot-unsigned
  dracut
  bash coreutils-single util-linux-core glibc-minimal-langpack libcurl-minimal
  dnf5
  openssh-server
  shadow-utils sudo iproute
  dbus-broker
)
UNITS=(systemd-networkd.service systemd-resolved.service sshd.service)
# GPT root-x86-64 type: enables systemd-repart Type=root matching and gpt-auto
ROOT_TYPE=4F68BCE3-1E14-4187-B907-06CE39F74A65
KARGS="root_karg_placeholder rw console=tty0 console=ttyS0,115200n8 selinux=0"

if [ "$PROFILE" = cloud ]; then
  PACKAGES+=(cloud-init cloud-utils-growpart e2fsprogs)
  # cloud-init >= 25 unit names (main/local/network); target ties them together
  UNITS+=(cloud-init-main.service cloud-init-local.service cloud-init-network.service
          cloud-config.service cloud-final.service cloud-init.target)
  GROWFS_OPT=""
else
  PACKAGES+=(afterburn)
  UNITS+=(afterburn-sshkeys.target afterburn-sshkeys@fedora.service
          tinystorm-metadata.service systemd-repart.service)
  GROWFS_OPT=",x-systemd.growfs"
  KARGS+=" ignition.platform.id=proxmoxve"
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
mkfs.fat -F32 -n ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L root "${LOOP}p2"
ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
ESP_UUID="$(blkid -s UUID -o value "${LOOP}p1")"

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

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

if [ "$PROFILE" = micro ]; then
  # cloud-init would create this on first boot; micro bakes it (locked password,
  # keys arrive via afterburn from the cidata drive)
  chroot "$MNT" useradd -m -G wheel -s /bin/bash fedora
  chmod 0440 "$MNT/etc/sudoers.d/wheel-nopasswd"
fi

for unit in "${UNITS[@]}"; do
  if [ -e "$MNT/usr/lib/systemd/system/$unit" ] || [ -e "$MNT/etc/systemd/system/$unit" ]; then
    systemctl --root="$MNT" enable "$unit"
  else
    echo "WARN: unit $unit not present, skipping" >&2
  fi
done

# ---- kernel, initramfs, bootloader ----------------------------------------
# kernel-install usually skips in a chroot (no machine-id); place files ourselves.
rm -rf "$MNT"/boot/loader "$MNT"/boot/[0-9a-f]*[0-9a-f] 2>/dev/null || true
cp "$MNT/lib/modules/$KVER/vmlinuz" "$MNT/boot/vmlinuz-$KVER"

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
dnf5 -y --use-host-config --installroot="$MNT" --releasever="$RELEASEVER" clean all
rm -rf "$MNT"/var/cache/* "$MNT"/var/log/*.log "$MNT"/root/.bash_history

umount -R "$MNT/dev" "$MNT/proc" "$MNT/sys"
fstrim -v "$MNT/boot" || true
fstrim -v "$MNT" || true
df -h "$MNT" "$MNT/boot"
umount "$MNT/boot" "$MNT"
losetup -d "$LOOP"; LOOP=""

qemu-img convert -O qcow2 -c "$IMG" "$QCOW"
echo "== artifacts ($PROFILE) =="
ls -lhs "$IMG" "$QCOW"
