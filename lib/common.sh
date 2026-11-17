# shellcheck shell=bash
# Shared by the scripts of this repository. Sourced, not run.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Fixed by design. Changing any of these means changing the templates and the image too.
MOUNT_POINT=/srv/gitstick
REPOS_DIR=$MOUNT_POINT/git
MOUNT_UNIT=srv-gitstick.mount          # = systemd-escape --path --suffix=mount $MOUNT_POINT
SERVICE_UNIT=gitstick.service
CLEANUP_UNITS=(gitstick-cleanup.service gitstick-cleanup.timer)
LISTEN=127.0.0.1:9418
SERVER_UID=1000
SERVER_GID=1000
IMAGE=local/gitstick:2
OPT_DIR=/opt/gitstick
UNIT_DIR=/etc/systemd/system
UDEV_RULE=/etc/udev/rules.d/99-gitstick.rules

die() { echo "error: $*" >&2; exit 1; }
log() { echo "== $*"; }

need_root() {
  [ "$(id -u)" = 0 ] || die "run as root, e.g. ./as-root $0 $*"
}

# Reads config.env as plain KEY=VALUE lines. It is parsed, never sourced, so it can't run code.
# $1 = "full" (serial and UUID required) or "serial" (UUID may still be the placeholder).
load_config() {
  local need=${1:-full} f=${CONFIG:-$REPO_DIR/config.env} line key val n=0
  [ -f "$f" ] || die "$f not found: copy config.example.env to config.env and fill it in"
  CONFIG_FILE=$f
  STICK_SERIAL='' STICK_FS_UUID='' STICK_NAME='USB stick'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$f:$n: not a KEY=VALUE line"
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    [[ "$val" =~ ^\"(.*)\"$ ]] && val=${BASH_REMATCH[1]}
    case "$key" in
      STICK_SERIAL) STICK_SERIAL=$val ;;
      STICK_FS_UUID) STICK_FS_UUID=$val ;;
      STICK_NAME) STICK_NAME=$val ;;
      *) die "$f:$n: unknown setting $key" ;;
    esac
  done < "$f"
  [[ "$STICK_SERIAL" =~ ^[A-Za-z0-9_.-]{4,64}$ ]] || die "STICK_SERIAL '$STICK_SERIAL' isn't a USB serial number (see README)"
  [[ "$STICK_NAME" =~ ^[A-Za-z0-9\ ._()-]{1,60}$ ]] || die "STICK_NAME may only hold letters, digits, spaces and ._()-"
  if [ "$need" = full ]; then
    [[ "$STICK_FS_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
      || die "STICK_FS_UUID '$STICK_FS_UUID' isn't an ext4 UUID (format-stick fills it in)"
  fi
  STICK_FS_UUID_ESC=${STICK_FS_UUID//-/\\x2d}          # systemd's escaping of '-' in unit names
  DEVICE_UNIT="dev-disk-by\\x2duuid-${STICK_FS_UUID_ESC}.device"
  FSCK_UNIT="systemd-fsck@dev-disk-by\\x2duuid-${STICK_FS_UUID_ESC}.service"
}

# render TEMPLATE > stdout: fills @STICK_SERIAL@, @STICK_FS_UUID@, @STICK_FS_UUID_ESC@, @STICK_NAME@.
render() {
  local t
  t=$(cat "$1"; printf x); t=${t%x}
  t=${t//"@STICK_FS_UUID_ESC@"/"$STICK_FS_UUID_ESC"}
  t=${t//"@STICK_FS_UUID@"/"$STICK_FS_UUID"}
  t=${t//"@STICK_SERIAL@"/"$STICK_SERIAL"}
  t=${t//"@STICK_NAME@"/"$STICK_NAME"}
  if [[ "$t" =~ @[A-Z_]+@ ]]; then die "$1: placeholder ${BASH_REMATCH[0]} left unfilled"; fi
  printf '%s' "$t"
}

# The block device (e.g. /dev/sda) whose USB serial is STICK_SERIAL; dies unless there is exactly one.
stick_disk() {
  local found
  found=$(lsblk -dnpo NAME,SERIAL,TRAN | awk -v s="$STICK_SERIAL" '$2 == s && $3 == "usb" {print $1}')
  [ -n "$found" ] || return 1
  [ "$(printf '%s\n' "$found" | wc -l)" = 1 ] || die "more than one USB disk with serial $STICK_SERIAL"
  printf '%s\n' "$found"
}

# The USB device directory in sysfs (e.g. /sys/bus/usb/devices/6-2) with serial STICK_SERIAL.
stick_usb_dir() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/serial" ] && [ "$(cat "$d/serial")" = "$STICK_SERIAL" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

stick_mounted_rw() {
  findmnt -rn --mountpoint "$MOUNT_POINT" --source "UUID=$STICK_FS_UUID" --types ext4 --options rw >/dev/null
}

# Runs a command as SERVER_UID:SERVER_GID (the owner of everything on the stick).
as_server_user() {
  setpriv --reuid="$SERVER_UID" --regid="$SERVER_GID" --clear-groups -- \
    env HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent "$@"
}

# git inside the server image, as SERVER_UID, no network, with the stick's git/ at /srv/git.
# $1 = ro|rw, rest = git arguments.
image_git() {
  local mode=$1; shift
  local opt=""; [ "$mode" = ro ] && opt=",readonly"
  docker run --rm --network none --user "$SERVER_UID:$SERVER_GID" --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --pull=never \
    --mount "type=bind,source=$REPOS_DIR,target=/srv/git$opt" \
    --entrypoint git "$IMAGE" "$@"
}
