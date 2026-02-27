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

---

## 1. Déploiement de l'Ingress NGINX

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

## 2. Ajout du repository Helm Bitwarden

```bash
helm repo add bitwarden https://charts.bitwarden.com/
helm repo update
```

---

## 3. Gestion des StorageClass et des volumes gérer par Rancher 

### Création du provisionner pour alimenter les PVCs
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
```

### Vérification de la StorageClass
```bash
kubectl get storageclass
```

### Supprimer le StorageClass en mode delete 
```bash
kubectl delete storageclass local-path
```

### Pour les supprimer 
```bash
kubectl delete storageclass <NAME>
```

### Pour voir tout les PVCs
```bash 
kubectl get pvc -n bitwarden
```

### Si on utilise minio pour le stockage S3 des backups : 
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
Voici un exemple de docker compose que l'on peut utilise pour minio. 
Mais en plus de cela il nous faut récupérer notre acces key et secret key de minio donc une fois que nous avons lancer minio il suffit de aller dans le menu a gauche dans Acces Keys et en crée une nouvelles.
Comme on peut le voir les fichiers dans backup_bitwarden ce sont eux qui vont nous aider a faire les backups de bitwarden et c'est restore. 
Donc on vas légérement modifier les fichier .sh pour intégré le faites qu'il faut aller sauvegarder les backups sur Minio et aller les chercher sur minio. 

Ou allons-nous stockée donc c'est deux clef acces key et secret key. 
Dans un secret Kubernetes : 
```bash 
kubectl create secret generic bitwarden-minio-credentials \
  --namespace bitwarden \
  --from-literal=accessKey=TON_ACCESS_KEY \
  --from-literal=secretKey=TON_SECRET_KEY
