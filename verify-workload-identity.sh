#!/bin/bash

# Azure Workload Identity Verification Script
# This script checks all critical components for proper configuration

set +e  # Don't exit on errors, we want to see all results

# Variables
RESOURCE_GROUP="rg-appointment"
AKS_CLUSTER_NAME="aks-appointment"
KEY_VAULT_NAME="kv-appointment"
MANAGED_IDENTITY_NAME="mi-appointment"
NAMESPACE="nsp-appointment"
SERVICE_ACCOUNT_NAME="svc-appointment"
FEDERATED_CRED_NAME="aks-federated-credential"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0

check_pass() {
    echo -e "${GREEN}✓ PASS${NC} - $1"
    ((PASSED++))
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC} - $1"
    echo -e "${YELLOW}  → $2${NC}"
    ((FAILED++))
}

check_info() {
    echo -e "${BLUE}ℹ INFO${NC} - $1"
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Azure Workload Identity Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Section 1: AKS Cluster
echo -e "${BLUE}[1] Checking AKS Cluster Configuration${NC}"
echo ""

# Check OIDC Issuer enabled
OIDC_ENABLED=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "oidcIssuerProfile.enabled" -o tsv 2>/dev/null)
if [ "$OIDC_ENABLED" == "true" ]; then
    check_pass "OIDC Issuer is enabled"
else
    check_fail "OIDC Issuer is not enabled" "Enable with: az aks update --enable-oidc-issuer"
fi

# Check OIDC Issuer URL
OIDC_ISSUER=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv 2>/dev/null)
if [ ! -z "$OIDC_ISSUER" ]; then
    check_pass "OIDC Issuer URL is configured"
    check_info "Issuer: $OIDC_ISSUER"
else
    check_fail "OIDC Issuer URL not found" "Check AKS cluster configuration"
fi

# Check Workload Identity enabled
WI_ENABLED=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "securityProfile.workloadIdentity.enabled" -o tsv 2>/dev/null)
if [ "$WI_ENABLED" == "true" ]; then
    check_pass "Workload Identity is enabled"
else
    check_fail "Workload Identity is not enabled" "Enable with: az aks update --enable-workload-identity"
fi

echo ""

# Section 2: Key Vault
echo -e "${BLUE}[2] Checking Azure Key Vault${NC}"
echo ""

# Check Key Vault exists
KV_EXISTS=$(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query name -o tsv 2>/dev/null)
if [ "$KV_EXISTS" == "$KEY_VAULT_NAME" ]; then
    check_pass "Key Vault exists"
else
    check_fail "Key Vault not found" "Create Key Vault: az keyvault create --name $KEY_VAULT_NAME"
fi

# Check RBAC authorization
RBAC_ENABLED=$(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query "properties.enableRbacAuthorization" -o tsv 2>/dev/null)
if [ "$RBAC_ENABLED" == "true" ]; then
    check_pass "Key Vault uses RBAC authorization"
else
    check_fail "Key Vault is not using RBAC" "This may use Access Policies instead (also valid)"
fi

# Check test secret exists
SECRET_EXISTS=$(az keyvault secret show --vault-name $KEY_VAULT_NAME --name "ApiKey" --query name -o tsv 2>/dev/null)
if [ "$SECRET_EXISTS" == "ApiKey" ]; then
    check_pass "Test secret 'ApiKey' exists"
    SECRET_VALUE=$(az keyvault secret show --vault-name $KEY_VAULT_NAME --name "ApiKey" --query value -o tsv 2>/dev/null)
    check_info "Secret value: $SECRET_VALUE"
else
    check_fail "Test secret 'ApiKey' not found" "Create secret: az keyvault secret set --vault-name $KEY_VAULT_NAME --name ApiKey --value 'test'"
fi

echo ""

# Section 3: Managed Identity
echo -e "${BLUE}[3] Checking Managed Identity${NC}"
echo ""

# Check Managed Identity exists
MI_EXISTS=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query name -o tsv 2>/dev/null)
if [ "$MI_EXISTS" == "$MANAGED_IDENTITY_NAME" ]; then
    check_pass "Managed Identity exists"
else
    check_fail "Managed Identity not found" "Create: az identity create --name $MANAGED_IDENTITY_NAME"
fi

# Get Managed Identity IDs
MI_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query clientId -o tsv 2>/dev/null)
MI_PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query principalId -o tsv 2>/dev/null)

if [ ! -z "$MI_CLIENT_ID" ]; then
    check_pass "Managed Identity Client ID retrieved"
    check_info "Client ID: $MI_CLIENT_ID"
else
    check_fail "Could not retrieve Managed Identity Client ID" "Check Managed Identity configuration"
fi

if [ ! -z "$MI_PRINCIPAL_ID" ]; then
    check_pass "Managed Identity Principal ID retrieved"
