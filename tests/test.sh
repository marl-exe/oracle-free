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
  "iam availability-domain list") printf '{"data":[{"name":"test:AD-1"},{"name":"test:AD-2"},{"name":"test:AD-3"}]}\n' ;;
  "compute instance list-vnics")
    if [[ "${MOCK_MODE:-}" == noip ]]; then exit 77; fi
    printf '203.0.113.42\n'
    ;;
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
    elif [[ "${MOCK_MODE:-}" == all_capacity ]]; then
      printf '{"status":500,"code":"OutOfHostCapacity"}\n' >&2
      exit 1
    elif [[ "${MOCK_MODE:-}" == rotate && " $* " == *' --availability-domain test:AD-1 '* ]]; then
      printf '{"status":500,"code":"OutOfHostCapacity"}\n' >&2
      exit 1
    elif [[ "${MOCK_MODE:-}" == rotate_cfg && " $* " == *' --availability-domain test:AD-2 '* ]]; then
      printf '{"status":500,"code":"OutOfHostCapacity"}\n' >&2
      exit 1
    else
      printf 'ocid1.instance.oc1..TESTONLY\n'
    fi
    ;;
  *) echo "Unexpected OCI command: $*" >&2; exit 91 ;;
esac
EOF
cat > "$TESTDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Mock Discord: capture URL from config stdin and JSON argument; never network.
cat >> "$HOME/mock-curl-configs"
printf '%s\n' "$*" >> "$HOME/mock-curl-args"
[[ "${MOCK_CURL_FAIL:-0}" == 0 ]]
EOF
cat > "$TESTDIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# Skip inter-shape sleep; stop when entering a retry cooldown to avoid a loop.
if [[ "$1" -gt 120 ]]; then exit 95; fi
exit 0
EOF
chmod +x "$TESTDIR/bin/oci" "$TESTDIR/bin/sleep" "$TESTDIR/bin/curl"
rm -f "$HOME/mock-oci-calls"

run_case() {
  local expected="$1" mode="$2" output actual
  output="$TESTDIR/$mode.out"
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
grep -q 'Public IP: 203.0.113.42' "$TESTDIR/normal.out"
grep -q -- '--shape-config {"ocpus":1,"memoryInGBs":6}' "$HOME/mock-oci-calls"
echo "PASS: AMD capacity -> ARM 1/6 accepted -> RUNNING -> IP and success marker"

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

rm -f "$HOME/.oracle-free-provisioned"
: > "$HOME/mock-oci-calls"
run_case 0 rotate
grep -q 'No host capacity for VM.Standard.A1.Flex in test:AD-1' "$TESTDIR/rotate.out"
grep -q 'Trying VM.Standard.A1.Flex in test:AD-2' "$TESTDIR/rotate.out"
[[ ! -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: auto ARM multi-AD rotation, capacity then success"

rm -f "$HOME/.oracle-free-provisioned"
: > "$HOME/mock-oci-calls"
run_case 95 all_capacity
[[ ! -e "$HOME/.oracle-free-launch-pending" ]]
for ad in test:AD-1 test:AD-2 test:AD-3; do
  grep -q "No host capacity for VM.Standard.A1.Flex in $ad" "$TESTDIR/all_capacity.out"
done
echo "PASS: all ARM ADs exhausted before cooldown"

printf 'ARM_AVAILABILITY_DOMAINS="test:AD-2,test:AD-3"\n' >> "$ORACLE_FREE_CONFIG"
: > "$HOME/mock-oci-calls"
run_case 0 rotate_cfg
grep -q 'Trying VM.Standard.A1.Flex in test:AD-2' "$TESTDIR/rotate_cfg.out"
grep -q 'Trying VM.Standard.A1.Flex in test:AD-3' "$TESTDIR/rotate_cfg.out"
! grep -q 'Trying VM.Standard.A1.Flex in test:AD-1' "$TESTDIR/rotate_cfg.out"
echo "PASS: explicit ARM AD ordering and selection"

rm -f "$HOME/.oracle-free-provisioned"
printf 'ARM_OCPUS=2\nARM_MEMORY_GB=12\n' >> "$ORACLE_FREE_CONFIG"
run_case 0 normal
grep -q -- '--shape-config {"ocpus":2,"memoryInGBs":12}' "$HOME/mock-oci-calls"
echo "PASS: configurable ARM sizing 2 OCPU / 12 GB"

rm -f "$HOME/.oracle-free-provisioned"
printf 'ARM_OCPUS=3\n' >> "$ORACLE_FREE_CONFIG"
before=$(wc -l < "$HOME/mock-oci-calls")
run_case 78 invalid_size
after=$(wc -l < "$HOME/mock-oci-calls")
[[ "$before" -eq "$after" ]]
sed -i '$d' "$ORACLE_FREE_CONFIG"
echo "PASS: reject ARM sizing outside configured guardrails"

printf 'ARM_AVAILABILITY_DOMAINS="test:AD-UNKNOWN"\n' >> "$ORACLE_FREE_CONFIG"
run_case 78 invalid_ad
sed -i '$d' "$ORACLE_FREE_CONFIG"
echo "PASS: reject unknown ARM AD"

printf 'DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/123456/TESTTOKENONLY"\n' >> "$ORACLE_FREE_CONFIG"
: > "$HOME/mock-curl-configs"
: > "$HOME/mock-curl-args"
run_case 0 discord
grep -q 'https://discord.com/api/webhooks/123456/TESTTOKENONLY' "$HOME/mock-curl-configs"
grep -q 'Oracle Free SUCCESS' "$HOME/mock-curl-args"
grep -q '203.0.113.42' "$HOME/mock-curl-args"
! grep -q 'TESTTOKENONLY' "$HOME/mock-curl-args"
! grep -q 'TESTTOKENONLY' "$TESTDIR/discord.out"
echo "PASS: Discord startup/success JSON; webhook token absent from argv and logs"

rm -f "$HOME/.oracle-free-provisioned"
MOCK_CURL_FAIL=1 run_case 0 discord_failed
[[ -e "$HOME/.oracle-free-provisioned" ]]
echo "PASS: Discord failure does not affect instance success"

rm -f "$HOME/.oracle-free-provisioned"
run_case 0 noip
grep -q 'Public IP: unavailable' "$TESTDIR/noip.out"
[[ -e "$HOME/.oracle-free-provisioned" ]]
echo "PASS: public IP lookup failure does not affect success"

echo "All mocked tests passed. No real OCI API calls were made."
