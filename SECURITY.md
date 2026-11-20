# Security policy

AutoSSL runs as root, installs trusted ACME client software and handles TLS private keys. Review source and signed upstream releases before use. Report vulnerabilities privately to the repository maintainer; do not post keys, ACME account details, or private domains in public issues.

- No direct piping of remote scripts into a root shell; only pinned signed `acme.sh` release is installed.
- The upstream SSH signing key is hard-coded for tag verification. Verify changes to that key separately; a GitHub release tag alone does not authorize trust changes.
- Certificates are stored under root-owned `/etc/autossl/certs`; never expose `private.pem` publicly.
- If Nginx is explicitly selected, it may be installed, started and reloaded; a dedicated ACME-only HTTP vhost is created only for a new hostname. Existing explicit Nginx server blocks are not rewritten.
- The script does not modify firewall rules, DNS records, production HTTPS settings, or Pingtunnel. A new HTTP vhost may alter default/wildcard routing; review when using on a live site.
- Do not run unreviewed updates or execute this installer with untrusted/sudo-preserved environment variables.
- The repository workflow tests simulated operation only; production deployments should verify actual issuance and renewal with a test domain.

- Contact email is optional for Let's Encrypt; the wizard never creates fake emails. No contact email means no email notices.
- After issuance only file paths are shown; the private PEM contents are never printed. Public PEM links to the fullchain.
