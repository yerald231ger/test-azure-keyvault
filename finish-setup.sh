#!/bin/bash
set -e

# Variables
RESOURCE_GROUP="rg-appointment"
AKS_CLUSTER_NAME="aks-appointment"
KEY_VAULT_NAME="kv-appointment"
MANAGED_IDENTITY_NAME="mi-appointment"
NAMESPACE="nsp-appointment"
SERVICE_ACCOUNT_NAME="svc-appointment"

echo "=== Finishing Azure Workload Identity Setup ==="

# Get OIDC Issuer
OIDC_ISSUER=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "OIDC Issuer: $OIDC_ISSUER"

# Add secret to Key Vault
echo "\nAdding secret to Key Vault..."
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "ApiKey" --value "MySecretValue-$(date +%s)"

# Create Managed Identity
echo "\nCreating Managed Identity..."
az identity create --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME

# Get Managed Identity details
IDENTITY_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query principalId -o tsv)
echo "Managed Identity Client ID: $IDENTITY_CLIENT_ID"

# Grant Key Vault access to Managed Identity
echo "\nGranting Managed Identity access to Key Vault..."
KEY_VAULT_ID=$(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee-object-id $IDENTITY_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --scope $KEY_VAULT_ID

# Create Federated Identity Credential
echo "\nCreating Federated Identity Credential..."
az identity federated-credential create \
    --name "aks-federated-credential" \
    --identity-name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer $OIDC_ISSUER \
    --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"

# Create Kubernetes Service Account
echo "\nCreating Kubernetes Service Account..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    azure.workload.identity/client-id: $IDENTITY_CLIENT_ID
EOF

echo "\n=== Setup Complete! ==="
echo "Managed Identity Client ID: $IDENTITY_CLIENT_ID"
echo "Service Account: $SERVICE_ACCOUNT_NAME in namespace $NAMESPACE"
