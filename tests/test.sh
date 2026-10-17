#!/usr/bin/env bash
# All mocked: never connects to Oracle or invokes a real OCI CLI.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for script in oracle-free.sh install.sh uninstall.sh tests/test.sh tests/test-install-account.sh; do
  bash -n "$ROOT/$script"
done
echo "PASS: Bash syntax"
bash "$ROOT/tests/test-install-account.sh"

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
python3 -c 'import json,sys; print(json.dumps(sys.argv[2:]), file=open(sys.argv[1], "a"))' "$HOME/mock-oci-argv.jsonl" "$@"
case "$1 $2 $3" in
  "compute instance list")
    if [[ "${MOCK_MODE:-}" == existing || "${MOCK_MODE:-}" == pending_running || "${MOCK_MODE:-}" == pending_transition ]]; then
      printf '{"data":[{"id":"ocid1.instance.oc1..EXISTING","lifecycle-state":"RUNNING"}]}\n'
    elif [[ "${MOCK_MODE:-}" == multiple ]]; then
      printf '{"data":[{"id":"ocid1.instance.oc1..EXISTING1","lifecycle-state":"RUNNING"},{"id":"ocid1.instance.oc1..EXISTING2","lifecycle-state":"RUNNING"}]}\n'
    elif [[ "${MOCK_MODE:-}" == malformed ]]; then
      printf '{malformed json\n'
    else
      printf '{"data":[]}\n'
    fi
    ;;
  "compute instance get")
    if [[ "${MOCK_MODE:-}" == pending_transition ]]; then
      count_file="$HOME/mock-instance-get-count"
      count=0
      [[ ! -f "$count_file" ]] || read -r count < "$count_file"
      count=$((count + 1))
      printf '%s\n' "$count" > "$count_file"
      if [[ "$count" == 1 ]]; then printf 'PROVISIONING\n'; else printf 'RUNNING\n'; fi
    else
      printf 'RUNNING\n'
    fi
    ;;
  "iam availability-domain list") printf '{"data":[{"name":"test:AD-1"},{"name":"test:AD-2"},{"name":"test:AD-3"}]}\n' ;;
  "compute instance list-vnics")
    if [[ "${MOCK_MODE:-}" == noip ]]; then exit 77; fi
    printf '203.0.113.42\n'
    ;;
  "compute image list")
    shape=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == --shape ]]; then shape="$arg"; fi
      previous="$arg"
    done
    if [[ "${MOCK_MODE:-}" == both_images_empty || ( "${MOCK_MODE:-}" == amd_image_empty && "$shape" == VM.Standard.E2.1.Micro ) || ( "${MOCK_MODE:-}" == arm_image_empty && "$shape" == VM.Standard.A1.Flex ) ]]; then
      printf '{"data":[]}\n'
    elif [[ "$shape" == VM.Standard.E2.1.Micro && "${MOCK_MODE:-}" == image_auth ]]; then
      printf '{"status":401,"code":"NotAuthenticated"}\n' >&2
      exit 1
    elif [[ "$shape" == VM.Standard.E2.1.Micro && "${MOCK_MODE:-}" == image_429 ]]; then
      printf '{"status":429,"code":"TooManyRequests"}\n' >&2
      exit 1
    elif [[ "$shape" == VM.Standard.E2.1.Micro && "${MOCK_MODE:-}" == image_transient ]]; then
      printf '{"status":503,"code":"ServiceUnavailable"}\n' >&2
      exit 1
    elif [[ "$shape" == VM.Standard.E2.1.Micro && "${MOCK_MODE:-}" == image_unexpected ]]; then
      printf '{"status":400,"code":"InvalidParameter"}\n' >&2
      exit 1
    else
      printf '{"data":[{"id":"ocid1.image.oc1..TESTONLY"}]}\n'
    fi
    ;;
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

launch_count() {
  python3 - "$HOME/mock-oci-argv.jsonl" <<'PY'
import json,sys
with open(sys.argv[1], encoding="utf-8") as source:
    calls=[json.loads(line) for line in source if line.strip()]
print(sum(call[:3] == ["compute", "instance", "launch"] for call in calls))
PY
}