else
    check_fail "Could not retrieve Managed Identity Principal ID" "Check Managed Identity configuration"
fi

echo ""

# Section 4: RBAC Permissions
echo -e "${BLUE}[4] Checking RBAC Permissions${NC}"
echo ""

# Check Managed Identity has Key Vault role
KV_ID=$(az keyvault show --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv 2>/dev/null)
ROLE_ASSIGNED=$(az role assignment list --assignee $MI_PRINCIPAL_ID --scope $KV_ID --query "[?roleDefinitionName=='Key Vault Secrets User'].roleDefinitionName" -o tsv 2>/dev/null)

if [ "$ROLE_ASSIGNED" == "Key Vault Secrets User" ]; then
    check_pass "Managed Identity has 'Key Vault Secrets User' role"
else
    check_fail "Managed Identity does not have Key Vault Secrets User role" "Grant access: az role assignment create --role 'Key Vault Secrets User' --assignee-object-id $MI_PRINCIPAL_ID --scope $KV_ID"
fi

echo ""

# Section 5: Federated Identity Credential
echo -e "${BLUE}[5] Checking Federated Identity Credential${NC}"
echo ""

# Check federated credential exists
FED_CRED_EXISTS=$(az identity federated-credential show --name $FEDERATED_CRED_NAME --identity-name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query name -o tsv 2>/dev/null)

if [ "$FED_CRED_EXISTS" == "$FEDERATED_CRED_NAME" ]; then
    check_pass "Federated credential exists"
else
    check_fail "Federated credential not found" "Create federated credential"
fi

# Check issuer matches
FED_ISSUER=$(az identity federated-credential show --name $FEDERATED_CRED_NAME --identity-name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query issuer -o tsv 2>/dev/null)

if [ "$FED_ISSUER" == "$OIDC_ISSUER" ]; then
    check_pass "Federated credential issuer matches AKS OIDC issuer"
else
    check_fail "Federated credential issuer mismatch" "Expected: $OIDC_ISSUER, Got: $FED_ISSUER"
fi

# Check subject
EXPECTED_SUBJECT="system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
FED_SUBJECT=$(az identity federated-credential show --name $FEDERATED_CRED_NAME --identity-name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query subject -o tsv 2>/dev/null)

if [ "$FED_SUBJECT" == "$EXPECTED_SUBJECT" ]; then
    check_pass "Federated credential subject is correct"
else
    check_fail "Federated credential subject mismatch" "Expected: $EXPECTED_SUBJECT, Got: $FED_SUBJECT"
fi

# Check audience
FED_AUDIENCE=$(az identity federated-credential show --name $FEDERATED_CRED_NAME --identity-name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query "audiences[0]" -o tsv 2>/dev/null)

if [ "$FED_AUDIENCE" == "api://AzureADTokenExchange" ]; then
    check_pass "Federated credential audience is correct"
else
    check_fail "Federated credential audience incorrect" "Expected: api://AzureADTokenExchange, Got: $FED_AUDIENCE"
fi

echo ""

# Section 6: Kubernetes Resources
echo -e "${BLUE}[6] Checking Kubernetes Resources${NC}"
echo ""

# Check namespace exists
NS_EXISTS=$(kubectl get namespace $NAMESPACE -o name 2>/dev/null)
if [ ! -z "$NS_EXISTS" ]; then
    check_pass "Namespace '$NAMESPACE' exists"
else
    check_fail "Namespace '$NAMESPACE' not found" "Create: kubectl create namespace $NAMESPACE"
fi

# Check service account exists
SA_EXISTS=$(kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $NAMESPACE -o name 2>/dev/null)
if [ ! -z "$SA_EXISTS" ]; then
    check_pass "Service Account '$SERVICE_ACCOUNT_NAME' exists"
else
    check_fail "Service Account '$SERVICE_ACCOUNT_NAME' not found" "Create service account with workload identity annotation"
fi

