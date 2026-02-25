#!/bin/bash
# backup-bitwarden.sh - Backup MSSQL Bitwarden chiffré vers NFS

set -e

NAMESPACE="bitwarden"
MSSQL_POD="bitwarden-self-host-mssql-0"
NFS_SERVER="192.168.10.51"
NFS_PATH="/var/nfs/bitwarden"
NFS_MOUNT="/mnt/nfs-bitwarden"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="vault_${TIMESTAMP}.bak"
GPG_RECIPIENT="Bitwarden Backup"
RETENTION_DAYS=7

# 1. Récupérer le mot de passe SA depuis le secret
SA_PASSWORD=$(kubectl get secret custom-secret -n ${NAMESPACE} -o jsonpath='{.data.SA_PASSWORD}' | base64 -d)

echo "=== [1/5] Backup MSSQL ==="
kubectl exec ${MSSQL_POD} -n ${NAMESPACE} -- /opt/mssql-tools/bin/sqlcmd \
  -S localhost -U sa -P "${SA_PASSWORD}" \
  -Q "BACKUP DATABASE [vault] TO DISK = N'/var/opt/mssql/backups/${BACKUP_FILE}' WITH FORMAT, NAME = 'vault-full-backup'"

echo "=== [2/5] Copie depuis le pod ==="
kubectl cp ${NAMESPACE}/${MSSQL_POD}:/var/opt/mssql/backups/${BACKUP_FILE} /tmp/${BACKUP_FILE}

echo "=== [3/5] Chiffrement GPG ==="
gpg --encrypt --recipient "${GPG_RECIPIENT}" --trust-model always -o /tmp/${BACKUP_FILE}.gpg /tmp/${BACKUP_FILE}
rm -f /tmp/${BACKUP_FILE}
echo "Fichier chiffré: ${BACKUP_FILE}.gpg"

echo "=== [4/5] Envoi vers NFS ==="
sudo mkdir -p ${NFS_MOUNT}
sudo mount -t nfs ${NFS_SERVER}:${NFS_PATH} ${NFS_MOUNT} 2>/dev/null || true
sudo cp /tmp/${BACKUP_FILE}.gpg ${NFS_MOUNT}/${BACKUP_FILE}.gpg
echo "Backup copié: ${NFS_MOUNT}/${BACKUP_FILE}.gpg ($(du -h ${NFS_MOUNT}/${BACKUP_FILE}.gpg | cut -f1))"

echo "=== [5/5] Nettoyage (>${RETENTION_DAYS} jours) ==="
sudo find ${NFS_MOUNT} -name "vault_*.bak.gpg" -mtime +${RETENTION_DAYS} -delete -print
echo "Backups restants:"
ls -lh ${NFS_MOUNT}/vault_*.bak.gpg 2>/dev/null || echo "Aucun"

# Nettoyage local
rm -f /tmp/${BACKUP_FILE}.gpg
sudo umount ${NFS_MOUNT} 2>/dev/null || true

echo "=== Backup terminé avec succès ==="