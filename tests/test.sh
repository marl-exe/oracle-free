#!/usr/bin/env bash
# All mocked: never connects to Oracle or invokes a real OCI CLI.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bash -n "$ROOT/oracle-free.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh"
echo "PASS: Bash syntax"

TESTDIR=$(mktemp -d)
trap 'rm -rf -- "$TESTDIR"' EXIT
export HOME="$TESTDIR/home"
export ORACLE_FREE_CONFIG="$TESTDIR/config"
export PATH="$TESTDIR/bin:/usr/bin:/bin"
mkdir -p "$HOME/.oci" "$HOME/.ssh" "$TESTDIR/bin"
printf 'mock OCI config\n' > "$HOME/.oci/config"
printf 'ssh-ed25519 AAAATESTONLY test@example.invalid\n' > "$HOME/.ssh/oracle-free-key.pub"
cat > "$ORACLE_FREE_CONFIG" <<'EOF'
REGION="ap-singapore-1"
COMPARTMENT_OCID="ocid1.compartment.oc1..TESTONLY"
SUBNET_OCID="ocid1.subnet.oc1..TESTONLY"
INSTANCE_NAME="oracle-free-retry"
RETRY_SECONDS=900
SHAPE_SPACING_SECONDS=120
THROTTLE_SECONDS=1800
MAX_THROTTLE_SECONDS=3600
EOF

cat > "$TESTDIR/bin/oci" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$HOME/mock-oci-calls"
case "$1 $2 $3" in
  "compute instance list")
    if [[ "${MOCK_MODE:-}" == existing ]]; then
      printf '{"data":[{"id":"ocid1.instance.oc1..EXISTING","lifecycle-state":"RUNNING"}]}\n'
    else
      printf '{"data":[]}\n'
    fi
    ;;
  "compute instance get") printf 'RUNNING\n' ;;
  "iam availability-domain list") printf 'test:AD-1\n' ;;
  "compute image list") printf 'ocid1.image.oc1..TESTONLY\n' ;;
  "compute instance launch")
    if [[ "${MOCK_MODE:-}" == timeout ]]; then
      printf '{"status":504,"code":"ServiceUnavailable"}\n' >&2
      exit 1
    elif [[ "${MOCK_MODE:-}" == limited ]]; then
      printf '{"status":429,"code":"TooManyRequests"}\n' >&2
      exit 1
    elif [[ "${MOCK_MODE:-}" == denied ]]; then
      printf '{"status":403,"code":"NotAuthorizedOrNotFound"}\n' >&2
      exit 1
    elif [[ " $* " == *' VM.Standard.E2.1.Micro '* ]]; then
      printf '{"status":500,"code":"OutOfHostCapacity"}\n' >&2
      exit 1
    else
      printf 'ocid1.instance.oc1..TESTONLY\n'
    fi
    ;;
  *) echo "Unexpected OCI command: $*" >&2; exit 91 ;;
esac
EOF
cat > "$TESTDIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# Skip inter-shape sleep; stop when entering a retry cooldown to avoid a loop.
if [[ "$1" -gt 120 ]]; then exit 95; fi
exit 0
EOF
chmod +x "$TESTDIR/bin/oci" "$TESTDIR/bin/sleep"
rm -f "$HOME/mock-oci-calls"

run_case() {
  local expected="$1" mode="$2" output="$TESTDIR/$mode.out" actual
  set +e
  MOCK_MODE="$mode" /usr/bin/bash "$ROOT/oracle-free.sh" >"$output" 2>&1
  actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || {
    echo "FAIL: $mode exited $actual, expected $expected" >&2
    cat "$output" >&2
    exit 1
  }
}

run_case 0 normal
[[ -f "$HOME/.oracle-free-provisioned" ]] || { echo "FAIL: missing success marker"; exit 1; }
[[ ! -e "$HOME/.oracle-free-launch-pending" ]] || { echo "FAIL: stale pending marker"; exit 1; }
grep -q 'VM.Standard.E2.1.Micro' "$HOME/mock-oci-calls"
grep -q 'VM.Standard.A1.Flex' "$HOME/mock-oci-calls"
echo "PASS: AMD capacity -> ARM accepted -> RUNNING -> success marker"

before=$(wc -l < "$HOME/mock-oci-calls")
run_case 0 normal
after=$(wc -l < "$HOME/mock-oci-calls")
[[ "$before" -eq "$after" ]] || { echo "FAIL: launched after success"; exit 1; }
echo "PASS: repeated invocation does not call OCI after success"

rm -f "$HOME/.oracle-free-provisioned"
printf 'unknown\n' > "$HOME/.oracle-free-launch-pending"
run_case 78 pending
[[ -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: interrupted launch blocks new launch"

rm -f "$HOME/.oracle-free-launch-pending"
run_case 78 timeout
[[ -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: ambiguous network failure blocks future launches"

rm -f "$HOME/.oracle-free-launch-pending"
run_case 95 limited
[[ ! -e "$HOME/.oracle-free-launch-pending" ]]
grep -q 'Rate limit cooldown: 1800 seconds' "$TESTDIR/limited.out"
echo "PASS: explicit HTTP 429 clears marker and applies cooldown"

run_case 1 denied
[[ -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: permanent authorization error stops and preserves marker"

rm -f "$HOME/.oracle-free-launch-pending"
run_case 0 existing
[[ -e "$HOME/.oracle-free-provisioned" ]]
echo "PASS: existing instance is adopted without launching"

echo "All mocked tests passed. No real OCI API calls were made."
