#!/bin/bash
namespace="bitwarden"
SCRIPT_DIR="$(dirname "$0")"

echo "=========================================="
echo " RESTORE COMPLET BITWARDEN"
echo "=========================================="
echo ""
echo "Ce script va :"
echo "  1. Recreer le secret bitwarden-minio-credentials"
echo "  2. Telecharger et appliquer le secret custom-secret depuis MinIO"
echo "  3. Attendre que vous fassiez helm install"
echo "  4. Restaurer les PVCs (dataprotection, attachments, licenses)"
echo "  5. Restaurer la base de donnees"
echo ""

# ============================================================
# 0. CREDENTIALS MINIO
# ============================================================
echo "=========================================="
echo " 0/4 - Credentials MinIO"
echo "=========================================="
read -p "MinIO Access Key : " ACCESS_KEY
read -s -p "MinIO Secret Key : " SECRET_KEY
echo ""

# Cree le namespace si besoin
kubectl create namespace $namespace 2>/dev/null || true

# (Re)cree le secret bitwarden-minio-credentials
kubectl delete secret bitwarden-minio-credentials -n $namespace 2>/dev/null || true
kubectl create secret generic bitwarden-minio-credentials \
    -n $namespace \
    --from-literal=accessKey="$ACCESS_KEY" \
    --from-literal=secretKey="$SECRET_KEY"
echo "Secret bitwarden-minio-credentials cree."

# ============================================================
# 1. RESTORE SECRET KUBERNETES
# ============================================================
echo ""
echo "=========================================="
echo " 1/4 - Restore secret Kubernetes (custom-secret)"
echo "=========================================="

kubectl delete pod mc-secret-restore -n $namespace 2>/dev/null || true
kubectl run mc-secret-restore \
    --restart=Never -n $namespace \
    --image=minio/mc \
    --env="AK=${ACCESS_KEY}" \
    --env="SK=${SECRET_KEY}" \
    --command -- sh -c \
    'mc alias set m http://192.168.10.121:9000 "$AK" "$SK" --insecure >/dev/null 2>&1; LINE=$(mc ls m/backup-bitwarden/secrets/ --insecure 2>/dev/null | sort | tail -1); LATEST=${LINE##* }; echo "Telechargement de $LATEST..." >&2; mc cat m/backup-bitwarden/secrets/$LATEST --insecure'

echo -n "Demarrage"
until kubectl get pod mc-secret-restore -n $namespace --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

kubectl wait pod/mc-secret-restore -n $namespace \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null || true

PHASE=$(kubectl get pod mc-secret-restore -n $namespace -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$PHASE" != "Succeeded" ]; then
    echo "ERREUR : le telechargement du secret a echoue (phase: $PHASE)."
    kubectl logs -n $namespace mc-secret-restore 2>/dev/null || true
    kubectl delete pod mc-secret-restore -n $namespace 2>/dev/null || true
    exit 1
fi

kubectl logs -n $namespace mc-secret-restore | sed -n '/^apiVersion:/,$p' | kubectl apply -f -
kubectl delete pod mc-secret-restore -n $namespace 2>/dev/null || true
echo "Secret custom-secret restaure."

# ============================================================
# 2. HELM INSTALL (pause manuelle)
# ============================================================
echo ""
echo "=========================================="
echo " 2/4 - Helm install"
echo "=========================================="
echo ""
echo "Lancez maintenant la commande en dehors du dossier bitwarden_helm dans un autre terminal :"
echo ""
echo "  helm install bitwarden ./bitwarden_helm/self-host \
        --namespace bitwarden \
        --values bitwarden_helm/self-host/values.preprod.yaml"
echo ""
read -p "Appuyez sur Entree une fois que helm install est termine..."

# ============================================================
# 3. RESTORE PVCs
# ============================================================
echo ""
echo "=========================================="
echo " 3/4 - Restore PVCs (dataprotection, attachments, licenses)"
echo "=========================================="

kubectl delete job -n $namespace -l app=bitwarden-pvc-restore 2>/dev/null || true
sleep 2
kubectl apply -n $namespace -f "$SCRIPT_DIR/../pvc-backup/pvc-restore-job.yaml"

echo -n "Demarrage du pod"
until kubectl get pods -n $namespace -l app=bitwarden-pvc-restore --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD_PVC=$(kubectl get pods -n $namespace -l app=bitwarden-pvc-restore -o jsonpath="{.items[0].metadata.name}")
kubectl wait -n $namespace --for=jsonpath='{.status.containerStatuses[0].state.running}' pod/$POD_PVC --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD_PVC -c restore-pvcs -f 2>/dev/null || true

kubectl wait -n $namespace --for=condition=complete job/bitwarden-pvc-restore --timeout=300s 2>/dev/null || true
echo "PVCs restaures."

# ============================================================
# 4. RESTORE BASE DE DONNEES
# ============================================================
echo ""
echo "=========================================="
echo " 4/4 - Restore base de donnees"
echo "=========================================="

bash "$SCRIPT_DIR/db-restore.sh"

# ============================================================
echo ""
echo "=========================================="
echo " Restore complet termine !"
echo " Redemarrez les pods Bitwarden si necessaire."
echo "=========================================="
