#!/bin/bash
# Point d'accès Wi-Fi dont la sortie est forcée dans le tunnel de l'UE 5G.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$HERE/config.env"

RUNDIR=/run/5g-launcher-wifi-ap
PSK_FILE=/etc/5g-launcher/ap.psk
MARK=0x5a5
TABLE=10500

log() { echo "[wifi-ap] $*"; }
die() { log "ERREUR : $*" >&2; exit 1; }
exists_rule() { ip rule show | grep -q "fwmark ${MARK}.*lookup ${TABLE}"; }
iptables_add() {
  if [ "$1" = -t ]; then
    local table="$2" chain="$3"; shift 3
    iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1 || iptables -t "$table" -I "$chain" "$@"
  else
    local chain="$1"; shift
    iptables -C "$chain" "$@" >/dev/null 2>&1 || iptables -I "$chain" "$@"
  fi
}

show_ue_diagnostics() {
  command -v kubectl >/dev/null || return 0
  log "Diagnostic du gNB RFsim :"
  kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n oai-ran -o wide 2>&1 || true
  kubectl --kubeconfig=/etc/kubernetes/admin.conf logs -n oai-ran deployment/oai-gnb --tail=60 2>&1 || true
  log "Diagnostic de l'UE :"
  kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n oai-ue -o wide 2>&1 || true
  kubectl --kubeconfig=/etc/kubernetes/admin.conf logs -n oai-ue deployment/oai-simulated-ue --all-containers --tail=80 2>&1 || true
}

stop_ap() {
  if [ -f "$RUNDIR/dnsmasq.pid" ]; then kill "$(cat "$RUNDIR/dnsmasq.pid")" 2>/dev/null || true; fi
  if [ -f "$RUNDIR/hostapd.pid" ]; then kill "$(cat "$RUNDIR/hostapd.pid")" 2>/dev/null || true; fi
  rm -f "$RUNDIR/dnsmasq.pid" "$RUNDIR/hostapd.pid"
  iptables -t nat -D POSTROUTING -s "$WIFI_AP_SUBNET" -o "$WIFI_AP_UPSTREAM" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$WIFI_AP_IFACE" -o "$WIFI_AP_UPSTREAM" -s "$WIFI_AP_SUBNET" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$WIFI_AP_UPSTREAM" -o "$WIFI_AP_IFACE" -d "$WIFI_AP_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i "$WIFI_AP_IFACE" -s "$WIFI_AP_SUBNET" -j MARK --set-mark "$MARK" 2>/dev/null || true
  iptables -t mangle -D FORWARD -i "$WIFI_AP_IFACE" -o "$WIFI_AP_UPSTREAM" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
  iptables -t mangle -D FORWARD -i "$WIFI_AP_UPSTREAM" -o "$WIFI_AP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
  ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
  ip route flush table "$TABLE" 2>/dev/null || true
  ip addr del "$WIFI_AP_HOST_IP/24" dev "$WIFI_AP_IFACE" 2>/dev/null || true
  ip link set "$WIFI_AP_IFACE" down 2>/dev/null || true
  if [ -f "$RUNDIR/created-interface" ]; then iw dev "$WIFI_AP_IFACE" del 2>/dev/null || true; fi
  rm -rf "$RUNDIR"
  log "Point d'accès arrêté."
}

