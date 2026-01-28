# CrowdStrike Falcon Platform Deployment

Deploy CrowdStrike Falcon sensor, Kubernetes Admission Controller (KAC), and Image Analyzer to Kubernetes clusters and ECS Fargate tasks.

Two deployment methods are provided:
- **Shell script** — uses the unified `falcon-platform` umbrella Helm chart
- **Terraform** — manages Helm releases and ECR image lifecycle as infrastructure-as-code

## What Gets Deployed

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Falcon Sensor | `falcon-system` | Protects cluster nodes (or Fargate pods via sidecar) |
| Falcon KAC | `falcon-kac` | Validates containers at admission time |
| Falcon Image Analyzer | `falcon-image-analyzer` | Scans container images for vulnerabilities |

## Prerequisites

### Tools (auto-installed by the shell script if missing)

- `kubectl` — configured with access to your cluster
- `helm` (v3)
- `curl`
- `jq`

### CrowdStrike API Credentials

1. Log in to the Falcon console
2. Go to **Support and resources > Resources and tools > API clients and keys**
3. Click **Create API client**
4. Assign scopes: **Falcon Images Download: Read**, **Sensor Download: Read**
5. Save the Client ID and Client Secret

---

## Method 1: Shell Script (`falcon-platform-install.sh`)

The script deploys all three components using the single `crowdstrike/falcon-platform` umbrella chart with `createComponentNamespaces: true`.

### Quick Start

```bash
chmod +x falcon-platform-install.sh

./falcon-platform-install.sh --cluster-name my-cluster
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--cluster-name NAME` | *(required)* | Name of your Kubernetes cluster |
| `--mode node\|fargate` | `node` | `node` = DaemonSet sensor, `fargate` = sidecar sensor |
| `--cloud REGION` | `us-1` | Falcon cloud region (`us-1`, `us-2`, `eu-1`, `us-gov-1`) |
| `--backend bpf\|kernel` | `bpf` | Sensor backend (node mode only) |
| `--chart-version VER` | latest | Pin a specific Helm chart version |
| `--tags TAGS` | none | Comma-separated sensor grouping tags |
| `-h, --help` | | Show help |

### Credentials

Set environment variables **or** the script will prompt you:

```bash
export FALCON_CLIENT_ID="your-client-id"
export FALCON_CLIENT_SECRET="your-client-secret"
```

### Examples

```bash
# Node mode (default)
./falcon-platform-install.sh --cluster-name prod-cluster

# Fargate mode
./falcon-platform-install.sh --cluster-name prod-cluster --mode fargate

# EU region with pinned chart version
./falcon-platform-install.sh \
  --cluster-name prod-cluster \
  --cloud eu-1 \
  --chart-version 1.20.0

# CI/CD (non-interactive)
export FALCON_CLIENT_ID="abc123"
export FALCON_CLIENT_SECRET="secret456"
./falcon-platform-install.sh \
  --cluster-name prod-cluster \
  --cloud us-2 \
  --tags "env:prod,team:platform"
```

---

## Method 2: Terraform

The Terraform modules manage ECR repositories, image pulls, and Helm releases for EKS and ECS Fargate deployments.

### Directory Structure

```
terraform-falcon-sensor/
  main.tf                  # Root module (ECR + image push)
  variables.tf             # Root variables
  terraform.tfvars.example # Example variable values
  modules/
    eks/                   # Deploys sensor, KAC, and IAR via Helm
    ecs-fargate/           # Patches ECS task definitions with container sensor
  examples/
    eks-complete/          # Full EKS deployment example
    ecs-complete/          # Full ECS Fargate deployment example
```

### EKS Quick Start

```bash
cd terraform-falcon-sensor
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

The EKS module deploys three Helm releases (falcon-sensor, falcon-kac, falcon-image-analyzer) into separate namespaces with pod-security admission labels.

### ECS Fargate Quick Start

The ECS module patches existing task definitions by injecting the Falcon container sensor sidecar. See `examples/ecs-complete/` for a full working example.

### Required Variables

| Variable | Description |
|----------|-------------|
| `falcon_client_id` | CrowdStrike API Client ID |
| `falcon_client_secret` | CrowdStrike API Client Secret |
| `falcon_cid` | CrowdStrike Customer ID with checksum |
| `falcon_cloud` | Cloud region (default: `us-1`) |
| `eks_cluster_name` | EKS cluster name (for EKS deployments) |

---

## Security

- Shell script: secrets are written to a temp file with `chmod 600`, never passed as CLI arguments, and deleted on exit via `trap`
- Shell script uses `set -euo pipefail` to stop on any error
- Terraform: sensitive variables are marked `sensitive = true` and won't appear in plan output
- All namespaces get pod-security admission labels (`privileged` level) as required by the Falcon sensor

## Troubleshooting

### "kubectl cannot reach a cluster"
Your kubeconfig isn't set up. Run `kubectl cluster-info` to debug.

### "Helm v3 is required"
Remove Helm v2 and let the script install v3, or install it yourself.

### Pods stuck in Pending/CrashLoopBackOff
```bash
kubectl describe pod -n falcon-system <pod-name>
kubectl logs -n falcon-system <pod-name>
```

### Wrong cloud region
If authentication fails, check your `--cloud` value matches your Falcon tenant (visible in your console URL).

### Need to start over
Run the script again — it uses `helm upgrade --install` so it updates in place.

## Verifying Deployments

```bash
kubectl get pods -n falcon-system
kubectl get pods -n falcon-kac
kubectl get pods -n falcon-image-analyzer
```

## Links

- [Falcon Helm Charts](https://github.com/CrowdStrike/falcon-helm)
- [CrowdStrike Container Security](https://github.com/CrowdStrike/Container-Security)
- [CrowdStrike Documentation](https://falcon.crowdstrike.com/documentation)
# Deploy-CS-Sensor-on-AWS-Fargate
