# AutoSSL — Minimal SSL Wizard

[فارسی](README.fa.md) · [Security](SECURITY.md) · [Review](ISSUES.md)

An independent interactive Let's Encrypt certificate manager for systemd Linux, based on [monhacer/AutoSSL](https://github.com/monhacer/AutoSSL) (MIT).

## Installation

~~~bash
git clone https://github.com/MSMSofts/AutoSSL.git
cd AutoSSL
sudo bash AutoSSL.sh
~~~

Or download and inspect just the installer:

~~~bash
curl -fSLo AutoSSL.sh https://raw.githubusercontent.com/MSMSofts/AutoSSL/main/AutoSSL.sh
sudo bash AutoSSL.sh
~~~

Choose **1 — Install & obtain SSL** in the menu. The wizard asks **only two things**:

1. **Domain**, such as sub.example.com (no URL prefix).
2. **Challenge method:** 1 = Standalone; 2 = Webroot + Nginx, automatic.

No package-manager, email, webroot, service name or extra confirmation prompt. AutoSSL detects and installs missing dependencies, installs the pinned signed acme.sh 3.1.7 release, issues and validates the ECC certificate, and enables a daily persistent systemd renewal timer.

Contact email is optional for Let's Encrypt. To receive CA notifications, supply a real email with this command:

~~~bash
sudo env AUTOSSL_EMAIL=you@example.com bash AutoSSL.sh
~~~

There are no fake/generated email addresses. Without contact email, expiry notices cannot be delivered by email.

## Result: clearly labeled PEM paths at the bottom

After a **successful** issuance, AutoSSL prints the two paths and exits the wizard:

~~~text
PRIVATE KEY (PEM) / کلید خصوصی:
 /etc/autossl/certs/sub.example.com/private.pem

PUBLIC CERTIFICATE (PEM) / گواهی عمومی:
 /etc/autossl/certs/sub.example.com/public.pem
~~~

private.pem contains the secret key and is permission-restricted. public.pem points to fullchain.pem (the certificate + CA chain) and therefore stays current on renewals. The private key **contents** are never printed.

## Standalone vs Webroot + Nginx

| Choice | Requirements | Automation |
| --- | --- | --- |
| Standalone | Public inbound TCP port 80 must be **free** now **and during every future renewal** | acme.sh handles a temporary standalone listener; no existing services are stopped |
| Webroot + Nginx | Public inbound TCP port 80 accessible | Nginx is installed/started if required; for a new hostname a managed HTTP-01 virtual host and webroot are created and tested. For a hostname with an **existing explicit Nginx server_name**, acme.sh temporary Nginx validation is used instead, without overwriting the vhost |

The AutoSSL-managed HTTP virtual host for a **new domain** serves HTTP-01 challenges and returns **404 for other paths**. It does not configure your application or HTTPS. Review wildcard/default/catch-all Nginx server routing before using this option on a live domain.

Correct domain A/AAAA records, public port 80, hosting firewall/NAT and network connectivity to Let's Encrypt are still required. They cannot be automatically changed without network/provider access. Wildcards need DNS-01 and are not supported.

## Optional command-line administration

~~~bash
sudo autossl menu
sudo autossl status --domain sub.example.com
sudo autossl doctor --domain sub.example.com
sudo autossl renew
sudo autossl issue --domain sub.example.com --challenge standalone
sudo autossl issue --domain sub.example.com --challenge nginx
sudo autossl issue --domain sub.example.com --challenge webroot --webroot /var/www/html
systemctl status autossl-renew.timer
journalctl -u autossl-renew.service -n 100 --no-pager
~~~

The wizard does not auto-configure production TLS settings or restart unrelated services. Existing CLI users can still pass an optional --email argument during install or a --reload-service for an existing TLS service already configured to load the correct PEM files.

**Testing:** GitHub Actions covers Bash syntax, ShellCheck and mocked standalone/wizard/Nginx/renewal cases. Actual Let's Encrypt issuance and renewal on a real VPS/domain still require an end-to-end test.

See [SECURITY.md](SECURITY.md), [ISSUES.md](ISSUES.md), and the original [MIT license](upstream/LICENSE).
