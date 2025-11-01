#!/bin/bash

set -e

# Variables
RESOURCE_GROUP="rg-appointment"
ACR_NAME="acr$(openssl rand -hex 3)"  # Random suffix to ensure uniqueness
AKS_CLUSTER_NAME="aks-appointment"
IMAGE_NAME="test-keyvault-api"
IMAGE_TAG="v1"
NAMESPACE="nsp-appointment"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Build and Deploy Application${NC}"
echo -e "${BLUE}========================================${NC}"

# Step 1: Create Azure Container Registry (Basic tier - lowest cost)
echo -e "\n${GREEN}Step 1: Creating Azure Container Registry (Basic tier)...${NC}"
az acr create \
    --resource-group $RESOURCE_GROUP \
    --name $ACR_NAME \
    --sku Basic

# Get ACR login server
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer -o tsv)
echo "ACR Login Server: $ACR_LOGIN_SERVER"

# Step 2: Build Docker image with ACR
echo -e "\n${GREEN}Step 2: Building Docker image...${NC}"
cd test_azure_keyvault_api
az acr build --registry $ACR_NAME --image ${IMAGE_NAME}:${IMAGE_TAG} .
cd ..

# Step 3: Attach ACR to AKS (grants AKS permission to pull images)
echo -e "\n${GREEN}Step 3: Attaching ACR to AKS...${NC}"
az aks update \
    --resource-group $RESOURCE_GROUP \
    --name $AKS_CLUSTER_NAME \
    --attach-acr $ACR_NAME

# Step 4: Update deployment.yaml with actual image name
echo -e "\n${GREEN}Step 4: Updating deployment manifest...${NC}"
FULL_IMAGE_NAME="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
sed "s|<YOUR_CONTAINER_REGISTRY>/test-keyvault-api:v1|${FULL_IMAGE_NAME}|g" k8s/deployment.yaml > k8s/deployment-updated.yaml

# Step 5: Deploy to Kubernetes
echo -e "\n${GREEN}Step 5: Deploying to AKS...${NC}"
kubectl apply -f k8s/deployment-updated.yaml

# Wait for deployment to be ready
echo -e "\n${GREEN}Waiting for deployment to be ready...${NC}"
kubectl wait --for=condition=available --timeout=180s deployment/keyvault-api -n $NAMESPACE

# Get service external IP
echo -e "\n${YELLOW}Waiting for LoadBalancer external IP (this may take 2-3 minutes)...${NC}"
echo "You can check status with: kubectl get service keyvault-api-service -n $NAMESPACE"

# Try to get external IP (with timeout)
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get service keyvault-api-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ ! -z "$EXTERNAL_IP" ]; then
        break
    fi
    echo "Waiting for external IP... ($i/30)"
    sleep 10
done

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${GREEN}Deployment Information:${NC}"
echo "ACR Name: $ACR_NAME"
echo "Image: $FULL_IMAGE_NAME"
echo "Namespace: $NAMESPACE"

if [ ! -z "$EXTERNAL_IP" ]; then
    echo "External IP: $EXTERNAL_IP"
    echo -e "\n${GREEN}Test your API:${NC}"
    echo "curl http://$EXTERNAL_IP/"
    echo "curl http://$EXTERNAL_IP/users"
else
    echo -e "\n${YELLOW}External IP not yet assigned. Check with:${NC}"
    echo "kubectl get service keyvault-api-service -n $NAMESPACE"
fi

echo -e "\n${GREEN}View pod logs:${NC}"
echo "kubectl logs -l app=keyvault-api -n $NAMESPACE -f"

echo -e "\n${GREEN}View pod details:${NC}"
echo "kubectl get pods -n $NAMESPACE"
echo "kubectl describe pod -l app=keyvault-api -n $NAMESPACE"