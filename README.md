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

## 3. Mise en place du stockage persistant

Bitwarden nécessite un stockage persistant pour les données applicatives.

### Déploiement du provisioner local-path

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
```

### Vérification des pods

```bash
kubectl get pods -n local-path-storage
```

### Vérification de la StorageClass

```bash
kubectl get storageclass
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
helm upgrade bitwarden bitwarden/self-host \
  --install \
  --namespace bitwarden \
  --values self-host/values.preprod.yaml \
  --debug \
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