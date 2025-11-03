#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG
########################################

# Domaine racine cible
BASE_DOMAIN="${BASE_DOMAIN:-ai-dev.fake-domain.name}"

# Classe d'Ingress ciblée (vide = toutes)
INGRESS_CLASS="${INGRESS_CLASS:-public}"

# cert-manager ClusterIssuer (laisser vide pour ne pas toucher)
CERT_ISSUER="${CERT_ISSUER:-}"

# Filtre namespaces (regex CSV, ex: "ai-.*,default"), sinon tous
NAMESPACE_SEL="${NAMESPACE_SEL:-}"

# Filtre labels kubectl (ex: "app=myapp")
LABEL_SEL="${LABEL_SEL:-}"

# Mode: --plan | --apply | --rollback
MODE="${1:---plan}"

# Forcer un domaine ou un cluster c0..c4
DEST_DOMAIN_FORCE="${DEST_DOMAIN_FORCE:-}"    # ex: "c2.ai-dev.fake-domain.name"
DEST_CLUSTER_FORCE="${DEST_CLUSTER_FORCE:-}"  # ex: "c2"

# Suffixe utilisé en cas de conflit de nom
SUFFIX_BASE="${SUFFIX_BASE:--aidev}"

OUT_DIR="${OUT_DIR:-./ingress-aidev-out}"
TMP_DIR="$(mktemp -d)"
ALL_ING_JSON="$TMP_DIR/all-ing.json"
PLAN_JSON="$TMP_DIR/plan.json"
mkdir -p "$OUT_DIR"

# LLM optionnel pour résumer le plan (API compatible OpenAI)
# Exemple d'environnement :
#   OPENAI_API_MODEL='ai-chat'
#   OPENAI_API_KEY="${COMMUN_KEY}"
#   OPENAI_API_BASE='https://api-ai.numerique-interieur.com/v1'
OPENAI_API_MODEL="${OPENAI_API_MODEL:-ai-chat}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_API_BASE="${OPENAI_API_BASE:-}"
DIFF_EXPLAIN_FILE="${DIFF_EXPLAIN_FILE:-$OUT_DIR/llm-plan-summary.md}"

########################################
# HELPERS
########################################

info(){ echo -e "[\e[36mINFO\e[0m] $*"; }
warn(){ echo -e "[\e[33mWARN\e[0m] $*"; }
err(){ echo -e "[\e[31mERR \e[0m] $*" >&2; }

require(){
  command -v "$1" >/dev/null 2>&1 || { err "binaire manquant: $1"; exit 1; }
}

require kubectl
require jq
# yq est optionnel : si indisponible, les manifests resteront en JSON (YAML valide)
if command -v yq >/dev/null 2>&1; then
  HAS_YQ=1
else
  warn "yq introuvable, les manifests seront générés en JSON (compatible YAML)."
  HAS_YQ=0
fi

# Conversion JSON -> YAML compatible (go-yq ou python-yq)
json_to_yaml() {
  local json_file="$1" yaml_file="$2"

  if [[ "$HAS_YQ" -eq 1 ]]; then
    local tmp_yaml
    tmp_yaml="${yaml_file}.tmp"

    # go-yq (mikefarah) : yq eval -P
    if yq eval -P '.' "$json_file" >"$tmp_yaml" 2>/dev/null; then
      mv "$tmp_yaml" "$yaml_file"
      return 0
    fi

    # python yq (kislyuk) : yq -y
    if yq -y '.' "$json_file" >"$tmp_yaml" 2>/dev/null; then
      mv "$tmp_yaml" "$yaml_file"
      return 0
    fi

    rm -f "$tmp_yaml"
    warn "Impossible de convertir ${json_file} en YAML avec yq, fallback JSON."
  fi

  # Fallback : JSON est un sous-ensemble de YAML 1.2, on recopie simplement
  cp "$json_file" "$yaml_file"
  return 0
}
require curl

# kubectl options
KNS_OPTS=(-A)
if [[ -n "$NAMESPACE_SEL" ]]; then
  KNS_OPTS=()
fi

KSEL_OPTS=()
[[ -n "$LABEL_SEL" ]] && KSEL_OPTS+=( -l "$LABEL_SEL" )

# Filtre jq pour les namespaces
NS_REGEX=""
if [[ -n "$NAMESPACE_SEL" ]]; then
  ns_regex_body="$(echo "$NAMESPACE_SEL" | sed 's/,/|/g')"
  NS_REGEX="^(${ns_regex_body})$"
fi

########################################
# CLUSTER → DOMAINE
########################################

