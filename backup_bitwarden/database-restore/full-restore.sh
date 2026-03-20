#!/bin/bash
# Usage :
#   ./full-restore.sh              -> restore complet (secrets + helm + PVCs + DB + restart)
#   ./full-restore.sh --pvcs-only  -> restaure uniquement les PVCs et redemarre les pods
#   ./full-restore.sh --db-only    -> restaure uniquement la base de donnees
set -euo pipefail

namespace="bitwarden"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-complet}"
S3_ENDPOINT="https://s3.rbx.io.cloud.ovh.net"
S3_PATH="s3://database-repairsoft/backup_bitwarden"

echo "=========================================="
echo " RESTORE BITWARDEN [mode: $MODE]"
echo "=========================================="
echo ""

# ---------- Fonctions utilitaires ----------

check_job() {
    local JOB=$1 TIMEOUT=${2:-300}
    echo -n "  Attente job/$JOB"
    kubectl wait -n "$namespace" --for=condition=complete "job/$JOB" --timeout="${TIMEOUT}s" 2>/dev/null \
        && echo "" || echo " (timeout)"

    local SUCCEEDED
    SUCCEEDED=$(kubectl get job "$JOB" -n "$namespace" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "$SUCCEEDED" != "1" ]; then
        local FAILED POD
        FAILED=$(kubectl get job "$JOB" -n "$namespace" -o jsonpath='{.status.failed}' 2>/dev/null || echo "?")
        echo "ERREUR : job $JOB echoue (succeeded=$SUCCEEDED, failed=$FAILED)" >&2
        POD=$(kubectl get pods -n "$namespace" -l "job-name=$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$POD" ]; then
            echo "--- Logs ---" >&2
            kubectl logs -n "$namespace" "$POD" --all-containers 2>/dev/null >&2 || true
        fi
        exit 1
    fi
    echo "  Job $JOB : OK"
}

cleanup() {
    kubectl delete configmap bitwarden-restore-id -n "$namespace" 2>/dev/null || true
    kubectl delete secret bitwarden-gpg-private-key -n "$namespace" 2>/dev/null || true
    echo "Nettoyage secrets temporaires effectue."
}
trap cleanup EXIT

# ---------- 0. Credentials & configuration ----------

echo "--- 0. Credentials & configuration ---"

read -p "S3 OVH Access Key : " ACCESS_KEY
read -s -p "S3 OVH Secret Key : " SECRET_KEY; echo ""
read -p "Chemin vers votre cle privee GPG (.asc) : " GPG_PRIVATE_KEY_PATH
read -s -p "Passphrase GPG : " GPG_PASSPHRASE; echo ""

if [ ! -f "$GPG_PRIVATE_KEY_PATH" ]; then
    echo "ERREUR : fichier '$GPG_PRIVATE_KEY_PATH' introuvable." >&2
    exit 1
fi

# Namespace cree ici car mc-read-latest en a besoin avant meme la section setup secrets
kubectl create namespace "$namespace" 2>/dev/null || true

# ---------- Lister les backups disponibles ----------

echo ""
echo "Lecture du dernier backup disponible sur S3 OVH..."

# Lecture du fichier "latest" ecrit par db-backup.sh apres chaque backup reussi
kubectl delete pod mc-read-latest -n "$namespace" 2>/dev/null || true
kubectl run mc-read-latest \
    --restart=Never -n "$namespace" \
    --image=amazon/aws-cli \
    --env="AWS_ACCESS_KEY_ID=${ACCESS_KEY}" \
    --env="AWS_SECRET_ACCESS_KEY=${SECRET_KEY}" \
    --command -- sh -c \
    'set -e; aws s3 cp s3://database-repairsoft/backup_bitwarden/latest - --endpoint-url https://s3.rbx.io.cloud.ovh.net'

LATEST_ID=""
if kubectl wait pod/mc-read-latest -n "$namespace" \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=30s 2>/dev/null; then
    LATEST_ID=$(kubectl logs mc-read-latest -n "$namespace" 2>/dev/null | tr -d '[:space:]')
fi
kubectl delete pod mc-read-latest -n "$namespace" 2>/dev/null || true

