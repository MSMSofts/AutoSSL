# Security policy

AutoSSL runs as root, installs trusted ACME client software and handles TLS private keys. Review source and signed upstream releases before use. Report vulnerabilities privately to the repository maintainer; do not post keys, ACME account details, or private domains in public issues.

- No direct piping of remote scripts into a root shell; only pinned signed `acme.sh` release is installed.
- The upstream SSH signing key is hard-coded for tag verification. Verify changes to that key separately; a GitHub release tag alone does not authorize trust changes.
- Certificates are stored under root-owned `/etc/autossl/certs`; never expose `private.pem` publicly.
- No automatic service restarts; a requested reload hook requires preexisting configuration.
- The script does not modify firewall rules, DNS records, proxy TLS settings, or Pingtunnel.
- Do not run unreviewed updates or execute this installer with untrusted/sudo-preserved environment variables.
- The repository workflow tests simulated operation only; production deployments should verify actual issuance and renewal with a test domain.
