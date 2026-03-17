#!/bin/bash
set -euo pipefail

namespace="bitwarden"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ID=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
S3_ENDPOINT="https://s3.rbx.io.cloud.ovh.net"
S3_PATH="s3://database-repairsoft/backup_bitwarden"

echo "=========================================="
echo " BACKUP BITWARDEN"
echo " ID : ${BACKUP_ID}"
echo "=========================================="

# ---------- Fonctions utilitaires ----------

check_job() {
    local JOB=$1 TIMEOUT=${2:-300}
    echo -n "  Attente job/$JOB"
    kubectl wait -n "$namespace" --for=condition=complete "job/$JOB" --timeout="${TIMEOUT}s" 2>/dev/null \
        && echo "" || echo " (timeout atteint, verification statut...)"

    local SUCCEEDED
    SUCCEEDED=$(kubectl get job "$JOB" -n "$namespace" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "$SUCCEEDED" != "1" ]; then
        local FAILED POD
        FAILED=$(kubectl get job "$JOB" -n "$namespace" -o jsonpath='{.status.failed}' 2>/dev/null || echo "?")
        echo "ERREUR : job $JOB echoue (succeeded=$SUCCEEDED, failed=$FAILED)" >&2
        POD=$(kubectl get pods -n "$namespace" -l "job-name=$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$POD" ]; then
            echo "--- Logs du pod $POD ---" >&2
            kubectl logs -n "$namespace" "$POD" --all-containers 2>/dev/null >&2 || true
        fi
        exit 1
    fi
    echo "  Job $JOB : OK"
}

