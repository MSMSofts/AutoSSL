#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
script="$(cd "$(dirname "$0")/.." && pwd)/AutoSSL.sh"
[[ "$(id -u)" == 0 ]] || { echo 'Tests require root inside disposable CI runner.' >&2; exit 1; }
[[ ! -e /opt/autossl/acme/acme.sh && ! -e /opt/autossl/.acme-version && ! -e /etc/autossl/certs/example.test ]] || {
  echo 'Refusing tests because real AutoSSL test paths exist.' >&2
  exit 1
}
work=$(mktemp -d)
cleanup() {
  rm -rf /opt/autossl/acme/acme.sh /etc/autossl/certs/example.test "$work"
  rm -f /opt/autossl/.acme-version
}
trap cleanup EXIT
bash -n "$script"
bash "$script" help | grep -q 'Interactive wizard'
printf '0\n' | bash "$script" wizard | grep -q 'AutoSSL 2.1.0 - SSL Wizard'
if bash "$script" issue --domain '../bad' >/dev/null 2>&1; then echo 'Accepted directory traversal.' >&2; exit 1; fi
if bash "$script" issue --domain 'bad..example.com' >/dev/null 2>&1; then echo 'Accepted bad DNS domain.' >&2; exit 1; fi
if bash "$script" issue --domain '*example.com' >/dev/null 2>&1; then echo 'Accepted wildcard in HTTP-01.' >&2; exit 1; fi
if bash "$script" issue --domain 'example.test' --challenge webroot --webroot ../tmp >/dev/null 2>&1; then echo 'Accepted relative webroot.' >&2; exit 1; fi
if bash "$script" install --email 'bad@@domain' >/dev/null 2>&1; then echo 'Accepted invalid email.' >&2; exit 1; fi
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=example.test \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
mkdir -p /opt/autossl/acme "$work/webroot"
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
printf '2\nexample.test\n2\n%s\nn\ny\n0\n' "$work/webroot" | bash "$script" wizard >/dev/null
[[ -s /etc/autossl/certs/example.test/private.pem ]]
[[ -s /etc/autossl/certs/example.test/fullchain.pem ]]
[[ "$(stat -c %a /etc/autossl/certs/example.test/private.pem)" == 600 ]]
printf 'AutoSSL wizard and mocked issuance/renewal checks: PASS\n'
