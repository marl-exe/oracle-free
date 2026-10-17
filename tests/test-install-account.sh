#!/usr/bin/env bash
# Isolated tests for install.sh account validation; no host accounts or files are changed.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TESTDIR=$(mktemp -d)
trap 'rm -rf -- "$TESTDIR"' EXIT

# Pull the production function and account-setup block directly from install.sh.
sed -n '/^validate_service_account() {$/,/^}$/p' "$ROOT/install.sh" > "$TESTDIR/validator.sh"
sed -n '/^if ! getent passwd oracle-free/,/^install -d -o oracle-free/p' "$ROOT/install.sh" > "$TESTDIR/account-setup.sh"
[[ -s "$TESTDIR/validator.sh" && -s "$TESTDIR/account-setup.sh" ]]

cat > "$TESTDIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE="$EXPECTED_HOME"
getent() {
  case "$1:$2" in
    passwd:oracle-free)
      [[ "${ACCOUNT_PRESENT:-1}" == 1 ]] || return 2
      [[ "${ACCOUNT_PASSWD:-}" != __MISSING__ ]] || return 2
      printf '%s\n' "${ACCOUNT_PASSWD:-oracle-free:x:500:500:Oracle service:$EXPECTED_HOME:/usr/sbin/nologin}"
      ;;
    group:oracle-free)
      [[ "${GROUP_PRESENT:-1}" == 1 ]] || return 2
      [[ "${ACCOUNT_GROUP:-}" != __MISSING__ ]] || return 2
      printf '%s\n' "${ACCOUNT_GROUP:-oracle-free:x:500:}"
      ;;
    *) return 2 ;;
  esac
}
id() {
  [[ "$1" == -G && "${2:-}" == oracle-free ]] || return 2
  [[ "${ACCOUNT_GROUP_IDS:-}" != __MISSING__ ]] || return 2
  printf '%s\n' "${ACCOUNT_GROUP_IDS:-500}"
}
useradd() {
  printf '%s\n' "$*" >> "$CALL_LOG"
  ACCOUNT_PRESENT=1
  export ACCOUNT_PRESENT
}
install() {
  printf '%s\n' "$*" >> "$PROTECTED_LOG"
}
source "$VALIDATOR_FILE"
if [[ "${RUN_SETUP_SNIPPET:-0}" == 1 ]]; then
  # This is the account creation, validation, and first protected operation from install.sh.
  source "$SETUP_FILE"
else
  validate_service_account "$EXPECTED_HOME" "$LOGIN_DEFS"
fi
HARNESS

cat > "$TESTDIR/login.defs" <<'EOF'
SYS_UID_MIN 100
SYS_UID_MAX 999
EOF
# Point the extracted installer block at the isolated UID-range fixture.
sed -i "s|/etc/login.defs|$TESTDIR/login.defs|g" "$TESTDIR/account-setup.sh"

BASE_PASSWD='oracle-free:x:500:500:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin'
BASE_GROUP='oracle-free:x:500:'
BASE_GROUP_IDS=500
export EXPECTED_HOME=/var/lib/oracle-free LOGIN_DEFS="$TESTDIR/login.defs"
export VALIDATOR_FILE="$TESTDIR/validator.sh" SETUP_FILE="$TESTDIR/account-setup.sh"
export CALL_LOG="$TESTDIR/calls.log" PROTECTED_LOG="$TESTDIR/protected.log"

run_validator() {
  local expected=$1 name=$2
  shift 2
  : > "$CALL_LOG"
  : > "$PROTECTED_LOG"
  set +e
  env "$@" bash "$TESTDIR/harness.sh" > "$TESTDIR/output" 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    cat "$TESTDIR/output" >&2
    echo "FAIL: $name returned $actual, expected $expected" >&2
    exit 1
  fi
  if [[ -s "$CALL_LOG" || -s "$PROTECTED_LOG" ]]; then
    echo "FAIL: $name attempted account mutation" >&2
    exit 1
  fi
}

run_install_guard() {
  local name=$1
  shift
  : > "$CALL_LOG"
  : > "$PROTECTED_LOG"
  set +e
  env RUN_SETUP_SNIPPET=1 "$@" bash "$TESTDIR/harness.sh" > "$TESTDIR/output" 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne 1 || -s "$CALL_LOG" || -s "$PROTECTED_LOG" ]]; then
    cat "$TESTDIR/output" >&2
    echo "FAIL: $name did not fail before protected install operations" >&2
    exit 1
  fi
}

run_validator 0 "existing valid account" \
  ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS="$BASE_GROUP_IDS"
echo "PASS: existing valid system account"