cleanup() {
    kubectl delete configmap bitwarden-backup-id -n "$namespace" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- Vérifications préalables ----------

if ! kubectl get secret bitwarden-gpg-public-key -n "$namespace" &>/dev/null; then
    echo "ERREUR : secret 'bitwarden-gpg-public-key' introuvable dans le namespace '$namespace'." >&2
    echo ""
    echo "Créez-le avec votre clé publique GPG :"
    echo "  gpg --export --armor 'Bitwarden Backup' > /tmp/bitwarden-public.asc"
    echo "  kubectl create secret generic bitwarden-gpg-public-key -n $namespace \\"
    echo "    --from-file=public.asc=/tmp/bitwarden-public.asc"
    exit 1
fi

if ! kubectl get secret bitwarden-s3-credentials -n "$namespace" &>/dev/null; then
    echo "ERREUR : secret 'bitwarden-s3-credentials' introuvable." >&2
    exit 1
fi

ACCESS_KEY=$(kubectl get secret bitwarden-s3-credentials -n "$namespace" -o jsonpath='{.data.accessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret bitwarden-s3-credentials -n "$namespace" -o jsonpath='{.data.secretKey}' | base64 -d)

# Crée le ConfigMap d'ID partagé entre tous les jobs de cette session
kubectl delete configmap bitwarden-backup-id -n "$namespace" 2>/dev/null || true
kubectl create configmap bitwarden-backup-id -n "$namespace" --from-literal=id="${BACKUP_ID}"
echo "ID de backup : ${BACKUP_ID}"

# ============================================================
# 1. BACKUP BASE DE DONNÉES
# ============================================================
echo ""
echo "--- 1/3 Backup base de données ---"

kubectl delete job -n "$namespace" -l app=bitwarden-backup 2>/dev/null || true
sleep 2
kubectl apply -n "$namespace" -f "$SCRIPT_DIR/backup-job.yaml"

echo -n "  Démarrage"
until kubectl get pods -n "$namespace" -l app=bitwarden-backup --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD=$(kubectl get pods -n "$namespace" -l app=bitwarden-backup -o jsonpath='{.items[0].metadata.name}')
echo "  Pod : $POD"

echo "  --- backup-db ---"
kubectl logs -n "$namespace" "$POD" -c backup-db -f 2>/dev/null || true
echo "  --- encrypt-gpg ---"
kubectl logs -n "$namespace" "$POD" -c encrypt-gpg -f 2>/dev/null || true
echo "  --- upload-s3 ---"
kubectl logs -n "$namespace" "$POD" -c upload-s3 -f 2>/dev/null || true

check_job bitwarden-backup 300

# ============================================================
# 2. BACKUP SECRET KUBERNETES
# ============================================================
echo ""
echo "--- 2/3 Backup secret Kubernetes ---"

SECRET_B64=$(kubectl get secret custom-secret -n "$namespace" -o yaml | base64 -w 0)
kubectl delete pod mc-secret-upload -n "$namespace" 2>/dev/null || true
kubectl run mc-secret-upload \
    --restart=Never -n "$namespace" \
    --image=amazon/aws-cli \
    --env="AWS_ACCESS_KEY_ID=${ACCESS_KEY}" \
    --env="AWS_SECRET_ACCESS_KEY=${SECRET_KEY}" \
    --env="TS=${BACKUP_ID}" \
    --env="SECRET_YAML=${SECRET_B64}" \
    --command -- sh -c \
    'set -e; printf "%s" "$SECRET_YAML" | base64 -d | aws s3 cp - "s3://database-repairsoft/backup_bitwarden/secrets/custom-secret_${TS}.yaml" --endpoint-url https://s3.rbx.io.cloud.ovh.net; echo "Secret uploade : secrets/custom-secret_${TS}.yaml"'

kubectl wait pod/mc-secret-upload -n "$namespace" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null || {
    PHASE=$(kubectl get pod mc-secret-upload -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
    echo "ERREUR : upload secret echoue (phase=$PHASE)" >&2
    kubectl logs -n "$namespace" mc-secret-upload 2>/dev/null >&2 || true
    kubectl delete pod mc-secret-upload -n "$namespace" 2>/dev/null || true
    exit 1
}
kubectl logs -n "$namespace" mc-secret-upload 2>/dev/null || true
kubectl delete pod mc-secret-upload -n "$namespace" 2>/dev/null || true

# ============================================================
# 3. BACKUP PVCs
# ============================================================
echo ""
echo "--- 3/3 Backup PVCs (dataprotection, attachments, licenses) ---"

kubectl delete job -n "$namespace" -l app=bitwarden-pvc-backup 2>/dev/null || true
sleep 2
kubectl apply -n "$namespace" -f "$SCRIPT_DIR/../pvc-backup/pvc-backup-job.yaml"

echo -n "  Démarrage"
until kubectl get pods -n "$namespace" -l app=bitwarden-pvc-backup --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD_PVC=$(kubectl get pods -n "$namespace" -l app=bitwarden-pvc-backup -o jsonpath='{.items[0].metadata.name}')
echo "  Pod : $POD_PVC"

echo "  --- encrypt-pvcs ---"
kubectl logs -n "$namespace" "$POD_PVC" -c encrypt-pvcs -f 2>/dev/null || true
echo "  --- backup-pvcs ---"
kubectl logs -n "$namespace" "$POD_PVC" -c backup-pvcs -f 2>/dev/null || true

check_job bitwarden-pvc-backup 300

# Ecrit le fichier "latest" sur MinIO — lu par full-restore.sh pour connaitre le dernier backup
kubectl delete pod mc-latest-write -n "$namespace" 2>/dev/null || true
kubectl run mc-latest-write \
    --restart=Never -n "$namespace" \
    --image=amazon/aws-cli \
    --env="AWS_ACCESS_KEY_ID=${ACCESS_KEY}" \
    --env="AWS_SECRET_ACCESS_KEY=${SECRET_KEY}" \
    --env="BID=${BACKUP_ID}" \
    --command -- sh -c \
    'set -e; printf "%s" "$BID" | aws s3 cp - s3://database-repairsoft/backup_bitwarden/latest --endpoint-url https://s3.rbx.io.cloud.ovh.net; echo "Fichier latest mis a jour : $BID"'

kubectl wait pod/mc-latest-write -n "$namespace" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=30s 2>/dev/null || {
    echo "AVERTISSEMENT : mise a jour du fichier latest echouee (non bloquant)." >&2
}
kubectl logs -n "$namespace" mc-latest-write 2>/dev/null || true
kubectl delete pod mc-latest-write -n "$namespace" 2>/dev/null || true

echo ""
echo "=========================================="
echo " BACKUP COMPLET : OK"
echo " ID : ${BACKUP_ID}"
echo "=========================================="
