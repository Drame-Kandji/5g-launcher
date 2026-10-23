#!/bin/bash
# Arrête le modem puis supprime le gNB, le coeur 5G et Kubernetes.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE" || exit 1
source ./config.env
export PATH="$HERE/.venv/bin:$PATH"
[ "$(id -u)" -eq 0 ] || { echo "lancez avec sudo"; exit 1; }
"$HERE/wifi_ap.sh" stop 2>/dev/null || true
[ -x "$QDONG_DIR/stop.sh" ] && ( cd "$QDONG_DIR" && ./stop.sh )
NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')}"
if [ -z "${ORCH_SUDO_PASSWORD:-}" ]; then read -rsp "Mot de passe sudo de $ORCH_USER : " ORCH_SUDO_PASSWORD; echo; fi
export NODE_IP ORCH_USER ORCH_SUDO_PASSWORD NODE_PROVISIONED MNC_LEN
export ANSIBLE_HOST_KEY_CHECKING=False
"$HERE/.venv/bin/python" deploy_5g.py --teardown
