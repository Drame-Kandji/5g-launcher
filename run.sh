#!/bin/bash
# =====================================================================
#  UNE SEULE COMMANDE :   sudo ./run.sh
#  1. vérifie la machine (USRP B210, modem Quectel, réseau, paquets)
#  2. lit l'IMSI de la SIM dans le modem
#  3. déploie le coeur OAI, puis le gNB/UE simulés ou le gNB OAI avec la B210
#  4. démarre le point d'accès Wi-Fi via l'UE virtuelle, ou connecte le modem
#
#  Options : --clean (tout supprimer puis redéployer)  --no-ue (sans le modem)
#            --teardown (tout arrêter et supprimer)
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE" || exit 1
source ./config.env
mkdir -p logs
LOG="$HERE/logs/run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "ERREUR : $*"; exit 1; }

RAN_MODE="${RAN_MODE:-usrp}"
CLEAN=""; NO_UE=0
for a in "$@"; do
  case "$a" in
    --clean) CLEAN="--clean" ;;
    --no-ue) NO_UE=1 ;;
    --teardown) exec "$HERE/teardown.sh" ;;
    *) die "option inconnue : $a" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "lancez avec sudo :  sudo ./run.sh"
command -v apt-get >/dev/null || die "ce lanceur suppose Debian ou Ubuntu (apt)"
getent passwd "$ORCH_USER" >/dev/null || die "l'utilisateur $ORCH_USER n'existe pas (voir config.env)"

# ---------- 1. Contrôles de la machine ----------
log "1/5 Contrôles de la machine"
USB_LIST="$(lsusb)"
if [ "$RAN_MODE" = "auto" ]; then
  if grep -qi 'Ettus' <<< "$USB_LIST"; then RAN_MODE="usrp"; else RAN_MODE="virtual"; fi
  log "Mode choisi automatiquement : $RAN_MODE"
fi
export RAN_MODE
if [ "$RAN_MODE" = "usrp" ]; then
  grep -qi 'Ettus' <<< "$USB_LIST" || die "USRP B210 introuvable (lsusb). Branchez-la sur un port USB 3.0, ou passez RAN_MODE=\"virtual\" dans config.env. Un modem avec SIM ne peut pas se connecter à un RAN simulé."
  log "USRP B210 détectée."
else
  log "Mode virtuel : le coeur, le gNB OAI RFsim et l'UE OAI logiciel seront déployés."
fi
grep -qiE 'Quectel|2c7c' <<< "$USB_LIST" && log "Modem Quectel détecté." || log "ATTENTION : modem Quectel non vu par lsusb."
[ -e /dev/cdc-wdm0 ] || log "ATTENTION : /dev/cdc-wdm0 absent (modem pas en mode MBIM ?)."

need_pkgs() {
  local missing=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    log "Installation des paquets manquants : ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || die "installation impossible (Internet ?)"
  fi
}
need_pkgs usbutils openssh-server openssh-client git curl python3-venv python3-pip python3-yaml python3-kubernetes python3-pymysql libmbim-utils iproute2 iputils-ping iperf3
if [ "$RAN_MODE" = virtual ] && [ "${WIFI_AP_ENABLE:-false}" = true ]; then
  need_pkgs iw hostapd dnsmasq iptables
fi

ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || log "ATTENTION : pas d'accès Internet. Le déploiement télécharge Kubernetes et les images OAI : il échouera sans Internet."
if [ -n "$(swapon --show)" ]; then log "Désactivation du swap (exigé par Kubernetes)"; swapoff -a; fi
modprobe overlay 2>/dev/null; modprobe br_netfilter 2>/dev/null
sysctl -qw net.ipv4.ip_forward=1 net.bridge.bridge-nf-call-iptables=1 2>/dev/null
systemctl stop ModemManager 2>/dev/null && log "ModemManager arrêté (il perturbe le modem)."

for c in kubeadm kubectl helm; do
  command -v "$c" >/dev/null 2>&1 || MISSING_K8S="${MISSING_K8S:-} $c"
