#!/usr/bin/env bash
# Oracle Always Free capacity retryer. Run as the dedicated oracle-free user.
set -Eeuo pipefail
umask 077

CONFIG_FILE="${ORACLE_FREE_CONFIG:-/etc/oracle-free/config}"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing readable config: $CONFIG_FILE" >&2; exit 78; }

# Defaults. The administrator-owned config may override these values.
REGION=""
COMPARTMENT_OCID=""
SUBNET_OCID=""
INSTANCE_NAME="oracle-free-retry"
SSH_PUBLIC_KEY_FILE="$HOME/.ssh/oracle-free-key.pub"
AVAILABILITY_DOMAIN=""
# Empty: discover all ARM ADs. Otherwise comma-separated AD names, no spaces.
ARM_AVAILABILITY_DOMAINS=""
ARM_OCPUS=1
ARM_MEMORY_GB=6
DISCORD_WEBHOOK_URL=""
STATUS_NOTIFICATION_SECONDS=21600
RETRY_SECONDS=900
SHAPE_SPACING_SECONDS=120
THROTTLE_SECONDS=1800
MAX_THROTTLE_SECONDS=3600

# shellcheck source=/dev/null
source "$CONFIG_FILE"

die() { echo "ERROR: $*" >&2; exit 78; }
[[ "$COMPARTMENT_OCID" =~ ^ocid1\.(tenancy|compartment)\. ]] || die "Configure COMPARTMENT_OCID."
[[ "$SUBNET_OCID" == ocid1.subnet.* ]] || die "Configure SUBNET_OCID."
[[ "$REGION" =~ ^[a-z]{2}-[a-z0-9-]+-[0-9]+$ ]] || die "Configure REGION (for example ap-singapore-1)."
[[ "$INSTANCE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$ ]] || die "Invalid INSTANCE_NAME."
for var in RETRY_SECONDS SHAPE_SPACING_SECONDS THROTTLE_SECONDS MAX_THROTTLE_SECONDS; do
  value="${!var}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$var must be a positive integer."
  (( 10#$value >= 60 )) || die "$var must be at least 60 seconds."
done
(( 10#$MAX_THROTTLE_SECONDS >= 10#$THROTTLE_SECONDS )) || die "MAX_THROTTLE_SECONDS must be >= THROTTLE_SECONDS."
for var in ARM_OCPUS ARM_MEMORY_GB; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || die "$var must be an integer."
done
(( ARM_OCPUS >= 1 && ARM_OCPUS <= 2 )) || die "ARM_OCPUS must be 1 or 2."
(( ARM_MEMORY_GB >= ARM_OCPUS && ARM_MEMORY_GB <= 12 )) || die "ARM_MEMORY_GB must be between ARM_OCPUS and 12."
[[ "$STATUS_NOTIFICATION_SECONDS" =~ ^[0-9]+$ ]] || die "STATUS_NOTIFICATION_SECONDS must be an integer."
(( STATUS_NOTIFICATION_SECONDS >= 3600 )) || die "STATUS_NOTIFICATION_SECONDS must be at least 3600."
if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
  [[ "$DISCORD_WEBHOOK_URL" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[a-zA-Z0-9_-]+$ ]] || die "Invalid Discord webhook URL."
  command -v curl >/dev/null 2>&1 || die "curl is required when Discord notifications are configured."
fi
[[ -s "$SSH_PUBLIC_KEY_FILE" && -r "$SSH_PUBLIC_KEY_FILE" ]] || die "Missing SSH public key: $SSH_PUBLIC_KEY_FILE"
grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+' "$SSH_PUBLIC_KEY_FILE" || die "SSH public key has an unexpected format."
for command in oci python3 flock mktemp tee sync; do
  command -v "$command" >/dev/null 2>&1 || die "Missing command: $command"
done
[[ -r "$HOME/.oci/config" ]] || die "Missing OCI CLI credentials in $HOME/.oci/config"

PENDING_FILE="$HOME/.oracle-free-launch-pending"
SUCCESS_FILE="$HOME/.oracle-free-provisioned"
LOCK_FILE="$HOME/.oracle-free-retry.lock"
LOG_FILE="$HOME/oracle-free-retry.log"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another oracle-free process is already running."
  exit 0
fi

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

error_file=$(mktemp)
trap 'rm -f -- "$error_file"' EXIT
trap 'echo "Interrupted; stopping without retrying uncertain launches."; exit 130' INT TERM

is_throttled() {
  grep -Eiq 'TooManyRequests|"status"[[:space:]]*:[[:space:]]*429|user.rate.limit|too many requests' "$error_file"
}
is_capacity() {
  grep -Eiq 'OutOfHostCapacity|OutOfCapacity|out.of.host.capacity|out.of.capacity' "$error_file"
}
is_transient() {
  grep -Eiq '"status"[[:space:]]*:[[:space:]]*(500|502|503|504)|ServiceUnavailable|InternalError|ConnectTimeout|ReadTimeout|ConnectionError|ConnectionReset' "$error_file"
}

# Webhook delivery is best effort and never changes provisioning outcome.
# curl reads the webhook from stdin configuration, not its process arguments.
notify_discord() {
  local message="$1"
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
  if ! printf 'url = "%s"\n' "$DISCORD_WEBHOOK_URL" |
      curl --config - --fail --silent --max-time 20 --connect-timeout 8 \
      --request POST --data-urlencode "content=$message" \
      --output /dev/null 2>/dev/null; then
    echo "Warning: Discord notification failed (continuing)." >&2
  fi
  return 0
}

# Optional IP lookup after success, never affects the success marker.
get_public_ip() {
  local id="$1" address
  if ! address=$(oci compute instance list-vnics \
      --instance-id "$id" --region "$REGION" \
      --query 'data[0]."public-ip"' --raw-output --no-retry \
      2>/dev/null); then
    printf 'unavailable\n'
    return 0
  fi
  if [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf '%s\n' "$address"
  else
    printf 'unavailable\n'
  fi
}

# After confirmation, write success atomically before clearing the pending marker.
record_success() {
  local id="$1" shape="${2:-existing}" ad="${3:-unknown}" tmp public_ip
  tmp=$(mktemp "$HOME/.oracle-free-success.XXXXXX") || die "Cannot prepare success record."
  printf '%s\n' "$id" > "$tmp"
  sync -f "$tmp" || die "Cannot sync success record."
  mv -f -- "$tmp" "$SUCCESS_FILE" || die "Cannot save success record."
  sync -f "$SUCCESS_FILE" || die "Cannot sync success record."
  rm -f -- "$PENDING_FILE" || die "Cannot clear pending record."
  echo "SUCCESS: Instance is RUNNING: $id"
  public_ip=$(get_public_ip "$id")
  echo "Public IP: $public_ip"
  notify_discord "Oracle Free SUCCESS: $INSTANCE_NAME ($shape, $ad, $REGION). Public IP: $public_ip. Instance: $id"
  exit 0
}

verify_running() {
  local id="$1" shape="${2:-existing}" ad="${3:-unknown}" state attempt
  for ((attempt=1; attempt<=40; attempt++)); do
    : > "$error_file"
    if ! state=$(oci compute instance get \
        --instance-id "$id" --region "$REGION" \
        --query 'data."lifecycle-state"' --raw-output --no-retry 2>"$error_file"); then
      echo "Cannot verify instance $id; manual review needed." >&2
      notify_discord "Oracle Free STOPPED: Cannot verify instance $id in $REGION. Manual review required."
      cat "$error_file" >&2
      exit 78
    fi
    case "$state" in
      RUNNING) record_success "$id" "$shape" "$ad" ;;
      PROVISIONING|STARTING) echo "Instance $id: $state ($attempt/40)" ;;
      *) die "Unexpected instance lifecycle $state for $id; manual review needed." ;;
    esac
    sleep 30
  done
  notify_discord "Oracle Free STOPPED: $id did not reach RUNNING in 20 minutes; manual review required."
  die "Instance $id did not reach RUNNING within 20 minutes; manual review needed."
}

# Fail closed on malformed results, failed reads, or more than one matching instance.
# Some OCI CLI versions print nothing for an empty --all result.
check_existing() {
  local response found
  : > "$error_file"
  if ! response=$(oci compute instance list \
      --compartment-id "$COMPARTMENT_OCID" --region "$REGION" \
      --display-name "$INSTANCE_NAME" --all --output json --no-retry \
      2>"$error_file"); then
    echo "Cannot reliably list existing instances; refusing another launch." >&2
    cat "$error_file" >&2
    exit 78
  fi
  [[ -n "$response" ]] || { echo "No existing instance found."; return 0; }
  if ! found=$(printf '%s\n' "$response" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
items=obj.get("data") if isinstance(obj,dict) else obj
if not isinstance(items,list): raise ValueError("Expected instance list")
ids=[]
for item in items:
    if not isinstance(item,dict): raise ValueError("Unexpected instance item")
    if item.get("lifecycle-state") not in ("TERMINATING","TERMINATED"):
        ident=item.get("id")
        if not isinstance(ident,str) or not ident.startswith("ocid1.instance."):
            raise ValueError("Missing valid instance id")
        ids.append(ident)
print("\n".join(ids))
' 2>"$error_file"); then
    echo "Unparseable OCI instance list; manual review needed." >&2
    cat "$error_file" >&2
    exit 78
  fi
  if [[ -n "$found" ]]; then
    [[ "$found" != *$'\n'* ]] || die "Multiple matching instances exist; manual review needed."
    echo "Existing instance found: $found"
    verify_running "$found"
  fi
  echo "No existing instance found."
}

if [[ -e "$SUCCESS_FILE" ]]; then
  echo "Provisioning already completed. No new launch will be attempted."
  exit 0
fi

if [[ -e "$PENDING_FILE" ]]; then
  echo "An earlier launch may have been interrupted. Reconciling first..."
  check_existing
  notify_discord "Oracle Free STOPPED: An earlier launch is unresolved in $REGION. Review the pending marker."
  die "Launch outcome still uncertain. Verify OCI Console, then resolve the pending marker manually."
fi

echo "Starting Oracle Always Free capacity retryer (region: $REGION)."
echo "AMD: VM.Standard.E2.1.Micro; ARM: VM.Standard.A1.Flex ($ARM_OCPUS OCPU / $ARM_MEMORY_GB GB); boot volume: 50 GB."
check_existing

echo "Discovering Availability Domains in $REGION..."
ad_json=$(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_OCID" --region "$REGION" \
  --output json --no-retry) || die "Could not discover availability domains."
ad_lines=$(printf '%s\n' "$ad_json" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
items=obj.get("data") if isinstance(obj,dict) else obj
if not isinstance(items,list) or not items: raise ValueError("No ADs returned")
for item in items:
    if not isinstance(item,dict) or not isinstance(item.get("name"),str):
        raise ValueError("Invalid availability domain")
    print(item["name"])
') || die "Malformed Availability Domain list."
mapfile -t ALL_ADS <<< "$ad_lines"
for ad in "${ALL_ADS[@]}"; do
  [[ "$ad" =~ ^[A-Za-z0-9:._-]+$ ]] || die "Unexpected availability-domain name."
done

is_known_ad() {
  local needle="$1" value
  for value in "${ALL_ADS[@]}"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

# AVAILABILITY_DOMAIN pins AMD and, unless overridden, ARM (legacy option).
# ARM_AVAILABILITY_DOMAINS independently selects a comma-separated ARM list.
AMD_AD="${AVAILABILITY_DOMAIN:-${ALL_ADS[0]}}"
is_known_ad "$AMD_AD" || die "Configured AMD availability domain is not in the region."

if [[ -n "$ARM_AVAILABILITY_DOMAINS" ]]; then
  IFS=',' read -r -a ARM_ADS <<< "$ARM_AVAILABILITY_DOMAINS"
elif [[ -n "$AVAILABILITY_DOMAIN" ]]; then
  ARM_ADS=("$AVAILABILITY_DOMAIN")
else
  ARM_ADS=("${ALL_ADS[@]}")
fi

declare -A AD_SEEN=()
unique_arm_ads=()
for ad in "${ARM_ADS[@]}"; do
  [[ "$ad" =~ ^[A-Za-z0-9:._-]+$ ]] || die "ARM_AVAILABILITY_DOMAINS contains an invalid AD."
  is_known_ad "$ad" || die "ARM candidate $ad is not a discovered AD in $REGION."
  if [[ -z "${AD_SEEN[$ad]:-}" ]]; then
    unique_arm_ads+=("$ad")
    AD_SEEN["$ad"]=1
  fi
done
ARM_ADS=("${unique_arm_ads[@]}")
(("${#ARM_ADS[@]}" > 0)) || die "No usable ARM Availability Domains."

echo "AMD Availability Domain: $AMD_AD"
echo "ARM Availability Domains: ${ARM_ADS[*]}"

SHAPES=("VM.Standard.E2.1.Micro" "VM.Standard.A1.Flex")
declare -A IMAGES
for shape in "${SHAPES[@]}"; do
  echo "Finding Ubuntu 24.04 image for $shape..."
  image_id=$(oci compute image list \
    --compartment-id "$COMPARTMENT_OCID" --region "$REGION" \
    --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
    --shape "$shape" --sort-by TIMECREATED --sort-order DESC --limit 1 \
    --query 'data[0].id' --raw-output --no-retry) || die "Image lookup failed for $shape."
  [[ "$image_id" == ocid1.image.* ]] || die "No compatible image available for $shape."
  IMAGES["$shape"]="$image_id"
done

notify_discord "Oracle Free STARTED: $INSTANCE_NAME in $REGION. AMD first; ARM $ARM_OCPUS OCPU / $ARM_MEMORY_GB GB across ${#ARM_ADS[@]} AD(s)."
last_status_notification=$(date +%s)

round=0
throttle_delay=$THROTTLE_SECONDS
while true; do
  round=$((round + 1))
  echo "[$(date -Is)] Round $round (unlimited)"
  now=$(date +%s)
  if (( now - last_status_notification >= STATUS_NOTIFICATION_SECONDS )); then
    notify_discord "Oracle Free STATUS: $INSTANCE_NAME in $REGION is still searching for capacity (round $round)."
    last_status_notification="$now"
  fi

  throttled=0
  attempts_in_round=0
  for shape in "${SHAPES[@]}"; do
    if [[ "$shape" == "VM.Standard.E2.1.Micro" ]]; then
      candidate_ads=("$AMD_AD")
    else
      candidate_ads=("${ARM_ADS[@]}")
    fi

    for ad in "${candidate_ads[@]}"; do
      check_existing
      if (( attempts_in_round > 0 )); then
        echo "Spacing launch requests by $SHAPE_SPACING_SECONDS seconds..."
        sleep "$SHAPE_SPACING_SECONDS"
        check_existing
      fi

      args=(compute instance launch
        --compartment-id "$COMPARTMENT_OCID"
        --availability-domain "$ad"
        --subnet-id "$SUBNET_OCID"
        --region "$REGION"
        --shape "$shape"
        --image-id "${IMAGES[$shape]}"
        --display-name "$INSTANCE_NAME"
        --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE"
        --assign-public-ip true
        --boot-volume-size-in-gbs 50
        --no-retry
        --query 'data.id'
        --raw-output)
      if [[ "$shape" == "VM.Standard.A1.Flex" ]]; then
        args+=(--shape-config "{\"ocpus\":$ARM_OCPUS,\"memoryInGBs\":$ARM_MEMORY_GB}")
      fi

      echo "Trying $shape in $ad..."
      : > "$error_file"
      # Durable write-before-send marker, with the target AD included.
      if ! (set -C; printf 'timestamp=%s\nshape=%s\nad=%s\n' \
          "$(date -Is)" "$shape" "$ad" > "$PENDING_FILE"); then
        die "Cannot create exclusive pending-launch marker."
      fi
      sync -f "$PENDING_FILE" || die "Cannot sync pending-launch marker."
      attempts_in_round=$((attempts_in_round + 1))

      if instance_id=$(oci "${args[@]}" 2>"$error_file"); then
        [[ "$instance_id" == ocid1.instance.* ]] || die "Unexpected successful launch response; check OCI Console."
        echo "Launch accepted: $instance_id ($shape, $ad)"
        verify_running "$instance_id" "$shape" "$ad"
      fi

      if is_throttled; then
        rm -f -- "$PENDING_FILE" || die "Cannot clear pending marker."
        echo "Rate limited on $shape in $ad."
        throttled=1
        break
      elif is_capacity; then
        rm -f -- "$PENDING_FILE" || die "Cannot clear pending marker."
        echo "No host capacity for $shape in $ad."
      elif is_transient; then
        echo "Ambiguous launch result for $shape in $ad; retaining pending marker." >&2
        notify_discord "Oracle Free STOPPED: Ambiguous launch for $INSTANCE_NAME ($shape, $ad, $REGION). Review pending marker."
        cat "$error_file" >&2
        exit 78
      else
        echo "Non-retryable launch error for $shape in $ad; retaining pending marker." >&2
        notify_discord "Oracle Free STOPPED: Non-retryable launch error for $INSTANCE_NAME ($shape, $ad, $REGION)."
        cat "$error_file" >&2
        exit 1
      fi
    done
    (( throttled == 0 )) || break
  done

  if (( throttled )); then
    echo "Rate limit cooldown: $throttle_delay seconds."
    sleep "$throttle_delay"
    throttle_delay=$((throttle_delay * 2))
    if (( throttle_delay > MAX_THROTTLE_SECONDS )); then
      throttle_delay=$MAX_THROTTLE_SECONDS
    fi
  else
    throttle_delay=$THROTTLE_SECONDS
    echo "Waiting $RETRY_SECONDS seconds before next round..."
    sleep "$RETRY_SECONDS"
  fi
done
