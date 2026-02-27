#!/bin/bash
namespace="bitwarden"

# Supprime l'ancien job s'il existe encore
kubectl delete job -n $namespace -l app=bitwarden-restore 2>/dev/null || true
sleep 2

# Lance le job de restore
kubectl apply -n $namespace -f $(dirname "$0")/restore-job.yaml

# Attend que le pod soit créé
echo -n "Démarrage du pod"
until kubectl get pods -n $namespace -l app=bitwarden-restore --no-headers 2>/dev/null | grep -q .; do
    echo -n "."
    sleep 1
done
echo ""

POD=$(kubectl get pods -n $namespace -l app=bitwarden-restore -o jsonpath="{.items[0].metadata.name}")

# Suit les logs du téléchargement depuis MinIO
echo "=== Téléchargement depuis MinIO ==="
kubectl wait -n $namespace --for=jsonpath='{.status.initContainerStatuses[0].state.running}' pod/$POD --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD -c download-minio -f 2>/dev/null || true

# Suit les logs de la restauration SQL
echo ""
echo "=== Restauration de la base de données ==="
kubectl wait -n $namespace --for=jsonpath='{.status.containerStatuses[0].state.running}' pod/$POD --timeout=60s 2>/dev/null || true
kubectl logs -n $namespace $POD -c restore-db -f 2>/dev/null || true

# Vérifie le statut final du job
echo ""
kubectl wait -n $namespace --for=condition=complete job/bitwarden-restore --timeout=120s 2>/dev/null
if [ $? -eq 0 ]; then
    echo "Restore terminé avec succès."
else
    echo "ATTENTION : le job ne s'est pas terminé correctement."
    kubectl describe pod -n $namespace $POD
    exit 1
fi