start_ap() {
  [ "${WIFI_AP_ENABLE:-false}" = true ] || { log "WIFI_AP_ENABLE=false, point d'accès ignoré."; return; }
  [ "$(id -u)" -eq 0 ] || die "lancez avec sudo."
  [ ! -d "$RUNDIR" ] || stop_ap
  for cmd in iw ip iptables hostapd dnsmasq; do command -v "$cmd" >/dev/null || die "$cmd absent (installez iw hostapd dnsmasq)."; done
  ip link show "$WIFI_AP_PARENT" >/dev/null 2>&1 || die "carte Wi-Fi $WIFI_AP_PARENT introuvable."
  if ! ip link show "$WIFI_AP_UPSTREAM" >/dev/null 2>&1; then
    show_ue_diagnostics
    die "interface UE $WIFI_AP_UPSTREAM absente : l'UE virtuelle n'a pas créé son tunnel."
  fi
  if ! ip -4 -o addr show dev "$WIFI_AP_UPSTREAM" | grep -q ' inet '; then
    show_ue_diagnostics
    die "l'UE n'a pas reçu d'adresse de données sur $WIFI_AP_UPSTREAM; consultez les journaux ci-dessus."
  fi
  # OAI's simulated UE/UPF path drops or delays larger packets at MTU 1500.
  # 1300 was measured to restore sub-second HTTPS handshakes on this setup.
  local tunnel_mtu="${WIFI_AP_TUN_MTU:-1300}"
  [[ "$tunnel_mtu" =~ ^[0-9]+$ ]] || die "WIFI_AP_TUN_MTU doit être un entier."
  ip link set dev "$WIFI_AP_UPSTREAM" mtu "$tunnel_mtu" || die "impossible de régler la MTU de $WIFI_AP_UPSTREAM."
  iw dev "$WIFI_AP_PARENT" info >/dev/null 2>&1 || die "$WIFI_AP_PARENT n'est pas une interface Wi-Fi."
  local phy freq channel band
  phy="$(iw dev "$WIFI_AP_PARENT" info | awk '/wiphy/ {print "phy" $2; exit}')"
  # Avoid grep -q here: with pipefail it can close iw's pipe early and make
  # a supported AP mode look absent (SIGPIPE).
  iw phy "$phy" info | grep -E '^[[:space:]]+\* AP$' >/dev/null || die "$WIFI_AP_PARENT ne prend pas en charge le mode point d'accès. Utilisez une carte Wi-Fi compatible."
  # Some iw versions print frequencies as floating point (for example 5825.0).
  # Normalize to an integer before using Bash's integer comparisons.
  freq="$(iw dev "$WIFI_AP_PARENT" link | awk '/freq:/ {printf "%d\n", $2; exit}')"
  [ -n "$freq" ] || die "$WIFI_AP_PARENT n'est pas connectée en Wi-Fi; impossible de partager la même radio sans interrompre le réseau actuel."
  if [ "$freq" -ge 2412 ] && [ "$freq" -le 2472 ]; then channel=$(( (freq - 2407) / 5 )); band=g
  elif [ "$freq" -ge 5000 ] && [ "$freq" -le 5900 ]; then channel=$(( (freq - 5000) / 5 )); band=a
  else die "fréquence Wi-Fi ${freq} MHz non prise en charge pour le partage simultané."; fi

  mkdir -p "$RUNDIR" /etc/5g-launcher
  chmod 700 /etc/5g-launcher
  if [ -z "${WIFI_AP_PSK:-}" ]; then
    if [ -s "$PSK_FILE" ]; then WIFI_AP_PSK="$(cat "$PSK_FILE")"
    else WIFI_AP_PSK="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"; printf '%s\n' "$WIFI_AP_PSK" > "$PSK_FILE"; chmod 600 "$PSK_FILE"; fi
  fi
  [ "${#WIFI_AP_PSK}" -ge 8 ] && [ "${#WIFI_AP_PSK}" -le 63 ] || die "WIFI_AP_PSK doit contenir de 8 à 63 caractères."
  # A previous interrupted start may leave this interface behind as a
  # managed client. Recreate it explicitly in AP mode in that case.
  if iw dev "$WIFI_AP_IFACE" info >/dev/null 2>&1 && ! iw dev "$WIFI_AP_IFACE" info | grep -E 'type AP' >/dev/null; then
    iw dev "$WIFI_AP_IFACE" del || die "impossible de supprimer l'ancienne interface $WIFI_AP_IFACE."
  fi
  if ! iw dev "$WIFI_AP_IFACE" info >/dev/null 2>&1; then
    iw dev "$WIFI_AP_PARENT" interface add "$WIFI_AP_IFACE" type __ap || die "le pilote ne permet pas le mode client et AP simultané sur $WIFI_AP_PARENT. Une seconde carte Wi-Fi USB est nécessaire."
    touch "$RUNDIR/created-interface"
  fi
  # NetworkManager otherwise claims the newly created virtual interface and
  # wpa_supplicant can flip it back to managed mode, stopping the beacon.
  if command -v nmcli >/dev/null; then nmcli device set "$WIFI_AP_IFACE" managed no; fi
  # Some drivers create __ap as managed by default. Set AP explicitly and
  # give the virtual interface a distinct locally administered MAC address.
  local parent_mac mac_first mac_last ap_mac
  parent_mac="$(cat "/sys/class/net/$WIFI_AP_PARENT/address")"
  IFS=: read -r mac_first _ _ _ _ mac_last <<< "$parent_mac"
  mac_first="$(printf '%02x' "$((16#$mac_first | 2))")"
  mac_last="$(printf '%02x' "$(((16#$mac_last + 1) % 256))")"
  ap_mac="$mac_first:${parent_mac#*:}"
  ap_mac="${ap_mac%:*}:$mac_last"
  ip link set dev "$WIFI_AP_IFACE" address "$ap_mac"
  iw dev "$WIFI_AP_IFACE" set type __ap || die "impossible de passer $WIFI_AP_IFACE en mode AP."
  ip link set "$WIFI_AP_IFACE" up
  ip addr replace "$WIFI_AP_HOST_IP/24" dev "$WIFI_AP_IFACE"
  sysctl -qw net.ipv4.ip_forward=1

  cat > "$RUNDIR/hostapd.conf" <<EOF
interface=$WIFI_AP_IFACE
driver=nl80211
country_code=${WIFI_AP_COUNTRY}
ssid=${WIFI_AP_SSID}
hw_mode=${band}
channel=${channel}
ieee80211n=1
wmm_enabled=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${WIFI_AP_PSK}
EOF
  hostapd -B -P "$RUNDIR/hostapd.pid" -f "$RUNDIR/hostapd.log" "$RUNDIR/hostapd.conf" || die "hostapd n'a pas pu démarrer."
  # hostapd -B can return success before the driver rejects the channel.
  # Wait briefly and confirm the daemon is alive and has configured an SSID.
  sleep 2
  local hostapd_pid=""
  [ -s "$RUNDIR/hostapd.pid" ] && hostapd_pid="$(cat "$RUNDIR/hostapd.pid")"
  if [ -z "$hostapd_pid" ] || ! kill -0 "$hostapd_pid" 2>/dev/null || ! iw dev "$WIFI_AP_IFACE" info | grep -qi "ssid[[:space:]]\+$WIFI_AP_SSID"; then
    log "hostapd n'a pas activé le SSID sur le canal $channel."
    [ ! -s "$RUNDIR/hostapd.log" ] || tail -25 "$RUNDIR/hostapd.log" >&2
    stop_ap
    die "point d'accès non diffusé. Vérifiez le canal Wi-Fi amont et les restrictions DFS."
  fi
  dnsmasq --no-daemon --port=0 --interface="$WIFI_AP_IFACE" --bind-interfaces --except-interface=lo \
    --dhcp-range="${WIFI_AP_HOST_IP%.*}.10,${WIFI_AP_HOST_IP%.*}.200,255.255.255.0,12h" \
    --dhcp-option=option:router,"$WIFI_AP_HOST_IP" --dhcp-option=option:dns-server,1.1.1.1 \
    --pid-file="$RUNDIR/dnsmasq.pid" --log-facility="$RUNDIR/dnsmasq.log" &
  local dns_pid=$!
  echo "$dns_pid" > "$RUNDIR/dnsmasq.pid"
  sleep 1
  kill -0 "$dns_pid" 2>/dev/null || die "dnsmasq n'a pas pu démarrer; consultez $RUNDIR/dnsmasq.log."

  ip route replace default dev "$WIFI_AP_UPSTREAM" table "$TABLE"
  exists_rule || ip rule add fwmark "$MARK" table "$TABLE" priority 10500
  iptables_add -t mangle PREROUTING -i "$WIFI_AP_IFACE" -s "$WIFI_AP_SUBNET" -j MARK --set-mark "$MARK"
  iptables_add -t mangle FORWARD -i "$WIFI_AP_IFACE" -o "$WIFI_AP_UPSTREAM" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
  iptables_add -t mangle FORWARD -i "$WIFI_AP_UPSTREAM" -o "$WIFI_AP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
  iptables_add FORWARD -i "$WIFI_AP_IFACE" -o "$WIFI_AP_UPSTREAM" -s "$WIFI_AP_SUBNET" -j ACCEPT
  iptables_add FORWARD -i "$WIFI_AP_UPSTREAM" -o "$WIFI_AP_IFACE" -d "$WIFI_AP_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables_add -t nat POSTROUTING -s "$WIFI_AP_SUBNET" -o "$WIFI_AP_UPSTREAM" -j MASQUERADE
  log "SSID: $WIFI_AP_SSID | clé: $WIFI_AP_PSK | sortie: $WIFI_AP_UPSTREAM"
  log "Adresse de la passerelle: $WIFI_AP_HOST_IP (la clé est aussi enregistrée dans $PSK_FILE)."
}

case "${1:-start}" in
  start) start_ap ;;
  stop) stop_ap ;;
  restart) stop_ap; start_ap ;;
  status)
    if [ ! -s "$RUNDIR/hostapd.pid" ] || ! kill -0 "$(cat "$RUNDIR/hostapd.pid")" 2>/dev/null; then
      log "point d'accès arrêté ou non diffusé (hostapd absent)."
      exit 1
    fi
    iw dev "$WIFI_AP_IFACE" info 2>/dev/null | grep -qi "ssid[[:space:]]\+$WIFI_AP_SSID" || { log "hostapd tourne mais le SSID n'est pas actif."; exit 1; }
    iw dev "$WIFI_AP_IFACE" info
    ip -4 addr show dev "$WIFI_AP_IFACE"
    ip route show table "$TABLE"
    ;;
  *) die "usage: $0 {start|stop|restart|status}" ;;
esac
