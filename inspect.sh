#!/bin/bash
# Rassemble dans orchestrator-info.txt ce que l'orchestrateur installé sait faire
# (RAN virtuel, types de terminaux). Envoyez ce fichier pour adapter le lanceur.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE" || exit 1
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { echo "Lancez d'abord  sudo ./run.sh  (il installe l'orchestrateur dans .venv)."; exit 1; }
OUT="$HERE/orchestrator-info.txt"

DIRS="$("$PY" - <<'PYEOF'
import importlib, os
for m in ('orchestrator', 'metamodel'):
    try:
        print(os.path.dirname(importlib.import_module(m).__file__))
    except Exception:
        pass
PYEOF
)"

{
  echo "===== versions ====="
  "$PY" -m pip list 2>/dev/null | grep -iE "orchestrator|metamodel|ansible|kubernetes|pydantic"
  echo "===== dossiers ====="
  echo "$DIRS"
  for d in $DIRS; do
    echo "===== arborescence : $d ====="
    find "$d" -maxdepth 5 -not -path '*/__pycache__*' | sed "s|$d/||" | head -400
  done
  echo "===== mentions du RAN virtuel et des terminaux (rfsim, zmq, ue, simulat) ====="
  for d in $DIRS; do
    grep -rIn -i -E "rfsim|rf_sim|zmq|nr-ue|nrue|uesoftmodem|srsue|ocudu|simulat|virtual" "$d" --include='*' 2>/dev/null | grep -v '/__pycache__/' | cut -c1-220 | head -150
  done
  echo "===== schéma du metamodel : types de RU, de terminaux, de composants ====="
  "$PY" - <<'PYEOF' 2>&1 | head -c 20000
import json
try:
    from metamodel.models.metamodel import MetaModel
    schema = MetaModel.model_json_schema()
    defs = schema.get('$defs', {})
    print('définitions :', ', '.join(sorted(defs)))
    for name, d in sorted(defs.items()):
        if any(k in name.lower() for k in ('ue', 'ru', 'radio', 'gnb', 'rfsim', 'type')):
            print('---', name)
            print(json.dumps(d, indent=1)[:1800])
except Exception as ex:
    print('introspection impossible :', ex)
PYEOF
  echo "===== charts Helm et gabarits liés au gNB et aux terminaux ====="
  for d in $DIRS; do
    find "$d" -type f \( -ipath '*gnb*' -o -ipath '*nr-ue*' -o -ipath '*oai-ue*' -o -ipath '*/ue/*' \) -not -path '*/__pycache__/*' 2>/dev/null | head -60
  done
  echo "===== contenu des gabarits gNB (extraits) ====="
  for f in $(for d in $DIRS; do find "$d" -type f -ipath '*gnb*' \( -name '*.yaml' -o -name '*.j2' -o -name '*.tpl' \) 2>/dev/null; done | head -8); do
    echo "--- $f"; head -c 4000 "$f"; echo
  done
} > "$OUT" 2>&1

echo "Fichier créé : $OUT ($(wc -c < "$OUT") octets)"
echo "Envoyez-moi ce fichier dans la conversation."
