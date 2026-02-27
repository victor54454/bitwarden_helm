#!/bin/bash
namespace="bitwarden"

# Supprime l'ancien job s'il existe encore
kubectl delete job -n $namespace -l app=bitwarden-backup 2>/dev/null || true
sleep 2

# Lance le job de backup
kubectl apply -n $namespace -f $(dirname "$0")/backup-job.yaml

# Attend que le pod soit créé
echo -n "Démarrage du pod"
until kubectl get pods -n $namespace -l app=bitwarden-backup --no-headers 2>/dev/null | grep -q .; do
    echo -n "."
    sleep 1
done
echo ""

POD=$(kubectl get pods -n $namespace -l app=bitwarden-backup -o jsonpath="{.items[0].metadata.name}")

# Attend et suit les logs de l'init container (backup SQL)
echo "=== Backup de la base de données ==="
kubectl wait -n $namespace --for=jsonpath='{.status.initContainerStatuses[0].state.running}' pod/$POD --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD -c backup-db -f 2>/dev/null || true

# Attend que le container principal (upload MinIO) démarre
echo ""
echo "=== Upload vers MinIO ==="
kubectl wait -n $namespace --for=jsonpath='{.status.containerStatuses[0].state.running}' pod/$POD --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD -c upload-minio -f 2>/dev/null || true

# Vérifie le statut final du job
echo ""
kubectl wait -n $namespace --for=condition=complete job/bitwarden-backup --timeout=60s 2>/dev/null
if [ $? -eq 0 ]; then
    echo "Backup terminé avec succès."
else
    echo "ATTENTION : le job ne s'est pas terminé correctement."
    kubectl describe pod -n $namespace $POD
    exit 1
fi
