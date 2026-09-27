#!/usr/bin/env bash
# Environmental and interoperability verification. Unlike the deterministic E2E suite, missing
# hardware, permissions, credentials, public-network reachability, or an opt-in scope is SKIP—not
# PASS. A supplied boundary that produces the wrong result is FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/toolchain_preflight.sh" || exit 1

ENV_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pathem-env.XXXXXX")"
FTP_PID=""
SSHD_PID=""
APP_PID=""
cleanup() {
  for process_id in "$APP_PID" "$FTP_PID" "$SSHD_PID"; do
    if [[ -n "$process_id" ]]; then
      kill -TERM "$process_id" 2>/dev/null || true
      wait "$process_id" 2>/dev/null || true
    fi
  done
  if [[ "$ENV_SCRATCH" == *pathem-env.* ]]; then rm -rf "$ENV_SCRATCH"; fi
}
trap cleanup EXIT

XCODE_SWIFT="$(xcrun --toolchain XcodeDefault --find swift)"
green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; dim=$'\033[2m'; reset=$'\033[0m'
passed=0; failed=0; skipped=0

timeout_run() { perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$@"; }

scenario() {
  local name="$1"; shift
  local output result
  output="$(timeout_run 180 "$@" 2>&1)"
  result="$(grep -oE 'RESULT: (PASS|SKIP|FAIL).*' <<<"$output" | tail -1)"
  case "$result" in
    "RESULT: PASS"*)
      printf "  %sPASS%s  %-38s %s%s%s\n" "$green" "$reset" "$name" "$dim" "${result#RESULT: PASS  }" "$reset"
      passed=$((passed + 1))
      ;;
    "RESULT: SKIP"*)
      printf "  %sSKIP%s  %-38s %s%s%s\n" "$yellow" "$reset" "$name" "$dim" "${result#RESULT: SKIP  }" "$reset"
      skipped=$((skipped + 1))
      ;;
    *)
      printf "  %sFAIL%s  %-38s %s\n" "$red" "$reset" "$name" "${result:-no RESULT line}"
      tail -12 <<<"$output" | sed 's/^/        /'
      failed=$((failed + 1))
      ;;
  esac
}

skip() {
  printf "  %sSKIP%s  %-38s %s%s%s\n" "$yellow" "$reset" "$1" "$dim" "$2" "$reset"
  skipped=$((skipped + 1))
}

pass() {
  printf "  %sPASS%s  %-38s %s%s%s\n" "$green" "$reset" "$1" "$dim" "$2" "$reset"
  passed=$((passed + 1))
}

echo "==> Building environmental probe and app"
"$XCODE_SWIFT" build --build-system native --product pathem-env-probe >/dev/null || exit 1
"$XCODE_SWIFT" build --build-system native --product Pathem >/dev/null || exit 1
BIN_DIR="$("$XCODE_SWIFT" build --build-system native --show-bin-path)"
PROBE="$BIN_DIR/pathem-env-probe"
APP="$BIN_DIR/Pathem"

echo "==> Host boundaries"
scenario "cross-volume + image lifecycle" "$PROBE" storage
scenario "25k-file real enumeration" "$PROBE" large-tree
scenario "shell + arbitrary external tool" "$PROBE" external-tool
scenario "permission-state probes" "$XCODE_SWIFT" "$ROOT/test/environmental/permission_probe.swift"

export PATHEM_CONFIG_DIR="$ENV_SCRATCH/config"
env PATHEM_DEMO=1 PATHEM_CONFIG_DIR="$PATHEM_CONFIG_DIR" "$APP" >"$ENV_SCRATCH/app.log" 2>&1 &
APP_PID=$!
for _ in {1..40}; do
  kill -0 "$APP_PID" 2>/dev/null || break
  window_count="$("$XCODE_SWIFT" "$ROOT/test/e2e/window_probe.swift" "$APP_PID" 2>/dev/null || true)"
  [[ "$window_count" =~ ^[1-9][0-9]*$ ]] && break
  sleep 0.1
done
scenario "external accessibility tree" "$XCODE_SWIFT" "$ROOT/test/environmental/accessibility_probe.swift" "$APP_PID"
kill -TERM "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

echo "==> Hermetic protocol interoperability"
FTP_ROOT="$ENV_SCRATCH/ftp-root"
FTP_PORT_FILE="$ENV_SCRATCH/ftp-port"
/usr/bin/python3 "$ROOT/test/environmental/ftp_fixture.py" \
  --root "$FTP_ROOT" --port-file "$FTP_PORT_FILE" >"$ENV_SCRATCH/ftp.log" 2>&1 &
