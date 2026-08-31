#!/usr/bin/env bash
# Boot the built image under QEMU/OVMF with a NoCloud/Proxmox-style cidata seed.
#   cloud (default): wait for cloud-init to finish and a serial login prompt.
#   tinycloudinit:   ssh in as fedora with the afterburn-injected key, check
#                    sudo and that systemd-repart grew the root fs.
# Runs as root on the build box. PROFILE=tinycloudinit ./scripts/smoke-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$HERE/VERSION")"
PROFILE="${PROFILE:-cloud}"
case "$PROFILE" in
  cloud) NAME="tinystorm" ;;
  tinycloudinit) NAME="tinycloudinit" ;;
  *) echo "unknown PROFILE '$PROFILE'" >&2; exit 1 ;;
esac
WORK=/build/images/tinystorm
IMG="$WORK/${NAME}-${VERSION}.raw"
TESTDIR="$WORK/smoke-$PROFILE"
SEED="$TESTDIR/seed.img"
DISK="$TESTDIR/test.raw"
LOG="$TESTDIR/serial.log"
TIMEOUT="${SMOKE_TIMEOUT:-420}"
SSH_PORT=2322

command -v qemu-system-x86_64 >/dev/null || dnf5 -y install qemu-system-x86-core edk2-ovmf
OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd
[ -f "$OVMF_CODE" ] || { echo "OVMF not found at $OVMF_CODE" >&2; exit 1; }

mkdir -p "$TESTDIR"
# kill a stale VM from an aborted previous run (it would hold the ssh port)
{ pkill -f "hostfwd=tcp:127.0.0.1:$SSH_PORT" && sleep 1; } || true
rm -f "$SEED" "$DISK" "$LOG" "$TESTDIR/qemu.pid" "$TESTDIR/id_smoke"*
cp --sparse=always "$IMG" "$DISK"
truncate -s 5G "$DISK"          # bigger than the 3G image: growth must kick in
cp "$OVMF_VARS" "$TESTDIR/vars.fd"

ssh-keygen -q -t ed25519 -N '' -f "$TESTDIR/id_smoke"
PUBKEY="$(cat "$TESTDIR/id_smoke.pub")"

# seed: ISO9660 labeled 'cidata', Proxmox-style. afterburn mounts the device
# explicitly as iso9660 and requires user-data, meta-data, vendor-data AND
# network-config to all exist (Proxmox always writes all four).
command -v xorriso >/dev/null || dnf5 -y install xorriso
SEEDFILES="$TESTDIR/seedfiles"
rm -rf "$SEEDFILES"; mkdir -p "$SEEDFILES"
cat > "$SEEDFILES/user-data" <<EOF
#cloud-config
hostname: ${NAME}-smoke
password: tinystorm
chpasswd: { expire: false }
ssh_pwauth: true
ssh_authorized_keys:
  - $PUBKEY
runcmd:
  - echo "TINYSTORM_SMOKE_OK \$(uname -r)" > /dev/ttyS0
EOF
cat > "$SEEDFILES/meta-data" <<EOF
instance-id: ${NAME}-smoke-1
local-hostname: ${NAME}-smoke
EOF
echo '{}' > "$SEEDFILES/vendor-data"
printf 'version: 1\nconfig: []\n' > "$SEEDFILES/network-config"
xorriso -as mkisofs -quiet -volid cidata -joliet -rock -o "$SEED" "$SEEDFILES"

ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
qemu-system-x86_64 -machine q35,accel=$ACCEL -m 1024 -smp 2 -display none \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$TESTDIR/vars.fd" \
  -drive if=virtio,format=raw,file="$DISK" \
  -drive if=virtio,format=raw,file="$SEED" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=n0 \
  -serial "file:$LOG" -pidfile "$TESTDIR/qemu.pid" -daemonize

stop_qemu() { kill "$(cat "$TESTDIR/qemu.pid")" 2>/dev/null || true; }

if [ "$PROFILE" = cloud ]; then
  for _ in $(seq "$TIMEOUT"); do
    if grep -q "TINYSTORM_SMOKE_OK" "$LOG" 2>/dev/null && grep -q "login:" "$LOG"; then
      stop_qemu
      echo "SMOKE TEST PASSED ($PROFILE/$ACCEL)"
      grep -E "TINYSTORM_SMOKE_OK|Cloud-init .* finished" "$LOG" | tail -3
      exit 0
    fi
    sleep 1
  done
else
  SSH=(ssh -p "$SSH_PORT" -i "$TESTDIR/id_smoke" -o StrictHostKeyChecking=no
       -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes
       fedora@127.0.0.1)
  for _ in $(seq "$TIMEOUT"); do
    if OUT="$("${SSH[@]}" 'echo "MICRO_OK $(hostname) $(sudo -n id -u) $(findmnt -bno size /)"' 2>/dev/null)"; then
      stop_qemu
      read -r _ HOST SUDO_UID ROOT_SIZE <<< "$OUT"
      echo "ssh login OK: hostname=$HOST sudo_uid=$SUDO_UID rootfs=$((ROOT_SIZE/1024/1024)) MB"
      FAIL=0
      [ "$HOST" = "${NAME}-smoke" ] || { echo "FAIL: hostname not applied"; FAIL=1; }
      [ "$SUDO_UID" = 0 ] || { echo "FAIL: passwordless sudo broken"; FAIL=1; }
      # image root is ~2.7G; a grown fs on the 5G test disk is >4G
      [ "$ROOT_SIZE" -gt $((4*1024*1024*1024)) ] || { echo "FAIL: rootfs did not grow"; FAIL=1; }
      [ "$FAIL" = 0 ] && echo "SMOKE TEST PASSED ($PROFILE/$ACCEL)" && exit 0
      exit 1
    fi
    sleep 1
  done
fi

stop_qemu
echo "SMOKE TEST FAILED ($PROFILE) — last serial output:" >&2
tail -40 "$LOG" >&2
exit 1
