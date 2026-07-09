#!/bin/bash

############################################################################
#
#    Agno Azure Redeploy
#
#    Usage: ./scripts/azure/redeploy.sh
#
#    Rebuilds the image locally (linux/amd64), pushes it to the ACR
#    created by up.sh, and rolls the agent-os container app to it with a
#    fresh revision suffix (same tag, so the roll must be forced).
#
#    Overrides (env vars): AZURE_RESOURCE_GROUP (agentos); AZURE_ACR_NAME
#    is read from the env file where up.sh persisted it.
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-agentos}"
APP_NAME="agent-os"

if ! command -v az &> /dev/null; then
    echo "Azure CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi
if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
    echo "Docker is required (the image is built locally). Start Docker and retry."
    exit 1
fi

# AZURE_ACR_NAME lives in the env file (persisted by up.sh).
if [[ -z "$AZURE_ACR_NAME" ]]; then
    for f in .env.production .env; do
        if [[ -f "$f" ]]; then
            AZURE_ACR_NAME="$(sed -nE 's/^AZURE_ACR_NAME=(.*)$/\1/p' "$f" | head -1)"
            [[ -n "$AZURE_ACR_NAME" ]] && break
        fi
    done
fi
if [[ -z "$AZURE_ACR_NAME" ]]; then
    echo "AZURE_ACR_NAME not found (env or env file). Run ./scripts/azure/up.sh first."
    exit 1
fi

if ! az containerapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" &> /dev/null; then
    echo "Container app '${APP_NAME}' not found in resource group '${RESOURCE_GROUP}'. Run ./scripts/azure/up.sh first."
    exit 1
fi

IMAGE="${AZURE_ACR_NAME}.azurecr.io/agentos:latest"

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Building + pushing image${NC}"
echo ""
echo -e "${DIM}> docker build --platform linux/amd64 -t ${IMAGE} . && docker push ${IMAGE}${NC}"
az acr login --name "$AZURE_ACR_NAME"
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Rolling ${APP_NAME}${NC}"
echo ""
echo -e "${DIM}> az containerapp update -g ${RESOURCE_GROUP} -n ${APP_NAME} --image ${IMAGE}${NC}"
# Same tag ⇒ force a new revision so the platform re-pulls the image.
az containerapp update --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --image "$IMAGE" --revision-suffix "r$(date +%s)" --output none

echo ""
echo -e "${BOLD}Done.${NC}"
echo -e "${DIM}Logs: az containerapp logs show -g ${RESOURCE_GROUP} -n ${APP_NAME} --follow${NC}"
echo ""