# Check service account annotation
SA_CLIENT_ID=$(kubectl get serviceaccount $SERVICE_ACCOUNT_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' 2>/dev/null)

if [ ! -z "$SA_CLIENT_ID" ]; then
    check_pass "Service Account has workload identity annotation"

    # Verify it matches Managed Identity Client ID
    if [ "$SA_CLIENT_ID" == "$MI_CLIENT_ID" ]; then
        check_pass "Service Account annotation matches Managed Identity Client ID"
    else
        check_fail "Service Account annotation mismatch" "SA: $SA_CLIENT_ID, MI: $MI_CLIENT_ID"
    fi
else
    check_fail "Service Account missing workload identity annotation" "Add annotation: azure.workload.identity/client-id=$MI_CLIENT_ID"
fi

echo ""

# Section 7: Application Deployment
echo -e "${BLUE}[7] Checking Application Deployment${NC}"
echo ""

# Check deployment exists
DEPLOY_EXISTS=$(kubectl get deployment keyvault-api -n $NAMESPACE -o name 2>/dev/null)
if [ ! -z "$DEPLOY_EXISTS" ]; then
    check_pass "Deployment 'keyvault-api' exists"
else
    check_fail "Deployment 'keyvault-api' not found" "Deploy application"
fi

# Check deployment uses correct SA
DEPLOY_SA=$(kubectl get deployment keyvault-api -n $NAMESPACE -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
if [ "$DEPLOY_SA" == "$SERVICE_ACCOUNT_NAME" ]; then
    check_pass "Deployment uses correct service account"
else
    check_fail "Deployment service account mismatch" "Expected: $SERVICE_ACCOUNT_NAME, Got: $DEPLOY_SA"
fi

# Check workload identity label
WI_LABEL=$(kubectl get deployment keyvault-api -n $NAMESPACE -o jsonpath='{.spec.template.metadata.labels.azure\.workload\.identity/use}' 2>/dev/null)
if [ "$WI_LABEL" == "true" ]; then
    check_pass "Deployment has workload identity label"
else
    check_fail "Deployment missing workload identity label" "Add label: azure.workload.identity/use=true"
fi

# Check pod status
POD_STATUS=$(kubectl get pods -n $NAMESPACE -l app=keyvault-api -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
if [ "$POD_STATUS" == "Running" ]; then
    check_pass "Pod is running"
else
    check_fail "Pod is not running" "Status: $POD_STATUS. Check: kubectl describe pod -l app=keyvault-api -n $NAMESPACE"
fi

# Check service exists
SVC_EXISTS=$(kubectl get service keyvault-api-service -n $NAMESPACE -o name 2>/dev/null)
if [ ! -z "$SVC_EXISTS" ]; then
    check_pass "Service 'keyvault-api-service' exists"
else
    check_fail "Service 'keyvault-api-service' not found" "Create service"
fi

# Check external IP
EXTERNAL_IP=$(kubectl get service keyvault-api-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ ! -z "$EXTERNAL_IP" ]; then
    check_pass "Service has external IP assigned"
    check_info "External IP: $EXTERNAL_IP"
else
    check_fail "Service does not have external IP" "Wait for LoadBalancer provisioning"
fi

echo ""

# Section 8: Functional Tests
echo -e "${BLUE}[8] Functional Testing${NC}"
echo ""

if [ ! -z "$EXTERNAL_IP" ]; then
    # Test API endpoint
    API_RESPONSE=$(curl -s http://$EXTERNAL_IP/ 2>/dev/null)

    if [ ! -z "$API_RESPONSE" ]; then
        check_pass "API is reachable"

        # Extract secret value from response
        API_SECRET=$(echo $API_RESPONSE | grep -o '"secretValue":"[^"]*"' | cut -d'"' -f4)

        if [ ! -z "$API_SECRET" ]; then
            check_pass "API returns secret value"
            check_info "API Secret: $API_SECRET"

            # Compare with Key Vault
            if [ "$API_SECRET" == "$SECRET_VALUE" ]; then
                check_pass "API secret matches Key Vault secret ✨"
            else
                check_fail "Secret value mismatch" "API: $API_SECRET, KV: $SECRET_VALUE"
            fi
        else
            check_fail "API response does not contain secret value" "Response: $API_RESPONSE"
        fi
    else
        check_fail "API is not reachable" "Check pod logs: kubectl logs -l app=keyvault-api -n $NAMESPACE"
    fi
else
    check_info "Skipping functional tests - no external IP available"
fi

echo ""

# Section 9: Security Checks
echo -e "${BLUE}[9] Security Verification${NC}"
echo ""

# Check no secrets in configmaps
CM_COUNT=$(kubectl get configmap -n $NAMESPACE 2>/dev/null | wc -l)
check_info "ConfigMaps in namespace: $((CM_COUNT - 1))"

# Check deployment env vars don't contain secrets
ENV_VARS=$(kubectl get deployment keyvault-api -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null)
if [[ ! "$ENV_VARS" =~ "SECRET" ]] && [[ ! "$ENV_VARS" =~ "KEY" ]] && [[ ! "$ENV_VARS" =~ "PASSWORD" ]]; then
    check_pass "No obvious secrets in environment variables"
else
    check_fail "Potential secrets in environment variables" "Review: $ENV_VARS"
fi

echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All checks passed! Azure Workload Identity is properly configured.${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some checks failed. Review the output above for details.${NC}"
    echo ""
    echo "Troubleshooting tips:"
    echo "1. Check pod logs: kubectl logs -l app=keyvault-api -n $NAMESPACE"
    echo "2. Describe pod: kubectl describe pod -l app=keyvault-api -n $NAMESPACE"
    echo "3. Check events: kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
    echo "4. Review the checklist: WORKLOAD_IDENTITY_CHECKLIST.md"
    exit 1
fi