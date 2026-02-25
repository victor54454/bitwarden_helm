#!/bin/bash
# backup-bitwarden.sh - Backup MSSQL Bitwarden vers NFS

set -e

NAMESPACE="bitwarden"
MSSQL_POD="bitwarden-self-host-mssql-0"
NFS_SERVER="192.168.10.51"
NFS_PATH="/var/nfs/bitwarden"
NFS_MOUNT="/mnt/nfs-bitwarden"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="vault_${TIMESTAMP}.bak"
RETENTION_DAYS=7

# 1. Récupérer le mot de passe SA depuis le secret
SA_PASSWORD=$(kubectl get secret custom-secret -n ${NAMESPACE} -o jsonpath='{.data.SA_PASSWORD}' | base64 -d)

echo "=== [1/4] Backup MSSQL ==="
kubectl exec ${MSSQL_POD} -n ${NAMESPACE} -- /bin/sh -c \
  "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '${SA_PASSWORD}' -C -Q \"BACKUP DATABASE [vault] TO DISK = N'/var/opt/mssql/backups/${BACKUP_FILE}' WITH FORMAT, COMPRESSION, NAME = 'vault-full-backup'\""

echo "=== [2/4] Copie depuis le pod ==="
kubectl cp ${NAMESPACE}/${MSSQL_POD}:/var/opt/mssql/backups/${BACKUP_FILE} /tmp/${BACKUP_FILE}

echo "=== [3/4] Envoi vers NFS ==="
sudo mkdir -p ${NFS_MOUNT}
sudo mount -t nfs ${NFS_SERVER}:${NFS_PATH} ${NFS_MOUNT} 2>/dev/null || true
sudo cp /tmp/${BACKUP_FILE} ${NFS_MOUNT}/${BACKUP_FILE}
echo "Backup copié: ${NFS_MOUNT}/${BACKUP_FILE} ($(du -h ${NFS_MOUNT}/${BACKUP_FILE} | cut -f1))"

echo "=== [4/4] Nettoyage (>${RETENTION_DAYS} jours) ==="
sudo find ${NFS_MOUNT} -name "vault_*.bak" -mtime +${RETENTION_DAYS} -delete -print
echo "Backups restants:"
ls -lh ${NFS_MOUNT}/vault_*.bak 2>/dev/null || echo "Aucun"

# Nettoyage local
rm -f /tmp/${BACKUP_FILE}
sudo umount ${NFS_MOUNT} 2>/dev/null || true

echo "=== Backup terminé avec succès ==="