FTP_PID=$!
for _ in {1..100}; do
  [[ -s "$FTP_PORT_FILE" ]] && break
  kill -0 "$FTP_PID" 2>/dev/null || break
  sleep 0.02
done

SFTP_ROOT="$ENV_SCRATCH/sftp-root"
mkdir -p "$SFTP_ROOT" "$ENV_SCRATCH/client-home/.ssh"
chmod 700 "$ENV_SCRATCH/client-home/.ssh"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$ENV_SCRATCH/client-key"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$ENV_SCRATCH/host-key"
cp "$ENV_SCRATCH/client-key.pub" "$ENV_SCRATCH/authorized_keys"
chmod 600 "$ENV_SCRATCH/authorized_keys" "$ENV_SCRATCH/client-key"
SFTP_PORT="$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
SFTP_USER="$(id -un)"
cat >"$ENV_SCRATCH/sshd_config" <<EOF
Port $SFTP_PORT
ListenAddress 127.0.0.1
HostKey $ENV_SCRATCH/host-key
AuthorizedKeysFile $ENV_SCRATCH/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $ENV_SCRATCH/sshd.pid
LogLevel ERROR
Subsystem sftp internal-sftp
AllowUsers $SFTP_USER
EOF
/usr/sbin/sshd -D -e -f "$ENV_SCRATCH/sshd_config" >"$ENV_SCRATCH/sshd.log" 2>&1 &
SSHD_PID=$!
for _ in {1..100}; do
  if /usr/bin/nc -z 127.0.0.1 "$SFTP_PORT" 2>/dev/null; then break; fi
  kill -0 "$SSHD_PID" 2>/dev/null || break
  sleep 0.02
done

if [[ -s "$FTP_PORT_FILE" ]] && /usr/bin/nc -z 127.0.0.1 "$SFTP_PORT" 2>/dev/null; then
  scenario "loopback FTP + SFTP CRUD" env \
    HOME="$ENV_SCRATCH/client-home" \
    PATHEM_LOCAL_FTP_PORT="$(<"$FTP_PORT_FILE")" \
    PATHEM_LOCAL_SFTP_PORT="$SFTP_PORT" \
    PATHEM_LOCAL_SFTP_USER="$SFTP_USER" \
    PATHEM_LOCAL_SFTP_KEY="$ENV_SCRATCH/client-key" \
    PATHEM_LOCAL_SFTP_ROOT="$SFTP_ROOT" \
    "$PROBE" remote
else
  printf "  %sFAIL%s  %-38s\n" "$red" "$reset" "loopback FTP + SFTP fixtures"
  tail -8 "$ENV_SCRATCH/ftp.log" "$ENV_SCRATCH/sshd.log" 2>/dev/null | sed 's/^/        /'
  failed=$((failed + 1))
fi

echo "==> Opt-in host and public-network boundaries"
scenario "Spotlight indexed fixture" "$PROBE" spotlight
scenario "provider-backed listing" "$PROBE" provider-tree
scenario "online-only iCloud move" "$PROBE" icloud-eviction
scenario "public DHT lookup" "$PROBE" dht
scenario "router NAT-PMP / UPnP" "$PROBE" router
if [[ -n "${PATHEM_TRANSMISSION_DAEMON:-}" && -n "${PATHEM_TRANSMISSION_REMOTE:-}" ]]; then
  scenario "Transmission torrent transfer" env \
    PATHEM_TRANSMISSION_DAEMON="$PATHEM_TRANSMISSION_DAEMON" \
    PATHEM_TRANSMISSION_REMOTE="$PATHEM_TRANSMISSION_REMOTE" \
    "$ROOT/test/environmental/transmission_gate.sh"
else
  skip "Transmission torrent transfer" \
    "set PATHEM_TRANSMISSION_DAEMON and PATHEM_TRANSMISSION_REMOTE to opt in"
fi

if /usr/sbin/diskutil list external physical 2>/dev/null | grep -q '^/dev/'; then
  pass "physical external storage" "external physical disk detected; destructive checks intentionally excluded"
else
  skip "physical external storage" "no external physical disk attached"
fi
if /usr/sbin/system_profiler SPUSBDataType 2>/dev/null | grep -Eiq 'iPhone|iPad|Android'; then
  pass "physical mobile device" "USB mobile device detected"
else
  skip "physical mobile device" "no iOS/Android USB device detected"
fi
if /sbin/mount | grep -Eq ' on .* \((smbfs|nfs|webdavfs),'; then
  pass "mounted network share" "SMB/NFS/WebDAV mount detected"
else
  skip "mounted network share" "no supported network share mounted"
fi

echo
echo "==> $passed passed, $skipped skipped, $failed failed"
[[ $failed -eq 0 ]]
