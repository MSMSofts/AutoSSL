#!/usr/bin/env bash
# AutoSSL: independent, security-hardened interactive ACME certificate manager.
# Original idea: https://github.com/monhacer/AutoSSL (MIT); see upstream/LICENSE.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly AUTOSSL_VERSION='2.2.0'
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
missing_deps() {
  local cmd
  for cmd in git curl openssl socat ssh-keygen flock systemctl install mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || return 0
  done
  return 1
}
install_package() {
  local package="$1"
  need_root
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y "$package"
  elif command -v yum >/dev/null 2>&1; then yum install -y "$package"
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --needed --noconfirm "$package"
  else fatal 'No supported package manager (apt/dnf/yum/pacman).'; fi
}
ensure_deps() {
  if missing_deps; then
    say 'Automatically installing missing system dependencies...'
    install_deps
  fi
  check_deps
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
  [[ -x "$ACME_HOME/acme.sh" && -f "$VERSION_FILE" ]] || fatal 'Install AutoSSL first: sudo bash AutoSSL.sh install'
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
  local -a install_args=(--install --home "$ACME_HOME" --config-home "$ACME_HOME" --nocron --noprofile)
  if [[ -n "$email" ]]; then
    install_args+=(-m "$email")
  else
    say "No email configured. Let's Encrypt permits contact-free accounts; expiration notices will not be emailed."
  fi
  (cd "$repo" && ./acme.sh "${install_args[@]}")
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
ReadWritePaths=/opt/autossl /etc/autossl /var/lib/autossl -/etc/nginx /run
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
  if [[ -n "$EMAIL" ]]; then valid_email "$EMAIL"; fi
  if [[ "$INSTALL_DEPS" == 1 ]]; then install_deps; else ensure_deps; fi
  lock_run
  mkdir -p "$APP_DIR" "$CERT_ROOT" /var/lib/autossl /usr/local/sbin
  chmod 700 "$APP_DIR" "$CERT_ROOT" /var/lib/autossl
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
# The Nginx choice is fully managed for a NEW hostname: install Nginx if
# absent, provision an isolated HTTP-01 vhost, validate it and reload safely.
# An EXISTING hostname uses the upstream acme.sh Nginx challenge mode instead,
# to avoid rewriting or shadowing a user's production server block.
nginx_domain_declared() {
  local current regex
  current=$(nginx -T 2>&1) || fatal 'Existing Nginx configuration is invalid. Fix nginx -t first.'
  regex=${DOMAIN//./\\.}
  grep -Eq "^[[:space:]]*server_name[[:space:]]+[^;]*${regex}([[:space:];]|$)" <<< "$current"
}
prepare_nginx() {
  need_root
  if ! command -v nginx >/dev/null 2>&1; then
    say 'Installing Nginx automatically for HTTP-01 webroot validation...'
    install_package nginx
  fi
  need nginx
  [[ -d /etc/nginx ]] || fatal 'Missing /etc/nginx. Repair Nginx installation.'
  local conf="/etc/nginx/conf.d/autossl-${DOMAIN}.conf"
  local vhost_owned=0 probe response
  WEBROOT="/var/lib/autossl/challenges/$DOMAIN"
  if [[ -e "$conf" ]]; then
    grep -Fqx '# AutoSSL-managed HTTP-01 vhost' "$conf" || fatal "Refusing to overwrite unrelated Nginx configuration: $conf"
    vhost_owned=1
  elif nginx_domain_declared; then
    say 'Existing Nginx virtual host detected; using acme.sh Nginx validation without modifying it.'
    NGINX_HTTP_MODE='nginx'
    return 0
  fi
  mkdir -p /etc/nginx/conf.d /var/lib/autossl/challenges "$WEBROOT/.well-known/acme-challenge"
  chmod 755 /var/lib/autossl /var/lib/autossl/challenges "$WEBROOT" "$WEBROOT/.well-known" "$WEBROOT/.well-known/acme-challenge"
  if (( vhost_owned == 0 )); then
    cat > "$conf" <<NGINX
# AutoSSL-managed HTTP-01 vhost
server {
    listen 80;
    server_name $DOMAIN;
    root $WEBROOT;
    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
NGINX
  fi
  chmod 644 "$conf"
  if ! nginx -t; then
    if (( vhost_owned == 0 )); then rm -f -- "$conf"; fi
    fatal 'Nginx configuration failed nginx -t; new managed vhost reverted.'
  fi
  local nginx_dump
  nginx_dump=$(nginx -T 2>&1) || fatal "Failed to inspect Nginx configuration."
  if ! grep -Fq "# configuration file $conf:" <<< "$nginx_dump"; then
    if (( vhost_owned == 0 )); then rm -f -- "$conf"; fi
    fatal 'Nginx does not include /etc/nginx/conf.d/*.conf; cannot configure webroot safely.'
  fi
  if systemctl is-active --quiet nginx.service; then
    if ! systemctl reload nginx.service; then
      if (( vhost_owned == 0 )); then rm -f -- "$conf"; nginx -t && systemctl reload nginx.service || true; fi
      fatal 'Could not reload Nginx; managed vhost was rolled back.'
    fi
  else
    if ! systemctl enable --now nginx.service; then
      if (( vhost_owned == 0 )); then rm -f -- "$conf"; fi
      fatal 'Nginx could not start; check port 80 conflicts and journalctl -u nginx.'
    fi
  fi
  probe="autossl-$(openssl rand -hex 12)"
  printf '%s\n' "$probe" > "$WEBROOT/.well-known/acme-challenge/$probe"
  response=$(curl -fsS --noproxy '*' --connect-timeout 4 --max-time 10 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/.well-known/acme-challenge/$probe") || {
    rm -f -- "$WEBROOT/.well-known/acme-challenge/$probe"
    fatal 'Nginx HTTP-01 local self-test failed; check server_name and port 80.'
  }
  rm -f -- "$WEBROOT/.well-known/acme-challenge/$probe"
  [[ "$response" == "$probe" ]] || fatal 'Nginx served unexpected HTTP-01 content; refusing issuance.'
  NGINX_HTTP_MODE='webroot'
  say "Nginx webroot prepared and verified automatically: $WEBROOT"
}
ensure_ready() {
  need_root
  if [[ ! -x "$ACME_HOME/acme.sh" || ! -f "$VERSION_FILE" || "$(cat "$VERSION_FILE" 2>/dev/null || true)" != "$ACME_VERSION" || ! -x "$BIN_PATH" || ( "$(readlink -f -- "$0")" != "$BIN_PATH" && ! -s "$BIN_PATH" ) ]]; then
    say 'First-run setup: dependencies, verified acme.sh and systemd renewal timer...'
    install_app
  else
    if [[ "$(readlink -f -- "$0")" != "$BIN_PATH" ]] && ! cmp -s -- "$0" "$BIN_PATH"; then
      say 'Installing the updated AutoSSL wrapper automatically...'
      local temp_path
      temp_path=$(mktemp /usr/local/sbin/.autossl.XXXXXX)
      install -m 0755 "$0" "$temp_path"
      mv -f "$temp_path" "$BIN_PATH"
    fi
    if ! systemctl is-enabled --quiet "$TIMER"; then
      say 'Restoring automatic certificate renewal timer...'
      write_timer
    fi
  fi
}
show_pem_paths() {
  local cert_dir="$CERT_ROOT/$DOMAIN"
  printf '\n'
  printf '==============================================\n'
  printf ' AutoSSL — certificate installed for %s\n' "$DOMAIN"
  printf '==============================================\n'
  printf '\n'
  printf ' PRIVATE KEY (PEM) / کلید خصوصی:\n'
  printf ' %s/private.pem\n' "$cert_dir"
  printf '\n'
  printf ' PUBLIC CERTIFICATE (PEM) / گواهی عمومی:\n'
  printf ' %s/public.pem\n' "$cert_dir"
  printf '==============================================\n'
}
issue_cert() {
  need_root
  [[ -n "$DOMAIN" ]] || fatal 'Missing --domain.'
  valid_domain "$DOMAIN"
  [[ "$CHALLENGE" == standalone || "$CHALLENGE" == webroot || "$CHALLENGE" == nginx ]] || fatal 'Choose standalone, webroot, or nginx.'
  check_install
  lock_run
  if [[ "$CHALLENGE" == nginx ]]; then
    prepare_nginx
  fi
  if [[ "$CHALLENGE" == webroot || ( "$CHALLENGE" == nginx && "$NGINX_HTTP_MODE" == webroot ) ]]; then
    [[ -n "$WEBROOT" && "$WEBROOT" == /* && -d "$WEBROOT" && -w "$WEBROOT" ]] || fatal 'Provide writable absolute existing --webroot directory.'
  else
    [[ "$CHALLENGE" == nginx || -z "$WEBROOT" ]] || fatal '--webroot requires --challenge webroot.'
  fi
  if [[ -n "$RELOAD_SERVICE" ]]; then
    valid_service "$RELOAD_SERVICE"
    systemctl cat "$RELOAD_SERVICE.service" >/dev/null 2>&1 || fatal 'Requested reload service does not exist.'
    [[ "$(systemctl show -p CanReload --value "$RELOAD_SERVICE.service" 2>/dev/null)" == yes ]] || fatal 'Requested service does not support systemctl reload.'
  fi
  if [[ "$CHALLENGE" == standalone ]]; then
    say 'Standalone requires free publicly reachable TCP port 80 now AND at renewal time.'
    if command -v ss >/dev/null 2>&1 && [[ -n "$(ss -ltn '( sport = :80 )' | tail -n +2)" ]]; then
      fatal 'TCP port 80 is already listening. Use webroot or free the port safely.'
    fi
  elif [[ "$CHALLENGE" == webroot || "$NGINX_HTTP_MODE" == webroot ]]; then
    say "Webroot: serving /.well-known/acme-challenge/ from $WEBROOT on TCP 80."
  else
    say 'Existing Nginx vhost: upstream acme.sh will perform its temporary Nginx HTTP-01 challenge.'
  fi
  local dir rc=0
  dir="$CERT_ROOT/$DOMAIN"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local -a issue=(--issue -d "$DOMAIN" --server letsencrypt --keylength ec-256)
  if [[ "$CHALLENGE" == standalone ]]; then
    issue+=(--standalone)
  elif [[ "$CHALLENGE" == nginx && "$NGINX_HTTP_MODE" == nginx ]]; then
    issue+=(--nginx)
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
  ln -sfnT fullchain.pem "$dir/public.pem"
  show_pem_paths
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
AutoSSL v2.2 — two-step wizard, signed acme.sh 3.1.7, auto renewal.

  sudo bash AutoSSL.sh                  Interactive wizard (same as "wizard")
  sudo bash AutoSSL.sh wizard           Interactive setup, issue, status and renewal
  sudo bash AutoSSL.sh install [--email admin@example.com]
  sudo autossl issue --domain example.com --challenge nginx # automatic Nginx HTTP-01
  sudo autossl issue --domain example.com [--challenge standalone]
  sudo autossl issue --domain example.com --challenge webroot --webroot /var/www/html [--reload-service nginx]
  sudo autossl status --domain example.com
  sudo autossl renew
  sudo autossl doctor [--domain example.com]
  sudo autossl install-deps

Standalone requires TCP/80 available for issuance and subsequent renewals.
Webroot requires a reachable HTTP challenge directory. Wildcards/DNS-01 are not supported.
On wizard's Nginx choice, Nginx may be installed, started and safely reloaded.
Email is optional; set --email (CLI) or AUTOSSL_EMAIL (environment) for notices.
HTTPS Nginx server configuration is not modified automatically.
HELP
}
wizard_issue() {
  local choice
  DOMAIN=$(ask 'Domain / دامنه (example.com): ') || return 1
  valid_domain "$DOMAIN"
  printf '\n  1) Standalone — free port 80 / پورت ۸۰ آزاد\n'
  printf '  2) Webroot + Nginx — automatic setup / تنظیم خودکار Nginx\n'
  choice=$(ask 'Choose [1/2] / انتخاب: ') || return 1
  case "$choice" in
    1) CHALLENGE='standalone'; WEBROOT='';;
    2) CHALLENGE='nginx'; WEBROOT='';;
    *) say 'Invalid choice. Please enter 1 or 2.'; return 1 ;;
  esac
  ensure_ready
  issue_cert
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
      1|2) wizard_issue; break ;;
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
DOMAIN='' EMAIL="${AUTOSSL_EMAIL:-}" CHALLENGE='standalone' WEBROOT='' RELOAD_SERVICE='' INSTALL_DEPS=0 NGINX_HTTP_MODE=''
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
