# Déploiement de Bitwarden Self-Hosted sur Kubernetes

Ce document décrit le déploiement de Bitwarden self-hosted sur un cluster Kubernetes à l'aide de Helm, avec :

- **Ingress NGINX** (HTTP 8080 / HTTPS 4444)
- **Stockage persistant** via `local-path-provisioner`
- **Secrets Kubernetes** pour la configuration sensible

---

## Prérequis

- Cluster Kubernetes fonctionnel
- `kubectl` configuré
- `helm` installé
- Accès administrateur au cluster
- Certificats TLS (`tls.crt` et `tls.key`)
- Fichier `values.preprod.yaml` prêt pour Bitwarden
- Dossier `tmp/` contenant les clés de chiffrement et de déchiffrement

---

## 1. Déploiement de l'Ingress NGINX

### Ajout du repo Helm de Bitwarden

```bash
helm repo add bitwarden https://charts.bitwarden.com/
```
```bash
helm repo update
```
```bash
kubectl create namespace bitwarden
```
```bash
helm search repo bitwarden
```

La commande `helm search repo` confirme l'ajout des deux repos.

Deux cas de figure :
- **Première installation** : suivre l'intégralité de la procédure ci-dessous (secrets, ingress, etc.).
- **Restauration** : créer l'ingress et les PVC s'ils n'existent pas, puis lancer directement le script de restauration (section 9).

### Création du namespace

```bash
kubectl create namespace ingress-nginx
```

### Déploiement de l'Ingress Controller

```bash
kubectl apply -f ~/bitwarden_helm/ingress_nginx/ingress-nginx.yaml
```

### Vérification du démarrage

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=60s
```

---

## 2. StorageClass et volumes gérés par Rancher

### Création du provisionner pour alimenter les PVCs

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
```

### Vérification de la StorageClass

```bash
kubectl get storageclass
```

### Suppression de la StorageClass en mode delete

```bash
kubectl delete storageclass local-path
```

### Suppression d'une StorageClass quelconque

```bash
kubectl delete storageclass <NAME>
```

---

## 3. Stockage S3

### Option MinIO (tests)

```yaml
services:
  minio:
    image: minio/minio:RELEASE.2025-01-20T14-49-07Z
    container_name: minio
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"   # API S3
      - "127.0.0.1:9001:9001"   # Console web
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - minio-data:/data
    restart: unless-stopped

volumes:
  minio-data:
```

Exemple de docker-compose utilisable pour MinIO.

Une fois MinIO lancé, générer une access key et une secret key depuis le menu latéral, section **Access Keys**.

Les fichiers du dossier `backup_bitwarden` gèrent les backups et leur restauration. Ils doivent être adaptés pour pointer vers MinIO.

### Stockage des clés dans un secret Kubernetes

```bash
kubectl create secret generic bitwarden-minio-credentials \
  --namespace bitwarden \
  --from-literal=accessKey=<ACCESS_KEY> \
  --from-literal=secretKey=<SECRET_KEY>
```

⚠️ Les clés MinIO doivent être conservées.

### Option OVH

Le secret Kubernetes doit être adapté pour être reconnu par le système lors de son appel :

```bash
kubectl create secret generic bitwarden-s3-credentials -n bitwarden \
  --from-literal=accessKey="<ACCESS_KEY_OVH>" \
  --from-literal=secretKey="<SECRET_KEY_OVH>"
```

Le projet a été conçu pour fonctionner avec un stockage S3 OVH — c'est la configuration utilisée pour les tests. Pour basculer sur MinIO, il suffit de modifier les fichiers du dossier `backup_bitwarden`.

---

## 4. Création des secrets Bitwarden

Les informations sensibles sont stockées dans un secret Kubernetes.

```bash
kubectl create secret generic custom-secret -n bitwarden \
  --from-literal=globalSettings__installation__id="" \
  --from-literal=globalSettings__installation__key="" \
  --from-literal=globalSettings__mail__smtp__username="" \
  --from-literal=globalSettings__mail__smtp__password="" \
  --from-literal=globalSettings__yubico__clientId="dummy" \
  --from-literal=globalSettings__yubico__key="dummy" \
  --from-literal=globalSettings__hibpApiKey="dummy" \
  --from-literal=SA_PASSWORD="" \
  --from-literal=adminSettings__admins=""
```

### Description des variables importantes

| Variable | Description |
|---|---|
| `globalSettings__installation__id` | https://bitwarden.com/fr-fr/host/ |
| `globalSettings__installation__key` | https://bitwarden.com/fr-fr/host/ |
| `globalSettings__mail__smtp__username` | Adresse mail émettrice des mails de création de compte |
| `globalSettings__mail__smtp__password` | Mot de passe application de l'adresse mail |
| `SA_PASSWORD` | Mot de passe du compte SQL Server utilisé par Bitwarden |
| `adminSettings__admins` | Adresse(s) email(s) des comptes administrateurs Bitwarden |

