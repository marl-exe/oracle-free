# Security Policy

## Sensitive information

Do not commit or publish OCI API signing keys, local OCI CLI configuration, private SSH keys, credentials, instance state, or logs. Use the provided example configuration with placeholders.

The script submits real cloud provisioning requests when the service is explicitly started. Review the IAM scope and Always Free resource quota before use.

## Vulnerability reports

Please avoid opening public issues containing secrets or detailed exploit instructions. If GitHub private vulnerability reporting is enabled for this repository, use **Security → Report a vulnerability**. Otherwise contact the maintainer privately through an established secure channel.

## Recovery and incident response

If you suspect a credential leak, revoke/rotate affected OCI API keys immediately and inspect OCI Audit for unexpected actions. Stop the service while investigating:

```bash
sudo systemctl disable --now oracle-free.service
```

Never remove the pending-launch marker without verifying that Oracle did not create an instance.
