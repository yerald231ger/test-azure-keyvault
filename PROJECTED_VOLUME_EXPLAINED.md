# Projected Volume - Where and When It's Created

## TL;DR

**You DON'T create the Projected volume** - it's automatically injected by the Azure Workload Identity webhook when your pod starts.

---

## The Two-Stage Process

### Stage 1: What YOU Write (deployment.yaml)

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
        azure.workload.identity/use: "true"  # ← This triggers the webhook
    spec:
      serviceAccountName: svc-appointment    # ← ServiceAccount with MI annotation
      containers:
      - name: api
        image: your-image:tag
        # NO volumes defined here!
        # NO volumeMounts defined here!
```

**Key points:**
- You only add the **label** `azure.workload.identity/use: "true"`
- You reference the **ServiceAccount** that has the Managed Identity annotation
- You do **NOT** define any volumes or volumeMounts for the token

### Stage 2: What the Webhook INJECTS (actual pod)

When you apply your deployment, the **mutating admission webhook** intercepts the pod creation and modifies it:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: keyvault-api-xyz123
  namespace: nsp-appointment
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: svc-appointment
  containers:
  - name: api
    image: your-image:tag
    env:
    # ← INJECTED: These environment variables are added by the webhook
    - name: AZURE_AUTHORITY_HOST
      value: "https://login.microsoftonline.com/"
    - name: AZURE_FEDERATED_TOKEN_FILE
      value: "/var/run/secrets/azure/tokens/azure-identity-token"
    - name: AZURE_TENANT_ID
      value: "your-tenant-id"
    - name: AZURE_CLIENT_ID
      value: "your-managed-identity-client-id"
    volumeMounts:
    # ← INJECTED: This volume mount is added by the webhook
    - name: azure-identity-token
      mountPath: /var/run/secrets/azure/tokens
      readOnly: true
  volumes:
  # ← INJECTED: This projected volume is added by the webhook
  - name: azure-identity-token
    projected:
      sources:
      - serviceAccountToken:
          audience: api://AzureADTokenExchange
          expirationSeconds: 3600
          path: azure-identity-token
```

---

## When Does This Happen?

```
1. You run: kubectl apply -f deployment.yaml
                    ↓
2. Kubernetes API receives the pod spec
                    ↓
3. Mutating Admission Webhook intercepts
   (azure-workload-identity-webhook)
                    ↓
4. Webhook checks:
   - Does pod have label "azure.workload.identity/use=true"? ✓
   - Does ServiceAccount have "azure.workload.identity/client-id" annotation? ✓
                    ↓
5. Webhook modifies pod spec:
   - Adds environment variables
   - Adds projected volume
   - Adds volume mount
                    ↓
6. Modified pod spec is saved to etcd
                    ↓
7. Kubelet starts the pod with injected configuration
                    ↓
8. Pod starts with token available at:
   /var/run/secrets/azure/tokens/azure-identity-token
```

**Timeline:** This all happens in milliseconds during pod creation, before your container starts.

---

## Where Does the Webhook Run?

The Azure Workload Identity webhook runs as a system component in your AKS cluster:

```bash
# Check if the webhook is running
kubectl get pods -n kube-system -l azure-workload-identity.io/system=true
```

Output:
```
NAME                                         READY   STATUS    RESTARTS   AGE
azure-wi-webhook-controller-manager-xxxxx    1/1     Running   0          5d
```

The webhook is automatically installed when you create an AKS cluster with `--enable-workload-identity`.

---

## How to Verify the Projected Volume Was Injected

### Method 1: Describe the Running Pod

```bash
kubectl describe pod -n nsp-appointment -l app=keyvault-api
```

Look for:

```yaml
Volumes:
  azure-identity-token:
    Type:                    Projected (a volume that contains injected data)
    TokenExpirationSeconds:  3600
Mounts:
  /var/run/secrets/azure/tokens from azure-identity-token (ro)
Environment:
  AZURE_AUTHORITY_HOST:        https://login.microsoftonline.com/
  AZURE_FEDERATED_TOKEN_FILE:  /var/run/secrets/azure/tokens/azure-identity-token
  AZURE_TENANT_ID:             <your-tenant-id>
  AZURE_CLIENT_ID:             <your-client-id>
```

### Method 2: Get the Full Pod YAML

```bash
kubectl get pod -n nsp-appointment -l app=keyvault-api -o yaml
```

Look for the `volumes` section at the bottom - you'll see the projected volume that wasn't in your deployment.yaml.

### Method 3: Exec into the Pod and Check

```bash
# List the tokens directory
kubectl exec -n nsp-appointment deployment/keyvault-api -- ls -la /var/run/secrets/azure/tokens/

# View the token file
kubectl exec -n nsp-appointment deployment/keyvault-api -- cat /var/run/secrets/azure/tokens/azure-identity-token

# Decode the JWT token to see its contents
kubectl exec -n nsp-appointment deployment/keyvault-api -- cat /var/run/secrets/azure/tokens/azure-identity-token | cut -d. -f2 | base64 -d
```

Output (JWT payload):
```json
{
  "aud": ["api://AzureADTokenExchange"],
  "exp": 1234567890,
  "iat": 1234564290,
  "iss": "https://eastus.oic.prod-aks.azure.com/<guid>/",
  "sub": "system:serviceaccount:nsp-appointment:svc-appointment",
  "kubernetes.io": {
    "namespace": "nsp-appointment",
    "pod": {
      "name": "keyvault-api-xyz123",
      "uid": "abc-def-ghi"
    },
    "serviceaccount": {
      "name": "svc-appointment",
      "uid": "123-456-789"
    }
  }
}
```

---

## Understanding the Projected Volume Type

### What is a Projected Volume?

