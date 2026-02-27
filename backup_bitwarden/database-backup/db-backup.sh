#!/bin/bash
namespace="bitwarden"
TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Récupère les credentials MinIO depuis le secret Kubernetes
ACCESS_KEY=$(kubectl get secret bitwarden-minio-credentials -n $namespace -o jsonpath='{.data.accessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret bitwarden-minio-credentials -n $namespace -o jsonpath='{.data.secretKey}' | base64 -d)

# ============================================================
# 1. BACKUP BASE DE DONNEES
# ============================================================
echo "=========================================="
echo " 1/3 - Backup base de données"
echo "=========================================="

kubectl delete job -n $namespace -l app=bitwarden-backup 2>/dev/null || true
sleep 2
kubectl apply -n $namespace -f $(dirname "$0")/backup-job.yaml

echo -n "Démarrage du pod"
until kubectl get pods -n $namespace -l app=bitwarden-backup --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD=$(kubectl get pods -n $namespace -l app=bitwarden-backup -o jsonpath="{.items[0].metadata.name}")

echo "--- Backup SQL ---"
kubectl wait -n $namespace --for=jsonpath='{.status.initContainerStatuses[0].state.running}' pod/$POD --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD -c backup-db -f 2>/dev/null || true

echo "--- Upload MinIO ---"
kubectl wait -n $namespace --for=jsonpath='{.status.containerStatuses[0].state.running}' pod/$POD --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD -c upload-minio -f 2>/dev/null || true

kubectl wait -n $namespace --for=condition=complete job/bitwarden-backup --timeout=120s 2>/dev/null || true
echo "Base de données sauvegardée."

# ============================================================
# 2. BACKUP SECRET KUBERNETES
# ============================================================
echo ""
echo "=========================================="
echo " 2/3 - Backup Secret Kubernetes"
echo "=========================================="

# Encode le secret en base64 pour l'injecter via une variable d'env (évite les problèmes de stdin)
SECRET_B64=$(kubectl get secret custom-secret -n $namespace -o yaml | base64 -w 0)

kubectl delete pod mc-secret-upload -n $namespace 2>/dev/null || true
kubectl run mc-secret-upload \
    --restart=Never -n $namespace \
    --image=minio/mc \
    --env="AK=${ACCESS_KEY}" \
    --env="SK=${SECRET_KEY}" \
    --env="TS=${TIMESTAMP}" \
    --env="SECRET_YAML=${SECRET_B64}" \
    --command -- sh -c \
    'mc alias set m http://192.168.10.99:9000 "$AK" "$SK" --insecure 2>/dev/null; mc mb --ignore-existing m/backup-bitwarden --insecure 2>/dev/null; printf "%s" "$SECRET_YAML" | base64 -d | mc pipe "m/backup-bitwarden/secrets/custom-secret_${TS}.yaml" --insecure'

# Attend que le pod se termine
kubectl wait pod/mc-secret-upload -n $namespace --for=condition=Ready --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace mc-secret-upload -f 2>/dev/null || true
kubectl wait pod/mc-secret-upload -n $namespace --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null || true
kubectl delete pod mc-secret-upload -n $namespace 2>/dev/null || true

echo "Secret sauvegardé : secrets/custom-secret_${TIMESTAMP}.yaml"

# ============================================================
# 3. BACKUP PVCs
# ============================================================
echo ""
echo "=========================================="
echo " 3/3 - Backup PVCs (dataprotection, attachments, licenses)"
echo "=========================================="

kubectl delete job -n $namespace -l app=bitwarden-pvc-backup 2>/dev/null || true
sleep 2
kubectl apply -n $namespace -f $(dirname "$0")/../pvc-backup/pvc-backup-job.yaml

echo -n "Démarrage du pod"
until kubectl get pods -n $namespace -l app=bitwarden-pvc-backup --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD_PVC=$(kubectl get pods -n $namespace -l app=bitwarden-pvc-backup -o jsonpath="{.items[0].metadata.name}")
kubectl wait -n $namespace --for=jsonpath='{.status.containerStatuses[0].state.running}' pod/$POD_PVC --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD_PVC -c backup-pvcs -f 2>/dev/null || true

kubectl wait -n $namespace --for=condition=complete job/bitwarden-pvc-backup --timeout=300s 2>/dev/null || true
echo "PVCs sauvegardés."

# ============================================================
echo ""
echo "=========================================="
echo " Backup complet termine : ${TIMESTAMP}"
echo "=========================================="
