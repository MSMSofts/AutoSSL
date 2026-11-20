#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
script="$(cd "$(dirname "$0")/.." && pwd)/AutoSSL.sh"
[[ "$(id -u)" == 0 ]] || { echo 'Tests require root inside disposable CI runner.' >&2; exit 1; }
[[ ! -e /opt/autossl/acme/acme.sh && ! -e /opt/autossl/.acme-version && ! -e /etc/autossl/certs/example.test ]] || {
  echo 'Refusing tests because real AutoSSL test paths exist.' >&2
  exit 1
}
[[ ! -e /usr/local/sbin/autossl && ! -e /etc/nginx/conf.d/autossl-example.test.conf ]] || { echo 'Existing AutoSSL/Nginx test configuration: refusing CI overwrite.' >&2; exit 1; }
work=$(mktemp -d)
cleanup() {
  rm -rf /opt/autossl/acme/acme.sh /etc/autossl/certs/example.test "$work"
  rm -f /opt/autossl/.acme-version /usr/local/sbin/autossl /etc/nginx/conf.d/autossl-example.test.conf
  rm -rf /var/lib/autossl/challenges/example.test
}
trap cleanup EXIT
bash -n "$script"
bash "$script" help | grep -q 'two-step wizard'
printf '0\n' | bash "$script" wizard | grep -q 'AutoSSL 2.2.0 - SSL Wizard'
if bash "$script" issue --domain '../bad' >/dev/null 2>&1; then echo 'Accepted directory traversal.' >&2; exit 1; fi
if bash "$script" issue --domain 'bad..example.com' >/dev/null 2>&1; then echo 'Accepted bad DNS domain.' >&2; exit 1; fi
if bash "$script" issue --domain '*example.com' >/dev/null 2>&1; then echo 'Accepted wildcard in HTTP-01.' >&2; exit 1; fi
if bash "$script" issue --domain 'example.test' --challenge webroot --webroot ../tmp >/dev/null 2>&1; then echo 'Accepted relative webroot.' >&2; exit 1; fi
if bash "$script" install --email 'bad@@domain' >/dev/null 2>&1; then echo 'Accepted invalid email.' >&2; exit 1; fi
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=example.test \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
mkdir -p /opt/autossl/acme "$work/webroot" "$work/mockbin" /etc/nginx/conf.d
install -m 0755 "$script" /usr/local/sbin/autossl
printf '3.1.7\n' > /opt/autossl/.acme-version
cat > /opt/autossl/acme/acme.sh <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
mode='' key='' full=''
while (($#)); do
  case "$1" in
    --issue|--install-cert|--cron) mode="$1"; shift ;;
    --key-file) key="$2"; shift 2 ;;
    --fullchain-file) full="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$mode" in
  --issue|--cron) exit 0 ;;
  --install-cert)
    cp "$AUTOSSL_MOCK_KEY" "$key"
    cp "$AUTOSSL_MOCK_CERT" "$full"
    exit 0 ;;
  *) exit 1 ;;
esac
MOCK
chmod 700 /opt/autossl/acme/acme.sh
export AUTOSSL_MOCK_KEY="$work/key.pem" AUTOSSL_MOCK_CERT="$work/cert.pem"
bash "$script" issue --domain example.test --challenge webroot --webroot "$work/webroot"
bash "$script" status --domain example.test | grep -q 'notAfter='
bash "$script" renew
# End-to-end interactive menu path with mocked ACME backend (choose issue, webroot, no reload).
# Test 1: two-prompt Standalone wizard; fake systemctl and ss avoid real system mutations.
cat > "$work/mockbin/systemctl" <<'MOCKSYSTEM'
#!/usr/bin/env bash
case "${1:-}" in is-enabled|is-active|reload|enable|daemon-reload|list-timers) exit 0 ;; *) exit 0 ;; esac
MOCKSYSTEM
cat > "$work/mockbin/ss" <<'MOCKSS'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
MOCKSS
cat > "$work/mockbin/nginx" <<'MOCKNGINX'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit 0 ;;
  -T)
    printf 'server { server_name _; }\n'
    [[ "${AUTOSSL_MOCK_EXISTING_VHOST:-0}" == 1 ]] && printf 'server_name example.test;\n'
    for f in /etc/nginx/conf.d/autossl-*.conf; do
      if [[ -f "$f" ]]; then printf '# configuration file %s:\n' "$f"; cat -- "$f"; fi
    done
    exit 0 ;;
  *) exit 1 ;;
esac
MOCKNGINX
cat > "$work/mockbin/curl" <<'MOCKCURL'
#!/usr/bin/env bash
url="${*: -1}"
probe="${url##*/}"
cat "/var/lib/autossl/challenges/example.test/.well-known/acme-challenge/$probe"
MOCKCURL
chmod 755 "$work/mockbin/"*
export PATH="$work/mockbin:$PATH"
printf '1\nexample.test\n1\n' | bash "$script" wizard >"$work/wizard-standalone.txt"
grep -q '/etc/autossl/certs/example.test/private.pem' "$work/wizard-standalone.txt"
grep -q '/etc/autossl/certs/example.test/public.pem' "$work/wizard-standalone.txt"
! tail -n 5 "$work/wizard-standalone.txt" | grep -q 'Select \[0-6\]'

# Test 2: managed Webroot + Nginx configuration.
printf '1\nexample.test\n2\n' | bash "$script" wizard >"$work/wizard-nginx.txt"
[[ -f /etc/nginx/conf.d/autossl-example.test.conf ]]
grep -q '/etc/autossl/certs/example.test/private.pem' "$work/wizard-nginx.txt"
grep -q '/etc/autossl/certs/example.test/public.pem' "$work/wizard-nginx.txt"

# Test 3: existing named Nginx site receives non-destructive --nginx ACME validation.
rm -f /etc/nginx/conf.d/autossl-example.test.conf
export AUTOSSL_MOCK_EXISTING_VHOST=1
bash "$script" issue --domain example.test --challenge nginx >"$work/existing-nginx.txt"
[[ ! -e /etc/nginx/conf.d/autossl-example.test.conf ]]
grep -q '/etc/autossl/certs/example.test/public.pem' "$work/existing-nginx.txt"
[[ -s /etc/autossl/certs/example.test/private.pem ]]
[[ -s /etc/autossl/certs/example.test/fullchain.pem ]]
[[ "$(readlink /etc/autossl/certs/example.test/public.pem)" == fullchain.pem ]]
[[ "$(stat -c %a /etc/autossl/certs/example.test/private.pem)" == 600 ]]
printf 'AutoSSL v2.2 two-prompt wizard, Nginx and mocked renewal checks: PASS\n'