### Secret du webhook Discord (notifications de fin de backup)

```bash
kubectl create secret generic bitwarden-discord-webhook -n bitwarden \
  --from-literal=url="https://discord.com/api/webhooks/<ID>/<TOKEN>"
```

### Vérification des secrets

```bash
kubectl get secret -n bitwarden
```

---

## 5. Création du secret TLS

Les certificats TLS sont nécessaires pour l'accès HTTPS.

```bash
openssl req -x509 -nodes -days 365 -newkey ec \
  -pkeyopt ec_paramgen_curve:P-256 \
  -keyout privkey.pem \
  -out fullchain.pem \
  -subj "/CN=<IP>.nip.io"
```
```bash
kubectl create secret tls tls-secret \
  --key privkey.pem \
  --cert fullchain.pem \
  -n bitwarden
```

---

## 6. Création du secret de chiffrement des backups

```bash
kubectl create secret generic bitwarden-gpg-public-key \
  --from-file=public.asc=/tmp/public.asc \
  -n bitwarden
```

---

## 7. Déploiement de Bitwarden avec Helm

```bash
helm install bitwarden ./bitwarden_helm/self-host \
  --namespace bitwarden \
  --values bitwarden_helm/self-host/values.preprod.yaml \
  --timeout 10m
```

⚠️ Ne pas oublier de lancer le CronJob : `backup_bitwarden/database-backup/backup-cronjob.yaml`

---

## 8. Chiffrement et déchiffrement des backups

### Clés GPG

Les scripts de backup et de restauration s'utilisent avec `kubectl`. Les clés publique et privée sont toutes deux nécessaires : la publique pour chiffrer, la privée pour déchiffrer. Elles peuvent être placées dans le dossier `tmp/`.

Vérifier la présence de la clé de chiffrement sur le node hébergeant Bitwarden :

```bash
gpg --list-keys
```

Vérifier la présence de la clé de déchiffrement sur ce même node :

```bash
gpg --list-secret-keys
```

#### Exemple de sortie — clé publique

```bash
user@host:~/bitwarden_helm/partage_nfs$ gpg --list-key
/home/user/.gnupg/pubring.kbx
-------------------------------
pub   ed25519 2026-02-25 [SC]
      A0D9F405586AC6EE76E85CDB70169E6628FB20FC
uid           [ultimate] Bitwarden Backup <exemple@exemple.fr>
sub   cv25519 2026-02-25 [E]
```

#### Exemple de sortie — clé privée

```bash
user@host:~/minio$ gpg --list-secret-keys
/home/user/.gnupg/pubring.kbx
------------------------------
sec   rsa4096 2025-10-01 [SC]
      FE9E26892B7CCA1A58E934871DC9CFA13D696195
uid          [  ultime ] HelmDeployment
ssb   rsa4096 2025-10-01 [E]

sec   ed25519 2026-02-26 [SC]
      CFB496BA6800650BE44D53FE6D5A26A37A68EA1B
uid          [  ultime ] Bitwarden Backup
ssb   cv25519 2026-02-26 [E]
```

### Déchiffrer un backup

```bash
gpg --decrypt vault_XXXXXXXX.bak.gpg > vault_restored.bak
```

Le chiffrement est utilisé pour les backups de Bitwarden. Une paire de clés protégée par passphrase doit être générée sur le modèle des exemples ci-dessus. `kubectl` est configuré sur chaque serveur concerné.

---

## 9. Backup et restauration

### Créer un backup

```bash
bash bitwarden_helm/backup_bitwarden/database-backup/db-backup.sh
```

### Restaurer un backup dans une nouvelle instance Bitwarden

![Répartition des étapes manuelles et automatisées](photo/image.png)

Le tableau ci-dessus détaille la répartition entre les étapes manuelles et celles prises en charge par le script.

#### Étape 1 — Simuler le sinistre (désinstaller Bitwarden)

```bash
helm uninstall bitwarden -n bitwarden
```

Vérifier que les ressources sont supprimées :

```bash
kubectl get pods -n bitwarden
```

#### Étape 2 — Lancer le full-restore

```bash
bash backup_bitwarden/database-restore/full-restore.sh
```

Le script demande les identifiants MinIO et l'emplacement de la clé privée correspondant à la clé publique ayant chiffré le backup. Il marque ensuite une pause pour permettre de lancer `helm install` manuellement depuis un autre terminal. Une fois `helm install` terminé, revenir au terminal initial et valider avec Entrée.

#### Étape 3 — Vérifier

Se connecter à l'interface Bitwarden et vérifier la présence des comptes restaurés.

---

## 10. Commandes AWS S3

### Lister les backups présents sur le S3

```bash
aws s3 ls "s3://<BUCKET>/backup_bitwarden/" --endpoint-url "https://s3.rbx.io.cloud.ovh.net" --recursive --human-readable --summarize
```

Prérequis : la configuration AWS CLI doit être renseignée.

![Configuration AWS CLI](photo/image2.png)