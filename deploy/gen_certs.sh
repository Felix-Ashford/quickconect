#!/usr/bin/env bash
# 閻㈢喐鍨?QuickConect 閼奉亞顒?CA 娑撳孩婀囬崝鈥虫珤鐠囦椒鍔熼敍鍦桟DSA P-256閿涘鈧?# 閻劍纭? ./gen_certs.sh <閺堝秴濮熼崳銊ュ彆缂冩厲P> [鏉堟挸鍤惄顔肩秿閿涘矂绮拋?./certs]
# 娴溠呭⒖: ca.crt ca.key server.crt server.key
#   - ca.crt 闂団偓鐟曚焦褰佹笟娑氱舶鐎广垺鍩涚粩顖氫粵鐠囦椒鍔熼柨浣哥暰閿涘牊瀵氱痪鐟扮サ閸忋儱顓归幋椋庮伂閿?#   - server.crt/server.key 閺€鎯у煂 VPS 閻?/etc/quickconect/
set -euo pipefail

IP="${1:-}"
DOMAIN="${QC_DOMAIN:-}"
[[ -n "$IP" || -n "$DOMAIN" ]] || { echo "provide IP or QC_DOMAIN"; exit 2; }
OUT="${2:-./certs}"
mkdir -p "$OUT"

# 1) 缁変焦婀侀弽?CA閿?0 楠炶揪绱?
openssl ecparam -genkey -name prime256v1 -out "$OUT/ca.key"
openssl req -x509 -new -key "$OUT/ca.key" -sha256 -days 3650 \
  -out "$OUT/ca.crt" -subj "/CN=QuickConect Root CA"

CN="${DOMAIN:-$IP}"
openssl ecparam -genkey -name prime256v1 -out "$OUT/server.key"
openssl req -new -key "$OUT/server.key" -out "$OUT/server.csr" -subj "/CN=$CN"
SAN=""
[[ -n "$IP" ]] && SAN="IP:$IP"
if [[ -n "$DOMAIN" ]]; then
  [[ -n "$SAN" ]] && SAN="${SAN},"
  SAN="${SAN}DNS:$DOMAIN"
fi
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$SAN" > "$OUT/san.ext"
openssl x509 -req -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server.crt" -days 1825 -sha256 -extfile "$OUT/san.ext"
rm -f "$OUT/server.csr" "$OUT/san.ext"

chmod 600 "$OUT"/*.key
echo "---- 鐠囦椒鍔熷鑼晸閹存劒绨?$OUT ----"
echo "鐎广垺鍩涚粩顖炴敚鐎规氨鏁ら惃?CA 閹稿洨姹楅敍鍦獺A-256閿?"
openssl x509 -in "$OUT/ca.crt" -noout -fingerprint -sha256
