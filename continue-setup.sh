#!/bin/bash

# Azure Workload Identity Setup - Continuation Script
# This picks up from Step 4 onwards

set -e

# Variables - Must match the original setup
RESOURCE_GROUP="rg-appointment"
LOCATION="eastus"
AKS_CLUSTER_NAME="aks-appointment"
KEY_VAULT_NAME="kv-appointment"
MANAGED_IDENTITY_NAME="mi-appointment"
NAMESPACE="nsp-appointment"
SERVICE_ACCOUNT_NAME="svc-appointment"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Continuing Azure Workload Identity Setup${NC}"
echo -e "${BLUE}========================================${NC}"

# Get OIDC Issuer URL (needed for federated credential)
echo -e "\n${GREEN}Getting OIDC Issuer URL...${NC}"
OIDC_ISSUER=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "OIDC Issuer: $OIDC_ISSUER"

# Step 4: Create Azure Key Vault (Standard tier - lowest cost)
echo -e "\n${GREEN}Step 4: Creating Azure Key Vault (Standard tier)...${NC}"
az keyvault create \
    --name $KEY_VAULT_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --sku standard

# Add a test secret to Key Vault (wait for RBAC propagation)
echo -e "\n${GREEN}Adding test secret to Key Vault (waiting 10s for RBAC propagation)...${NC}"
sleep 10
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name "ApiKey" \
    --value "MySecretValue-$(date +%s)"

# Step 5: Create User-Assigned Managed Identity (No cost)
echo -e "\n${GREEN}Step 5: Creating User-Assigned Managed Identity...${NC}"
az identity create \
    --resource-group $RESOURCE_GROUP \
    --name $MANAGED_IDENTITY_NAME

# Get Managed Identity details
IDENTITY_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query principalId -o tsv)

echo "Managed Identity Client ID: $IDENTITY_CLIENT_ID"
echo "Managed Identity Principal ID: $IDENTITY_PRINCIPAL_ID"

# Step 6: Grant Key Vault access to Managed Identity using RBAC
echo -e "\n${GREEN}Step 6: Granting Managed Identity access to Key Vault (using RBAC)...${NC}"
KEY_VAULT_ID=$(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee-object-id $IDENTITY_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --scope $KEY_VAULT_ID

# Step 7: Create Federated Identity Credential
echo -e "\n${GREEN}Step 7: Creating Federated Identity Credential...${NC}"
az identity federated-credential create \
    --name "aks-federated-credential" \
    --identity-name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer $OIDC_ISSUER \
    --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"

# Step 8: Create Kubernetes Service Account
echo -e "\n${GREEN}Step 8: Creating Kubernetes Service Account...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    azure.workload.identity/client-id: $IDENTITY_CLIENT_ID
EOF

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Setup Complete!${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${GREEN}Summary of created resources:${NC}"
echo "Resource Group: $RESOURCE_GROUP"
echo "AKS Cluster: $AKS_CLUSTER_NAME (Free tier)"
echo "Namespace: $NAMESPACE"
echo "Key Vault: $KEY_VAULT_NAME (Standard tier)"
echo "Key Vault URL: https://${KEY_VAULT_NAME}.vault.azure.net/"
echo "Managed Identity: $MANAGED_IDENTITY_NAME"
echo "Managed Identity Client ID: $IDENTITY_CLIENT_ID"
echo "Service Account: $SERVICE_ACCOUNT_NAME (namespace: $NAMESPACE)"
echo "OIDC Issuer: $OIDC_ISSUER"

echo -e "\n${GREEN}Verification Commands:${NC}"
echo "kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $NAMESPACE -o yaml"
echo "kubectl get pods -n $NAMESPACE"
echo "az keyvault secret show --vault-name $KEY_VAULT_NAME --name ApiKey"