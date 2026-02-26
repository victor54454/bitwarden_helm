#!/bin/bash
# backup-bitwarden.sh - Backup MSSQL Bitwarden chiffré vers MinIO S3

set -e
export PATH=$PATH:/usr/local/bin

# Installer mc si absent
if ! command -v mc &> /dev/null; then
    echo "=== Installation de mc (MinIO Client) ==="
    curl -sO https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.2025-01-17T23-25-50Z
    chmod +x mc.RELEASE.2025-01-17T23-25-50Z
    sudo mv mc.RELEASE.2025-01-17T23-25-50Z /usr/local/bin/mc
    mc alias set minio http://192.168.10.99:9000 minioadmin minioadmin
fi

NAMESPACE="bitwarden"
MSSQL_POD="bitwarden-self-host-mssql-0"
MINIO_ALIAS="minio"
MINIO_BUCKET="bitwarden-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="vault_${TIMESTAMP}.bak"
GPG_RECIPIENT="Bitwarden Backup"
RETENTION_DAYS=7

# Créer le bucket s'il n'existe pas
mc mb --ignore-existing ${MINIO_ALIAS}/${MINIO_BUCKET}

# 1. Récupérer le mot de passe SA depuis le secret
SA_PASSWORD=$(kubectl get secret custom-secret -n ${NAMESPACE} -o jsonpath='{.data.SA_PASSWORD}' | base64 -d)

echo "=== [1/6] Backup MSSQL ==="
kubectl exec ${MSSQL_POD} -n ${NAMESPACE} -- /opt/mssql-tools/bin/sqlcmd \
  -S localhost -U sa -P "${SA_PASSWORD}" \
  -Q "BACKUP DATABASE [vault] TO DISK = N'/var/opt/mssql/backups/${BACKUP_FILE}' WITH FORMAT, NAME = 'vault-full-backup'"

echo "=== [2/6] Copie depuis le pod ==="
kubectl cp ${NAMESPACE}/${MSSQL_POD}:/var/opt/mssql/backups/${BACKUP_FILE} /tmp/${BACKUP_FILE}

echo "=== [3/6] Backup des clés Data Protection ==="
API_POD=$(kubectl get pod -n ${NAMESPACE} -l app=bitwarden-self-host-api -o jsonpath='{.items[0].metadata.name}')
rm -rf /tmp/dataprotection-keys
kubectl cp ${NAMESPACE}/${API_POD}:/etc/bitwarden/core/aspnet-dataprotection /tmp/dataprotection-keys
tar czf /tmp/dataprotection-keys_${TIMESTAMP}.tar.gz -C /tmp dataprotection-keys
rm -rf /tmp/dataprotection-keys
echo "Clés Data Protection sauvegardées"

echo "=== [4/6] Chiffrement GPG ==="
gpg --encrypt --recipient "${GPG_RECIPIENT}" --trust-model always -o /tmp/${BACKUP_FILE}.gpg /tmp/${BACKUP_FILE}
gpg --encrypt --recipient "${GPG_RECIPIENT}" --trust-model always -o /tmp/dataprotection-keys_${TIMESTAMP}.tar.gz.gpg /tmp/dataprotection-keys_${TIMESTAMP}.tar.gz
rm -f /tmp/${BACKUP_FILE} /tmp/dataprotection-keys_${TIMESTAMP}.tar.gz
echo "Fichiers chiffrés"

echo "=== [5/6] Envoi vers MinIO ==="
mc cp /tmp/${BACKUP_FILE}.gpg ${MINIO_ALIAS}/${MINIO_BUCKET}/${BACKUP_FILE}.gpg
mc cp /tmp/dataprotection-keys_${TIMESTAMP}.tar.gz.gpg ${MINIO_ALIAS}/${MINIO_BUCKET}/dataprotection-keys_${TIMESTAMP}.tar.gz.gpg
echo "Backup envoyé sur MinIO"

echo "=== [6/6] Nettoyage (>${RETENTION_DAYS} jours) ==="
mc find ${MINIO_ALIAS}/${MINIO_BUCKET} --name "vault_*.bak.gpg" --older-than ${RETENTION_DAYS}d --exec "mc rm {}"
mc find ${MINIO_ALIAS}/${MINIO_BUCKET} --name "dataprotection-keys_*.tar.gz.gpg" --older-than ${RETENTION_DAYS}d --exec "mc rm {}"
echo "Backups restants:"
mc ls ${MINIO_ALIAS}/${MINIO_BUCKET}/

# Nettoyage local
rm -f /tmp/${BACKUP_FILE}.gpg /tmp/dataprotection-keys_${TIMESTAMP}.tar.gz.gpg

echo "=== Backup terminé avec succès ==="