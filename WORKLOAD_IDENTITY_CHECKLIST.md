# Azure Workload Identity Configuration Checklist

This checklist ensures your Azure Workload Identity setup is properly configured and working correctly.

## 📋 Prerequisites

- [ ] Azure CLI installed and up to date (`az --version`)
- [ ] kubectl installed (`kubectl version --client`)
- [ ] Logged into Azure (`az account show`)
- [ ] Correct subscription selected

## 🏗️ Infrastructure Components

### Azure Kubernetes Service (AKS)

- [ ] **AKS cluster exists**
  ```bash
  az aks show --resource-group rg-appointment --name aks-appointment
  ```

- [ ] **OIDC Issuer is enabled**
  ```bash
  az aks show --resource-group rg-appointment --name aks-appointment --query "oidcIssuerProfile.enabled" -o tsv
  # Expected: true
  ```

- [ ] **OIDC Issuer URL is available**
  ```bash
  az aks show --resource-group rg-appointment --name aks-appointment --query "oidcIssuerProfile.issuerUrl" -o tsv
  # Expected: https://eastus.oic.prod-aks.azure.com/<tenant-id>/<guid>/
  ```

- [ ] **Workload Identity is enabled in security profile**
  ```bash
  az aks show --resource-group rg-appointment --name aks-appointment --query "securityProfile.workloadIdentity.enabled" -o tsv
  # Expected: true
  ```

- [ ] **kubectl has cluster credentials**
  ```bash
  kubectl config current-context
  # Expected: aks-appointment
  ```

### Azure Key Vault

- [ ] **Key Vault exists**
  ```bash
  az keyvault show --name kv-appointment --resource-group rg-appointment
  ```

- [ ] **Key Vault uses RBAC authorization**
  ```bash
  az keyvault show --name kv-appointment --resource-group rg-appointment --query "properties.enableRbacAuthorization" -o tsv
  # Expected: true
  ```

- [ ] **Test secret exists in Key Vault**
  ```bash
  az keyvault secret show --vault-name kv-appointment --name ApiKey --query name -o tsv
  # Expected: ApiKey
  ```

- [ ] **Test secret has a value**
  ```bash
  az keyvault secret show --vault-name kv-appointment --name ApiKey --query value -o tsv
  # Expected: MySecretValue-<timestamp>
  ```

### Managed Identity

- [ ] **User-Assigned Managed Identity exists**
  ```bash
  az identity show --resource-group rg-appointment --name mi-appointment
  ```

- [ ] **Managed Identity has Client ID**
  ```bash
  az identity show --resource-group rg-appointment --name mi-appointment --query clientId -o tsv
  # Expected: <guid>
  ```

- [ ] **Managed Identity has Principal ID**
  ```bash
  az identity show --resource-group rg-appointment --name mi-appointment --query principalId -o tsv
  # Expected: <guid>
  ```

### RBAC Permissions

- [ ] **Managed Identity has Key Vault Secrets User role**
  ```bash
  az role assignment list --assignee $(az identity show --resource-group rg-appointment --name mi-appointment --query principalId -o tsv) --scope $(az keyvault show --name kv-appointment --resource-group rg-appointment --query id -o tsv) --query "[?roleDefinitionName=='Key Vault Secrets User'].roleDefinitionName" -o tsv
  # Expected: Key Vault Secrets User
  ```

### Federated Identity Credential

- [ ] **Federated credential exists**
  ```bash
  az identity federated-credential list --identity-name mi-appointment --resource-group rg-appointment --query "[].name" -o tsv
  # Expected: aks-federated-credential
  ```

- [ ] **Federated credential has correct issuer**
  ```bash
  az identity federated-credential show --name aks-federated-credential --identity-name mi-appointment --resource-group rg-appointment --query issuer -o tsv
  # Should match: az aks show --resource-group rg-appointment --name aks-appointment --query "oidcIssuerProfile.issuerUrl" -o tsv
  ```

- [ ] **Federated credential has correct subject**
  ```bash
  az identity federated-credential show --name aks-federated-credential --identity-name mi-appointment --resource-group rg-appointment --query subject -o tsv
  # Expected: system:serviceaccount:nsp-appointment:svc-appointment
  ```

