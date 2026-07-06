#!/bin/bash

############################################################################
#
#    Agno Azure Teardown
#
#    Usage:
#      ./scripts/azure/down.sh          # asks before destroying
#      ./scripts/azure/down.sh --yes    # no prompt (CI / automation)
#
#    Deletes the ENTIRE resource group created by up.sh — container app,
#    environment, Postgres (ALL DATA), ACR, VNet, DNS zone, everything in
#    it. up.sh creates a dedicated group (default `agentos`) precisely so
#    teardown is this complete. If you pointed AZURE_RESOURCE_GROUP at a
#    shared group, the resource listing below is your last chance to stop.
#
#    Overrides (env vars): AZURE_RESOURCE_GROUP (agentos)
#
############################################################################

set -e

# Colors
DIM='\033[2m'
BOLD='\033[1m'
RED='\033[31m'
NC='\033[0m'

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-agentos}"

# Preflight
if ! command -v az &> /dev/null; then
    echo "Azure CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi
SUBSCRIPTION="$(az account show --query name -o tsv 2> /dev/null || true)"
if [[ -z "$SUBSCRIPTION" ]]; then
    echo "Not logged in to Azure. Run: az login"
    exit 1
fi
if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
    echo "Resource group '${RESOURCE_GROUP}' doesn't exist (subscription '${SUBSCRIPTION}') — nothing to tear down."
    exit 1
fi

echo ""
echo -e "${BOLD}This deletes resource group ${RESOURCE_GROUP} (subscription ${SUBSCRIPTION}) and EVERYTHING in it:${NC}"
az resource list --resource-group "$RESOURCE_GROUP" --query '[].{name:name, type:type}' -o table
echo -e "  ${RED}including the Postgres server — all data deleted${NC}"
echo ""

if [[ "$1" != "--yes" ]]; then
    printf "Type the resource group name (%s) to confirm: " "$RESOURCE_GROUP"
    IFS= read -r CONFIRM
    if [[ "$CONFIRM" != "$RESOURCE_GROUP" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""
echo -e "${BOLD}Deleting ${RESOURCE_GROUP} (takes several minutes)...${NC}"
az group delete --name "$RESOURCE_GROUP" --yes --output none

# `az group delete` blocks until done, but verify rather than trust the
# exit code — a token expiry mid-delete would otherwise read as success.
if [[ "$(az group exists --name "$RESOURCE_GROUP")" == "true" ]]; then
    echo ""
    echo -e "${BOLD}Teardown incomplete${NC} — the group still exists. Check:"
    echo -e "${DIM}  az group show --name ${RESOURCE_GROUP}${NC}"
    exit 1
fi

echo ""
echo -e "${BOLD}Done.${NC} Resource group confirmed gone. Verify anytime with: az group list -o table"
echo ""
