#!/bin/bash
# État complet du réseau 5G et du modem.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE" || exit 1
source ./config.env
[ -f /etc/kubernetes/admin.conf ] && export KUBECONFIG=/etc/kubernetes/admin.conf
echo "=== Pods du coeur 5G (oai-core) ==="; kubectl get pods -n oai-core 2>&1
echo "=== Pods du RAN (oai-ran) ===";       kubectl get pods -n oai-ran -o wide 2>&1
echo "=== UE logicielle (oai-ue) ===";      kubectl get pods -n oai-ue -o wide 2>&1
echo "=== Point d'accès Wi-Fi / tunnel 5G ==="; "$HERE/wifi_ap.sh" status 2>&1 || true
echo "=== Abonnés enregistrés (AMF) ==="
kubectl logs -n oai-core deploy/oai-amf 2>/dev/null | grep "has been registered" | tail -5
echo "=== Modem ==="
python3 at.py cmd 'AT+COPS?'
python3 at.py cmd 'AT+QENG="servingcell"'
echo "=== Interface wwan0 ==="; ip -4 addr show wwan0 2>&1