assert_launch_arguments() {
  python3 - "$HOME/mock-oci-argv.jsonl" <<'PY'
import json,sys
with open(sys.argv[1], encoding="utf-8") as source:
    calls=[json.loads(line) for line in source if line.strip()]
launches=[call for call in calls if call[:3] == ["compute", "instance", "launch"]]
assert launches, "no launch calls recorded"
def option(args, name):
    index=args.index(name)
    return args[index+1]
for args in launches:
    assert option(args, "--compartment-id").startswith("ocid1.compartment.")
    assert option(args, "--subnet-id").startswith("ocid1.subnet.")
    assert option(args, "--region") == "ap-singapore-1"
    assert option(args, "--availability-domain").startswith("test:AD-")
    assert option(args, "--image-id").startswith("ocid1.image.")
    assert option(args, "--boot-volume-size-in-gbs") == "50"
    assert option(args, "--assign-public-ip") == "true"
    assert "--no-retry" in args
    shape=option(args, "--shape")
    if shape == "VM.Standard.A1.Flex":
        config=json.loads(option(args, "--shape-config"))
        assert config == {"ocpus":2,"memoryInGBs":12}, config
    else:
        assert shape == "VM.Standard.E2.1.Micro"
        assert "--shape-config" not in args
PY
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

rm -f "$HOME/.oracle-free-provisioned"
printf 'accepted but not reconciled\n' > "$HOME/.oracle-free-launch-pending"
before=$(launch_count)
run_case 0 pending_running
after=$(launch_count)
[[ "$before" -eq "$after" ]]
[[ -e "$HOME/.oracle-free-provisioned" && ! -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: restart reconciles pending launch to an existing RUNNING instance without relaunch"

rm -f "$HOME/.oracle-free-provisioned" "$HOME/mock-instance-get-count"
printf 'accepted but still provisioning\n' > "$HOME/.oracle-free-launch-pending"
before=$(launch_count)
run_case 0 pending_transition
after=$(launch_count)
[[ "$before" -eq "$after" ]]
[[ -e "$HOME/.oracle-free-provisioned" && ! -e "$HOME/.oracle-free-launch-pending" ]]
grep -q 'PROVISIONING (1/40)' "$TESTDIR/pending_transition.out"
echo "PASS: restart waits for a pending instance to reach RUNNING without relaunch"

rm -f "$HOME/.oracle-free-provisioned" "$HOME/.oracle-free-launch-pending"
printf 'accepted launch awaiting reconciliation\n' > "$HOME/.oracle-free-launch-pending"
before=$(launch_count)
run_case 78 multiple
after=$(launch_count)
[[ "$before" -eq "$after" && -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: multiple matching instances preserve pending state and fail closed before launch"

run_case 78 malformed
after=$(launch_count)
[[ "$before" -eq "$after" && -e "$HOME/.oracle-free-launch-pending" ]]
echo "PASS: malformed existing-instance response fails closed before launch"

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
: > "$HOME/mock-oci-argv.jsonl"
run_case 0 normal
grep -q -- '--shape-config {"ocpus":2,"memoryInGBs":12}' "$HOME/mock-oci-calls"
echo "PASS: configurable ARM sizing 2 OCPU / 12 GB"
assert_launch_arguments
echo "PASS: OCI launch arguments and ARM shape-config are passed as distinct valid values"

rm -f "$HOME/.oracle-free-provisioned" "$HOME/.oracle-free-launch-pending"
before=$(launch_count)
run_case 0 amd_image_empty
after=$(launch_count)
[[ "$after" -gt "$before" ]]
grep -q 'No compatible Ubuntu 24.04 image for VM.Standard.E2.1.Micro; skipping this shape.' "$TESTDIR/amd_image_empty.out"
! grep -q 'Trying VM.Standard.E2.1.Micro' "$TESTDIR/amd_image_empty.out"
grep -q 'Trying VM.Standard.A1.Flex' "$TESTDIR/amd_image_empty.out"
echo "PASS: empty AMD image result skips AMD and continues with ARM"

rm -f "$HOME/.oracle-free-provisioned" "$HOME/.oracle-free-launch-pending"
before=$(launch_count)
run_case 95 arm_image_empty
after=$(launch_count)
[[ "$after" -gt "$before" ]]
grep -q 'Trying VM.Standard.E2.1.Micro' "$TESTDIR/arm_image_empty.out"
! grep -q 'Trying VM.Standard.A1.Flex' "$TESTDIR/arm_image_empty.out"
echo "PASS: empty ARM image result preserves AMD attempts"

rm -f "$HOME/.oracle-free-launch-pending"
before=$(launch_count)
run_case 78 both_images_empty
after=$(launch_count)
[[ "$after" -eq "$before" ]]
grep -q 'No compatible Ubuntu 24.04 image is available for either configured shape' "$TESTDIR/both_images_empty.out"
echo "PASS: no images for either shape stops before launch"

for mode in image_auth image_429 image_transient image_unexpected; do
  before=$(launch_count)
  run_case 78 "$mode"
  after=$(launch_count)
  [[ "$after" -eq "$before" ]]
  case "$mode" in
    image_auth) grep -q 'authentication or authorization failed during image discovery' "$TESTDIR/$mode.out" ;;
    image_429) grep -q 'rate-limited image discovery' "$TESTDIR/$mode.out" ;;
    image_transient) grep -q 'Transient OCI API error during image discovery' "$TESTDIR/$mode.out" ;;
    image_unexpected) grep -q 'Unexpected OCI API error during image discovery' "$TESTDIR/$mode.out" ;;
  esac
done
echo "PASS: image-discovery auth, rate-limit, transient, and unexpected errors fail safely"

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
