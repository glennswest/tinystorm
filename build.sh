#!/usr/bin/env bash
# tinystorm — build the tiniest bootable Fedora cloud image.
# Runs as root on the build box (Fedora host matching RELEASEVER).
# Artifacts land in /build/images/tinystorm — never on the SSD root, never /tmp.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$HERE/VERSION")"
RELEASEVER=43
IMG_SIZE=3G          # sparse; cloud-init growpart expands to the real disk
ESP_MIB=256
WORK=/build/images/tinystorm
IMG="$WORK/tinystorm-${VERSION}.raw"
QCOW="$WORK/tinystorm-${VERSION}.qcow2"
MNT="$WORK/mnt"

PACKAGES=(
  kernel-core
  systemd systemd-udev systemd-networkd systemd-resolved systemd-boot-unsigned
  dracut
  bash coreutils-single util-linux-core glibc-minimal-langpack libcurl-minimal
  dnf5
  openssh-server
  cloud-init cloud-utils-growpart e2fsprogs
  shadow-utils sudo iproute
  dbus-broker
)

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
type=linux, name=root
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

cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID  /      ext4  defaults,noatime          0 1
UUID=$ESP_UUID   /boot  vfat  umask=0077,shortname=lower 0 2
EOF

# resolved owns /etc/resolv.conf
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

# empty machine-id -> first-boot semantics, regenerated per instance
: > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"

for unit in systemd-networkd systemd-resolved sshd \
            cloud-init-local cloud-init cloud-config cloud-final; do
  if [ -e "$MNT/usr/lib/systemd/system/$unit.service" ]; then
    systemctl --root="$MNT" enable "$unit.service"
  else
    echo "WARN: unit $unit.service not present, skipping" >&2
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
title tinystorm $VERSION
linux /vmlinuz-$KVER
initrd /initramfs-$KVER.img
options root=UUID=$ROOT_UUID rw console=tty0 console=ttyS0,115200n8 selinux=0
EOF

# ---- shrink ----------------------------------------------------------------
dnf5 -y --use-host-config --installroot="$MNT" --releasever="$RELEASEVER" clean all
rm -rf "$MNT"/var/cache/* "$MNT"/var/log/*.log "$MNT"/root/.bash_history

umount -R "$MNT/dev" "$MNT/proc" "$MNT/sys"
fstrim -v "$MNT" || true
df -h "$MNT" "$MNT/boot"
umount "$MNT/boot" "$MNT"
losetup -d "$LOOP"; LOOP=""

qemu-img convert -O qcow2 -c "$IMG" "$QCOW"
echo "== artifacts =="
ls -lhs "$IMG" "$QCOW"
