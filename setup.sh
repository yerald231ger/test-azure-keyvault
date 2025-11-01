#!/bin/bash

# Azure Workload Identity Complete Setup Script
# This script creates all necessary Azure and Kubernetes resources

set -e

# Configuration Variables
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
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Azure Workload Identity Setup${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Create Resource Group
echo -e "\n${GREEN}[1/8] Creating Resource Group...${NC}"
az group create --name $RESOURCE_GROUP --location $LOCATION

# 2. Create AKS Cluster with OIDC and Workload Identity
echo -e "\n${GREEN}[2/8] Creating AKS Cluster (this takes 5-10 minutes)...${NC}"
az aks create \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_CLUSTER_NAME \
    --node-count 1 \
    --node-vm-size Standard_B2s \
    --tier free \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --network-plugin azure \
    --generate-ssh-keys

# 3. Get AKS Credentials
echo -e "\n${GREEN}[3/8] Getting AKS credentials...${NC}"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --overwrite-existing

# Get OIDC Issuer URL
OIDC_ISSUER=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "OIDC Issuer: $OIDC_ISSUER"

# Create Namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 4. Create Key Vault
echo -e "\n${GREEN}[4/8] Creating Key Vault...${NC}"
az keyvault create \
    --name $KEY_VAULT_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --sku standard \
    --enable-rbac-authorization true

# Add test secret
echo -e "\n${GREEN}[5/8] Adding test secret to Key Vault...${NC}"
sleep 10  # Wait for RBAC propagation
az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name "ApiKey" \
    --value "MySecretValue-$(date +%s)"

# 5. Create Managed Identity
echo -e "\n${GREEN}[6/8] Creating Managed Identity...${NC}"
az identity create \
    --resource-group $RESOURCE_GROUP \
    --name $MANAGED_IDENTITY_NAME

# Get Managed Identity details
IDENTITY_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query principalId -o tsv)

# 6. Grant Key Vault access to Managed Identity
echo -e "\n${GREEN}[7/8] Granting Managed Identity access to Key Vault...${NC}"
KEY_VAULT_ID=$(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee-object-id $IDENTITY_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --scope $KEY_VAULT_ID

# 7. Create Federated Identity Credential
echo -e "\n${GREEN}[8/8] Creating Federated Identity Credential...${NC}"
az identity federated-credential create \
    --name "aks-federated-credential" \
    --identity-name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer $OIDC_ISSUER \
    --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"

# 8. Create Kubernetes Service Account
echo -e "\n${GREEN}Creating Kubernetes Service Account...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    azure.workload.identity/client-id: $IDENTITY_CLIENT_ID
EOF

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Setup Complete!${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${GREEN}Created Resources:${NC}"
echo "• Resource Group: $RESOURCE_GROUP"
echo "• AKS Cluster: $AKS_CLUSTER_NAME"
echo "• Namespace: $NAMESPACE"
echo "• Key Vault: $KEY_VAULT_NAME"
echo "• Key Vault URL: https://${KEY_VAULT_NAME}.vault.azure.net/"
echo "• Managed Identity: $MANAGED_IDENTITY_NAME"
echo "• Managed Identity Client ID: $IDENTITY_CLIENT_ID"
echo "• Service Account: $SERVICE_ACCOUNT_NAME"
echo "• OIDC Issuer: $OIDC_ISSUER"

echo -e "\n${GREEN}Verification Commands:${NC}"
echo "kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $NAMESPACE"
echo "az keyvault secret show --vault-name $KEY_VAULT_NAME --name ApiKey"

echo -e "\n${YELLOW}Next Steps:${NC}"
echo "1. Run: ./deploy-app.sh (to build and deploy your application)"
echo "2. Run: ./verify-workload-identity.sh (to verify the setup)"
