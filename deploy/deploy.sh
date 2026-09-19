#!/usr/bin/env bash
# QuickConect 一键部署（在开发机上执行，Git Bash / Linux / macOS 均可）。
# 构建 Linux 二进制 → 上传到 VPS → 以 root 执行 install.sh。
#
# 用法:
#   ./deploy.sh <host> <ssh用户> <ssh私钥路径> [ssh端口]
# 例:
#   ./deploy.sh 124.223.44.151 ubuntu ~/.ssh/tencent_cloud.pem 22
# 换 VPS 时同样执行这一条即可；要迁移老数据，先 rsync 旧机
# /var/lib/quickconect/ 整目录到新机同路径，再跑本脚本。
set -euo pipefail

HOST="${1:-${QC_HOST:-}}"
SSH_USER="${2:-${QC_USER:-ubuntu}}"
KEY="${3:-${QC_KEY:-}}"
PORT="${4:-${QC_PORT:-22}}"
[[ -n "$HOST" && -n "$KEY" ]] || { echo "用法: $0 <host> <ssh用户> <私钥路径> [端口]"; exit 2; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# ---- 1. 构建 Linux 二进制（优先用项目内置的便携 Go） ----
echo "==> 构建 Linux 二进制"
GO_BIN="$(command -v go || true)"
[[ -z "$GO_BIN" && -x "$REPO/.tools/go/bin/go" ]] && GO_BIN="$REPO/.tools/go/bin/go"
[[ -n "$GO_BIN" ]] || { echo "错误: 找不到 go，请先安装或确认 .tools/go 存在"; exit 1; }
mkdir -p "$REPO/dist"
(cd "$REPO/server" && GOOS=linux GOARCH=amd64 "$GO_BIN" build -o "$REPO/dist/quickconect-server-linux-amd64" .)

# ---- 2. 上传 ----
echo "==> 上传到 $SSH_USER@$HOST"
SSH_OPTS=(-i "$KEY" -p "$PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
ssh "${SSH_OPTS[@]}" "$SSH_USER@$HOST" "mkdir -p /tmp/quickconect-deploy"
scp "${SSH_OPTS[@]/-p/-P}" "$REPO/dist/quickconect-server-linux-amd64" \
    "$REPO/deploy/install.sh" "$SSH_USER@$HOST:/tmp/quickconect-deploy/"

# ---- 3. 执行安装 ----
echo "==> 执行安装（幂等，可重复跑）"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$HOST" \
  "sudo bash /tmp/quickconect-deploy/install.sh --server-ip $HOST"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$HOST" "rm -rf /tmp/quickconect-deploy"

echo "==> 完成。验证: curl -k https://$HOST:8443/healthz"