done
if [ -n "${MISSING_K8S:-}" ]; then
  log "Note : absents de cette machine :${MISSING_K8S}. L'étape 'prepare' de l'orchestrateur est censée les installer (Internet requis)."
fi

# ---------- 2. Identité de la SIM ----------
if [ "$RAN_MODE" = virtual ]; then
  log "2/5 Identité de l'UE virtuelle"
  IMSI="${SIM_IMSI:-001010000000018}"
  IMEI="868371054166950"
  log "IMSI virtuel : $IMSI (aucun modem physique n'est utilisé). Vérifiez SIM_K et SIM_OPC dans config.env."
else
  log "2/5 Lecture de la SIM dans le modem"
  export AT_PORT
  IMSI=""; IMEI=""; ICCID=""
  eval "$(python3 "$HERE/at.py" info 2>/dev/null)"
  [ -n "${IMSI:-}" ] || die "SIM illisible : modem absent, SIM absente ou verrouillée par un code PIN."
  log "Port AT : $AT_PORT | IMSI : $IMSI | IMEI : ${IMEI:-?} | ICCID : ${ICCID:-?}"
  case "$IMSI" in
    001010000000017|001010000000018) log "SIM de l'exemple des organisateurs reconnue : les clés par défaut conviennent." ;;
    *) log "IMSI différent de l'exemple : vérifiez SIM_K et SIM_OPC dans config.env (valeurs fournies par les organisateurs)." ;;
  esac
fi

# ---------- 3. Python, orchestrateur, SSH ----------
log "3/5 Préparation de l'orchestrateur"
PYBIN=""
for p in python3.14 python3.13 python3.12 python3; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'; then PYBIN="$p"; break; fi
done
[ -n "$PYBIN" ] || die "Python 3.12 ou plus est requis (sudo apt install python3.12 python3.12-venv)."
VENV="$HERE/.venv"
export PATH="$VENV/bin:$PATH"   # ansible-runner doit trouver ansible-playbook
[ -x "$VENV/bin/python" ] || "$PYBIN" -m venv "$VENV" || die "création du venv impossible (python3-venv ?)"
if ! "$VENV/bin/python" -c 'import orchestrator, metamodel' 2>/dev/null; then
  log "Installation de l'orchestrateur Post-5G"
  if [ -n "$ORCH_SOURCE" ]; then
    "$VENV/bin/pip" install -q --upgrade "$ORCH_SOURCE" --extra-index-url=https://gitlab.inria.fr/api/v4/projects/70914/packages/pypi/simple || die "installation de l'orchestrateur impossible"
  else
    "$VENV/bin/pip" install -q --upgrade "git+https://gitlab.inria.fr/slices-ri/blueprints/post-5g/orchestrator.git" --extra-index-url=https://gitlab.inria.fr/api/v4/projects/70914/packages/pypi/simple || die "installation de l'orchestrateur impossible (Internet ? accès au GitLab d'Inria ?)"
  fi
fi
REQ=""
if [ -n "$ORCH_SOURCE" ] && [ -d "$ORCH_SOURCE" ]; then REQ="$(find "$ORCH_SOURCE" -maxdepth 4 -name requirements.yaml 2>/dev/null | head -1)"; fi
if [ -n "$REQ" ]; then
  "$VENV/bin/ansible-galaxy" install -r "$REQ" >/dev/null 2>&1 || log "ATTENTION : ansible-galaxy a signalé une erreur sur $REQ"
else
  "$VENV/bin/ansible-galaxy" collection install kubernetes.core community.general ansible.posix >/dev/null 2>&1 || log "ATTENTION : collections Ansible non installées (voir README)."
fi
# The orchestrator's OAI subscriber roles call ansible.mysql.mysql_query.
# Some published requirements still name its former community.mysql namespace.
"$VENV/bin/ansible-galaxy" collection install ansible.mysql >/dev/null 2>&1 || die "installation de la collection Ansible ansible.mysql impossible. Vérifiez l'accès Internet, puis relancez sudo ./run.sh."

NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
[ -n "$NODE_IP" ] || die "adresse IP de la machine introuvable (renseignez NODE_IP dans config.env)"
log "Adresse de la machine : $NODE_IP"
# Ansible controls this single-node cluster from the same host. Use loopback
# for its SSH transport so a Wi-Fi roam/drop cannot interrupt provisioning;
# NODE_IP remains the real interface address used by Kubernetes and RFsim.
NODE_SSH_HOST="${NODE_SSH_HOST:-127.0.0.1}"

# If Wi-Fi changed since kubeadm init, rebuild the local cluster instead of
# timing out against the old control-plane address. On a worker, admin.conf is
# absent, so also inspect kubelet.conf for its remote API endpoint.
if [ -z "$CLEAN" ]; then
  for KCFG in /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf; do
    [ -f "$KCFG" ] || continue
    API_IP="$(awk '/server: https:\/\// {sub(/^.*https:\/\//, ""); sub(/:.*/, ""); print; exit}' "$KCFG")"
    if [ -n "$API_IP" ] && [ "$API_IP" != "$NODE_IP" ]; then
      die "Kubernetes utilise encore l'ancienne API $API_IP (adresse actuelle : $NODE_IP, détectée dans $KCFG). Relancez avec sudo ./run.sh --clean pour reconstruire le cluster local."
    fi
  done
fi

systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
UHOME="$(getent passwd "$ORCH_USER" | cut -d: -f6)"
install -d -m 700 -o "$ORCH_USER" "$UHOME/.ssh"
PUB="$(cat /root/.ssh/id_ed25519.pub)"
grep -qF "$PUB" "$UHOME/.ssh/authorized_keys" 2>/dev/null || echo "$PUB" >> "$UHOME/.ssh/authorized_keys"
chown "$ORCH_USER": "$UHOME/.ssh/authorized_keys"; chmod 600 "$UHOME/.ssh/authorized_keys"
ssh-keyscan -H "$NODE_IP" >> /root/.ssh/known_hosts 2>/dev/null
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$ORCH_USER@$NODE_IP" true || die "connexion SSH à $ORCH_USER@$NODE_IP impossible"
log "SSH vers $ORCH_USER@$NODE_IP : OK"

if [ -z "${ORCH_SUDO_PASSWORD:-}" ]; then read -rsp "Mot de passe sudo de $ORCH_USER : " ORCH_SUDO_PASSWORD; echo; fi

# ---------- 4. Déploiement du réseau 5G ----------
log "4/5 Déploiement du réseau 5G (première fois : 10 à 20 minutes selon la connexion)"
export NODE_IP NODE_SSH_HOST ORCH_USER ORCH_SUDO_PASSWORD NODE_PROVISIONED MNC_LEN DNN BAND_HALF TX_GAIN_DB RX_GAIN_DB TX_ATT_DB RX_ATT_DB SIM_K SIM_OPC IMSI IMEI RAN_MODE
export ANSIBLE_HOST_KEY_CHECKING=False
"$VENV/bin/python" deploy_5g.py $CLEAN || die "le déploiement a échoué : lisez les messages ci-dessus ou le journal $LOG"

# ---------- 5. Modem ----------
if [ "$RAN_MODE" = "virtual" ]; then
  log "5/5 Mode virtuel : coeur, gNB RFsim et UE logiciel déployés pour l'abonné $IMSI."
  if [ "${WIFI_AP_ENABLE:-false}" = true ]; then
    log "Démarrage du point d'accès Wi-Fi; le trafic client passera par l'UE 5G virtuelle."
    "$HERE/wifi_ap.sh" start || die "le point d'accès n'a pas démarré. Le réseau 5G reste déployé; corrigez le message ci-dessus puis relancez sudo ./wifi_ap.sh start."
  fi
elif [ "$NO_UE" = 1 ]; then
  log "Option --no-ue : modem non connecté."
else
  log "5/5 Connexion du modem à votre réseau 5G"
  "$HERE/ue_connect.sh" || die "la connexion du modem a échoué (voir ci-dessus). Le réseau 5G reste déployé : relancez  sudo ./ue_connect.sh"
fi
log "TERMINÉ. État : sudo ./status.sh | Arrêter le point d'accès : sudo ./wifi_ap.sh stop | Tout arrêter : sudo ./run.sh --teardown"
