#!/usr/bin/env bash
set -euo pipefail
SERVER_IP=""
SERVER_DOMAIN=""
LISTEN_PORT="8443"
LISTEN_PORT_SET="false"
SSH_PORT="22"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    --server-domain) SERVER_DOMAIN="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; LISTEN_PORT_SET="true"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) || { echo "invalid --listen-port: $LISTEN_PORT" >&2; exit 2; }
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || { echo "invalid --ssh-port: $SSH_PORT" >&2; exit 2; }
PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) BIN_SRC="$PAYLOAD_DIR/quickconect-server-linux-amd64" ;;
  aarch64|arm64) BIN_SRC="$PAYLOAD_DIR/quickconect-server-linux-arm64" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
[[ -f "$BIN_SRC" ]] || { echo "missing binary: $BIN_SRC" >&2; exit 1; }
[[ -f "$PAYLOAD_DIR/firewall.sh" ]] || { echo "missing firewall.sh: upload the complete deployment bundle" >&2; exit 1; }
echo "[1/7] Preparing user and directories"
id -u quickconect &>/dev/null || useradd --system --home-dir /var/lib/quickconect --shell /usr/sbin/nologin quickconect
mkdir -p /opt/quickconect /etc/quickconect /var/lib/quickconect/media
echo "[2/7] Installing server binary"
install -m 0755 "$BIN_SRC" /opt/quickconect/quickconect-server
echo "[3/7] Preserving or creating configuration"
if [[ ! -f /etc/quickconect/config.yaml ]]; then
  cat > /etc/quickconect/config.yaml <<EOF
listen: ":$LISTEN_PORT"
tls_enabled: true
tls_cert: /etc/quickconect/server.crt
tls_key: /etc/quickconect/server.key
db_path: /var/lib/quickconect/quickconect.db
media_path: /var/lib/quickconect/media
media_max_mb: 100
user_quota_gb: 10
ntfy:
  enabled: true
  base_url: https://ntfy.sh
  coalesce_seconds: 30
  include_sender: false
EOF
  echo "    閻庣懓鎲¤ぐ鍐疮閹捐绀?/etc/quickconect/config.yaml"
else
  echo "Existing config kept"
  CURRENT_LISTEN="$(sed -nE 's/^listen:[[:space:]]*":([0-9]+)".*/\1/p' /etc/quickconect/config.yaml | head -n 1)"
  if [[ "$LISTEN_PORT_SET" == "true" ]]; then
    sed -i -E "s#^listen:.*#listen: \":$LISTEN_PORT\"#" /etc/quickconect/config.yaml
    echo "Configured service port: $LISTEN_PORT"
  elif [[ -n "$CURRENT_LISTEN" ]]; then
    echo "Using existing configured service port: $CURRENT_LISTEN"
    LISTEN_PORT="$CURRENT_LISTEN"
  fi
