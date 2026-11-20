# Source review, issues and implemented fixes

**Reviewed original:** [monhacer/AutoSSL](https://github.com/monhacer/AutoSSL), commit `db5a0372f1462fd3e5032b817a35b0f5e4c99e55`. These are code-quality/security observations, **not** proven exploitable security vulnerabilities.

| Level | Observed in original | Improvement in this repo |
|---|---|---|
| High | Root executes `curl https://get.acme.sh | sh` with no signature/pinning | Install **acme.sh 3.1.7** only from SSH-signed annotated tag; require known tag SHA and pinned public signer |
| High | Fabricates a Gmail address when operator omits email | Email is optional with Let's Encrypt; supports a genuine optional contact via AUTOSSL_EMAIL or --email and never fabricates an address |
| High | Lacks strict failure handling around ACME issue and cert install | Strict Bash mode, explicit ACME result checks, `openssl x509` validity+hostname check |
| High | Assumes standalone TCP/80 is always available | Two-input wizard provides standalone or automated Nginx/webroot with a safe existing-site fallback |
| Medium | Forces issuance with `--force` | Avoids unnecessary orders and ACME CA rate limits |
| Medium | Automatically restarts unrelated web services | Reload **only** the explicitly named service; persist reload hook across renewals |
| Medium | No clearly controlled renewal scheduler | Dedicated persistent daily systemd timer with logs, no acme.sh cron dependency |
| Medium | Domain interpolated into filesystem path without strict validation | Strict ASCII DNS label validation, root-only target directories |
| Medium | Can run duplicate ACME operations at once | `flock` exclusivity for installation/issue/renew |
| Medium | No formal reinstall / diagnosis workflow | Idempotent install handling, doctor, status and wizard menu |
| Low | Depends on socat but doesn't comprehensively prepare system | Dependency installer for APT, DNF/YUM and Pacman |
| Low | Sparse documentation and tests | Bilingual guides, security notes and mocked CI checks |

**Important upstream change:** [acme.sh 3.1.7](https://github.com/acmesh-official/acme.sh/releases/tag/3.1.7), released 2026-11-19, fixed a bug in how untrusted CA-returned values were parsed/persisted. Our wrapper pins that release rather than following an unsupervised branch update.

## Known remaining restrictions

1. Live issuance requires a real domain, correct DNS records (A/AAAA), port 80 and CA connectivity; mocked CI does not prove it works on a specific VPS.
2. Standalone renewal requires port 80 free **every** time a certificate is due for renewal; no automatic service stopping is performed.
3. New-hostname Nginx webroot challenges are automated; existing explicit Nginx hosts use temporary acme.sh Nginx mode; production HTTPS configuration remains administrator-controlled.
4. Only **HTTP-01** issuance is included; wildcard and DNS-01 APIs are excluded.
5. Only **systemd Linux** is supported. For unsupported distributions, dependencies and timer require a different implementation.
6. The acme.sh dependency is intentionally pinned; upgrading requires a manual security review and signature/hash update.
7. Cert files are root-only by default. If a non-root service needs access, use carefully scoped permissions/ACLs.
8. No automatic CA staging dry-run occurs. Deploy to a noncritical host and verify a genuine renewal before relying on it.

## AutoSSL v2.2 improvements

- Wizard asks only domain and Standalone vs automatic Nginx choice, after selecting the install menu action.
- Missing dependencies install automatically; contact email is optional (Let's Encrypt supports no-email accounts).
- For new Nginx names, create and locally test a managed HTTP-01 vhost and webroot; for existing explicit vhosts, use non-destructive acme.sh Nginx validation.
- Final output shows separately labeled private.pem and public.pem paths. Public certificate is a symlink to the renewed fullchain.pem.
- Mocked CI covers both wizard choices and an existing named Nginx server. Real VPS issuance/renewal is not verified.
