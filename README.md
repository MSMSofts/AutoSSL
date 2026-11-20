# AutoSSL — Secure SSL Certificate Wizard

[فارسی](README.fa.md) · [Issue audit](ISSUES.md) · [Security](SECURITY.md)

Interactive **SSL certificate wizard** for Linux using Let's Encrypt and acme.sh. Run `sudo bash AutoSSL.sh` to open the menu, just like the original AutoSSL. Automated CLI mode remains available for deployment scripts.

> Independent project for `MSMSofts/AutoSSL`. **Does not require MSM-Pingtunnel** and does not change other applications unless explicitly configured.

## Features

- **Interactive wizard** to install dependencies, configure a domain, choose the HTTP validation mode, issue certificates, check validity, renew and diagnose failures.
- **Verified dependency**: signed `acme.sh` release **3.1.7** pinned by annotated tag Git object SHA, checked against the pinned upstream SSH signing key. No `curl | sh`.
- **Automatic renewal**: daily persistent `systemd` timer with randomized delay, journal logs, and optional `systemctl reload` hook on certificate install/renewal.
- **No fake email**, forced issuance, accidental service restarts or private-key output to terminal.
- **Standalone / Webroot HTTP-01**; support multiple domains one certificate at a time by repeating the wizard.
- **Protected files**: `/etc/autossl/certs/DOMAIN/private.pem` (`0600`) and `fullchain.pem` (`0644`) in root-only domain folders.
- **Diagnostics and tests**: `doctor`, `status`, Bash smoke tests and ShellCheck workflow.

## Requirements

- Ubuntu/Debian, Fedora/RHEL-family, or Arch with **systemd** running; root (`sudo`) privileges.
- A public domain resolving to this VPS (check both **A and AAAA records**, if present).
- Public inbound **TCP port 80** reachable by Let's Encrypt for HTTP-01.
- If using standalone: port 80 must be **free now and at every future renewal**.
- If using webroot: an existing HTTP server must serve `/.well-known/acme-challenge/` from the configured document root.
- Network reachability to GitHub during initial installation and to the ACME CA during certificate issuance/renewal.

Runtime dependencies: Bash, Git, curl, OpenSSL, socat, `ssh-keygen`, `flock`, `systemctl`, `mktemp`, CA certificates. Optional diagnostics: `ss` (iproute2) and `getent`.

## Quick start (interactive wizard)

```bash
git clone https://github.com/MSMSofts/AutoSSL.git
cd AutoSSL
sudo bash AutoSSL.sh
```

Choose **1** to install and obtain a certificate; the wizard asks for a real email, then the domain, challenge mode, optional reload service and final confirmation. Once installed, run `sudo autossl` to open the wizard from anywhere.

To download only the standalone script instead of cloning, use:

```bash
curl -fSLo AutoSSL.sh https://raw.githubusercontent.com/MSMSofts/AutoSSL/main/AutoSSL.sh
sudo bash AutoSSL.sh
```

Inspect scripts before executing them as root. The script itself verifies the pinned, signed upstream acme.sh release during installation.

## Non-interactive installation

```bash
sudo bash AutoSSL.sh install --email ops@example.com --install-deps
# Standalone (only when port 80 is free):
sudo autossl issue --domain example.com --challenge standalone
# Webroot (when an HTTP server already listens on port 80):
sudo autossl issue --domain example.com --challenge webroot --webroot /var/www/html --reload-service nginx
```

Replace the example email and domains. `--install-deps` explicitly allows changes by your OS package manager; omit it if required programs are installed.

The service reload is **opt-in** and requires the selected systemd service to support reload. Before selecting it, separately configure your web server to use:

```
/etc/autossl/certs/example.com/private.pem
/etc/autossl/certs/example.com/fullchain.pem
```

AutoSSL does **not** edit Nginx/Apache configuration. For a non-root web application, arrange carefully controlled group/ACL access, never `chmod 777` or world-readable private keys.

## Manage & troubleshoot

```bash
sudo autossl                        # Wizard menu
sudo autossl doctor --domain example.com
sudo autossl status --domain example.com
sudo autossl renew
systemctl list-timers --all autossl-renew.timer
systemctl status autossl-renew.timer
journalctl -u autossl-renew.service -n 100 --no-pager
```

`autossl renew` checks certificates and renews **only when due**. The scheduler does not stop other services to free port 80. If a reverse proxy uses 80, choose and correctly configure webroot. Avoid enabling competing Certbot/acme.sh renew jobs for the same certificate.

## Security & compatibility

The installer pins the upstream release to `3.1.7` and checks its **signed annotated tag** rather than trusting a moving branch. Updating acme.sh requires reviewing and changing the release version and tag SHA; there is deliberately no unverified automatic script upgrade. Back up `/opt/autossl` (ACME account and state) and `/etc/autossl/certs` securely, with private key permissions intact.

Wildcard certificates need DNS-01 and are intentionally outside the scope of this build; HTTP-01 works for ordinary hostnames. A public real-world issuance/renewal test requires a controllable domain and VPS and is not covered by local mocked tests. See [ISSUES.md](ISSUES.md).

## Source and licensing

This is an enhanced derivative of [monhacer/AutoSSL](https://github.com/monhacer/AutoSSL) (MIT, copyright © 2025 AioExp). Original sources and original license are preserved in `upstream/`. This repository uses the same MIT license; see [LICENSE](LICENSE).
