#!/usr/bin/env python3
"""Déploie le réseau 5G sur CETTE machine avec l'orchestrateur Post-5G :
Kubernetes (un seul nœud), coeur 5G OAI, gNB OAI avec la USRP B210.
C'est le notebook d'exemple des organisateurs, sans interface, avec contrôles automatiques.

Options : --clean (supprime tout puis redéploie)  --teardown (supprime tout et s'arrête)
Les paramètres arrivent par variables d'environnement (voir run.sh et config.env)."""
import argparse
import asyncio
import json
import os
import re
import sys
import time
from pathlib import Path


def e(name, default=''):
    return os.environ.get(name, default)


def log(msg):
    print(time.strftime('[%H:%M:%S]'), msg, flush=True)


def ue_rf_frequency_hz():
    """Return the OAI UE carrier-centre frequency for the configured band half."""
    point_a = 640722 if e('BAND_HALF', '1') == '1' else 642055
    point_a_hz = 3_000_000_000 + (point_a - 600_000) * 15_000
    return point_a_hz + (51 * 12 * 30_000) // 2


def configure_kubelet_template():
    """Keep the requested 1% disk eviction threshold through kubeadm resets."""
    import ansible

    template = Path(ansible.__file__).parent / 'roles/k8s/create/templates/kubeadm-config.yaml.j2'
    source = template.read_text()
    if 'mergeDefaultEvictionSettings:' not in source:
        anchor = 'cgroupDriver: systemd'
        if anchor not in source:
            raise RuntimeError(f'Impossible de régler le seuil disque dans {template}')
        source = source.replace(anchor, '''cgroupDriver: systemd
evictionHard:
  nodefs.available: "1%"
  imagefs.available: "1%"
mergeDefaultEvictionSettings: true''', 1)
        template.write_text(source)

    # Helm upgrades can replace a pod; k8s_info in the installed role has a
    # race when its first query lands between deletion and recreation.
    wait_tasks = Path(ansible.__file__).parent / 'roles/helm/install/tasks/main.yaml'
    wait_source = wait_tasks.read_text()
    # First-run images are large and may take several minutes on campus Wi-Fi;
    # the upstream 200-second timeout turns a slow pull into a failed install.
    wait_source, timeout_count = re.subn(
        r'(?m)^(\s*wait_timeout:\s*)\d+\s*$',
        r'\g<1>900',
        wait_source,
        count=1,
    )
    if timeout_count != 1:
        raise RuntimeError(f'Impossible d’allonger le délai d’attente des pods dans {wait_tasks}')
    wait_tasks.write_text(wait_source)

    marker = "- name: Give Kubernetes a moment to create '{{ chart_name }}' pod"
    anchor = "- name: Wait for '{{ chart_name }}' pod to become ready"
    if marker not in wait_source:
        if anchor not in wait_source:
            raise RuntimeError(f'Impossible de corriger l’attente des pods dans {wait_tasks}')
        wait_source = wait_source.replace(anchor, f'''{marker}
  ansible.builtin.pause:
    seconds: 5

{anchor}''', 1)
        wait_tasks.write_text(wait_source)

    # A previous virtual run may have customized the installed OAI chart.
    # Restore its normal pod networking when this launcher is used with USRP.
    if e('RAN_MODE') != 'virtual':
        gnb_template = Path(ansible.__file__).parent / (
            'roles/helm/prepare/files/ran/oai/oai-gnb/templates/deployment.yaml'
        )
        gnb_source = gnb_template.read_text()
        gnb_source = gnb_source.replace('      hostNetwork: true\n', '', 1)
        gnb_source = gnb_source.replace(
            '      dnsPolicy: ClusterFirstWithHostNet\n',
            '      dnsPolicy: ClusterFirst\n',
            1,
        )
        gnb_template.write_text(gnb_source)
    else:
        # This installed orchestrator version keeps deriving the UE frequency
        # from the SSB and its resolved gNB address from the old pod IP, even
        # when advanced_config is set. Pin the one-node RFsim values in the
        # Jinja source before Helm renders the UE ConfigMap.
        ue_template = Path(ansible.__file__).parent / (
            'roles/helm/prepare/templates/ue/oai/oai-containerized/config.yaml.j2'
        )
        ue_source = ue_template.read_text()
        node_ip = e('NODE_IP')
        if not node_ip:
            raise RuntimeError('NODE_IP absent : impossible de configurer l’adresse du gNB RFsim.')
        ue_source, server_count = re.subn(
            r'(?m)^(\s*serveraddr = ).*?;',
            lambda match: f'{match.group(1)}"{node_ip}";',
            ue_source,
            count=1,
        )
        ue_source, frequency_count = re.subn(
            r'(?m)^(\s*rf_freq = ).*?L;',
            lambda match: f'{match.group(1)}{ue_rf_frequency_hz()}L;',
            ue_source,
            count=1,
        )
        if server_count != 1 or frequency_count != 1:
            raise RuntimeError(f'Impossible de corriger le template de configuration UE dans {ue_template}')
        ue_template.write_text(ue_source)