- [ ] **Federated credential has correct audience**
  ```bash
  az identity federated-credential show --name aks-federated-credential --identity-name mi-appointment --resource-group rg-appointment --query audiences -o tsv
  # Expected: api://AzureADTokenExchange
  ```

## ☸️ Kubernetes Components

### Namespace

- [ ] **Namespace exists**
  ```bash
  kubectl get namespace nsp-appointment
  # Expected: NAME            STATUS   AGE
  #          nsp-appointment   Active   <time>
  ```

### Service Account

- [ ] **Service Account exists**
  ```bash
  kubectl get serviceaccount svc-appointment -n nsp-appointment
  ```

- [ ] **Service Account has workload identity annotation**
  ```bash
  kubectl get serviceaccount svc-appointment -n nsp-appointment -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'
  # Should match the Managed Identity Client ID
  ```

- [ ] **Annotation value matches Managed Identity Client ID**
  ```bash
  # Compare these two values - they must match:
  kubectl get serviceaccount svc-appointment -n nsp-appointment -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'
  az identity show --resource-group rg-appointment --name mi-appointment --query clientId -o tsv
  ```

## 🚀 Application Deployment

### Deployment

- [ ] **Deployment exists**
  ```bash
  kubectl get deployment keyvault-api -n nsp-appointment
  ```

- [ ] **Deployment is using correct service account**
  ```bash
  kubectl get deployment keyvault-api -n nsp-appointment -o jsonpath='{.spec.template.spec.serviceAccountName}'
  # Expected: svc-appointment
  ```

- [ ] **Pod has workload identity label**
  ```bash
  kubectl get deployment keyvault-api -n nsp-appointment -o jsonpath='{.spec.template.metadata.labels.azure\.workload\.identity/use}'
  # Expected: true
  ```

- [ ] **Deployment has correct environment variables**
  ```bash
  kubectl get deployment keyvault-api -n nsp-appointment -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AzureKeyVaultName")].value}'
  # Expected: kv-appointment
  ```

### Pods

- [ ] **Pod is running**
  ```bash
  kubectl get pods -n nsp-appointment -l app=keyvault-api
  # Expected: STATUS = Running, READY = 1/1
  ```

- [ ] **Pod has service account mounted**
  ```bash
  kubectl describe pod -l app=keyvault-api -n nsp-appointment | grep "Service Account:"
  # Expected: Service Account:  svc-appointment
  ```

- [ ] **Pod has workload identity webhook injected volumes**
  ```bash
  kubectl describe pod -l app=keyvault-api -n nsp-appointment | grep -A 2 "azure-identity-token"
  # Should see azure-identity-token volume mounted
  ```

- [ ] **Pod logs show no authentication errors**
  ```bash
  kubectl logs -l app=keyvault-api -n nsp-appointment --tail=50 | grep -i "error\|exception\|fail"
  # Expected: No Key Vault or authentication errors
  ```

### Service

- [ ] **Service exists**
  ```bash
  kubectl get service keyvault-api-service -n nsp-appointment
  ```

- [ ] **Service has external IP assigned**
  ```bash
  kubectl get service keyvault-api-service -n nsp-appointment -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
  # Expected: <ip-address>
  ```

## 🧪 Functional Testing

### API Endpoints

- [ ] **Root endpoint returns Key Vault secret**
  ```bash
  EXTERNAL_IP=$(kubectl get service keyvault-api-service -n nsp-appointment -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  curl -s http://$EXTERNAL_IP/ | jq .
  # Expected: {"secretValue":"MySecretValue-<timestamp>"}
  ```

- [ ] **Secret value matches Key Vault**
  ```bash
  # Compare these two - they should match:
  curl -s http://$EXTERNAL_IP/ | jq -r .secretValue
  az keyvault secret show --vault-name kv-appointment --name ApiKey --query value -o tsv
  ```

- [ ] **Users endpoint works**
  ```bash
  curl -s http://$EXTERNAL_IP/users | jq .
  # Expected: [{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]
  ```

### Security Verification

- [ ] **No connection strings in configuration**
  ```bash
  kubectl get configmap -n nsp-appointment
  kubectl get secret -n nsp-appointment
  # Should NOT contain any Key Vault connection strings or access keys
  ```

