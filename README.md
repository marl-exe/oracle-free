# Oracle Free

**Oracle Cloud Always Free capacity retryer for Linux.** Tries the AMD Micro shape, then the Arm A1 Flex shape, and waits when Oracle reports out-of-host capacity. Uses the OCI CLI, Bash, and systemd. No Docker, web UI, or database.

> **Important:** This tool makes real OCI instance creation requests when you explicitly start the service. Oracle capacity is not guaranteed. It does not bypass API limits, quotas, policies, or billing rules. **Review your tenancy's remaining Always Free allowance, shape eligibility, boot-volume usage, and billing safeguards before enabling it.** The project cannot guarantee a zero-dollar bill.

## Features

- AMD **VM.Standard.E2.1.Micro** first, then Arm **VM.Standard.A1.Flex** with configurable sizing (default **1 OCPU / 6 GB RAM**, allowed up to 2 OCPUs / 12 GB RAM).
- 50 GB boot volume and Ubuntu 24.04 platform image, selected per region and shape.
- Automatically rotates Arm attempts across discovered Availability Domains (ADs), or an explicitly configured list; AMD continues using one AD.
- Default 15-minute interval between rounds, two-minute spacing **between all launch attempts**.
- 30–60-minute cooldown on explicit HTTP 429 responses.
- Process lock plus durable pending/success markers to limit accidental duplicate launches.
- Checks matching existing instances before launch; stops when an instance reaches **RUNNING**.
- **Fails closed** on uncertain launch outcomes, malformed OCI results, authentication errors, and unexpected lifecycle states.
- systemd persistence across VPS reboots; installation deliberately leaves the service **disabled**.
- Optional best-effort Discord webhook for start, periodic status, successful launch, and launch errors.
- On success, retrieves the new instance public IP when permitted (otherwise displays `unavailable`).
- Dedicated unprivileged Linux account. Private keys and actual configuration stay on your server.

## Requirements

- Ubuntu/Debian Linux with systemd, root access for one-time installation.
- A working OCI tenancy, API signing key, and IAM permissions to list/read instances and launch instances in the chosen compartment and network.
- A VCN and subnet configured for the intended region; a subnet allowing public IP assignment, internet gateway/route, and appropriate security rules if you require SSH access.
- Your own **SSH public key**. The matching private key stays on your own computer.
- Python 3 and the OCI CLI. Installer uses an existing service-visible CLI or installs it in a dedicated Python virtual environment using apt and pip.
- Available Always Free quota, including boot volume headroom.

The retryer is **not** a general compute orchestrator. It only requests the two shapes named above. It does not resize, create networks, terminate instances, or delete resources.

## Clean installation

~~~bash
git clone https://github.com/marl-exe/oracle-free.git
cd oracle-free
sudo bash install.sh
~~~

The installer creates:

| Location | Purpose |
|---|---|
| /opt/oracle-free/oracle-free.sh | Managed program (root-owned) |
| /etc/oracle-free/config | Private Bash configuration (root-owned, group-readable by oracle-free) |
| /var/lib/oracle-free/ | Service account home, logs, lock, and state |
| /var/lib/oracle-free/.oci/ | OCI CLI configuration and signing key |
| /var/lib/oracle-free/.ssh/ | Your SSH public key |
| /etc/systemd/system/oracle-free.service | systemd service, initially disabled |

The installer refuses to overwrite an existing oracle-free.service file, so it is **not** an in-place upgrade mechanism. Do not run it over a working custom deployment.

### 1. Configure OCI credentials

