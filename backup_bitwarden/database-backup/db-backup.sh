#!/bin/bash
# Declenche un backup manuel hors du planning du CronJob.
# Usage : ./db-backup.sh
set -euo pipefail

namespace="bitwarden"
JOB_NAME="bitwarden-backup-manual-$(date +%s)"

echo "=========================================="
echo " BACKUP MANUEL BITWARDEN"
echo " Job : $JOB_NAME"
echo "=========================================="

kubectl create job "$JOB_NAME" \
    --from=cronjob/bitwarden-backup \
    -n "$namespace"

echo "Job cree. Attente du demarrage..."
until kubectl get pods -n "$namespace" -l "job-name=$JOB_NAME" --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD=$(kubectl get pods -n "$namespace" -l "job-name=$JOB_NAME" -o jsonpath='{.items[0].metadata.name}')
echo "Pod : $POD"
echo ""

echo "--- Logs en direct ---"
kubectl logs -n "$namespace" "$POD" --all-containers --prefix -f 2>/dev/null || true

# Attendre que le job se termine reellement
if kubectl wait --for=condition=complete --timeout=300s job/"$JOB_NAME" -n "$namespace" 2>/dev/null; then
    echo ""
    echo "=========================================="
    echo " BACKUP MANUEL TERMINE : OK"
    echo "=========================================="
else
    echo ""
    echo "ERREUR : le backup a echoue. Verifiez les logs ci-dessus." >&2
    exit 1
fi