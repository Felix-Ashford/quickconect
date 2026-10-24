#!/usr/bin/env bash
# Add application/SSH rules without enabling an inactive firewall.
set -euo pipefail
PORT="${1:?service port required}"
SSH_PORT="${2:-22}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || exit 2
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || exit 2
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q 'Status: active'; then
  ufw allow "$SSH_PORT/tcp"
  ufw allow "$PORT/tcp"
  echo "Firewall: UFW allowed $PORT/tcp"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --add-port="$SSH_PORT/tcp"
  firewall-cmd --permanent --add-port="$SSH_PORT/tcp"
  firewall-cmd --add-port="$PORT/tcp"
  firewall-cmd --permanent --add-port="$PORT/tcp"
  echo "Firewall: firewalld allowed $PORT/tcp (runtime and persistent)"
elif command -v iptables >/dev/null; then
  # Insert ahead of cloud-image REJECT rules (not after them). Repeated runs
  # reuse our rule. Do not flush INPUT or enable an inactive UFW.
  iptables -w -C INPUT -p tcp --dport "$PORT" -m comment --comment quickconect -j ACCEPT 2>/dev/null ||
    iptables -w -I INPUT 1 -p tcp --dport "$PORT" -m comment --comment quickconect -j ACCEPT
  iptables -w -C INPUT -p tcp --dport "$SSH_PORT" -m comment --comment quickconect-ssh -j ACCEPT 2>/dev/null ||
    iptables -w -I INPUT 1 -p tcp --dport "$SSH_PORT" -m comment --comment quickconect-ssh -j ACCEPT
  if command -v ip6tables >/dev/null && [[ -f /proc/net/if_inet6 ]]; then
    ip6tables -w -C INPUT -p tcp --dport "$PORT" -m comment --comment quickconect -j ACCEPT 2>/dev/null ||
    ip6tables -w -I INPUT 1 -p tcp --dport "$PORT" -m comment --comment quickconect -j ACCEPT
    ip6tables -w -C INPUT -p tcp --dport "$SSH_PORT" -m comment --comment quickconect-ssh -j ACCEPT 2>/dev/null ||
      ip6tables -w -I INPUT 1 -p tcp --dport "$SSH_PORT" -m comment --comment quickconect-ssh -j ACCEPT
  fi
  if [[ "${3:-}" != '--apply' ]]; then
    install -m 0755 "$0" /opt/quickconect/firewall.sh
    cat > /etc/systemd/system/quickconect-firewall.service <<EOF
[Unit]
Description=QuickConect application firewall rule
After=network-pre.target netfilter-persistent.service ufw.service firewalld.service
Before=quickconect.service
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/quickconect/firewall.sh $PORT $SSH_PORT --apply
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable quickconect-firewall.service
  fi
  echo "Firewall: iptables allowed $PORT/tcp; boot rule installed"
else
  echo "Firewall: no supported backend detected; cannot verify host access to $PORT/tcp" >&2
  exit 1
fi
echo "Cloud security groups remain managed by the VPS provider."
