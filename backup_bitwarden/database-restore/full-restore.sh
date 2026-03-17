#!/bin/bash
# Usage :
#   ./full-restore.sh              -> restore complet (secrets + helm + PVCs + DB + restart)
#   ./full-restore.sh --pvcs-only  -> restaure uniquement les PVCs et redemarre les pods
#   ./full-restore.sh --db-only    -> restaure uniquement la base de donnees
set -euo pipefail

namespace="bitwarden"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-complet}"

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

read -p "MinIO Access Key : " ACCESS_KEY
read -s -p "MinIO Secret Key : " SECRET_KEY; echo ""
read -p "Chemin vers votre cle privee GPG (.asc) : " GPG_PRIVATE_KEY_PATH
read -s -p "Passphrase GPG : " GPG_PASSPHRASE; echo ""

if [ ! -f "$GPG_PRIVATE_KEY_PATH" ]; then
    echo "ERREUR : fichier '$GPG_PRIVATE_KEY_PATH' introuvable." >&2
    exit 1
fi

# ---------- Lister les backups disponibles ----------

echo ""
echo "Lecture du dernier backup disponible sur MinIO..."

# Lecture du fichier "latest" ecrit par db-backup.sh apres chaque backup reussi
kubectl delete pod mc-read-latest -n "$namespace" 2>/dev/null || true
kubectl run mc-read-latest \
    --restart=Never -n "$namespace" \
    --image=minio/mc \
    --env="AK=${ACCESS_KEY}" \
    --env="SK=${SECRET_KEY}" \
    --command -- sh -c \
    'set -e; mc alias set m http://192.168.10.121:9000 "$AK" "$SK" --insecure -q 2>/dev/null; mc cat m/backup-bitwarden/latest --insecure'

LATEST_ID=""
if kubectl wait pod/mc-read-latest -n "$namespace" \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=30s 2>/dev/null; then
    LATEST_ID=$(kubectl logs mc-read-latest -n "$namespace" 2>/dev/null | tr -d '[:space:]')
fi
kubectl delete pod mc-read-latest -n "$namespace" 2>/dev/null || true

if [ -n "$LATEST_ID" ]; then
    echo "Dernier backup disponible : $LATEST_ID"
else
    echo "Impossible de lire le fichier latest. Verifiez MinIO : http://192.168.10.121:9000"
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

kubectl create namespace "$namespace" 2>/dev/null || true

if [ "$MODE" = "complet" ]; then
    kubectl delete secret bitwarden-minio-credentials -n "$namespace" 2>/dev/null || true
    kubectl create secret generic bitwarden-minio-credentials -n "$namespace" \
        --from-literal=accessKey="$ACCESS_KEY" \
        --from-literal=secretKey="$SECRET_KEY"
    echo "Secret bitwarden-minio-credentials cree."
fi

kubectl delete secret bitwarden-gpg-private-key -n "$namespace" 2>/dev/null || true
kubectl create secret generic bitwarden-gpg-private-key -n "$namespace" \
    --from-file=private.asc="$GPG_PRIVATE_KEY_PATH" \
    --from-literal=passphrase="$GPG_PASSPHRASE"
echo "Secret bitwarden-gpg-private-key cree (temporaire)."

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

    kubectl delete pod mc-secret-restore -n "$namespace" 2>/dev/null || true
    kubectl run mc-secret-restore \
        --restart=Never -n "$namespace" --image=minio/mc \
        --env="AK=${ACCESS_KEY}" \
        --env="SK=${SECRET_KEY}" \
        --env="RESTORE_ID=${RESTORE_ID}" \
        --command -- sh -c \
        'set -e; mc alias set m http://192.168.10.121:9000 "$AK" "$SK" --insecure -q 2>/dev/null; echo "Telechargement secrets/custom-secret_${RESTORE_ID}.yaml..."; mc cat "m/backup-bitwarden/secrets/custom-secret_${RESTORE_ID}.yaml" --insecure'

    kubectl wait pod/mc-secret-restore -n "$namespace" \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null || {
        PHASE=$(kubectl get pod mc-secret-restore -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
        echo "ERREUR : telechargement secret echoue (phase=$PHASE)" >&2
        kubectl logs -n "$namespace" mc-secret-restore 2>/dev/null >&2 || true
        kubectl delete pod mc-secret-restore -n "$namespace" 2>/dev/null || true
        exit 1
    }

    kubectl logs -n "$namespace" mc-secret-restore | sed -n '/^apiVersion:/,$p' | kubectl apply -f -
    kubectl delete pod mc-secret-restore -n "$namespace" 2>/dev/null || true
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

    echo "  --- download-minio ---"
    kubectl logs -n "$namespace" "$POD_PVC" -c download-minio -f 2>/dev/null || true
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
