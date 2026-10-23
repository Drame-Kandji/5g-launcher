#!/bin/bash
# Initialise le modem Quectel (qhat-init) puis ouvre la session de données 5G et la teste.
# Ne modifie PAS la route par défaut : seul le trafic envoyé par wwan0 passe par la 5G.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE" || exit 1
source ./config.env
export PATH="$HERE/bin:$PATH"
DEV=/dev/cdc-wdm0
IF=wwan0

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "ERREUR : $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "lancez avec sudo"
[ -x "$QDONG_DIR/qhat-init" ] || die "qhat-init introuvable dans : $QDONG_DIR (voir config.env)"
command -v mbimcli >/dev/null || die "mbimcli absent (sudo apt install libmbim-utils)"

log "1/4 Initialisation du modem (qhat-init --dnn $DNN), environ 1 minute 30. Ne l'interrompez pas."
( cd "$QDONG_DIR" && ./qhat-init --dnn "$DNN" ) || log "qhat-init a signalé une erreur, on poursuit."

log "2/4 Attente de l'enregistrement sur le réseau 5G (2 minutes maximum)"
registered() { mbimcli -p -d "$DEV" --query-registration-state 2>/dev/null | grep -qiE "Register state: '(home|roaming)'"; }
ok=0
for i in $(seq 1 24); do
  if registered; then ok=1; break; fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  log "Le modem n'est PAS enregistré. Diagnostic :"
  python3 at.py cmd 'AT+COPS?'
  python3 at.py cmd 'AT+QENG="servingcell"'
  mbimcli -p -d "$DEV" --query-registration-state
  cat <<'MSG'
Pistes : le gNB est-il bien prêt (journaux du gNB) ? Le modem voit-il la bonne fréquence (bandes n78) ?
Modem et USRP trop proches : baissez TX_GAIN_DB dans config.env et relancez le déploiement.
La SIM est-elle bien dans le coeur (IMSI lu dans le modem) ? Le PLMN du réseau correspond-il à la SIM ?
MSG
  exit 2
fi
log "Modem enregistré sur le réseau 5G."

log "3/4 Ouverture de la session de données (DNN $DNN)"
mbimcli -p -d "$DEV" --attach-packet-service >/dev/null 2>&1
mbimcli -p -d "$DEV" --connect="apn=$DNN,ip-type=ipv4" || die "connexion de données refusée (voir le message ci-dessus et les journaux de l'AMF et du SMF)"
ip link set "$IF" up 2>/dev/null || die "interface $IF absente"
CFG="$(mbimcli -p -d "$DEV" --query-ip-configuration=0 2>/dev/null)"
UEIP="$(echo "$CFG" | grep -oP "IP \[0\]: '\K[^']+")"
GW="$(echo "$CFG" | grep -oP "Gateway: '\K[^']+")"
MTU="$(echo "$CFG" | grep -oP "MTU: '\K[^']+")"
[ -n "$UEIP" ] || die "aucune adresse IP reçue du réseau"
ip addr flush dev "$IF"
ip addr add "$UEIP" dev "$IF"
[ -n "$MTU" ] && ip link set dev "$IF" mtu "$MTU"
log "Adresse du modem sur le réseau 5G : $UEIP (passerelle $GW)"

log "4/4 Tests de la connexion"
if ping -I "$IF" -c 4 -W 2 "$GW" >/dev/null 2>&1; then
  log "OK : ping de la passerelle du coeur 5G ($GW) via la radio."
else
  log "ECHEC : pas de réponse de la passerelle $GW."
fi
if ping -I "$IF" -c 3 -W 2 1.1.1.1 >/dev/null 2>&1; then
  log "OK : accès Internet par la 5G (1.1.1.1)."
else
  log "Pas d'accès Internet par la 5G (le test du coeur ci-dessus suffit pour valider le réseau)."
fi
log "Signal radio :"
python3 at.py cmd 'AT+QENG="servingcell"'
echo
log "Pour utiliser la 5G : curl --interface $IF https://1.1.1.1/cdn-cgi/trace   ou   ping -I $IF $GW"
log "Débit : iperf3 -s sur la machine puis iperf3 -c <adresse> -B ${UEIP%%/*}"
exit 0