```
A garder c'est très important les clef de minio.

Le volumes dans le qu'elle sera stocké les backups : 
```bash
victor@kube:~/bitwarden_helm$ kgpvc bitwarden 
NAME                                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS        VOLUMEATTRIBUTESCLASS   AGE
bitwarden-self-host-applogs          Bound    pvc-e0941f0c-b664-4216-b9ce-d995c1d64b89   2Gi        RWO            local-path-retain   <unset>                 85m
bitwarden-self-host-attachments      Bound    pvc-f26e8930-3ea3-409c-8c31-d44800a16d75   5Gi        RWO            local-path-retain   <unset>                 85m
bitwarden-self-host-dataprotection   Bound    pvc-97624b3a-1f26-440f-8734-176d09086b72   1Gi        RWO            local-path-retain   <unset>                 85m
bitwarden-self-host-licenses         Bound    pvc-c02f1a04-3c30-47e6-a9cd-987680e804c7   1Gi        RWO            local-path-retain   <unset>                 85m
bitwarden-self-host-mssqlbackups     Bound    pvc-0e7ae396-b4fb-4442-bcfb-c1c2e8018f0a   10Gi       RWO            local-path-retain   <unset>                 85m
bitwarden-self-host-mssqldata        Bound    pvc-6faee74f-e8e6-4004-9c1a-6e81aa1e4101   20Gi       RWO            local-path-retain   <unset>                 85m
bitwarden-self-host-mssqllog         Bound    pvc-9e41ca37-2346-405a-a0d9-87392e5777f5   5Gi        RWO            local-path-retain   <unset>                 85m 
```
Le volumes qui gère tout ça est le ```bitwarden-self-host-mssqlbackups``` il a une place de 10 giga maxi donc il faut faire attention a ne pas le surcharger. C'est pour cela que dans le fichier backup-job.yaml j'ai ajouter la commande ```rm -f /backups/vault.bak.*``` supprime uniquement les fichiers qui ont un suffixe après vault.bak. C'est-à-dire les anciens backups renommés avec un timestamp. 
```bash
/backups/vault.bak                        ← GARDÉ (le nouveau backup frais)
/backups/vault.bak.2026-02-27T08:51:48Z  ← SUPPRIMÉ (l'ancien renommé)
/backups/vault.bak.2026-02-27T08:52:38Z  ← SUPPRIMÉ (encore plus vieux)
```
Donc pour faire une backup il faut lancer le fichier : ```db-backup.sh```
Pour faire une restore de la base de donnée il faut faire un ```db-restore.sh``` il ira ce connecter au minio et prendra la backup la plus recénte puis la re injectera dans notre bitwarden. Bien sur il faut démarer Bitwarden avant de faire le restore. 

---

## 4. Création du namespace Bitwarden

```bash
kubectl create namespace bitwarden
```

---

## 5. Création des secrets Bitwarden

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
|`globalSettings__installation__id` | https://bitwarden.com/fr-fr/host/ |
|`globalSettings__installation__key` | https://bitwarden.com/fr-fr/host/ |
|`globalSettings__mail__smtp__username` | Adresse mail qui envoie les mails de créeation de compte etc ... |
|`globalSettings__mail__smtp__password` | Mot de passe application de l'adresse mail | 
| `SA_PASSWORD` | Mot de passe du compte SQL Server utilisé par Bitwarden |
| `adminSettings__admins` | Adresse(s) email(s) des comptes administrateurs Bitwarden |


### Vérification du secret

```bash
kubectl get secret -n bitwarden
```

---

## 6. Création du secret TLS

Les certificats TLS sont nécessaires pour l'accès HTTPS.
```bash 
openssl req -x509 -nodes -days 365 -newkey ec \
  -pkeyopt ec_paramgen_curve:P-256 \
  -keyout privkey.pem \
  -out fullchain.pem \
  -subj "/CN=192.168.10.139.nip.io"
```
```bash
kubectl create secret tls tls-secret \
  --key privkey.pem \
  --cert fullchain.pem \
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

---

## 8. Suppression de Bitwarden

### Désinstallation Helm

```bash
helm uninstall bitwarden -n bitwarden
```

### Suppression des namespaces

```bash
kubectl delete namespace bitwarden
kubectl delete namespace local-path-storage
kubectl delete namespace ingress-nginx
```

## 9. Déchiffrement des backups : 
### Clef GPG : 
Clef public = chiffrement 
Clef priver = déchiffrement
Il faut donc vérifier que vous avez la bonne clef de chiffrement sur le nodes qui a bitwarden: 
```bash
gpg --list-keys 
```
Il faut aussi vérifier que nous avons la bonne clef de déchiffrement sur nodes qui a bitwarden :
```bash
gpg --list-secret-keys
``` 
#### Exemple de sortie pour clef public : 
```bash 
victor@kube:~/bitwarden_helm/partage_nfs$ gpg --list-key
/home/victor/.gnupg/pubring.kbx
-------------------------------
pub   ed25519 2026-02-25 [SC]
      A0D9F405586AC6EE76E85CDB70169E6628FB20FC
uid           [ultimate] Bitwarden Backup <questmk320@tuta.io>
sub   cv25519 2026-02-25 [E]
```
#### Exemple de sortie pour clef priver: 
```bash 
orktk@centaurus:~/victor/minio$ gpg --list-secret-keys
/home/orktk/.gnupg/pubring.kbx
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
---

```bash
 gpg --decrypt vault_XXXXXXXX.bak.gpg > vault_restored.bak
```


## 10. Les backups et comment en faire et comment les réinjecter : 

### Faire une backup : 
Donc rien de plus simple il faut aller exécuter ce fichier .sh ```bash bitwarden_helm/backup_bitwarden/database-backup/db-backup.sh```. 

### Faire une restoration de la backup dans un nouveauc bitwarden : 
Pour faire une restoration de la backup nous allons re mettre en place le ingress comme ce qui est montrais plus haut dans le readme. 
On fait pareille pour la partie local-path. 
Il faut que l'on re crée le secret :
```bash 
kubectl create secret tls tls-secret \
  --key privkey.pem \
  --cert fullchain.pem \
  -n bitwarden
```
Bien sûr comme dit plus haut il faut avoir bien sauvegarder les clef de Minio. 

La maintenant  nous pouvons lancer le script de full-restore.sh : 
```bash 
bash bitwarden_helm/backup_bitwarden/database-restore/full-restore.sh
```
![alt text](photo/image.png)
Comme on peut le voir sur la photo on peut comprendre ce qui est gérer par nous ou par le script. 