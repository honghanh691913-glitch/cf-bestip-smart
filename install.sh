#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
python3 ./install_cfst.py
chmod +x ./bestip_orchestrator.py
mkdir -p runtime generated
if command -v systemctl >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  sed "s|__PROJECT_DIR__|$ROOT|g" systemd/cf-bestip.service > /etc/systemd/system/cf-bestip.service
  cp systemd/cf-bestip.timer /etc/systemd/system/cf-bestip.timer
  if [[ ! -f /etc/cf-bestip.env ]]; then
    cat > /etc/cf-bestip.env <<'EOF'
# Fine-grained GitHub PAT. Repository permission: Contents = Read and write
GITHUB_TOKEN=
EOF
    chmod 600 /etc/cf-bestip.env
  fi
  systemctl daemon-reload
  systemctl enable --now cf-bestip.timer
  echo "systemd timer enabled. Edit /etc/cf-bestip.env and config.json before first publish."
else
  echo "CFST installed. systemd not installed (run install.sh as root on systemd Linux to enable timer)."
fi
