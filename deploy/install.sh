#!/usr/bin/env bash
# QuickConect 服务端一键安装/升级脚本（在 VPS 上以 root 执行）。
#
# 用法: sudo bash install.sh [--server-ip <公网IP>]
#   --server-ip  可选；用于生成自签证书的 IP SAN。不传则自动探测，
#                探测失败时用内网 IP（云服务器务必显式传公网 IP）。
#
# 特性：
#   - 幂等：可重复执行；升级二进制、重启服务，但【不会】动数据库/媒体/证书/配置
#   - 自包含：只需同目录下有 quickconect-server-linux-amd64 这个二进制
#   - 换机迁移：把旧机 /var/lib/quickconect 整目录 rsync 到新机后再跑本脚本即可
set -euo pipefail

SERVER_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$PAYLOAD_DIR/quickconect-server-linux-amd64"
[[ -f "$BIN_SRC" ]] || { echo "错误: 找不到 $BIN_SRC"; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) : ;;
  aarch64) echo "提示: 当前为 arm64 机器，本脚本携带的是 amd64 二进制，请在项目里交叉编译 arm64 后替换"; exit 1 ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

echo "==> 1/7 系统用户与目录"
id -u quickconect &>/dev/null || useradd --system --home-dir /var/lib/quickconect --shell /usr/sbin/nologin quickconect
mkdir -p /opt/quickconect /etc/quickconect /var/lib/quickconect/media

echo "==> 2/7 安装二进制"
install -m 0755 "$BIN_SRC" /opt/quickconect/quickconect-server

echo "==> 3/7 配置文件（已存在则保留）"
if [[ ! -f /etc/quickconect/config.yaml ]]; then
  cat > /etc/quickconect/config.yaml <<'EOF'
listen: ":8443"
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
  echo "    已写入 /etc/quickconect/config.yaml"
else
  echo "    保留现有配置"
fi

echo "==> 4/7 自签证书（已存在则保留）"
if [[ ! -f /etc/quickconect/server.crt ]]; then
  command -v openssl >/dev/null || { echo "错误: 需要 openssl"; exit 1; }
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(curl -s --max-time 5 https://api.ipify.org || true)"
  fi
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
    echo "    警告: 未能探测公网 IP，证书绑定到 [$SERVER_IP]；如这是内网 IP，"
    echo "    请用 sudo bash install.sh --server-ip <公网IP> 且先删除旧证书后重跑。"
  fi
  TMP="$(mktemp -d)"
  openssl ecparam -genkey -name prime256v1 -out "$TMP/ca.key" 2>/dev/null
  openssl req -x509 -new -key "$TMP/ca.key" -sha256 -days 3650 \
    -out "$TMP/ca.crt" -subj "/CN=QuickConect Root CA" 2>/dev/null
  openssl ecparam -genkey -name prime256v1 -out "$TMP/server.key" 2>/dev/null
  openssl req -new -key "$TMP/server.key" -out "$TMP/server.csr" -subj "/CN=$SERVER_IP" 2>/dev/null
  printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$SERVER_IP" > "$TMP/san.ext"
  openssl x509 -req -in "$TMP/server.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" \
    -CAcreateserial -out "$TMP/server.crt" -days 1825 -sha256 -extfile "$TMP/san.ext" 2>/dev/null
  install -m 0644 "$TMP/ca.crt" /etc/quickconect/ca.crt
  install -m 0644 "$TMP/server.crt" /etc/quickconect/server.crt
  install -m 0600 "$TMP/server.key" /etc/quickconect/server.key
  rm -rf "$TMP"
  echo "    证书已生成，绑定 IP: $SERVER_IP"
else
  echo "    保留现有证书"
fi

echo "==> 5/7 权限"
chown -R quickconect:quickconect /var/lib/quickconect
chown quickconect:quickconect /etc/quickconect/server.key
chmod 0600 /etc/quickconect/server.key

echo "==> 6/7 systemd 服务"
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
systemctl restart quickconect

echo "==> 7/7 防火墙"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 8443/tcp >/dev/null 2>&1 || true
  echo "    ufw 已放行 8443/tcp"
else
  echo "    ufw 未启用，跳过（云服务器请确认厂商安全组已放行 TCP 8443）"
fi

sleep 1
IP_SHOW="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"
echo ""
echo "================ 部署完成 ================"
systemctl is-active quickconect && echo "服务状态: 运行中" || { echo "服务状态: 异常"; journalctl -u quickconect -n 20 --no-pager; exit 1; }
echo "服务器地址: https://$IP_SHOW:8443"
echo "客户端证书指纹（登录 App 时粘贴到「证书指纹」栏）:"
FP="$(openssl x509 -in /etc/quickconect/server.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
echo "    $FP"
echo "建号命令示例:"
echo "    /opt/quickconect/quickconect-server adduser -config /etc/quickconect/config.yaml -name 用户名 -display 昵称 -password 密码"
echo "=========================================="
