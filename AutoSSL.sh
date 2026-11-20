#!/usr/bin/env bash
# AutoSSL: independent, security-hardened interactive ACME certificate manager.
# Original idea: https://github.com/monhacer/AutoSSL (MIT); see upstream/LICENSE.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly AUTOSSL_VERSION='2.1.0'
readonly ACME_VERSION='3.1.7'
readonly ACME_TAG_SHA='36d7fb616455b0f60b4dc45f2ebdea91019bcd95'
readonly ACME_SIGNER='github@neilpang.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBTjI0HBJn3uhfT2DsNcFybfAZi3ADbIacMpz1BItKdB'
readonly APP_DIR='/opt/autossl'
readonly ACME_HOME='/opt/autossl/acme'
readonly VERSION_FILE='/opt/autossl/.acme-version'
readonly CERT_ROOT='/etc/autossl/certs'
readonly BIN_PATH='/usr/local/sbin/autossl'
readonly TIMER='autossl-renew.timer'

say() { printf '[AutoSSL] %s\n' "$*" >&2; }
fatal() { printf '[AutoSSL] ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { (( EUID == 0 )) || fatal 'Run with sudo or as root.'; }
need() { command -v "$1" >/dev/null 2>&1 || fatal "Missing $1. Run: sudo bash AutoSSL.sh install-deps"; }
ask() {
  local prompt="$1" answer=''
  IFS= read -r -p "$prompt" answer || return 1
  printf '%s' "$answer"
}
yes_no() {
  local answer
  answer=$(ask "$1 [y/N]: ") || return 1
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}
lock_run() {
  need flock
  mkdir -p /run/lock
  exec 9>/run/lock/autossl.lock
  flock -n 9 || fatal 'Another AutoSSL operation is already running.'
}
valid_domain() {
  local domain="$1" label
  local -a labels=()
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != .* && "$domain" != *. ]] || fatal "Invalid domain: $domain"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || fatal 'Use an ASCII hostname, not wildcard or URL.'
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || fatal "Invalid hostname label: $domain"
  done
  [[ "${labels[${#labels[@]}-1]}" =~ ^[A-Za-z]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || fatal 'Invalid top-level domain.'
}
valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fatal 'Provide a real valid contact email.'
}
valid_service() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ && "$1" != *.service ]] || fatal 'Invalid systemd service name.'
}
check_deps() {
  local cmd
  for cmd in git curl openssl socat ssh-keygen flock systemctl install mktemp; do need "$cmd"; done
  [[ -d /run/systemd/system ]] || fatal 'systemd must be running (PID 1).'
}
install_deps() {
  need_root
  say 'Installing curl, git, openssl, socat, OpenSSH, CA certificates and system utilities.'
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl socat openssh-client iproute2 util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git openssl socat openssh-clients iproute util-linux
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git openssl socat openssh-clients iproute util-linux
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --needed --noconfirm ca-certificates curl git openssl socat openssh iproute2 util-linux
  else
    fatal 'No supported package manager (apt/dnf/yum/pacman). Install prerequisites manually.'
  fi
}
check_install() {
  [[ -x "$ACME_HOME/acme.sh" && -f "$VERSION_FILE" ]] || fatal 'Install AutoSSL first: sudo bash AutoSSL.sh install --email you@example.com'
  [[ "$(cat "$VERSION_FILE")" == "$ACME_VERSION" ]] || fatal 'Pinned acme.sh version mismatch. Reinstall from reviewed version.'
}
acme() {
  check_install
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_HOME" "$@"
}
install_signed_acme() (
  local email="$1" temp repo tag_sha
  temp=$(mktemp -d)
  trap 'rm -rf -- "$temp"' EXIT
  repo="$temp/source"
  mkdir -p "$repo" "$ACME_HOME"
  chmod 700 "$APP_DIR" "$ACME_HOME"
  printf '%s\n' "$ACME_SIGNER" > "$temp/allowed_signers"
  git -C "$repo" init -q
  git -C "$repo" remote add origin https://github.com/acmesh-official/acme.sh.git
  git -C "$repo" fetch -q --depth 1 origin "refs/tags/$ACME_VERSION:refs/tags/$ACME_VERSION"
  tag_sha=$(git -C "$repo" rev-parse "refs/tags/$ACME_VERSION")
  [[ "$tag_sha" == "$ACME_TAG_SHA" ]] || fatal 'acme.sh tag SHA mismatch. Download rejected.'
  git -C "$repo" -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$temp/allowed_signers" verify-tag "$ACME_VERSION" >/dev/null || fatal 'acme.sh release signature invalid.'
  git -C "$repo" checkout -q --detach "$ACME_VERSION"
  say "Verified acme.sh signed release $ACME_VERSION."
  (cd "$repo" && ./acme.sh --install --home "$ACME_HOME" --config-home "$ACME_HOME" --nocron --noprofile -m "$email")
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_HOME" --set-default-ca --server letsencrypt
  printf '%s\n' "$ACME_VERSION" > "$VERSION_FILE"
  chmod 600 "$VERSION_FILE"
)
write_timer() {
  local service_tmp timer_tmp
  service_tmp=$(mktemp /etc/systemd/system/.autossl-renew.service.XXXXXX)
  timer_tmp=$(mktemp /etc/systemd/system/.autossl-renew.timer.XXXXXX)
  cat > "$service_tmp" <<'SERVICE'
[Unit]
Description=AutoSSL daily ACME certificate renewal
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/sbin/autossl renew
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/autossl /etc/autossl /run
SERVICE
  cat > "$timer_tmp" <<'TIMER'
[Unit]
Description=Daily AutoSSL renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true
Unit=autossl-renew.service

[Install]
WantedBy=timers.target
TIMER
  chmod 644 "$service_tmp" "$timer_tmp"
  mv -f "$service_tmp" /etc/systemd/system/autossl-renew.service
  mv -f "$timer_tmp" /etc/systemd/system/autossl-renew.timer
  systemctl daemon-reload
  systemctl enable --now "$TIMER"
}
install_app() {
  need_root
  valid_email "$EMAIL"
  if [[ "$INSTALL_DEPS" == 1 ]]; then install_deps; fi
  check_deps
  lock_run
  mkdir -p "$APP_DIR" "$CERT_ROOT" /usr/local/sbin
  chmod 700 "$APP_DIR" "$CERT_ROOT"
  if [[ ! -x "$ACME_HOME/acme.sh" || ! -f "$VERSION_FILE" || "$(cat "$VERSION_FILE" 2>/dev/null || true)" != "$ACME_VERSION" ]]; then
    install_signed_acme "$EMAIL"
  else
    say "acme.sh $ACME_VERSION is already recorded as installed."
  fi
  local source_path temp_path
  source_path=$(readlink -f -- "$0")
  if [[ "$source_path" != "$BIN_PATH" ]]; then
    temp_path=$(mktemp /usr/local/sbin/.autossl.XXXXXX)
    install -m 0755 "$source_path" "$temp_path"
    mv -f "$temp_path" "$BIN_PATH"
  fi
  write_timer
  say 'Installed. Run: sudo autossl   (wizard), or sudo autossl issue --domain example.com'
}
issue_cert() {
  need_root
  [[ -n "$DOMAIN" ]] || fatal 'Missing --domain.'
  valid_domain "$DOMAIN"
  [[ "$CHALLENGE" == standalone || "$CHALLENGE" == webroot ]] || fatal 'Only standalone/webroot HTTP-01 challenges are supported.'
  if [[ "$CHALLENGE" == webroot ]]; then
    [[ -n "$WEBROOT" && "$WEBROOT" == /* && -d "$WEBROOT" && -w "$WEBROOT" ]] || fatal 'Provide writable absolute existing --webroot directory.'
  else
    [[ -z "$WEBROOT" ]] || fatal '--webroot requires --challenge webroot.'
  fi
  if [[ -n "$RELOAD_SERVICE" ]]; then
    valid_service "$RELOAD_SERVICE"
    systemctl cat "$RELOAD_SERVICE.service" >/dev/null 2>&1 || fatal 'Requested reload service does not exist.'
    [[ "$(systemctl show -p CanReload --value "$RELOAD_SERVICE.service" 2>/dev/null)" == yes ]] || fatal 'Requested service does not support systemctl reload.'
  fi
  check_install
  lock_run
  if [[ "$CHALLENGE" == standalone ]]; then
    say 'Standalone requires free publicly reachable TCP port 80 now AND at renewal time.'
    if command -v ss >/dev/null 2>&1 && [[ -n "$(ss -ltn '( sport = :80 )' | tail -n +2)" ]]; then
      fatal 'TCP port 80 is already listening. Use webroot or free the port safely.'
    fi
  else
    say "Webroot: ensure /.well-known/acme-challenge/ maps to $WEBROOT on public TCP 80."
  fi
  local dir rc=0
  dir="$CERT_ROOT/$DOMAIN"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local -a issue=(--issue -d "$DOMAIN" --server letsencrypt --keylength ec-256)
  if [[ "$CHALLENGE" == standalone ]]; then
    issue+=(--standalone)
  else
    issue+=(--webroot "$WEBROOT")
  fi
  acme "${issue[@]}" || rc=$?
  (( rc == 0 || rc == 2 )) || fatal "Certificate issuance failed (exit $rc)."
  local -a copied=(--install-cert -d "$DOMAIN" --ecc --key-file "$dir/private.pem" --fullchain-file "$dir/fullchain.pem")
  if [[ -n "$RELOAD_SERVICE" ]]; then
    copied+=(--reloadcmd "systemctl reload $RELOAD_SERVICE.service")
  fi
  acme "${copied[@]}" || fatal 'Certificate install or reload failed.'
  chmod 600 "$dir/private.pem"
  chmod 644 "$dir/fullchain.pem"
  openssl x509 -in "$dir/fullchain.pem" -noout -checkend 0 -checkhost "$DOMAIN" >/dev/null || fatal 'Certificate is expired, invalid, or does not match domain.'
  say "Certificate ready: $dir/fullchain.pem and $dir/private.pem"
}
renew_cert() {
  need_root
  check_install
  lock_run
  acme --cron || fatal 'Renewal failed. Inspect: journalctl -u autossl-renew.service'
  say 'Scheduled renewal check completed.'
}
status_cert() {
  need_root
  [[ -n "$DOMAIN" ]] || fatal 'Missing --domain.'
  valid_domain "$DOMAIN"
  local cert="$CERT_ROOT/$DOMAIN/fullchain.pem"
  [[ -s "$cert" ]] || fatal "No installed cert for $DOMAIN."
  openssl x509 -in "$cert" -noout -subject -issuer -dates
  if openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null; then
    say 'Certificate valid for more than 30 days.'
  else
    say 'Certificate expires within 30 days or has expired.'
  fi
  systemctl list-timers --all "$TIMER" --no-pager || true
}
doctor() {
  local cmd errors=0
  for cmd in bash git curl openssl socat ssh-keygen flock systemctl; do
    if command -v "$cmd" >/dev/null 2>&1; then say "OK: $cmd"; else say "MISSING: $cmd"; errors=1; fi
  done
  if [[ -x "$ACME_HOME/acme.sh" ]]; then say 'OK: acme.sh exists'; else say 'MISSING: acme.sh'; errors=1; fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled "$TIMER" >/dev/null 2>&1; then say 'OK: renewal timer enabled'; else say 'MISSING: renewal timer'; errors=1; fi
  fi
  if [[ -n "$DOMAIN" ]]; then
    valid_domain "$DOMAIN"
    if command -v getent >/dev/null 2>&1; then getent ahostsv4 "$DOMAIN" | head -n 1 || say 'WARNING: no IPv4 A lookup.'; fi
    [[ -f "$CERT_ROOT/$DOMAIN/fullchain.pem" ]] && say 'OK: cert exists' || say 'Certificate not installed yet.'
  fi
  (( errors == 0 )) || fatal 'Doctor found missing prerequisites.'
}
print_help() {
  cat <<'HELP'
AutoSSL v2.1 — free SSL certificate wizard, signed acme.sh 3.1.7, auto renewal.

  sudo bash AutoSSL.sh                  Interactive wizard (same as "wizard")
  sudo bash AutoSSL.sh wizard           Interactive setup, issue, status and renewal
  sudo bash AutoSSL.sh install --email admin@example.com [--install-deps]
  sudo autossl issue --domain example.com [--challenge standalone]
  sudo autossl issue --domain example.com --challenge webroot --webroot /var/www/html [--reload-service nginx]
  sudo autossl status --domain example.com
  sudo autossl renew
  sudo autossl doctor [--domain example.com]
  sudo autossl install-deps

Standalone requires TCP/80 available for issuance and subsequent renewals.
Webroot requires a reachable HTTP challenge directory. Wildcards/DNS-01 are not supported.
No service is restarted automatically. --reload-service is explicit and optional.
HELP
}
wizard_issue() {
  local value
  if [[ ! -x "$ACME_HOME/acme.sh" || ! -f "$VERSION_FILE" ]]; then
    say 'First run: required dependencies and acme.sh will be installed.'
    EMAIL=$(ask 'Registration email (real address): ') || return 1
    valid_email "$EMAIL"
    if yes_no 'Install missing system packages if needed?'; then INSTALL_DEPS=1; else INSTALL_DEPS=0; fi
    install_app
  fi
  DOMAIN=$(ask 'Domain / subdomain (example.com): ') || return 1
  valid_domain "$DOMAIN"
  printf '\nChallenge method:\n  1) Standalone (port 80 must be free)\n  2) Webroot (Nginx/Apache running)\n'
  value=$(ask 'Choose [1/2]: ') || return 1
  case "$value" in
    1) CHALLENGE=standalone; WEBROOT='' ;;
    2)
      CHALLENGE=webroot
      WEBROOT=$(ask 'Webroot absolute path (e.g. /var/www/html): ') || return 1
      ;;
    *) say 'Invalid challenge choice; nothing was issued.'; return 1 ;;
  esac
  RELOAD_SERVICE=''
  if yes_no 'Reload a configured systemd web service after certificate install/renewal?'; then
    RELOAD_SERVICE=$(ask 'Service name without .service (e.g. nginx): ') || return 1
  fi
  printf '\nDomain: %s\nMethod: %s\nWebroot: %s\nReload: %s\n' "$DOMAIN" "$CHALLENGE" "${WEBROOT:-<none>}" "${RELOAD_SERVICE:-<none>}"
  if yes_no "Proceed with real Let's Encrypt request?"; then issue_cert; else say 'Canceled.'; fi
}
wizard() {
  need_root
  local choice
  while :; do
    printf '\n=======================================\n'
    printf '  AutoSSL %s - SSL Wizard\n' "$AUTOSSL_VERSION"
    printf '=======================================\n'
    printf '  1) Install & obtain SSL certificate / نصب و دریافت گواهی\n'
    printf '  2) Issue another certificate / صدور گواهی جدید\n'
    printf '  3) Show certificate status / نمایش وضعیت گواهی\n'
    printf '  4) Check automatic/manual renewal / بررسی تمدید\n'
    printf '  5) Diagnose installation / عیب‌یابی\n'
    printf '  6) Install dependencies / نصب وابستگی‌ها\n'
    printf '  0) Exit / خروج\n'
    choice=$(ask 'Select [0-6]: ') || { printf '\n'; break; }
    case "$choice" in
      1|2) wizard_issue ;;
      3) DOMAIN=$(ask 'Domain: ') || break; status_cert ;;
      4) if yes_no 'Run renewal check now?'; then renew_cert; fi ;;
      5) DOMAIN=$(ask 'Domain for optional DNS check (blank to skip): ') || break; doctor ;;
      6) if yes_no 'Allow package manager to install dependencies?'; then install_deps; fi ;;
      0) break ;;
      *) say 'Invalid menu option.' ;;
    esac
  done
}

COMMAND="${1:-wizard}"
if (($#)); then shift; fi
DOMAIN='' EMAIL='' CHALLENGE='standalone' WEBROOT='' RELOAD_SERVICE='' INSTALL_DEPS=0
while (($#)); do
  case "$1" in
    --domain|--email|--challenge|--webroot|--reload-service)
      (($# >= 2)) || fatal "Missing value after $1"
      case "$1" in
        --domain) DOMAIN="$2" ;;
        --email) EMAIL="$2" ;;
        --challenge) CHALLENGE="$2" ;;
        --webroot) WEBROOT="$2" ;;
        --reload-service) RELOAD_SERVICE="$2" ;;
      esac
      shift 2 ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --help|-h) COMMAND='help'; shift ;;
    *) fatal "Unknown option: $1" ;;
  esac
done
case "$COMMAND" in
  wizard|menu) wizard ;;
  install) install_app ;;
  install-deps) install_deps ;;
  issue) issue_cert ;;
  renew) renew_cert ;;
  status) status_cert ;;
  doctor) doctor ;;
  help|-h|--help) print_help ;;
  *) print_help; fatal "Unknown command: $COMMAND" ;;
esac