if [ -n "$LATEST_ID" ]; then
    echo "Dernier backup disponible : $LATEST_ID"
else
    echo "Impossible de lire le fichier latest. Verifiez S3 OVH : https://s3.rbx.io.cloud.ovh.net"
    echo "(Le fichier 'latest' est cree par db-backup.sh apres chaque backup reussi)"
fi

read -p "ID du backup a restaurer (Entree = ${LATEST_ID:-?}) : " RESTORE_ID_INPUT
RESTORE_ID="${RESTORE_ID_INPUT:-$LATEST_ID}"

if [ -z "$RESTORE_ID" ]; then
    echo "ERREUR : aucun backup selectionne." >&2
    exit 1
fi
echo "Backup selectionne : $RESTORE_ID"

# ---------- Setup secrets K8s ----------

if [ "$MODE" = "complet" ]; then
    kubectl delete secret bitwarden-s3-credentials -n "$namespace" 2>/dev/null || true
    kubectl create secret generic bitwarden-s3-credentials -n "$namespace" \
        --from-literal=accessKey="$ACCESS_KEY" \
        --from-literal=secretKey="$SECRET_KEY"
    echo "Secret bitwarden-s3-credentials cree."
fi

kubectl delete secret bitwarden-gpg-private-key -n "$namespace" 2>/dev/null || true
kubectl create secret generic bitwarden-gpg-private-key -n "$namespace" \
    --from-file=private.asc="$GPG_PRIVATE_KEY_PATH" \
    --from-literal=passphrase="$GPG_PASSPHRASE"
echo "Secret bitwarden-gpg-private-key cree (temporaire)."

# Cree aussi la cle publique (necessaire pour le CronJob de backup)
GPG_PUBLIC_TMP=$(mktemp /tmp/bitwarden-public-XXXXXX.asc)
gpg --import "$GPG_PRIVATE_KEY_PATH" 2>/dev/null || true
gpg --export --armor > "$GPG_PUBLIC_TMP"
kubectl delete secret bitwarden-gpg-public-key -n "$namespace" 2>/dev/null || true
kubectl create secret generic bitwarden-gpg-public-key -n "$namespace" \
    --from-file=public.asc="$GPG_PUBLIC_TMP"
rm -f "$GPG_PUBLIC_TMP"
echo "Secret bitwarden-gpg-public-key cree (pour le CronJob de backup)."

kubectl delete configmap bitwarden-restore-id -n "$namespace" 2>/dev/null || true
kubectl create configmap bitwarden-restore-id -n "$namespace" --from-literal=id="$RESTORE_ID"
echo "ConfigMap bitwarden-restore-id cree (id=$RESTORE_ID)."

# ============================================================
# 1. RESTORE SECRET KUBERNETES (mode complet uniquement)
# ============================================================
if [ "$MODE" = "complet" ]; then
    echo ""
    echo "=========================================="
    echo " 1/4 Restore secret Kubernetes (custom-secret)"
    echo "=========================================="

    kubectl delete job -n "$namespace" -l app=bitwarden-secret-restore 2>/dev/null || true
    sleep 2
    kubectl apply -n "$namespace" -f "$SCRIPT_DIR/secret-restore-job.yaml"

    echo -n "  Démarrage"
    until kubectl get pods -n "$namespace" -l "app=bitwarden-secret-restore" --no-headers 2>/dev/null | grep -q .; do
        echo -n "."; sleep 1
    done
    echo ""

    POD_SECRET=$(kubectl get pods -n "$namespace" -l "app=bitwarden-secret-restore" -o jsonpath='{.items[0].metadata.name}')
    echo "  Pod : $POD_SECRET"

    echo -n "  Attente init container (download-s3)"
    until kubectl get pod -n "$namespace" "$POD_SECRET" \
        -o jsonpath='{.status.initContainerStatuses[0].state.running.startedAt}' 2>/dev/null | grep -q .; do
        echo -n "."; sleep 1
    done
    echo ""

    echo "  --- download-s3 ---"
    kubectl logs -n "$namespace" "$POD_SECRET" -c download-s3 -f 2>/dev/null || true

    echo -n "  Attente container principal (decrypt-output)"
    until kubectl get pod -n "$namespace" "$POD_SECRET" \
        -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null | grep -q .; do
        echo -n "."; sleep 1
    done
    echo ""

    echo "  --- decrypt-output ---"
    DECRYPT_TMP=$(mktemp)
    kubectl logs -n "$namespace" "$POD_SECRET" -c decrypt-output -f 2>/dev/null > "$DECRYPT_TMP" || true
    if [ ! -s "$DECRYPT_TMP" ]; then
        echo "ERREUR: le container decrypt-output n'a produit aucune sortie (mauvaise passphrase ?)" >&2
        rm -f "$DECRYPT_TMP"
        exit 1
    fi
    kubectl apply -f "$DECRYPT_TMP"
    rm -f "$DECRYPT_TMP"

    check_job bitwarden-secret-restore 60
    echo "Secret custom-secret restaure."

    # ============================================================
    # 2. HELM INSTALL (mode complet uniquement)
    # ============================================================
    echo ""
    echo "=========================================="
    echo " 2/4 Helm install"
    echo "=========================================="
    echo ""
    echo "Lancez dans un autre terminal (depuis le dossier parent de bitwarden_helm) :"
    echo ""
    echo "  helm install bitwarden ./bitwarden_helm/self-host \\"
    echo "    --namespace bitwarden \\"
    echo "    --values bitwarden_helm/self-host/values.preprod.yaml"
    echo ""
    read -p "Appuyez sur Entree une fois helm install termine et les pods demarres..."