cluster_to_domain() {
  local cluster="$1"
  case "$cluster" in
    c0) echo "c0.${BASE_DOMAIN}" ;;
    c1) echo "c1.${BASE_DOMAIN}" ;;
    c2) echo "c2.${BASE_DOMAIN}" ;;
    c3) echo "c3.${BASE_DOMAIN}" ;;
    c4) echo "c4.${BASE_DOMAIN}" ;;
    ""|*) echo "${BASE_DOMAIN}" ;;
  esac
}

# Choix intelligent du domaine cible pour un Ingress
# args: ns, labels_json, ann_json, first_host
pick_target_domain() {
  local ns="$1" labels_json="$2" ann_json="$3" first_host="$4"

  # 0) Overrides forts
  if [[ -n "$DEST_DOMAIN_FORCE" ]]; then
    echo "$DEST_DOMAIN_FORCE"
    return 0
  fi
  if [[ -n "$DEST_CLUSTER_FORCE" ]]; then
    cluster_to_domain "$DEST_CLUSTER_FORCE"
    return 0
  fi

  local cluster=""

  # 1) Annotation / label explicite
  cluster="$(jq -r '."aidev.k8s/cluster" // empty' <<<"$ann_json")"
  if [[ -z "$cluster" || "$cluster" == "null" ]]; then
    cluster="$(jq -r '."aidev.k8s/cluster" // empty' <<<"$labels_json")"
  fi

  # 2) Namespace contenant c0..c4
  if [[ -z "$cluster" || "$cluster" == "null" ]]; then
    if [[ "$ns" =~ (^|-)c([0-4])(-|$) ]]; then
      cluster="c${BASH_REMATCH[2]}"
    fi
  fi

  # 3) Host d'origine contenant ".cX."
  if [[ -z "$cluster" || "$cluster" == "null" ]]; then
    if [[ "$first_host" =~ \.c([0-4])\. ]]; then
      cluster="c${BASH_REMATCH[1]}"
    fi
  fi

  # 4) Fallback
  cluster_to_domain "$cluster"
}

########################################
# NOMMAGE (Ingress / Secret)
########################################

# Génère un nom sans conflit (on garde le nom si possible, sinon suffixe)
# args: ns, old_name, kind(ing|secret)
gen_name() {
  local ns="$1" old="$2" kind="$3"
  local suffix="$SUFFIX_BASE"
  local cand

  # nom d'origine si libre
  if [[ "$kind" == "ing" ]]; then
    if ! kubectl get ing -n "$ns" "$old" >/dev/null 2>&1; then
      echo "$old"
      return 0
    fi
  else
    if ! kubectl get secret -n "$ns" "$old" >/dev/null 2>&1; then
      echo "$old"
      return 0
    fi
  fi

  # sinon on suffixe
  local i=0
  while :; do
    if ((i==0)); then
      cand="${old}${suffix}"
    else
      cand="${old}${suffix}-${i}"
    fi

    if [[ "$kind" == "ing" ]]; then
      if ! kubectl get ing -n "$ns" "$cand" >/dev/null 2>&1; then
        echo "$cand"
        return 0
      fi
    else
      if ! kubectl get secret -n "$ns" "$cand" >/dev/null 2>&1; then
        echo "$cand"
        return 0
      fi
    fi
    ((i++))
  done
}

########################################
# COLLECTE DES INGRESS
########################################

info "Collecte des Ingress (état AVANT)…"
kubectl get ing "${KNS_OPTS[@]}" "${KSEL_OPTS[@]}" -o json > "$ALL_ING_JSON"

