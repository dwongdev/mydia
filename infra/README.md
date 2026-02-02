# Metadata Relay Infrastructure

Automated deployment of metadata-relay on OVHcloud VPS with k3s and external-dns.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Cloudflare                               │
│  ┌─────────────────┐                                            │
│  │ relay.mydia.dev │                                            │
│  └────────┬────────┘                                            │
└───────────┼─────────────────────────────────────────────────────┘
            │
            │    DNS managed by
            │    external-dns
            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    OVHcloud VPS ($4.20/mo)                       │
│                    4 vCPU / 8GB RAM / Unlimited BW               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                         k3s                                │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐   │  │
│  │  │   Traefik   │  │ cert-manager │  │  external-dns   │   │  │
│  │  │  (ingress)  │  │ (Let's Enc.) │  │  (Cloudflare)   │   │  │
│  │  └─────────────┘  └──────────────┘  └─────────────────┘   │  │
│  │                                                            │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │              metadata-relay (Phoenix)               │  │  │
│  │  │                                                     │  │  │
│  │  │  • TVDB/TMDB API proxy                             │  │  │
│  │  │  • Device pairing via Redis                        │  │  │
│  │  │  • SQLite database (persistent volume)             │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  │                                                            │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │                     Keel                            │  │  │
│  │  │           (auto-deploy on new images)               │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Cost

| Resource | Monthly Cost |
|----------|-------------|
| OVHcloud VPS-1 (4 vCPU, 8GB, unlimited BW) | $4.20 |
| **Total** | **$4.20/month** |

## Prerequisites

1. **OVHcloud Account** with API credentials
2. **Cloudflare Account** with your domain configured
3. **Local tools**: `kubectl`, `helm`, `ssh`, `uv` (Python)

## Quick Start

### 1. Create OVH API Credentials

Go to https://api.us.ovhcloud.com/createToken/ and create a token with:
- **GET/POST/PUT** on `/vps/*`
- **GET/POST** on `/order/*`
- **GET** on `/me/*`

Copy `ovh.conf.example` to `ovh.conf` and fill in your credentials:

```bash
cp infra/ovh.conf.example infra/ovh.conf
# Edit infra/ovh.conf with your API keys
```

### 2. Create Cloudflare API Token

Go to https://dash.cloudflare.com/profile/api-tokens and create a token with:
- **Zone:DNS:Edit** permission for your domain

### 3. Configure Deployment

```bash
cp infra/config.yaml.example infra/config.yaml
# Edit infra/config.yaml with your settings
```

Generate secrets:
```bash
# Generate relay secret
openssl rand -hex 32
```

### 4. Deploy

```bash
# Full deployment (provisions VPS, installs k3s, deploys everything)
./infra/deploy

# Or step by step
./infra/deploy --phase vps         # Provision/find VPS
./infra/deploy --phase kubeconfig  # Install k3s, get kubeconfig
./infra/deploy --phase kubernetes  # Install Traefik, cert-manager, external-dns, ArgoCD
./infra/deploy --phase app         # Deploy metadata-relay
./infra/deploy --phase verify      # Check health
```

### 5. Verify

```bash
# Check status
./infra/deploy --status

# Check health endpoint
curl https://relay.mydia.dev/health
```

## Commands

```bash
# Full deployment
./infra/deploy

# Dry run (see what would happen)
./infra/deploy --dry-run

# Run specific phase
./infra/deploy --phase kubernetes

# Skip phases
./infra/deploy --skip vps --skip kubeconfig

# Check status
./infra/deploy --status
```

## Directory Structure

```
infra/
├── deploy                 # Main deployment script (Python/uv)
├── config.yaml.example    # Configuration template
├── ovh.conf.example       # OVH API credentials template
├── README.md              # This file
└── kubernetes/
    ├── cert-manager/
    │   ├── values.yaml         # Helm values
    │   └── cluster-issuer.yaml # Let's Encrypt issuers
    └── apps/
        └── metadata-relay/
            ├── namespace.yaml
            ├── deployment.yaml
            ├── service.yaml
            ├── ingress.yaml
            ├── configmap.yaml
            ├── pvc.yaml
            └── secret.yaml.example
```

## How It Works

1. **VPS Phase**: Uses OVH API to find existing VPS or order a new one
2. **Kubeconfig Phase**: Installs k3s via SSH, fetches kubeconfig
3. **Kubernetes Phase**: Installs via Helm:
   - Traefik (ingress controller)
   - cert-manager (Let's Encrypt TLS)
   - external-dns (automatic Cloudflare DNS)
   - Keel (auto-deploy on new images)
4. **App Phase**: Deploys metadata-relay manifests
5. **Verify Phase**: Checks health endpoint

## Auto-Deploy

Keel watches for new container images and automatically updates deployments.
When a new `metadata-relay` image is pushed to GHCR, Keel triggers a rolling update.

The deployment is annotated with:
```yaml
keel.sh/policy: major      # Update on any new semver version
keel.sh/trigger: poll      # Poll registry for new images
keel.sh/pollSchedule: "@every 5m"
```

## DNS Management

DNS is managed automatically by **external-dns**:
- When an Ingress is created with a hostname, external-dns creates the DNS record in Cloudflare
- When an Ingress is deleted, the DNS record is removed
- No manual DNS configuration needed

## Troubleshooting

### Can't connect to VPS via SSH
```bash
# Check VPS status
./infra/deploy --status

# Manually SSH
ssh root@<vps-ip>
```

### kubectl not connecting
```bash
# Re-fetch kubeconfig
./infra/deploy --phase kubeconfig
```

### Pods not starting
```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Certificate not issued
```bash
kubectl get certificates -A
kubectl describe certificate metadata-relay-tls -n metadata-relay
kubectl logs -n cert-manager -l app=cert-manager
```

### DNS not updating
```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns
```

## Keel Dashboard

Keel provides a simple web UI for monitoring deployments:
```bash
# Port-forward to access Keel UI
kubectl port-forward -n kube-system svc/keel 9300:9300

# Access at http://localhost:9300
```
