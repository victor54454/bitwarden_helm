#!/bin/bash
# restore-bitwarden.sh - Restaure un backup MSSQL chiffré depuis NFS

set -e

NAMESPACE="bitwarden"
MSSQL_POD="bitwarden-self-host-mssql-0"
NFS_SERVER="192.168.10.51"
NFS_PATH="/var/nfs/bitwarden"
NFS_MOUNT="/mnt/nfs-bitwarden"

# 1. Monter le NFS et lister les backups disponibles
sudo mkdir -p ${NFS_MOUNT}
sudo mount -t nfs ${NFS_SERVER}:${NFS_PATH} ${NFS_MOUNT} 2>/dev/null || true

echo "=== Backups disponibles ==="
ls -lh ${NFS_MOUNT}/vault_*.bak.gpg 2>/dev/null || { echo "Aucun backup trouvé!"; exit 1; }

# 2. Demander quel backup restaurer
echo ""
read -p "Nom du fichier à restaurer (ex: vault_20260225_130835.bak.gpg): " BACKUP_FILE

if [ ! -f "${NFS_MOUNT}/${BACKUP_FILE}" ]; then
    echo "Erreur: ${BACKUP_FILE} introuvable!"
    exit 1
fi

# Déduire le nom du fichier Data Protection correspondant
DP_TIMESTAMP=$(echo ${BACKUP_FILE} | sed 's/vault_\(.*\)\.bak\.gpg/\1/')
DP_FILE="dataprotection-keys_${DP_TIMESTAMP}.tar.gz.gpg"

if [ ! -f "${NFS_MOUNT}/${DP_FILE}" ]; then
    echo "⚠️  Clés Data Protection non trouvées: ${DP_FILE}"
    read -p "Continuer sans les clés ? (oui/non): " SKIP_DP
    if [ "${SKIP_DP}" != "oui" ]; then exit 1; fi
    RESTORE_DP=false
else
    RESTORE_DP=true
fi

echo ""
read -p "⚠️  Cela va REMPLACER la base actuelle. Continuer ? (oui/non): " CONFIRM
if [ "${CONFIRM}" != "oui" ]; then
    echo "Annulé."
    exit 0
fi

# 3. Déchiffrer le backup
echo "=== [1/5] Déchiffrement GPG ==="
gpg --decrypt ${NFS_MOUNT}/${BACKUP_FILE} > /tmp/vault_restored.bak
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
    gpg --decrypt ${NFS_MOUNT}/${DP_FILE} > /tmp/dataprotection-keys.tar.gz
    tar xzf /tmp/dataprotection-keys.tar.gz -C /tmp
    API_POD=$(kubectl get pod -n ${NAMESPACE} -l app=bitwarden-self-host-api -o jsonpath='{.items[0].metadata.name}')
    kubectl cp /tmp/dataprotection-keys/ ${NAMESPACE}/${API_POD}:/etc/bitwarden/core/aspnet-dataprotection
    rm -rf /tmp/dataprotection-keys /tmp/dataprotection-keys.tar.gz
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
sudo umount ${NFS_MOUNT} 2>/dev/null || true

echo "=== Restauration terminée avec succès ==="