- [ ] **Application uses DefaultAzureCredential**
  ```bash
  # Verify in Program.cs that DefaultAzureCredential is used
  grep "DefaultAzureCredential" /Users/yerald231ger/Documents/Areas/curses_azure/test_azure_keyvault/test_azure_keyvault_api/Program.cs
  ```

- [ ] **No environment variables with secrets**
  ```bash
  kubectl get deployment keyvault-api -n nsp-appointment -o jsonpath='{.spec.template.spec.containers[0].env[*].name}{"\n"}'
  # Should only see: ASPNETCORE_ENVIRONMENT, AzureKeyVaultName (no secrets/keys)
  ```

## 🔍 Advanced Verification

### Token Exchange

- [ ] **Pod can request Azure token (exec into pod)**
  ```bash
  POD_NAME=$(kubectl get pod -n nsp-appointment -l app=keyvault-api -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n nsp-appointment $POD_NAME -- env | grep AZURE
  # Should see AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE
  ```

- [ ] **Federated token file exists in pod**
  ```bash
  kubectl exec -n nsp-appointment $POD_NAME -- cat /var/run/secrets/azure/tokens/azure-identity-token
  # Should output a JWT token
  ```

### Identity Webhook

- [ ] **Workload identity webhook is running**
  ```bash
  kubectl get pods -n kube-system | grep "azure-wi-webhook"
  # Expected: azure-wi-webhook pods in Running state
  ```

- [ ] **Mutating webhook configuration exists**
  ```bash
  kubectl get mutatingwebhookconfigurations | grep azure-wi
  # Expected: azure-wi-webhook-mutating-webhook-configuration
  ```

## 📊 Summary Commands

Run this comprehensive check:

```bash
#!/bin/bash
echo "=== Azure Workload Identity Health Check ==="
echo ""

echo "✓ AKS OIDC Issuer:"
az aks show --resource-group rg-appointment --name aks-appointment --query "oidcIssuerProfile.issuerUrl" -o tsv

echo ""
echo "✓ Workload Identity Enabled:"
az aks show --resource-group rg-appointment --name aks-appointment --query "securityProfile.workloadIdentity.enabled" -o tsv

echo ""
echo "✓ Managed Identity Client ID:"
az identity show --resource-group rg-appointment --name mi-appointment --query clientId -o tsv

echo ""
echo "✓ Service Account Annotation:"
kubectl get serviceaccount svc-appointment -n nsp-appointment -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'

echo ""
echo ""
echo "✓ Federated Credential Subject:"
az identity federated-credential show --name aks-federated-credential --identity-name mi-appointment --resource-group rg-appointment --query subject -o tsv

echo ""
echo "✓ Pod Status:"
kubectl get pods -n nsp-appointment -l app=keyvault-api

echo ""
echo "✓ API Test (retrieving Key Vault secret):"
EXTERNAL_IP=$(kubectl get service keyvault-api-service -n nsp-appointment -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s http://$EXTERNAL_IP/

echo ""
echo ""
echo "=== Health Check Complete ==="
```

## ✅ Success Criteria

Your Azure Workload Identity is properly configured when:

1. ✅ All infrastructure components exist and are properly configured
2. ✅ Managed Identity has correct RBAC permissions on Key Vault
3. ✅ Federated credential links the Kubernetes SA to Azure MI correctly
4. ✅ Service Account has the workload identity annotation
5. ✅ Pod has the workload identity label and uses the correct SA
6. ✅ API successfully retrieves secrets from Key Vault
7. ✅ Secret value from API matches the value in Key Vault
8. ✅ No secrets or connection strings are stored in Kubernetes

---

## 🐛 Troubleshooting

If any checks fail, refer to:

- [Azure Workload Identity Troubleshooting](https://azure.github.io/azure-workload-identity/docs/troubleshooting.html)
- Check pod logs: `kubectl logs -l app=keyvault-api -n nsp-appointment`
- Describe pod: `kubectl describe pod -l app=keyvault-api -n nsp-appointment`
- Check events: `kubectl get events -n nsp-appointment --sort-by='.lastTimestamp'`

Common issues:
- RBAC permissions not propagated (wait 5-10 minutes)
- Client ID mismatch between SA annotation and Managed Identity
- Federated credential subject doesn't match `system:serviceaccount:<namespace>:<serviceaccount>`
- Workload identity webhook not running
