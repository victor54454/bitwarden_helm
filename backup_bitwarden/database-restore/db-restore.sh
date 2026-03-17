#!/bin/bash
# Usage interne : appele par full-restore.sh apres creation du ConfigMap bitwarden-restore-id
set -euo pipefail

namespace="bitwarden"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Supprime l'ancien job s'il existe
kubectl delete job -n "$namespace" -l app=bitwarden-restore 2>/dev/null || true
sleep 2

kubectl apply -n "$namespace" -f "$SCRIPT_DIR/restore-job.yaml"

echo -n "  Démarrage"
until kubectl get pods -n "$namespace" -l app=bitwarden-restore --no-headers 2>/dev/null | grep -q .; do
    echo -n "."; sleep 1
done
echo ""

POD=$(kubectl get pods -n "$namespace" -l app=bitwarden-restore -o jsonpath='{.items[0].metadata.name}')
echo "  Pod : $POD"

echo "  --- download-s3 ---"
kubectl logs -n "$namespace" "$POD" -c download-s3 -f 2>/dev/null || true
echo "  --- decrypt-gpg ---"
kubectl logs -n "$namespace" "$POD" -c decrypt-gpg -f 2>/dev/null || true
echo "  --- restore-db ---"
kubectl logs -n "$namespace" "$POD" -c restore-db -f 2>/dev/null || true

kubectl wait -n "$namespace" --for=condition=complete job/bitwarden-restore --timeout=300s 2>/dev/null \
    && echo "" || echo ""

SUCCEEDED=$(kubectl get job bitwarden-restore -n "$namespace" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
if [ "$SUCCEEDED" != "1" ]; then
    FAILED=$(kubectl get job bitwarden-restore -n "$namespace" -o jsonpath='{.status.failed}' 2>/dev/null || echo "?")
    echo "ERREUR : restore DB echoue (succeeded=$SUCCEEDED, failed=$FAILED)" >&2
    exit 1
fi

echo "  Restore DB : OK"
