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
Il faut donc vérifer que vous avez la bonne clef de déchiffrement : 
```bash
gpg --list-key 
```
#### Exemple de sortie : 
```bash 
victor@kube:~/bitwarden_helm/partage_nfs$ gpg --list-key
/home/victor/.gnupg/pubring.kbx
-------------------------------
pub   ed25519 2026-02-25 [SC]
      A0D9F405586AC6EE76E85CDB70169E6628FB20FC
uid           [ultimate] Bitwarden Backup <questmk320@tuta.io>
sub   cv25519 2026-02-25 [E]
```
---

Le script dans ```bitwarden_helm/partage_nf/backup.sh``` nous permet de faire 
des backup et de la partager dans un dossier nfs partagé sur un autre serveur. On peut bien sûr changer le script pour faire le partage avec du S3.
Donc, si vous avez la clef privée sur vous, vous pourrez déchiffrer le backup et avec la clef publique le chiffrer. C'est pour cela que la clé publique doit être sur le serveur pour qu'ils puissent crypter le backup. La clef privée doit être gardée dans un lieu sûr qui ne risque pas d'être compromis. 

```bash
 gpg --decrypt vault_XXXXXXXX.bak.gpg > vault_restored.bak
```