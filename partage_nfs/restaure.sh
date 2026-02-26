#!/bin/bash
# restore-bitwarden.sh - Restaure un backup MSSQL chiffré depuis MinIO S3

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

# 1. Lister les backups disponibles
echo "=== Backups disponibles ==="
mc ls ${MINIO_ALIAS}/${MINIO_BUCKET}/ | grep "vault_.*\.bak\.gpg"

# 2. Demander quel backup restaurer
echo ""
read -p "Nom du fichier à restaurer (ex: vault_20260225_130835.bak.gpg): " BACKUP_FILE

# Vérifier que le fichier existe
mc stat ${MINIO_ALIAS}/${MINIO_BUCKET}/${BACKUP_FILE} > /dev/null 2>&1 || { echo "Erreur: ${BACKUP_FILE} introuvable!"; exit 1; }

# Déduire le nom du fichier Data Protection correspondant
DP_TIMESTAMP=$(echo ${BACKUP_FILE} | sed 's/vault_\(.*\)\.bak\.gpg/\1/')
DP_FILE="dataprotection-keys_${DP_TIMESTAMP}.tar.gz.gpg"

if mc stat ${MINIO_ALIAS}/${MINIO_BUCKET}/${DP_FILE} > /dev/null 2>&1; then
    RESTORE_DP=true
else
    echo "⚠️  Clés Data Protection non trouvées: ${DP_FILE}"
    read -p "Continuer sans les clés ? (oui/non): " SKIP_DP
    if [ "${SKIP_DP}" != "oui" ]; then exit 1; fi
    RESTORE_DP=false
fi

echo ""
read -p "⚠️  Cela va REMPLACER la base actuelle. Continuer ? (oui/non): " CONFIRM
if [ "${CONFIRM}" != "oui" ]; then
    echo "Annulé."
    exit 0
fi

# 3. Télécharger et déchiffrer le backup
echo "=== [1/5] Téléchargement et déchiffrement ==="
mc cp ${MINIO_ALIAS}/${MINIO_BUCKET}/${BACKUP_FILE} /tmp/${BACKUP_FILE}
gpg --decrypt /tmp/${BACKUP_FILE} > /tmp/vault_restored.bak
rm -f /tmp/${BACKUP_FILE}
echo "Déchiffré: /tmp/vault_restored.bak ($(du -h /tmp/vault_restored.bak | cut -f1))"

# 4. Copier dans le pod MSSQL
echo "=== [2/5] Copie vers le pod MSSQL ==="
kubectl cp /tmp/vault_restored.bak ${NAMESPACE}/${MSSQL_POD}:/var/opt/mssql/backups/vault_restored.bak

# 5. Restaurer la base
echo "=== [3/5] Restauration MSSQL ==="
SA_PASSWORD=$(kubectl get secret custom-secret -n ${NAMESPACE} -o jsonpath='{.data.SA_PASSWORD}' | base64 -d)

kubectl exec ${MSSQL_POD} -n ${NAMESPACE} -- /opt/mssql-tools/bin/sqlcmd \
  -S localhost -U sa -P "${SA_PASSWORD}" \
  -Q "USE [master]; ALTER DATABASE [vault] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE [vault] FROM DISK = N'/var/opt/mssql/backups/vault_restored.bak' WITH REPLACE; ALTER DATABASE [vault] SET MULTI_USER;"

# 6. Restaurer les clés Data Protection
echo "=== [4/5] Restauration des clés Data Protection ==="
if [ "${RESTORE_DP}" = true ]; then
    mc cp ${MINIO_ALIAS}/${MINIO_BUCKET}/${DP_FILE} /tmp/${DP_FILE}
    gpg --decrypt /tmp/${DP_FILE} > /tmp/dataprotection-keys.tar.gz
    tar xzf /tmp/dataprotection-keys.tar.gz -C /tmp
    API_POD=$(kubectl get pod -n ${NAMESPACE} -l app=bitwarden-self-host-api -o jsonpath='{.items[0].metadata.name}')
    kubectl cp /tmp/dataprotection-keys/ ${NAMESPACE}/${API_POD}:/etc/bitwarden/core/aspnet-dataprotection
    rm -rf /tmp/dataprotection-keys /tmp/dataprotection-keys.tar.gz /tmp/${DP_FILE}
    echo "Clés Data Protection restaurées"
else
    echo "Skipped (clés non disponibles)"
fi

# 7. Redémarrer les pods
echo "=== [5/5] Redémarrage des pods ==="
kubectl rollout restart deployment -n ${NAMESPACE}

# Nettoyage
rm -f /tmp/vault_restored.bak
kubectl exec ${MSSQL_POD} -n ${NAMESPACE} -- rm -f /var/opt/mssql/backups/vault_restored.bak

echo "=== Restauration terminée avec succès ==="