Generate or obtain your **own** OCI API signing key and OCI CLI configuration, following [Oracle's official instructions](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm). Use a **dedicated API-only IAM user** with the minimum permissions needed in the desired compartment and network.

Your local OCI CLI configuration must use the correct tenancy OCID, user OCID, API key fingerprint, region, and private signing-key path. For example, the contents of the *private server-side* file /var/lib/oracle-free/.oci/config are:

~~~ini
[DEFAULT]
user=ocid1.user.oc1..REPLACE_ME
tenancy=ocid1.tenancy.oc1..REPLACE_ME
fingerprint=REPLACE_WITH_YOUR_KEY_FINGERPRINT
region=ap-singapore-1
key_file=/var/lib/oracle-free/.oci/oci_api_key.pem
~~~

From a secure location on the server, install **your** CLI config and signing key:

~~~bash
sudo install -o oracle-free -g oracle-free -m 600 /secure/source/oci-config /var/lib/oracle-free/.oci/config
sudo install -o oracle-free -g oracle-free -m 600 /secure/source/oci_api_key.pem /var/lib/oracle-free/.oci/oci_api_key.pem
~~~

Replace both /secure/source paths. **Never commit these files to GitHub, paste the private key into an issue, or use the SSH public key as the OCI API signing key.**

IAM policy syntax and scopes depend on your identity domain, compartments, and VCN placement. The API user needs permission to inspect availability domains and images, list/get instances, launch instances, and use the appropriate subnet/VNIC network resources. Configure the narrowest practical scope. Do not grant tenancy-wide admin permissions to a retry script.

### 2. Install your SSH public key

~~~bash
sudo install -o oracle-free -g oracle-free -m 600 /secure/source/id_ed25519.pub /var/lib/oracle-free/.ssh/oracle-free-key.pub
~~~

Use a public key that corresponds to a private key **you retain**. RSA or ECDSA public keys also work.

### 3. Edit the retry configuration

~~~bash
sudoedit /etc/oracle-free/config
~~~

Copy and customize values from [config.example](config.example). In particular:

- **COMPARTMENT_OCID:** compartment where instances will be created (may be the tenancy root OCID).
- **SUBNET_OCID:** subnet for the new instance in the selected region.
- **REGION:** e.g., ap-singapore-1 (must match the subnet).
- **INSTANCE_NAME:** unique display name used to find existing instances.
- **AVAILABILITY_DOMAIN:** legacy option to pin AMD and (unless overridden) ARM to a single AD; default blank selects AMD's first discovered AD and all available ADs for ARM.
- **ARM_AVAILABILITY_DOMAINS:** comma-separated ADs to try for ARM **in order**, e.g. `example:AP-REGION-1-AD-2,example:AP-REGION-1-AD-1`. Leave empty to discover and try **all** regional ADs. Names must be returned by the region's AD API, without spaces.
- **ARM_OCPUS / ARM_MEMORY_GB:** Arm A1 Flex shape sizing; default `1` OCPU and `6` GB. This tool restricts values to 1–2 OCPUs and RAM between OCPU count and 12 GB. Available quotas still depend on other resources already provisioned in your tenancy.
- **DISCORD_WEBHOOK_URL:** optional. Empty disables Discord; configured webhook is used for startup, periodic status, success, and launch failures.
- **STATUS_NOTIFICATION_SECONDS:** default `21600` (six hours; minimum one hour).
- **SSH_PUBLIC_KEY_FILE:** defaults to the installed public key path, resolved under the service user's HOME.

Example private `/etc/oracle-free/config` settings:

~~~bash
ARM_OCPUS=1
ARM_MEMORY_GB=6

# Empty = all discovered ARM ADs; set specific full names to restrict/order.
ARM_AVAILABILITY_DOMAINS=""

# Leave empty to disable Discord notifications.
DISCORD_WEBHOOK_URL=""
STATUS_NOTIFICATION_SECONDS=21600
~~~

**Discord security:** Create a webhook in your Discord server channel settings. Treat its URL like a password; paste it only into the private server-side configuration, **never into `config.example` or GitHub**. The installer configures the installed file as `root:oracle-free`, mode `0640`. The program sends JSON messages via HTTPS, and notification failures cannot cause another instance launch. Do not share screenshots of the configured URL.

The provisioning script lists all regional ADs once at startup. For each retry round it tries **one AMD AD**, then each selected **ARM AD**, with the configured 120-second spacing between requests, checking for existing instances before each launch. A rate-limit response interrupts the round and applies the cooldown.

**Public IP:** After an instance reaches `RUNNING` and the success marker is written, the script optionally calls `oci compute instance list-vnics`. This requires suitable VNIC read permission. If lookup fails or no public IP is present, it logs `unavailable` and still exits successfully; the public IP is also included in the optional Discord success message when found.

Default retry intervals are 900, 120, 1800, and 3600 seconds. Change the configuration only while the service is stopped. Installed config should remain owned by root:oracle-free and mode 0640.

### 4. Check read-only authentication

Replace the example compartment ID and region with your own:

~~~bash
sudo runuser -u oracle-free -- env \
  HOME=/var/lib/oracle-free \
  PATH=/opt/oracle-free/venv/bin:/usr/local/bin:/usr/bin:/bin \
  oci iam availability-domain list \
  --compartment-id 'ocid1.compartment.oc1..REPLACE_ME' \
  --region ap-singapore-1 \
  --no-retry
~~~

Also verify that the user can list the target compartment's instances. The first real launch may reveal additional missing IAM permissions; if so, the script stops rather than retrying invalid requests indefinitely.

### 5. Explicitly start real provisioning

**This is the point at which live Oracle launch requests begin.** Only run when configuration, credentials, permissions, quotas, and billing safeguards are ready.

~~~bash
sudo systemctl enable --now oracle-free.service
sudo systemctl status oracle-free.service --no-pager
sudo journalctl -u oracle-free.service -f
~~~

No live launch requests occur from the installer or from the offline tests.

## Service commands

~~~bash
sudo systemctl status oracle-free.service
sudo journalctl -u oracle-free.service -n 80 --no-pager
sudo tail -n 80 /var/lib/oracle-free/oracle-free-retry.log

sudo systemctl stop oracle-free.service
sudo systemctl disable --now oracle-free.service
sudo systemctl enable --now oracle-free.service
~~~

Systemd starts the service after a VPS reboot if enabled. **The service exits normally after a confirmed RUNNING instance**, and a durable success file blocks subsequent provisioning if systemd starts again. A permanent or ambiguous error exits with a code that prevents automatic restart.

## Safety and recovery

- **Lock:** /var/lib/oracle-free/.oracle-free-retry.lock prevents concurrent processes on the same Linux host. This is *not* a distributed lock across different machines.
- **Pending:** /var/lib/oracle-free/.oracle-free-launch-pending is durably written **before** a launch API request. It is removed after an explicit capacity shortage or explicit rate-limit rejection. Network failures, crashes, unexpected responses, or permanent failures retain it.
- **Success:** /var/lib/oracle-free/.oracle-free-provisioned stores a confirmed instance OCID when the instance reaches RUNNING. It stops future launches, including after reboot.
- **Existing instances:** the script queries the configured compartment and matching display name. It exits without a new launch if a matching instance is found and becomes RUNNING. Multiple matching instances are treated as unsafe.

**If the service stops with a pending marker:** stop the service, inspect the OCI Console and instance list in the configured compartment/region, and determine whether a launch was accepted. Allow for delayed visibility of a newly created instance. If an instance exists, reconcile that instance and its state before further action. If *no* instance exists and you have confidently ruled out an in-flight launch, you may remove the pending marker as an **intentional manual recovery action**:

~~~bash
sudo systemctl stop oracle-free.service
# Review OCI Console and API results carefully FIRST.
sudo rm -- /var/lib/oracle-free/.oracle-free-launch-pending
sudo systemctl start oracle-free.service
~~~

**Never remove a pending or success marker just to force more retries.** A missed instance can cause a duplicate launch and unexpected costs. If a marker is present and the script cannot safely reconcile, it refuses to launch.

The tool only checks instances with the configured display name in the specified compartment. It cannot prove that no instance with a different name or in another compartment exists, or provide an exactly-once guarantee for a distributed cloud API.

## Tests

~~~bash
bash tests/test.sh
~~~

Tests run with a mocked OCI binary, temporary HOME, and fake OCIDs. They cover AMD-to-Arm fallback, multi-AD rotation, custom AD ordering, ARM sizing/limits, Discord success/failure behavior, public IP reporting and its failure path, repeat startup, interrupted launch, ambiguous timeout, rate limiting, permanent error, and existing-instance adoption. **Tests never contact Oracle.** GitHub Actions runs these on pushes and pull requests.

## Uninstall

~~~bash
sudo bash uninstall.sh
~~~

Stops/disables and removes the **managed** program and service. It intentionally **preserves** /etc/oracle-free/config and /var/lib/oracle-free/ so credentials, logs, and state are not deleted without your decision. Uninstall does **not** terminate any Oracle instance.

## Limitations

- Oracle may have no capacity for extended periods, especially in busy regions. Waiting does not reserve capacity.
- ARM A1 and AMD Micro shape availability and Always Free allowances are tenancy- and region-dependent.
- HTTP 429 causes cooldown, not aggressive retrying.
- AMD uses the first discovered AD by default; ARM rotates through discovered ADs unless restricted in configuration. Some regions have only one AD. This tool does not test AMD shape support across every AD.
- No direct cloud billing or resource-budget enforcement. Set up [OCI budgets and alerts](https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/budgetsoverview.htm).
- Launches request a public IPv4 address. Check applicable OCI networking charges and subnet permissions.

## License

[MIT](LICENSE). Community project; not affiliated with or endorsed by Oracle.
