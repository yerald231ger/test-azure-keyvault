# Azure Workload Identity with Kubernetes

This repository demonstrates how to use **Azure Workload Identity** to securely access Azure Key Vault from applications running in Azure Kubernetes Service (AKS) without storing credentials.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Components Explained](#components-explained)
- [How Workload Identity Works](#how-workload-identity-works)
- [Setup Instructions](#setup-instructions)
- [Configuration Details](#configuration-details)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)

---

## Overview

**Azure Workload Identity** is a modern, secure way to authenticate applications running in Kubernetes to Azure services. It eliminates the need to store credentials (passwords, keys, connection strings) in your application code or Kubernetes secrets.

### Key Benefits

- **No credentials in code or secrets** - Uses federated identity credentials
- **Automatic token management** - Kubernetes handles token rotation
- **Least privilege access** - Fine-grained RBAC permissions
- **Native Kubernetes integration** - Uses standard ServiceAccounts

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Azure Cloud                           │
│                                                              │
│  ┌──────────────────┐         ┌───────────────────┐          │
│  │   Key Vault      │◄────────│ Managed Identity  │          │
│  │   (Secrets)      │  RBAC   │   (mi-appointment)│          │
│  └──────────────────┘         └────────┬──────────┘          │
│                                         │                    │
│                                         │ Federated          │
│                                         │ Credential         │
│  ┌──────────────────────────────────────┼─────────────────┐  │
│  │           AKS Cluster                │                 │  │
│  │                                      │                 │  │
│  │  ┌─────────────────┐      ┌──────────▼─────────┐       │  │
│  │  │  Pod with App   │─────►│  Service Account   │       │  │
│  │  │  (keyvault-api) │      │  (svc-appointment) │       │  │
│  │  └─────────────────┘      └────────────────────┘       │  │
│  │         │                                              │  │
│  │         │ Uses                                         │  │
│  │         │ serviceAccountName                           │  │
│  │         ▼                                              │  │
│  │  OIDC Token Exchange ──► Azure AD ──► Access Token     │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

**Flow:**
1. Pod uses Kubernetes ServiceAccount
2. AKS injects OIDC token into pod
3. Azure SDK exchanges OIDC token for Azure AD token
4. Azure AD validates federated credential
5. App uses Azure AD token to access Key Vault

### Detailed Sequence Diagram

For a detailed step-by-step flow of how the `GET /` endpoint retrieves secrets from Key Vault using Workload Identity, see the PlantUML sequence diagram:

**File:** [workload-identity-flow.puml](workload-identity-flow.puml)

The diagram shows:
- **Application Startup**: Configuration loading, token exchange, and initial Key Vault secret retrieval
- **HTTP Request Flow**: How the endpoint accesses cached configuration
- **Token Refresh**: Automatic token rotation in the background

To view the diagram:
- Use [PlantUML Online Editor](https://www.plantuml.com/plantuml/uml/)
- VS Code with PlantUML extension
- IntelliJ IDEA with PlantUML plugin

Or generate PNG/SVG:
```bash
# Install PlantUML (requires Java)
brew install plantuml

# Generate diagram
plantuml workload-identity-flow.puml
```

---

## Components Explained

### 1. AKS Cluster with OIDC Issuer

**Configuration:**
```bash
az aks create \
    --enable-oidc-issuer \
    --enable-workload-identity
```

**What it does:**
- **OIDC Issuer**: Creates a public OIDC endpoint that issues JWT tokens for ServiceAccounts
- **Workload Identity**: Enables the mutating admission webhook that injects tokens into pods

**Why it's needed:**
- Kubernetes needs to issue verifiable identity tokens
- Azure AD needs to trust tokens from your AKS cluster

**Configuration check:**
```bash
# Get OIDC Issuer URL
az aks show -g rg-appointment -n aks-appointment \
  --query "oidcIssuerProfile.issuerUrl" -o tsv
# Output: https://eastus.oic.prod-aks.azure.com/<guid>/
```

---

### 2. Azure Managed Identity

**Configuration:**
```bash
az identity create \
    --name mi-appointment \
    --resource-group rg-appointment
```

**What it does:**
- Creates an identity in Azure AD
- Has a `clientId` (used by apps) and `principalId` (used for RBAC)
- Acts as the "identity" your pod assumes in Azure

**Why it's needed:**
- Azure services require an Azure AD identity for authentication
- This identity gets permissions to access Azure resources

**Key properties:**
```bash
# Client ID - used in ServiceAccount annotation
IDENTITY_CLIENT_ID=$(az identity show ... --query clientId -o tsv)

# Principal ID - used for role assignments
IDENTITY_PRINCIPAL_ID=$(az identity show ... --query principalId -o tsv)
```

---

### 3. Federated Identity Credential

**Configuration:**
```bash
az identity federated-credential create \
    --name "aks-federated-credential" \
    --identity-name mi-appointment \
    --issuer <OIDC_ISSUER_URL> \
    --subject "system:serviceaccount:nsp-appointment:svc-appointment"
```

**What it does:**
- Establishes trust between Kubernetes ServiceAccount and Azure Managed Identity
- Maps Kubernetes identity → Azure identity

**Parameters explained:**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `--issuer` | `https://eastus.oic.prod-aks.azure.com/<guid>/` | AKS OIDC endpoint - Azure AD will trust tokens from this issuer |
| `--subject` | `system:serviceaccount:nsp-appointment:svc-appointment` | Kubernetes ServiceAccount identity - only THIS ServiceAccount can use this identity |
| `--audience` | `api://AzureADTokenExchange` | Token exchange audience (automatically set) |

**Why it's needed:**
- Without this, Azure AD won't trust tokens from Kubernetes
- This is the "bridge" between Kubernetes and Azure AD

---

### 4. Kubernetes Namespace

**Configuration:**
```bash
kubectl create namespace nsp-appointment
```

**What it does:**
- Logical isolation for Kubernetes resources
- Part of the ServiceAccount identity (`system:serviceaccount:NAMESPACE:SERVICEACCOUNT`)

**Why it's needed:**
- Organizes resources
- The namespace is part of the federated credential subject

---

### 5. Kubernetes ServiceAccount

**Configuration:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: svc-appointment
  namespace: nsp-appointment
  annotations:
    azure.workload.identity/client-id: <MANAGED_IDENTITY_CLIENT_ID>
```

**What it does:**
- Standard Kubernetes identity mechanism
- The annotation links it to Azure Managed Identity

**Annotation explained:**

| Annotation | Value | Purpose |
|------------|-------|---------|
| `azure.workload.identity/client-id` | Client ID of Managed Identity | Tells the workload identity webhook which Azure identity to use |

**Why it's needed:**
- Pods use ServiceAccounts for identity
- The annotation is how Workload Identity knows which Azure identity to provide

**Useful commands:**
```bash
# List ServiceAccounts in namespace
kubectl get sa -n nsp-appointment

# View full details
kubectl get sa svc-appointment -n nsp-appointment -o yaml

# Get the client ID annotation
kubectl get sa svc-appointment -n nsp-appointment \
  -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'

# List all ServiceAccounts with workload identity across cluster
kubectl get sa -A -o json | \
  jq -r '.items[] | select(.metadata.annotations["azure.workload.identity/client-id"]) |
  "\(.metadata.namespace)/\(.metadata.name) -> \(.metadata.annotations["azure.workload.identity/client-id"])"'
```

---

### 6. Pod/Deployment Configuration

**Configuration:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keyvault-api
  namespace: nsp-appointment
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"  # ← Required
    spec:
      serviceAccountName: svc-appointment    # ← Required
      containers:
      - name: api
        image: your-image:tag
        env:
        - name: AZURE_CLIENT_ID
          value: <MANAGED_IDENTITY_CLIENT_ID>
        - name: KEY_VAULT_URL
          value: https://kv-appointment.vault.azure.net/
```

**Configuration explained:**

| Field | Value | Purpose |
|-------|-------|---------|
| `labels.azure.workload.identity/use` | `"true"` | Tells webhook to inject identity into this pod |
| `serviceAccountName` | `svc-appointment` | Links pod to ServiceAccount with Azure identity |
| `AZURE_CLIENT_ID` | Managed Identity Client ID | (Optional) Some SDKs need this explicitly |
| `KEY_VAULT_URL` | Key Vault URL | Your application configuration |

**What the webhook injects:**

When the pod is created, the workload identity webhook automatically adds:

1. **Environment variables:**
   - `AZURE_AUTHORITY_HOST`
   - `AZURE_FEDERATED_TOKEN_FILE`
   - `AZURE_TENANT_ID`

2. **Projected volume:**
   ```yaml
   volumes:
   - name: azure-identity-token
     projected:
       sources:
       - serviceAccountToken:
           audience: api://AzureADTokenExchange
           expirationSeconds: 3600
           path: azure-identity-token
   ```

3. **Volume mount:**
   - Mounted at `/var/run/secrets/azure/tokens/azure-identity-token`

> **📖 Deep Dive:** For a detailed explanation of where and when the projected volume is created, see [PROJECTED_VOLUME_EXPLAINED.md](PROJECTED_VOLUME_EXPLAINED.md). This document explains:
> - What you write vs. what the webhook injects
> - The complete pod creation flow
> - How to verify the volume was injected
> - Troubleshooting common issues

**Why it's needed:**
- The label triggers automatic token injection
- The ServiceAccount provides the Kubernetes identity
- Environment variables guide the Azure SDK

---

### 7. Azure Key Vault RBAC

**Configuration:**
```bash
# Enable RBAC on Key Vault
az keyvault create \
    --enable-rbac-authorization true

# Grant access to Managed Identity
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee-object-id <MANAGED_IDENTITY_PRINCIPAL_ID> \
    --scope /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/kv-appointment
```

**What it does:**
- Grants the Managed Identity permission to read secrets
- Uses Azure RBAC (not legacy Access Policies)

**Available roles:**

| Role | Permissions |
|------|-------------|
| `Key Vault Secrets User` | Read secrets only (recommended) |
| `Key Vault Secrets Officer` | Read, write, delete secrets |
| `Key Vault Reader` | Read metadata only (no secret values) |

**Why it's needed:**
- Even with valid authentication, you need authorization
- RBAC provides fine-grained, auditable permissions

---

## How Workload Identity Works

### Step-by-Step Flow

1. **Pod starts** with `serviceAccountName: svc-appointment` and label `azure.workload.identity/use: "true"`

2. **Webhook injects** OIDC token into pod at `/var/run/secrets/azure/tokens/azure-identity-token`

3. **Application code** uses Azure SDK (e.g., `DefaultAzureCredential`)
   ```csharp
   var credential = new DefaultAzureCredential();
   var client = new SecretClient(new Uri(keyVaultUrl), credential);
   ```

4. **DefaultAzureCredential** detects environment variables and reads the OIDC token file

5. **Token exchange** happens automatically:
   ```
   Kubernetes OIDC Token (JWT)
         ↓
   Azure AD Token Exchange Endpoint
         ↓
   Validates:
     - Token signature (from OIDC issuer)
     - Subject matches federated credential
     - Audience is api://AzureADTokenExchange
         ↓
   Issues Azure AD Access Token
   ```

6. **App uses Azure AD token** to call Key Vault API

7. **Key Vault validates** token and checks RBAC permissions

8. **Secret returned** to application

### Token Details

**Kubernetes OIDC Token (injected into pod):**
```json
{
  "aud": ["api://AzureADTokenExchange"],
  "exp": 1234567890,
  "iss": "https://eastus.oic.prod-aks.azure.com/<guid>/",
  "sub": "system:serviceaccount:nsp-appointment:svc-appointment",
  "kubernetes.io": {
    "namespace": "nsp-appointment",
    "serviceaccount": {
      "name": "svc-appointment",
      "uid": "..."
    }
  }
}
```

**Key fields:**
- `iss` (issuer): Must match federated credential issuer
- `sub` (subject): Must match federated credential subject
- `aud` (audience): Must be `api://AzureADTokenExchange`

---

## Setup Instructions

### Prerequisites

- Azure CLI installed and logged in
- kubectl installed
- Docker (for building images)
- Azure subscription

### Quick Start

1. **Create all Azure resources:**
   ```bash
   ./setup.sh
   ```
   This creates:
   - Resource group
   - AKS cluster with OIDC + Workload Identity
   - Key Vault with RBAC
   - Managed Identity
   - Federated credential
   - Kubernetes namespace and ServiceAccount

2. **Build and deploy application:**
   ```bash
   ./deploy-app.sh
   ```
   This:
   - Creates Azure Container Registry
   - Builds Docker image
   - Deploys to AKS
   - Exposes via LoadBalancer

3. **Verify setup:**
   ```bash
   ./verify-workload-identity.sh
   ```
   This runs comprehensive checks on all components

---

## Configuration Details

### Environment Variables in Application

Your application needs these environment variables:

```bash
# Key Vault URL (required)
KEY_VAULT_URL=https://kv-appointment.vault.azure.net/

# Managed Identity Client ID (optional, auto-detected in most cases)
AZURE_CLIENT_ID=<your-managed-identity-client-id>

# These are auto-injected by workload identity webhook:
AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
AZURE_TENANT_ID=<your-tenant-id>
```

### Application Code Example

**C# (.NET):**
```csharp
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;

var keyVaultUrl = Environment.GetEnvironmentVariable("KEY_VAULT_URL");
var credential = new DefaultAzureCredential();
var client = new SecretClient(new Uri(keyVaultUrl), credential);

KeyVaultSecret secret = await client.GetSecretAsync("ApiKey");
Console.WriteLine($"Secret: {secret.Value}");
```

**Key points:**
- Use `DefaultAzureCredential` - it automatically detects workload identity
- No credentials in code
- No connection strings needed

---

## Verification

### Check AKS Configuration

```bash
# Verify OIDC is enabled
az aks show -g rg-appointment -n aks-appointment \
  --query "oidcIssuerProfile.enabled"

# Get OIDC issuer URL
az aks show -g rg-appointment -n aks-appointment \
  --query "oidcIssuerProfile.issuerUrl" -o tsv

# Verify workload identity is enabled
az aks show -g rg-appointment -n aks-appointment \
  --query "securityProfile.workloadIdentity.enabled"
```

### Check Managed Identity

```bash
# Get client ID
az identity show -g rg-appointment -n mi-appointment \
  --query clientId -o tsv

# Check federated credential
az identity federated-credential show \
  -g rg-appointment \
  --identity-name mi-appointment \
  --name aks-federated-credential
```

### Check RBAC Permissions

```bash
# List role assignments for managed identity
PRINCIPAL_ID=$(az identity show -g rg-appointment -n mi-appointment --query principalId -o tsv)
az role assignment list --assignee $PRINCIPAL_ID --output table
```

### Check Kubernetes Resources

```bash
# Check ServiceAccount
kubectl get serviceaccount svc-appointment -n nsp-appointment -o yaml

# Check that annotation is present
kubectl get serviceaccount svc-appointment -n nsp-appointment \
  -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'

# Check pod configuration
kubectl get pod -n nsp-appointment -l app=keyvault-api -o yaml

# Look for injected volumes and environment variables
kubectl describe pod -n nsp-appointment -l app=keyvault-api
```

### Test Application

```bash
# Get external IP
EXTERNAL_IP=$(kubectl get service keyvault-api-service -n nsp-appointment -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test API endpoint
curl http://$EXTERNAL_IP/

# Check logs
kubectl logs -n nsp-appointment -l app=keyvault-api
```

---

## Troubleshooting

### Common Issues

#### 1. "Azure.Identity.CredentialUnavailableException"

**Symptom:** Application can't authenticate to Azure

**Possible causes:**
- Workload identity label missing on pod
- ServiceAccount not configured correctly
- Federated credential subject mismatch

**Solution:**
```bash
# Check pod has the label
kubectl get pod -n nsp-appointment -l app=keyvault-api \
  -o jsonpath='{.items[0].metadata.labels.azure\.workload\.identity/use}'
# Should return: true

# Check serviceAccountName
kubectl get pod -n nsp-appointment -l app=keyvault-api \
  -o jsonpath='{.items[0].spec.serviceAccountName}'
# Should return: svc-appointment

# Verify environment variables are injected
kubectl exec -n nsp-appointment deployment/keyvault-api -- env | grep AZURE
```

#### 2. "AuthenticationFailed: Audience validation failed"

**Symptom:** Token exchange fails

**Cause:** Federated credential audience mismatch

**Solution:**
```bash
# Check federated credential
az identity federated-credential show \
  -g rg-appointment \
  --identity-name mi-appointment \
  --name aks-federated-credential \
  --query audiences
# Should contain: api://AzureADTokenExchange
```

#### 3. "Forbidden: User does not have access"

**Symptom:** Authentication works but Key Vault access denied

**Cause:** Missing RBAC permissions

**Solution:**
```bash
# Grant Key Vault Secrets User role
PRINCIPAL_ID=$(az identity show -g rg-appointment -n mi-appointment --query principalId -o tsv)
KV_ID=$(az keyvault show -n kv-appointment -g rg-appointment --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee-object-id $PRINCIPAL_ID \
  --scope $KV_ID
```

#### 4. "OIDC issuer mismatch"

**Symptom:** Federated credential doesn't match AKS issuer

**Solution:**
```bash
# Get current OIDC issuer
OIDC_ISSUER=$(az aks show -g rg-appointment -n aks-appointment \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Check federated credential issuer
az identity federated-credential show \
  -g rg-appointment \
  --identity-name mi-appointment \
  --name aks-federated-credential \
  --query issuer -o tsv

# If mismatch, recreate federated credential
az identity federated-credential delete \
  -g rg-appointment \
  --identity-name mi-appointment \
  --name aks-federated-credential

az identity federated-credential create \
  --name aks-federated-credential \
  --identity-name mi-appointment \
  -g rg-appointment \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:nsp-appointment:svc-appointment"
```

#### 5. Tokens not being injected

**Symptom:** No `/var/run/secrets/azure/tokens/` volume in pod

**Cause:** Workload identity webhook not running or label missing

**Solution:**
```bash
# Check webhook is running
kubectl get pods -n kube-system -l azure-workload-identity.io/system=true

# Ensure pod has correct label (must be in pod template, not deployment)
kubectl get deployment keyvault-api -n nsp-appointment -o yaml | grep -A 5 "labels:"

# Delete and recreate pod to trigger webhook
kubectl delete pod -n nsp-appointment -l app=keyvault-api
```

### Debug Commands

```bash
# Check all workload identity components
./verify-workload-identity.sh

# View pod events
kubectl get events -n nsp-appointment --sort-by='.lastTimestamp'

# Check pod logs
kubectl logs -n nsp-appointment -l app=keyvault-api --tail=100

# Describe pod to see injected configuration
kubectl describe pod -n nsp-appointment -l app=keyvault-api

# Exec into pod and check token
kubectl exec -n nsp-appointment deployment/keyvault-api -- \
  cat /var/run/secrets/azure/tokens/azure-identity-token

# Decode the token (JWT)
kubectl exec -n nsp-appointment deployment/keyvault-api -- \
  cat /var/run/secrets/azure/tokens/azure-identity-token | \
  cut -d. -f2 | base64 -d | jq
```

---

## Cost Estimation

| Resource | SKU | Estimated Cost |
|----------|-----|----------------|
| AKS Control Plane | Free Tier | $0/month |
| AKS Worker Node | 1x Standard_B2s | ~$30-50/month |
| Key Vault | Standard | ~$0.03/10k operations |
| Managed Identity | N/A | $0 (no cost) |
| Container Registry | Basic | ~$5/month |

**Total:** ~$35-55/month (mostly for the VM)

---

## References

- [Azure Workload Identity Documentation](https://azure.github.io/azure-workload-identity/)
- [AKS Workload Identity Overview](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [Azure SDK for .NET - DefaultAzureCredential](https://learn.microsoft.com/dotnet/api/azure.identity.defaultazurecredential)
- [Key Vault RBAC Guide](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [Kubernetes ServiceAccounts](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