A **Projected Volume** is a special Kubernetes volume type that can combine multiple volume sources into a single directory. In this case, it's used to project a ServiceAccount token.

### Why Projected and not Secret?

```
❌ NOT a Secret volume - tokens aren't stored in etcd
❌ NOT a ConfigMap - tokens are sensitive and short-lived
✅ Projected ServiceAccount Token - dynamically generated, auto-rotated
```

**Key differences:**

| Feature | Secret Volume | Projected ServiceAccount Token |
|---------|--------------|--------------------------------|
| Storage | Stored in etcd | Generated on-demand |
| Rotation | Manual | Automatic (by kubelet) |
| Audience | Generic | Customizable (`api://AzureADTokenExchange`) |
| Expiration | No expiration | Configurable (3600s default) |
| Security | Less secure (in etcd) | More secure (ephemeral) |

### Projected Volume Configuration Breakdown

```yaml
volumes:
- name: azure-identity-token          # Volume name (referenced in volumeMounts)
  projected:                           # Volume type: projected
    sources:                           # Can combine multiple sources
    - serviceAccountToken:             # Source type: ServiceAccount token
        audience: api://AzureADTokenExchange  # Token audience (for Azure AD)
        expirationSeconds: 3600        # Token expires in 1 hour
        path: azure-identity-token     # Filename in the mounted directory
```

**What each field means:**

- **audience**: Who the token is intended for. Azure AD only accepts tokens with audience `api://AzureADTokenExchange`
- **expirationSeconds**: How long the token is valid. Kubelet automatically renews it before expiration
- **path**: The filename where the token will be written (`/var/run/secrets/azure/tokens/azure-identity-token`)

---

## The Complete Flow: From Deployment to Token

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. You create deployment.yaml                                   │
│    - Label: azure.workload.identity/use=true                    │
│    - ServiceAccount: svc-appointment                            │
│    - NO volumes defined                                         │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. kubectl apply -f deployment.yaml                             │
│    → Sends pod spec to Kubernetes API                           │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Mutating Admission Webhook (azure-wi-webhook)                │
│    → Checks label and ServiceAccount annotation                 │
│    → Injects:                                                   │
│      • Environment variables (AZURE_*)                          │
│      • Projected volume (azure-identity-token)                  │
│      • Volume mount (/var/run/secrets/azure/tokens)             │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Pod is created with modified spec                            │
│    → Scheduler assigns pod to node                              │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Kubelet on node starts the pod                               │
│    → Creates projected volume                                   │
│    → Requests token from kube-apiserver                         │
│    → Writes token to volume                                     │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Container starts                                              │
│    → Token file exists at:                                      │
│      /var/run/secrets/azure/tokens/azure-identity-token         │
│    → Environment variables set:                                 │
│      AZURE_FEDERATED_TOKEN_FILE=/var/run/...                    │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 7. Application (DefaultAzureCredential) starts                  │
│    → Reads AZURE_FEDERATED_TOKEN_FILE env var                   │
│    → Opens and reads the token file                             │
│    → Exchanges token with Azure AD                              │
│    → Gets Azure AD access token                                 │
│    → Accesses Key Vault                                         │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 8. Token Auto-Rotation (background, continuous)                 │
│    → Kubelet monitors token expiration                          │
│    → Renews token ~10 minutes before expiry                     │
│    → Writes new token to same file                              │
│    → Application picks up new token on next API call            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting: Volume Not Injected

If the projected volume is NOT appearing in your pod:

### Check 1: Pod Has the Label

```bash
kubectl get pod -n nsp-appointment -l app=keyvault-api \
  -o jsonpath='{.items[0].metadata.labels.azure\.workload\.identity/use}'
```

Should return: `true`

**Fix if missing:**
```yaml
# deployment.yaml - labels must be in pod template, not deployment metadata
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"  # ← Must be here
```

### Check 2: ServiceAccount Has the Annotation

```bash
kubectl get serviceaccount svc-appointment -n nsp-appointment \
  -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'
```

Should return: `<your-managed-identity-client-id>`

**Fix if missing:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: svc-appointment
  namespace: nsp-appointment
  annotations:
    azure.workload.identity/client-id: "<your-client-id>"  # ← Must be here
```

### Check 3: Webhook is Running

```bash
kubectl get pods -n kube-system -l azure-workload-identity.io/system=true
```

Should show a running webhook pod.

**Fix if not running:**
- Webhook is installed automatically with `--enable-workload-identity`
- If missing, your cluster may not have workload identity enabled
- Check: `az aks show -g rg-appointment -n aks-appointment --query "securityProfile.workloadIdentity.enabled"`

### Check 4: Restart Pod to Trigger Webhook

If you added the label after the pod was created:

```bash
# Delete pod to force recreation
kubectl delete pod -n nsp-appointment -l app=keyvault-api

# Or rollout restart the deployment
kubectl rollout restart deployment keyvault-api -n nsp-appointment
```

The webhook only runs during pod creation, not on existing pods.

---

## Summary

| Question | Answer |
|----------|--------|
| **Where is it created?** | By the Azure Workload Identity mutating admission webhook in your AKS cluster |
| **When is it created?** | During pod creation, before the container starts |
| **Do you define it?** | No, you only add the label `azure.workload.identity/use: "true"` |
| **Where does it mount?** | `/var/run/secrets/azure/tokens/azure-identity-token` |
| **What triggers injection?** | Pod label + ServiceAccount annotation |
| **How often does it refresh?** | Kubelet auto-renews ~10 minutes before expiration |
| **Can you see it in your YAML?** | No in deployment.yaml, yes in the running pod's YAML |

---

## References

- [Kubernetes Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Kubernetes ServiceAccount Tokens](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
- [Azure Workload Identity Webhook](https://azure.github.io/azure-workload-identity/docs/installation/mutating-admission-webhook.html)
