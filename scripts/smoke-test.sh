#!/usr/bin/env bash
# Boot the built image under QEMU/OVMF with a NoCloud seed and wait for
# cloud-init to finish and a serial login prompt. Runs as root on the build box.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$HERE/VERSION")"
WORK=/build/images/tinystorm
IMG="$WORK/tinystorm-${VERSION}.raw"
TESTDIR="$WORK/smoke"
SEED="$TESTDIR/seed.img"
DISK="$TESTDIR/test.raw"
LOG="$TESTDIR/serial.log"
TIMEOUT="${SMOKE_TIMEOUT:-420}"

command -v qemu-system-x86_64 >/dev/null || dnf5 -y install qemu-system-x86-core edk2-ovmf
OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd
[ -f "$OVMF_CODE" ] || { echo "OVMF not found at $OVMF_CODE" >&2; exit 1; }

mkdir -p "$TESTDIR"
rm -f "$SEED" "$DISK" "$LOG"
cp --sparse=always "$IMG" "$DISK"
cp "$OVMF_VARS" "$TESTDIR/vars.fd"

# NoCloud seed: vfat labeled 'cidata' with user-data/meta-data
truncate -s 4M "$SEED"
mkfs.fat -n CIDATA "$SEED" >/dev/null
SEEDMNT="$TESTDIR/seedmnt"
mkdir -p "$SEEDMNT"
mount -o loop "$SEED" "$SEEDMNT"
cat > "$SEEDMNT/user-data" <<'EOF'
#cloud-config
password: tinystorm
chpasswd: { expire: false }
ssh_pwauth: true
runcmd:
  - echo "TINYSTORM_SMOKE_OK $(uname -r)" > /dev/ttyS0
EOF
cat > "$SEEDMNT/meta-data" <<'EOF'
instance-id: tinystorm-smoke-1
local-hostname: tinystorm-smoke
EOF
umount "$SEEDMNT"

ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
qemu-system-x86_64 -machine q35,accel=$ACCEL -m 1024 -smp 2 -display none \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$TESTDIR/vars.fd" \
  -drive if=virtio,format=raw,file="$DISK" \
  -drive if=virtio,format=raw,file="$SEED" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -serial "file:$LOG" -pidfile "$TESTDIR/qemu.pid" -daemonize

for _ in $(seq "$TIMEOUT"); do
  if grep -q "TINYSTORM_SMOKE_OK" "$LOG" 2>/dev/null && grep -q "login:" "$LOG"; then
    kill "$(cat "$TESTDIR/qemu.pid")" 2>/dev/null || true
    echo "SMOKE TEST PASSED ($ACCEL)"
    grep -E "TINYSTORM_SMOKE_OK|Cloud-init .* finished" "$LOG" | tail -3
    exit 0
  fi
  sleep 1
done

kill "$(cat "$TESTDIR/qemu.pid")" 2>/dev/null || true
echo "SMOKE TEST FAILED — last serial output:" >&2
tail -40 "$LOG" >&2
exit 1
