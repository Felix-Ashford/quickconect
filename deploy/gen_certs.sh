#!/usr/bin/env bash
# 生成 QuickConect 自签 CA 与服务器证书（ECDSA P-256）。
# 用法: ./gen_certs.sh <服务器公网IP> [输出目录，默认 ./certs]
# 产物: ca.crt ca.key server.crt server.key
#   - ca.crt 需要提供给客户端做证书锁定（指纹嵌入客户端）
#   - server.crt/server.key 放到 VPS 的 /etc/quickconect/
set -euo pipefail

IP="${1:?用法: $0 <服务器IP> [输出目录]}"
OUT="${2:-./certs}"
mkdir -p "$OUT"

# 1) 私有根 CA（10 年）
openssl ecparam -genkey -name prime256v1 -out "$OUT/ca.key"
openssl req -x509 -new -key "$OUT/ca.key" -sha256 -days 3650 \
  -out "$OUT/ca.crt" -subj "/CN=QuickConect Root CA"

# 2) 服务器密钥与证书（5 年；客户端锁定的是 CA，换证书无需发版）
openssl ecparam -genkey -name prime256v1 -out "$OUT/server.key"
openssl req -new -key "$OUT/server.key" -out "$OUT/server.csr" -subj "/CN=$IP"
cat > "$OUT/san.ext" <<EOF
subjectAltName=IP:$IP
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server.crt" -days 1825 -sha256 -extfile "$OUT/san.ext"
rm -f "$OUT/server.csr" "$OUT/san.ext"

chmod 600 "$OUT"/*.key
echo "---- 证书已生成于 $OUT ----"
echo "客户端锁定用的 CA 指纹（SHA-256）:"
openssl x509 -in "$OUT/ca.crt" -noout -fingerprint -sha256
