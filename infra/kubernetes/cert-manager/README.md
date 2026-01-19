# cert-manager Configuration

This directory contains Helm values and ClusterIssuer manifests for cert-manager, which manages Let's Encrypt TLS certificates in the k3s cluster.

## Prerequisites

- k3s cluster running with Traefik ingress controller (default)
- kubectl configured to access the cluster
- Helm 3 installed

## Installation

### 1. Install cert-manager using Helm

```bash
# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager with our custom values
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.3 \
  --values values.yaml
```

### 2. Configure ClusterIssuers

**IMPORTANT**: Before applying the ClusterIssuer manifests, edit `cluster-issuer.yaml` and replace `YOUR_EMAIL_HERE` with your actual email address.

```bash
# Edit the file to add your email
vim cluster-issuer.yaml

# Apply the ClusterIssuers
kubectl apply -f cluster-issuer.yaml
```

### 3. Verify installation

```bash
# Check cert-manager pods are running
kubectl get pods -n cert-manager

# Check ClusterIssuers are ready
kubectl get clusterissuer
```

Expected output:
```
NAME                   READY   AGE
letsencrypt-prod       True    1m
letsencrypt-staging    True    1m
```

## Usage

### Testing with Staging

When setting up new ingresses, use `letsencrypt-staging` first to avoid hitting production rate limits:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-staging"
spec:
  tls:
  - hosts:
    - example.com
    secretName: example-tls-staging
  rules:
  - host: example.com
    # ... rest of ingress config
```

### Production Certificates

Once verified, switch to production:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - example.com
    secretName: example-tls-prod
```

## Resource Configuration

The `values.yaml` is optimized for a Hetzner CX21 server (2 vCPU, 2GB RAM):

- cert-manager controller: 10m CPU / 32Mi RAM (request), 100m CPU / 128Mi RAM (limit)
- webhook: 10m CPU / 32Mi RAM (request), 100m CPU / 128Mi RAM (limit)
- cainjector: 10m CPU / 32Mi RAM (request), 100m CPU / 128Mi RAM (limit)

Total resource request: ~30m CPU, ~96Mi RAM
Total resource limits: ~300m CPU, ~384Mi RAM

## Troubleshooting

### Check certificate status
```bash
kubectl get certificate -n <namespace>
kubectl describe certificate <cert-name> -n <namespace>
```

### Check certificate requests
```bash
kubectl get certificaterequest -n <namespace>
kubectl describe certificaterequest <req-name> -n <namespace>
```

### Check cert-manager logs
```bash
kubectl logs -n cert-manager deployment/cert-manager
```

### Common issues

1. **Certificate not issuing**: Check that your domain's DNS points to the server and port 80 is accessible
2. **HTTP-01 challenge failing**: Verify Traefik is routing traffic correctly
3. **Rate limits hit**: Use staging issuer for testing

## Rate Limits

- **Production**: 50 certificates per registered domain per week
- **Staging**: Much higher limits, use for testing

## References

- [cert-manager documentation](https://cert-manager.io/docs/)
- [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/)
- [HTTP-01 challenge](https://letsencrypt.org/docs/challenge-types/#http-01-challenge)