def build_models():
    imsi = e('IMSI') or '001010000000018'
    imei = e('IMEI') or '868371054166950'
    mnc_len = int(e('MNC_LEN', '2'))
    mcc, mnc = imsi[:3], imsi[3:3 + mnc_len]
    if e('BAND_HALF', '1') == '1':
        dl, point_a, ssb = 641333, 640722, 641376
    else:
        dl, point_a, ssb = 642667, 642055, 642709
    # OAI's UE `rf_freq` is the carrier centre, not the SSB centre.
    ue_rf_freq_hz = ue_rf_frequency_hz()
    k = e('SIM_K', 'fec86ba6eb707ed08905757b1bb44b8f')
    opc = e('SIM_OPC', 'C42449363BBAD02B66D16BC975D77CC1')
    dnn = e('DNN', 'internet')
    tx_gain, rx_gain = int(e('TX_GAIN_DB', '35')), int(e('RX_GAIN_DB', '114'))
    tx_att, rx_att = int(e('TX_ATT_DB', '10')), int(e('RX_ATT_DB', '10'))
    node_ip = e('NODE_IP')
    node_ssh_host = e('NODE_SSH_HOST') or node_ip
    user = e('ORCH_USER')
    pw = e('ORCH_SUDO_PASSWORD')
    provisioned = 'true' if e('NODE_PROVISIONED', 'true') == 'true' else 'false'
    virtual_mode = e('RAN_MODE', 'usrp') == 'virtual'
    ru_name = 'sim_ru' if virtual_mode else 'usrp01'

    if virtual_mode:
        ru_meta = '''rus:
  sim_ru:
    type: simulated
'''
        ue_meta = f'''ues:
  simulated_ue:
    type: containerized
    config:
      supi: '{imsi}'
      pei: '{imei}'
      authenticationData:
        k: '{k}'
        opc: '{opc}'
      subscriptions:
        - snssai: internet
          dnn: {dnn}
      gnbs:
        - gnb
      ru: sim_ru
      nrBands:
        - 78
'''
        ru_deployment = ''
        ue_deployment = f'''ues:
  simulated_ue:
    type: containerized
    implementation: oai
    namespace: oai-ue
    advanced_config:
      rf_freq: {ue_rf_freq_hz}
'''
    else:
        ru_meta = f'''rus:
  usrp01:
    type: usrp
    model: b210
    txAttenuationDB: {tx_att}
    rxAttenuationDB: {rx_att}
    txGainDB: {tx_gain}
    rxGainDB: {rx_gain}
'''
        ue_meta = f'''ues:
  qdong_modem:
    type: cots
    config:
      supi: '{imsi}'
      pei: '{imei}'
      authenticationData:
        k: '{k}'
        opc: '{opc}'
      subscriptions:
        - snssai: internet
          dnn: {dnn}
      gnbs:
        - gnb
      nrBands:
        - 78
'''
        ru_deployment = '''rus:
  usrp01:
    is_provisioned: true
'''
        ue_deployment = ''

    meta = f'''
core:
  components:
    nrf:
      type: nrf
      config:
        plmnList:
          - plmnId:
              mcc: '{mcc}'
              mnc: '{mnc}'
            snssaiList:
              - internet

    ausf:
      type: ausf
      config:
        plmnList:
          - mcc: '{mcc}'
            mnc: '{mnc}'

    amf:
      type: amf
      config:
        guamiList:
          - plmnId:
              mcc: '{mcc}'
              mnc: '{mnc}'
        taiList:
          - plmnId:
              mcc: '{mcc}'
              mnc: '{mnc}'
            tac: 1
        plmnList:
          - plmnId:
              mcc: '{mcc}'
              mnc: '{mnc}'
            snssaiList:
              - internet

    smf:
      type: smf
      config:
        snssaiList:
          - internet
        plmnList:
          - mcc: '{mcc}'
            mnc: '{mnc}'
        upfs:
          - upf

    upf:
      type: upf
      config:
        snssaiList:
          - internet

    udr:
      type: udr

    udm:
      type: udm

ran:
  components:
    gnb:
      type: gnb
      config:
        gnbId: 1
        tac: 1
        plmnList:
          - plmnId:
              mcc: '{mcc}'
              mnc: '{mnc}'
            snssaiList:
              - internet
        nrCellId: 1
        physicalCellId: 0
        radioConfiguration:
          nrBand: 78
          downlinkArfcn: {dl}
          pointAFrequencyArfcn: {point_a}
          channelBandwidthMhz: 20
          subcarrierSpacingKhz: 30
          ssbArfcn: {ssb}
          ssbSubcarrierSpacing: 30
          tddConfiguration:
            periodicityMilliseconds: 5.0
            nrofDownlinkSlots: 7
            nrofDownlinkSymbols: 6
            nrofUplinkSlots: 2
            nrofUplinkSymbols: 4
        ru: {ru_name}
        amf: amf

{ru_meta}
{ue_meta}

slices:
  internet:
    sst: 1
    sd: 0xFFFFFF
    dnns:
      {dnn}:
        ipv4Network: 11.1.1.0/24
'''

    dep = f'''
params:
  k8s:
    master_node: node01
    install_multus: false

nodes:
  node01:
    is_provisioned: {provisioned}
    ssh_info:
      hostname: {json.dumps(node_ssh_host)}
      user: {json.dumps(user)}
      sudo_password: {json.dumps(pw)}
    roles:
      - core
      - ran
      - ue

{ru_deployment}
{ue_deployment}

core:
  implementation: oai

ran:
  implementation: oai
  components:
    gnb:
      type: gnb
      advanced_config:
        initialDLBWPlocationAndBandwidth: 13750
        initialDLBWPcontrolResourceSetZero: 12
        initialULBWPlocationAndBandwidth: 13750
        ssb_perRACH_OccasionAndCB_PreamblesPerSSB: 14
        pusch_TargetSNRx10: 250
        pucch_TargetSNRx10: 200
        prach_dtx_threshold: 120
        pucch0_dtx_threshold: 100
'''
    return meta, dep


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--clean', action='store_true')
    ap.add_argument('--teardown', action='store_true')
    ap.add_argument('--core-only', action='store_true')
    args = ap.parse_args()

    if not args.teardown:
        configure_kubelet_template()

    from metamodel.models.metamodel import MetaModel
    from orchestrator.models.deployment import DeploymentModel
    from orchestrator.deployment import (K8SManagement, CoreManagement,
                                         RANManagement, UEManagement,
                                         ProvisioningManagement)

    meta_yaml, dep_yaml = build_models()
    metamodel = MetaModel.from_yaml(meta_yaml)
    deployment_model = DeploymentModel.from_yaml(dep_yaml)
    k8s = K8SManagement(metamodel=metamodel, deployment_model=deployment_model)
    core = CoreManagement(k8s)
    ran = None
    prov = ProvisioningManagement(core)
    NODE = 'node01'

    async def sh(cmd, become=True):
        try:
            r = await prov.run_node_command(command=cmd, nodes=[NODE], become=become, quiet=True)
            return r[NODE] if isinstance(r, dict) else str(r)
        except Exception:
            return None

    async def pods(ns):
        out = await sh(['kubectl', 'get', 'pods', '-n', ns, '--no-headers'])
        return [l.split() for l in (out or '').splitlines() if l.strip()]

    def all_running(rows):
        if not rows:
            return False
        for r in rows:
            if len(r) < 3 or r[2] != 'Running':
                return False
            a, b = r[1].split('/')
            if a != b:
                return False
        return True

    async def wait_pods(ns, minimum, timeout):
        t0 = time.time()
        while time.time() - t0 < timeout:
            rows = await pods(ns)
            if len(rows) >= minimum and all_running(rows):
                return True
            await asyncio.sleep(10)
        return False

    async def teardown():
        # L'orchestrateur ne connaît l'état d'un déploiement que dans le processus qui l'a créé :
        # on tente la suppression propre, puis on nettoie directement les machines.
        try:
            log('Suppression : UE')
            current_ran = ran if ran is not None else RANManagement(core)
            await UEManagement(current_ran).remove()
        except Exception as ex:
            log('  (UE ignorée) %s' % str(ex)[:120])
        try:
            log('Suppression : gNB')
            current_ran = ran if ran is not None else RANManagement(core)
            await current_ran.remove()
        except Exception as ex:
            log('  (gNB ignoré) %s' % str(ex)[:120])
        for name, obj in (('coeur 5G', core), ('Kubernetes', k8s)):
            try:
                log('Suppression : %s' % name)
                await obj.remove()
            except Exception as ex:
                log('  (%s ignoré) %s' % (name, str(ex)[:120]))
        log('Nettoyage direct')
        await sh(['bash', '-c', 'kubectl delete namespace oai-ue oai-ran oai-core --ignore-not-found --timeout=120s; kubeadm reset -f; rm -rf /etc/cni/net.d /root/.kube'])

    if args.teardown:
        await teardown()
        log('Tout est supprimé.')
        return 0
    if args.clean:
        await teardown()

    # Kubernetes, coeur : ces étapes sont rejouables sans danger (Ansible et Helm sont idempotents).
    # Abaisse le seuil d'éviction disque du kubelet à 1 % d'espace disponible.
    log('Réglage du seuil d’éviction disque du kubelet à 1 %')
    kubelet_disk_threshold = r'''python3 - <<'PY'
import yaml
from pathlib import Path

path = Path('/var/lib/kubelet/config.yaml')
if path.is_file():
    config = yaml.safe_load(path.read_text()) or {}
    hard = config.setdefault('evictionHard', {})
    hard['nodefs.available'] = '1%'
    hard['imagefs.available'] = '1%'
    if 'containerfs.available' in hard:
        hard['containerfs.available'] = '1%'
    config['mergeDefaultEvictionSettings'] = True
    path.write_text(yaml.safe_dump(config, sort_keys=False))
PY
if [ -f /var/lib/kubelet/config.yaml ]; then systemctl restart kubelet; fi'''
    if await sh(['bash', '-lc', kubelet_disk_threshold]) is None:
        log('ERREUR : impossible de régler le seuil kubelet. Vérifiez /var/lib/kubelet/config.yaml et python3-yaml.')
        return 1

    log('Étape 1/4 : Kubernetes (quelques minutes)')
    try:
        await k8s.deploy()
    except Exception as ex:
        log('ERREUR Kubernetes : %s' % ex)
        log('Pistes : mot de passe sudo exact ? accès Internet ? Collez-moi les lignes Ansible affichées juste au-dessus.')
        return 1
    log('Étape 2/4 : coeur 5G OAI (quelques minutes)')
    await core.deploy()
    if not await wait_pods('oai-core', 8, 600):
        log('ERREUR : les pods du coeur ne sont pas tous Running après 10 minutes.')
        print(await sh(['kubectl', 'get', 'pods', '-A', '-o', 'wide']))
        return 1
    log('Coeur 5G prêt : 8 pods Running.')

    try:
        # RANManagement reconciles AMF references at construction time, so
        # instantiate it only after the core and its AMF have been deployed.
        ran = RANManagement(core)
    except Exception as ex:
        log('ERREUR initialisation RAN : %s' % ex)
        return 1

    if args.core_only:
        log('RÉSEAU 5G (COEUR) PRÊT. Mode sans radio : le RAN virtuel et le terminal virtuel se déploient ensuite.')
        return 0

    if e('RAN_MODE') == 'virtual':
        log('Étape 3/4 : gNB OAI RFsim simulé')
        try:
            await ran.deploy()
        except Exception as ex:
            # Helm 4 may reject the ConfigMap after our prior local address
            # correction because kubectl owns data.gnb.yaml. Retry the rendered
            # release directly and let Helm take ownership of that field.
            log('Le déploiement Helm du gNB a échoué (%s) ; nouvelle tentative directe avec --force-conflicts.' % ex)
            refresh_gnb_chart = r'''set -e
helm upgrade --install --reset-values --force-conflicts --create-namespace \
  --namespace oai-ran \
  --values /root/helm-charts/ran/oai-gnb/values.yaml \
  oai-gnb /root/helm-charts/ran/oai-gnb \
  --wait --timeout 300s'''
            if await sh(['bash', '-lc', refresh_gnb_chart]) is None:
                log('ERREUR : Helm n’a pas pu reprendre le ConfigMap gNB après le conflit de propriété.')
                return 1
        # Keep RFsim on the node network. The UE uses hostNetwork too, and a
        # Calico pod IP is not a reliable endpoint for host-to-pod RFsim TCP.
        patch_gnb_network = r'''set -e
export NODE_IP=%s
kubectl get configmap oai-gnb-configmap -n oai-ran -o json | python3 -c 'import json,os,re,sys; o=json.load(sys.stdin); s=o["data"]["gnb.yaml"]; s,n=re.subn(r"(?m)^([ ]*GNB_IPV4_ADDRESS_FOR_NG(?:_AMF|U):[ ]*)[0-9.]+",lambda m:m.group(1)+os.environ["NODE_IP"],s); assert n==2, f"expected 2 gNB interface addresses, changed {n}"; o["data"]["gnb.yaml"]=s; print(json.dumps(o))' | kubectl replace -f -
REVISION=$(date +%%s)
kubectl patch deployment oai-gnb -n oai-ran --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"hostNetwork\":true,\"dnsPolicy\":\"ClusterFirstWithHostNet\"},\"metadata\":{\"annotations\":{\"5g-launcher/config-revision\":\"$REVISION\"}}}}}"
kubectl rollout status deployment/oai-gnb -n oai-ran --timeout=300s''' % e('NODE_IP')
        if await sh(['bash', '-lc', patch_gnb_network]) is None:
            log('ERREUR : impossible de placer le gNB RFsim sur le réseau hôte.')
            return 1
        if not await wait_pods('oai-ran', 1, 300):
            log('ERREUR : le pod du gNB virtuel ne devient pas Ready.')
            print(await sh(['kubectl', 'get', 'pods', '-n', 'oai-ran', '-o', 'wide']))
            return 1
        # RANManagement captured the old pod IP during Helm installation.
        # Host-network pods use the node address; pass that stable endpoint to
        # UEManagement so the rendered RFsim client config cannot retain 10.244/16.
        from ipaddress import ip_address
        ran.deployment_model.ran.components['gnb'].network_info = ip_address(e('NODE_IP'))

        log('Étape 4/4 : UE OAI logiciel')
        ue_manager = UEManagement(ran)
        ue_deployment = ue_manager.deployment_model.ues['simulated_ue']
        if ue_deployment.advanced_config is None:
            from orchestrator.models.ue import OAIAdvancedUEConfig
            ue_deployment.advanced_config = OAIAdvancedUEConfig()
        ue_deployment.advanced_config.rf_freq = ue_rf_frequency_hz()
        log('RFsim : serveur gNB %s:4043 ; fréquence centrale UE %s Hz.' % (
            e('NODE_IP'), ue_deployment.advanced_config.rf_freq,
        ))
        await ue_manager.deploy()
        # The installed kubernetes.core Helm module can report "unchanged"
        # when only a chart file consumed through .Files.Get changed. Upgrade
        # directly so the corrected nr-ue.conf reaches the ConfigMap.
        refresh_ue_chart = r'''set -e
helm upgrade --install --reset-values --force-conflicts oai-simulated-ue \
  /root/helm-charts/ue/oai-simulated-ue \
  --namespace oai-ue \
  --values /root/helm-charts/ue/oai-simulated-ue/values.yaml \
  --wait --timeout 300s'''
        if await sh(['bash', '-lc', refresh_ue_chart]) is None:
            log('ERREUR : Helm n’a pas appliqué la configuration RFsim corrigée à l’UE.')
            return 1
        # The UE's TUN interface must exist on the host for AP policy routing.
        patch_ue_network = r'''set -e
DEPLOYMENT=$(kubectl get deployments -n oai-ue -o jsonpath='{.items[0].metadata.name}')
test -n "$DEPLOYMENT"
REVISION=$(date +%s)
kubectl patch deployment "$DEPLOYMENT" -n oai-ue --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"hostNetwork\":true,\"dnsPolicy\":\"ClusterFirstWithHostNet\"},\"metadata\":{\"annotations\":{\"5g-launcher/config-revision\":\"$REVISION\"}}}}}"
kubectl rollout status deployment/"$DEPLOYMENT" -n oai-ue --timeout=300s'''
        if await sh(['bash', '-lc', patch_ue_network]) is None:
            log('ERREUR : impossible de partager l’interface TUN de l’UE virtuelle avec l’hôte.')
            return 1
        if not await wait_pods('oai-ue', 1, 600):
            log('ERREUR : le pod de l’UE virtuelle ne devient pas Ready.')
            print(await sh(['kubectl', 'get', 'pods', '-n', 'oai-ue', '-o', 'wide']))
            return 1
        log('RÉSEAU 5G VIRTUEL PRÊT : coeur OAI, gNB RFsim et UE logiciel déployés.')
        return 0

    # USRP et CPU
    lsusb = await sh(['lsusb'], become=False) or ''
    if 'Ettus' not in lsusb:
        log('ERREUR : la USRP B210 est introuvable (lsusb). Branchez-la sur un port USB 3.0.')
        return 1
    log('USRP B210 détectée. Réglage du CPU en mode performance.')
    await sh(['apt', 'install', '-y', 'cpufrequtils'])
    await sh(['bash', '-c', 'for ((i=0;i<$(nproc --all);i++)); do cpufreq-set -c $i -r -g performance; done'])

    # gNB : l'objet RAN ne peut être créé qu'APRÈS le déploiement du coeur
    log('Étape 3/4 : gNB OAI avec la B210')
    await ran.deploy()
    if not await wait_pods('oai-ran', 1, 300):
        log('ERREUR : le pod du gNB n\'est pas Running.')
        print(await sh(['kubectl', 'get', 'pods', '-n', 'oai-ran', '-o', 'wide']))
        return 1

    log('Étape 4/4 : contrôles')
    ready = False
    for _ in range(18):
        try:
            logs = (await ran.get_logs(components=['gnb'], quiet=True))['gnb']
        except Exception:
            logs = ''
        if 'RU 0 rf device ready' in logs:
            ready = True
            break
        await asyncio.sleep(10)
    log('gNB : radio %s.' % ('prête (RU 0 rf device ready)' if ready else 'NON confirmée dans les journaux'))
    try:
        amf = (await core.get_logs(components=['amf'], quiet=True))['amf']
    except Exception:
        amf = ''
    log('AMF : gNB %s.' % ('connecté (NGSetupRequest reçu)' if 'NGSetupRequest' in amf else 'NON connecté (pas de NGSetupRequest)'))
    if not (ready and 'NGSetupRequest' in amf):
        log('ERREUR : le réseau n\'est pas complètement opérationnel, voir les journaux ci-dessus.')
        return 1
    log('RÉSEAU 5G PRÊT. Vous pouvez connecter le modem.')
    return 0


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