# Exercise the exact installer setup block with a missing account. useradd is mocked;
# its mock makes the new account visible to subsequent getent calls.
: > "$CALL_LOG"
: > "$PROTECTED_LOG"
env ACCOUNT_PRESENT=0 ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS="$BASE_GROUP_IDS" \
  RUN_SETUP_SNIPPET=1 bash "$TESTDIR/harness.sh" > "$TESTDIR/output" 2>&1
grep -q '^--system --user-group --home-dir /var/lib/oracle-free --shell /usr/sbin/nologin oracle-free$' "$CALL_LOG"
grep -q '^-d -o oracle-free -g oracle-free -m 700 /var/lib/oracle-free /var/lib/oracle-free/.oci /var/lib/oracle-free/.ssh$' "$PROTECTED_LOG"
echo "PASS: fresh install creates a mocked system account and validates it"

: > "$CALL_LOG"
: > "$PROTECTED_LOG"
env RUN_SETUP_SNIPPET=1 ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS="$BASE_GROUP_IDS" \
  bash "$TESTDIR/harness.sh" > "$TESTDIR/output" 2>&1
[[ ! -s "$CALL_LOG" && -s "$PROTECTED_LOG" ]]
echo "PASS: existing valid account passes installer guard without account changes"

run_validator 1 "root UID" \
  ACCOUNT_PASSWD='oracle-free:x:0:500:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS="$BASE_GROUP_IDS"
run_install_guard "root UID" ACCOUNT_PASSWD='oracle-free:x:0:500:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
cat > "$TESTDIR/unexpected-login.defs" <<'EOF'
SYS_UID_MIN 700
SYS_UID_MAX 999
EOF
# Re-run after creating the restrictive fixture.
run_validator 1 "unexpected UID range" \
  ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS="$BASE_GROUP_IDS" \
  LOGIN_DEFS="$TESTDIR/unexpected-login.defs"
cp "$TESTDIR/unexpected-login.defs" "$TESTDIR/login.defs"
run_install_guard "unexpected UID range" ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
cat > "$TESTDIR/login.defs" <<'EOF'
SYS_UID_MIN 100
SYS_UID_MAX 999
EOF
run_validator 1 "incorrect primary group" \
  ACCOUNT_PASSWD='oracle-free:x:500:501:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_install_guard "incorrect primary group" ACCOUNT_PASSWD='oracle-free:x:500:501:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_validator 1 "incorrect home directory" \
  ACCOUNT_PASSWD='oracle-free:x:500:500:Oracle service:/tmp:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_install_guard "incorrect home directory" ACCOUNT_PASSWD='oracle-free:x:500:500:Oracle service:/tmp:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_validator 1 "incorrect login shell" \
  ACCOUNT_PASSWD='oracle-free:x:500:500:Oracle service:/var/lib/oracle-free:/bin/bash' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_install_guard "incorrect login shell" ACCOUNT_PASSWD='oracle-free:x:500:500:Oracle service:/var/lib/oracle-free:/bin/bash' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_validator 1 "extra supplementary group" \
  ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS='500 501'
run_install_guard "extra supplementary group" ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS='500 501'
run_validator 1 "missing account" ACCOUNT_PRESENT=0 ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_validator 1 "malformed account" \
  ACCOUNT_PASSWD='oracle-free:x:not-a-uid:500:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_install_guard "malformed account" ACCOUNT_PASSWD='oracle-free:x:not-a-uid:500:Oracle service:/var/lib/oracle-free:/usr/sbin/nologin' ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=500
run_validator 1 "missing group" \
  ACCOUNT_PASSWD="$BASE_PASSWD" GROUP_PRESENT=0 ACCOUNT_GROUP_IDS=500
run_install_guard "missing group" ACCOUNT_PASSWD="$BASE_PASSWD" GROUP_PRESENT=0 ACCOUNT_GROUP_IDS=500
run_validator 1 "malformed group" \
  ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP='oracle-free:x:not-a-gid:' ACCOUNT_GROUP_IDS=500
run_install_guard "malformed group" ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP='oracle-free:x:not-a-gid:' ACCOUNT_GROUP_IDS=500
run_validator 1 "unavailable membership data" \
  ACCOUNT_PASSWD="$BASE_PASSWD" ACCOUNT_GROUP="$BASE_GROUP" ACCOUNT_GROUP_IDS=__MISSING__
echo "PASS: unsafe, missing, and malformed account/group configurations fail validation"

# The account check must precede every protected directory/service installation command.
validation_line=$(grep -n '^validate_service_account ' "$ROOT/install.sh" | cut -d: -f1)
first_install_line=$(grep -nE '^(install|systemctl|systemd-analyze) ' "$ROOT/install.sh" | head -n1 | cut -d: -f1)
[[ -n "$validation_line" && -n "$first_install_line" && "$validation_line" -lt "$first_install_line" ]]
echo "PASS: account validation runs before protected installation operations"