# Plan : Ingress à dupliquer
# On ignore ceux dont un host termine déjà par :
#   - .ai-dev.fake-domain.name
#   - .cX.ai-dev.fake-domain.name (c0..c4)
info "Filtrage des Ingress à dupliquer…"
jq --arg base_domain "$BASE_DOMAIN" --arg ing_class "$INGRESS_CLASS" --arg ns_regex "$NS_REGEX" '
  .items
  | map(select(
      ($ns_regex == "") or (.metadata.namespace | test($ns_regex))
    ))
  | map(select(
      ( .spec.ingressClassName? // "" ) as $c
      | ($ing_class == "" or $c == $ing_class)
    ))
  | map(
      . as $ing
      | ( [ .spec.rules[]?.host ] | map(select(. != null)) ) as $hosts
      | if ($hosts | length) == 0 then empty
        else
          if (
            [ $hosts[] |
              ( endswith("." + $base_domain)
                or test("\\.c[0-4]\\." + $base_domain + "$")
              )
            ] | any
          )
          then empty
          else $ing
          end
      end
    )
' "$ALL_ING_JSON" > "$PLAN_JSON"

AFFECTED=$(jq 'length' "$PLAN_JSON")
if [[ "$AFFECTED" -eq 0 ]]; then
  warn "Aucun Ingress à dupliquer (rien ne correspond aux critères)."
  exit 0
fi

info "Ingress candidats: $AFFECTED"
jq -r '.[] | "\(.metadata.namespace)/\(.metadata.name)  ->  " +
  ( [.spec.rules[]?.host] | map(select(.!=null)) | join(",") )' "$PLAN_JSON" \
  | tee "$OUT_DIR/before-inventory.txt"

########################################
# BUILD DES CLONES
########################################

build_clone_yaml() {
  local ns="$1" name="$2"
  local ypath="$OUT_DIR/${ns}-${name}-aidev.yaml"

  # Ingress source complet depuis all-ing.json
  local src_file="$TMP_DIR/${ns}-${name}.json"
  jq -c --arg ns "$ns" --arg name "$name" '
    .items[] | select(.metadata.namespace==$ns and .metadata.name==$name)
  ' "$ALL_ING_JSON" >"$src_file"

  if [[ ! -s "$src_file" ]]; then
    warn "Ingress introuvable dans all-ing.json: ${ns}/${name}, ignoré."
    rm -f "$src_file"
    return 0
  fi

  local clone_json_file="$TMP_DIR/${ns}-${name}-clone.json"
  trap 'rm -f "$src_file" "$clone_json_file"' RETURN

  local orig_name
  orig_name="$(jq -r '.metadata.name' "$src_file")"

  local labels annotations first_host
  labels="$(jq -c '.metadata.labels // {}' "$src_file")"
  annotations="$(jq -c '.metadata.annotations // {}' "$src_file")"
  first_host="$(jq -r '[.spec.rules[]?.host] | map(select(.!=null)) | .[0] // ""' "$src_file")"

  # Choix intelligent du domaine cible
  local dest_domain
  dest_domain="$(pick_target_domain "$ns" "$labels" "$annotations" "$first_host")"

  # Dérive le nom à partir du NOUVEAU host (plus cohérent pour l'admin)
  local host_prefix dest_hostname base_name
  if [[ -n "$first_host" ]]; then
    host_prefix="$(printf '%s\n' "$first_host" | awk -F'.' '{print $1}')"
  else
    host_prefix="ingress"
  fi
  dest_hostname="${host_prefix}.${dest_domain}"                 # ex: demos.ai-dev.fake-domain.name
  base_name="$(printf '%s\n' "$dest_hostname" | tr '.' '-')"   # ex: demos-ai-dev-fake-domain-name

  # Nom du nouvel Ingress basé sur le nouveau host
  local new_ing_name
  new_ing_name="$(gen_name "$ns" "$base_name" "ing")"

  # TLS : on regarde s'il y a des blocs TLS
  local has_tls
  has_tls="$(jq '(.spec.tls // []) | length' "$src_file")"

  # Secret TLS cohérent avec le nouveau host (toujours initialisé)
  local tls_secret=""
  if (( has_tls > 0 )); then
    local tls_base
    tls_base="${base_name}-tls"
    tls_secret="$(gen_name "$ns" "$tls_base" "secret")"
  fi

  # Transformation principale en une seule passe jq
  jq \
    --arg dest_domain "$dest_domain" \
    --arg INGRESS_CLASS "$INGRESS_CLASS" \
    --arg CERT_ISSUER "$CERT_ISSUER" \
    --arg NEW_NAME "$new_ing_name" \
    --arg PARENT_NAME "$orig_name" \
    --arg tls_secret "$tls_secret" '
    .metadata.name = $NEW_NAME
    | .metadata.labels = ((.metadata.labels // {}) + {
        "duplicated-for":"ai-dev",
        "aidev.k8s/parent":$PARENT_NAME
      })
    | .metadata.annotations = ((.metadata.annotations // {}) + {
        "aidev.k8s/generated":"true",
        "aidev.k8s/dest-domain":$dest_domain
      })
    | if ($CERT_ISSUER|length)>0 then
        .metadata.annotations["cert-manager.io/cluster-issuer"] = $CERT_ISSUER
      else . end
    | .spec.ingressClassName = ( .spec.ingressClassName // $INGRESS_CLASS )

    # Hosts: on garde le prefix (avant le 1er point initial), on remplace le domaine
    | .spec.rules = (
        if (.spec.rules // [] | length) > 0 then
          (.spec.rules // [] | map(
            if has("host") and (.host != null) then
              .host = ((.host | split("/") | last | split(".") | .[0]) + "." + $dest_domain)
            else . end
          ))
        else .spec.rules
        end
      )

    # TLS: hosts alignés sur le même dest_domain et secretName cohérent
    | .spec.tls = (
        if (.spec.tls // [] | length) > 0 then
          ((.spec.tls // []) | map(
            .hosts = ((.hosts // []) | map(
              if . != null then
                (. | split("/") | last | split(".") | .[0]) + "." + $dest_domain
              else . end
            ))
            | if ($tls_secret|length)>0 then
                .secretName = $tls_secret
              else . end
          ))
        else null
        end
      )
    | del(
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.managedFields,
        .status
      )
  ' "$src_file" >"$clone_json_file"

  json_to_yaml "$clone_json_file" "$ypath"
}

info "Génération des manifests clones…"
while read -r ns name; do
  build_clone_yaml "$ns" "$name"
done < <(jq -r '.[] | "\(.metadata.namespace) \(.metadata.name)"' "$PLAN_JSON")

ls -1 "$OUT_DIR"/*-aidev.yaml > "$OUT_DIR/plan-files.txt"
info "Manifests générés: $(wc -l < "$OUT_DIR/plan-files.txt") fichiers YAML"

########################################
# MODES
########################################

if [[ "$MODE" == "--plan" ]]; then
  info "Mode plan : aucun changement appliqué."
  echo "👉 Manifests prêts dans: $OUT_DIR"

  # Résumé via LLM si OPENAI_API_* définis
  if [[ -n "$OPENAI_API_BASE" && -n "$OPENAI_API_KEY" ]]; then
    info "Résumé du plan via LLM (OPENAI_API_BASE)…"
    {
      echo "# Plan de duplication Ingress → ai-dev"
      echo
      echo "Domaine racine : ${BASE_DOMAIN}"
      echo
      echo "Ingress affectés :"
      echo
      cat "$OUT_DIR/before-inventory.txt"
    } > "$DIFF_EXPLAIN_FILE.input"

    api_base="${OPENAI_API_BASE%/}"
    curl -sS "${api_base}/chat/completions" \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg model "$OPENAI_API_MODEL" \
        --arg content "$(cat "$DIFF_EXPLAIN_FILE.input")" '
        {
          model: $model,
          messages: [
            { "role": "system", "content": "You are a concise DevOps assistant. Summarize this ingress migration plan in French." },
            { "role": "user", "content": $content }
          ],
          temperature: 0.1
        }')" \
      | jq -r '.choices[0].message.content // "Résumé LLM indisponible"' \
      > "$DIFF_EXPLAIN_FILE"

    info "Résumé LLM écrit dans: $DIFF_EXPLAIN_FILE"
  fi
  exit 0
fi

if [[ "$MODE" == "--rollback" ]]; then
  info "Rollback : suppression des Ingress clonés (label duplicated-for=ai-dev)…"
  kubectl delete ing -A -l 'duplicated-for=ai-dev' || true
  info "Rollback terminé."
  exit 0
fi

if [[ "$MODE" != "--apply" ]]; then
  err "Mode inconnu: $MODE (attendu: --plan | --apply | --rollback)"
  exit 1
fi

########################################
# APPLY
########################################

info "Application des manifests (server-side apply)…"
while read -r f; do
  kubectl apply --server-side --force-conflicts -f "$f"
done < "$OUT_DIR/plan-files.txt"

########################################
# VÉRIFICATION APRÈS
########################################

info "État APRÈS : Ingress clonés…"
kubectl get ing -A -l 'duplicated-for=ai-dev' -o wide | tee "$OUT_DIR/after-ingresses.txt"

# Détection d'une adresse LB commune
LB_ADDR="$(kubectl get ing -A -o json \
  | jq -r '.items[]?.status.loadBalancer.ingress[]? | (.ip // .hostname)' \
  | head -n1 || true)"

if [[ -z "$LB_ADDR" ]]; then
  warn "Impossible de déduire une adresse LB commune. Les probes HTTP HEAD sont sautées."
else
  info "Adresse LB détectée: $LB_ADDR"
  info "Probes HTTP HEAD via --resolve…"

  {
    echo "| Namespace | Ingress | Host | HTTP |"
    echo "|---|---|---|---|"
    kubectl get ing -A -l 'duplicated-for=ai-dev' -o json \
      | jq -r '
        .items[] | .metadata.namespace as $ns | .metadata.name as $name
        | [ .spec.rules[]?.host ] | map(select(.!=null)) | unique[]
        | [$ns,$name,.] | @tsv
      ' \
      | while IFS=$'\t' read -r ns name host; do
          code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
            --resolve "${host}:80:${LB_ADDR}" \
            "http://${host}/" 2>/dev/null || echo "ERR")"
          echo "| ${ns} | ${name} | ${host} | ${code} |"
        done
  } | tee "$OUT_DIR/http-probes.md"
fi

info "Terminé. Détails dans: $OUT_DIR"
