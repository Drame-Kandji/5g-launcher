# Lanceur 5G : un réseau 5G privé, testé avec la SIM, en une commande

```
sudo ./run.sh
```

Ce que fait la commande : contrôle la machine, déploie Kubernetes et le coeur OAI. En mode virtuel, elle déploie aussi le gNB OAI RFsim et une UE OAI logicielle. En mode USRP, elle déploie le gNB sur la B210, puis initialise et teste le modem Quectel.

## Deux modes (RAN_MODE dans config.env)
- `auto` : `usrp` si la B210 est détectée, sinon `virtual`.
- `virtual` : déploie le coeur OAI, un gNB et une UE logiciels avec RFsim, sans radio ni modem physiques. L'IMSI par défaut est fourni par `SIM_IMSI` ou l'exemple des organisateurs.
- `usrp` : déploie le coeur et le gNB sur la B210, puis connecte le modem Quectel.

## Avant la première fois
1. En mode `usrp` : USRP B210 sur un port **USB 3.0**, antennes branchées; modem Quectel connecté avec une SIM déverrouillée.
2. Ouvrez `config.env` : vérifiez `ORCH_USER`, `QDONG_DIR`, `BAND_HALF` (la moitié de bande de votre équipe).
3. Internet est nécessaire pour le premier déploiement.

En mode `virtual`, `WIFI_AP_ENABLE=true` active aussi le point d'accès Wi-Fi `EPT-5G`. Ses clients utilisent l'UE 5G logicielle comme sortie Internet. La clé est générée au premier lancement et affichée dans le journal; elle est enregistrée dans `/etc/5g-launcher/ap.psk`. Le lanceur essaie de créer `ap5g0` sur `wlp2s0`, en conservant le canal du Wi-Fi auquel la machine est connectée. Certains pilotes ne permettent pas le mode client et point d'accès simultanément : dans ce cas, une deuxième carte Wi-Fi USB compatible est requise. Commandes : `sudo ./wifi_ap.sh status` et `sudo ./wifi_ap.sh stop`.

## Si vous devez comprendre ce que sait faire l'orchestrateur
`sudo ./inspect.sh` crée `orchestrator-info.txt` (RAN virtuel, types de terminaux, gabarits du gNB). Envoyez ce fichier pour adapter le lanceur.

## Commandes
| Commande | Effet |
|---|---|
| `sudo ./run.sh` | Tout déployer, puis connecter le modem |
| `sudo ./run.sh --clean` | Tout supprimer puis redéployer |
| `sudo ./run.sh --no-ue` | Déployer le réseau sans toucher au modem |
| `sudo ./ue_connect.sh` | Reconnecter seulement le modem |
| `sudo ./status.sh` | État du coeur, du gNB, du modem et de wwan0 |
| `sudo ./wifi_ap.sh stop` | Arrêter seulement le point d'accès Wi-Fi |
| `sudo ./run.sh --teardown` | Tout arrêter et supprimer |

Les journaux sont dans `logs/`.

## Important
- Une SIM dans un modem physique ne peut se connecter qu'à une **vraie radio** (la B210). Le RAN RFsim ne transmet pas de signal radio.
- La route par défaut de la machine n'est **pas** modifiée : testez avec `ping -I wwan0 ...` ou `curl --interface wwan0 ...`.
- Si votre `qhat-init` affiche `reset-ue: not found`, le lanceur fournit un remplaçant (`bin/reset-ue`).
- Ne coupez pas `qhat-init` avec Ctrl-C : il attend 20 secondes la recherche du réseau.
- Si le modem et l'USRP sont à moins d'un mètre, baissez `TX_GAIN_DB` (par exemple 20).