fi

# ============================================================
# 3. RESTORE PVCs
# ============================================================
if [ "$MODE" = "complet" ] || [ "$MODE" = "--pvcs-only" ]; then
    STEP=$([ "$MODE" = "complet" ] && echo "3/4" || echo "1/2")
    echo ""
    echo "=========================================="
    echo " $STEP Restore PVCs (dataprotection, attachments, licenses)"
    echo "=========================================="

    kubectl delete job -n "$namespace" -l app=bitwarden-pvc-restore 2>/dev/null || true
    sleep 2
    kubectl apply -n "$namespace" -f "$SCRIPT_DIR/../pvc-backup/pvc-restore-job.yaml"

    echo -n "  Démarrage"
    until kubectl get pods -n "$namespace" -l app=bitwarden-pvc-restore --no-headers 2>/dev/null | grep -q .; do
        echo -n "."; sleep 1
    done
    echo ""

    POD_PVC=$(kubectl get pods -n "$namespace" -l app=bitwarden-pvc-restore -o jsonpath='{.items[0].metadata.name}')
    echo "  Pod : $POD_PVC"

    echo "  --- download-s3 ---"
    kubectl logs -n "$namespace" "$POD_PVC" -c download-s3 -f 2>/dev/null || true
    echo "  --- restore-pvcs ---"
    kubectl logs -n "$namespace" "$POD_PVC" -c restore-pvcs -f 2>/dev/null || true

    check_job bitwarden-pvc-restore 300
    echo "PVCs restaures avec succes."
fi

# ============================================================
# 4. RESTORE BASE DE DONNÉES
# ============================================================
if [ "$MODE" = "complet" ] || [ "$MODE" = "--db-only" ]; then
    STEP=$([ "$MODE" = "complet" ] && echo "4/4" || echo "1/2")
    echo ""
    echo "=========================================="
    echo " $STEP Restore base de donnees"
    echo "=========================================="

    bash "$SCRIPT_DIR/db-restore.sh"
fi

# ============================================================
# 5. REDÉMARRAGE DES PODS
# ============================================================
echo ""
echo "=========================================="
echo " Redémarrage des pods Bitwarden"
echo "=========================================="

kubectl rollout restart deployment -n "$namespace"
echo "Rollout restart lance. Attente de la stabilisation..."

kubectl rollout status deployment -n "$namespace" --timeout=180s 2>/dev/null && \
    echo "Tous les deployments sont prets." || \
    echo "Note : verification timeout. Lancez : kubectl get pods -n $namespace"

echo ""
echo "=========================================="
echo " RESTORE TERMINE [mode: $MODE]"
echo " Backup restaure : $RESTORE_ID"
echo "=========================================="