fi
echo "[4/7] Preserving or creating certificates"
if [[ ! -f /etc/quickconect/server.crt ]]; then
  command -v openssl >/dev/null || { echo "闂備焦瀵ч悷銊╊敋? 闂傚倸娲犻崑鎾绘偡?openssl"; exit 1; }
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(curl -s --max-time 5 https://api.ipify.org || true)"
  fi
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
echo "Public IP detection returned: $SERVER_IP"
echo "Pass --server-ip explicitly when needed"
  fi
  TMP="$(mktemp -d)"
  openssl ecparam -genkey -name prime256v1 -out "$TMP/ca.key" 2>/dev/null
  openssl req -x509 -new -key "$TMP/ca.key" -sha256 -days 3650 \
    -out "$TMP/ca.crt" -subj "/CN=QuickConect Root CA" 2>/dev/null
  openssl ecparam -genkey -name prime256v1 -out "$TMP/server.key" 2>/dev/null
  CN="${SERVER_DOMAIN:-$SERVER_IP}"
  openssl req -new -key "$TMP/server.key" -out "$TMP/server.csr" -subj "/CN=$CN" 2>/dev/null
  { printf 'subjectAltName='; [[ -n "$SERVER_IP" ]] && printf 'IP:%s' "$SERVER_IP"; [[ -n "$SERVER_DOMAIN" ]] && { [[ -n "$SERVER_IP" ]] && printf ','; printf 'DNS:%s' "$SERVER_DOMAIN"; }; printf '\nextendedKeyUsage=serverAuth\n'; } > "$TMP/san.ext"
  openssl x509 -req -in "$TMP/server.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" \
    -CAcreateserial -out "$TMP/server.crt" -days 1825 -sha256 -extfile "$TMP/san.ext" 2>/dev/null
  install -m 0644 "$TMP/ca.crt" /etc/quickconect/ca.crt
  install -m 0644 "$TMP/server.crt" /etc/quickconect/server.crt
  install -m 0600 "$TMP/server.key" /etc/quickconect/server.key
  rm -rf "$TMP"
  echo "    闁荤姴娲ｅ鎺楀礉閻斿鍟呴柤纰卞墯閺呮悂鏌熺€涙ê濮х紒杈ㄧ箘缁辨帡骞嬪┑鍫熸瘞 IP: $SERVER_IP"
else
  echo "Certificate created"
fi
echo "[5/7] Applying permissions"
chown -R quickconect:quickconect /var/lib/quickconect
chown quickconect:quickconect /etc/quickconect/server.key
chmod 0600 /etc/quickconect/server.key
echo "[6/7] Installing systemd service"
cat > /etc/systemd/system/quickconect.service <<'EOF'
[Unit]
Description=QuickConect private chat server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/opt/quickconect/quickconect-server serve -config /etc/quickconect/config.yaml
Restart=always
RestartSec=3
User=quickconect
Group=quickconect
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/quickconect
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable quickconect >/dev/null
if command -v ss >/dev/null; then
  CONFLICT="$(ss -ltnp 2>/dev/null | grep -E "[:.]$LISTEN_PORT[[:space:]]" | head -n 1 || true)"
  if [[ -n "$CONFLICT" ]]; then
    PID="$(printf '%s\n' "$CONFLICT" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
    CMDLINE=""
    [[ -n "$PID" && -r "/proc/$PID/cmdline" ]] && CMDLINE="$(tr '\0' ' ' < "/proc/$PID/cmdline")"
    if [[ "$CMDLINE" == *quickconect-server* ]]; then
      echo "Stopping previous QuickConect listener (pid $PID)"
      kill "$PID" 2>/dev/null || true
      for _ in {1..20}; do
        ss -ltnp 2>/dev/null | grep -Eq "[:.]$LISTEN_PORT[[:space:]]" || break
        sleep 0.25
      done
    else
      echo "Port $LISTEN_PORT is already in use: $CONFLICT" >&2
      echo "Change listen in /etc/quickconect/config.yaml or stop the other service, then deploy again." >&2
      exit 1
    fi
  fi
fi
if systemctl is-active --quiet quickconect; then
  systemctl restart quickconect
elif command -v ss >/dev/null && ss -ltnp 2>/dev/null | grep -Eq "[:.]$LISTEN_PORT[[:space:]]"; then
  LISTENER="$(ss -ltnp 2>/dev/null | grep -E "[:.]$LISTEN_PORT[[:space:]]" | head -n 1 || true)"
  echo "Port $LISTEN_PORT is already in use: $LISTENER" >&2
  echo "Stop the existing service or change listen in /etc/quickconect/config.yaml, then deploy again." >&2
  exit 1
else
  systemctl restart quickconect
fi
echo "[7/7] Configuring firewall"
if [[ -f "$PAYLOAD_DIR/firewall.sh" ]]; then
  bash "$PAYLOAD_DIR/firewall.sh" "$LISTEN_PORT" "$SSH_PORT"
else
  echo "Firewall helper missing from deployment bundle" >&2
  exit 1
fi
sleep 1
if systemctl is-active --quiet quickconect; then
  IP_SHOW="${SERVER_DOMAIN:-${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"
  echo "Deployment complete: https://$IP_SHOW:$LISTEN_PORT"
  echo "Client login certificate fingerprint (TLS server certificate SHA-256):"
  openssl x509 -in /etc/quickconect/server.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
else
  echo "Service failed to start" >&2
  journalctl -u quickconect -n 20 --no-pager || true
  exit 1
fi
