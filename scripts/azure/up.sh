#!/bin/bash

############################################################################
#
#    Agno Azure Setup (first-time provisioning)
#
#    Usage:     ./scripts/azure/up.sh [--yes]
#    Redeploy:  ./scripts/azure/redeploy.sh
#    Sync env:  ./scripts/azure/env-sync.sh
#    Teardown:  ./scripts/azure/down.sh
#
#    Prerequisites:
#      - Azure CLI (az) installed and `az login` completed
#      - Docker running (image is built locally, linux/amd64)
#      - OPENAI_API_KEY set in environment (or .env / .env.production)
#
#    Provisions, in the resource group (default `agentos`, one group per
#    deployment — down.sh deletes the whole group):
#      VNet + delegated subnets → private DNS zone → ACR (+ local image
#      push) → PostgreSQL Flexible Server 17 (private access, pgvector
#      allowlisted) → Container Apps environment → the agent-os app at
#      2 vCPU / 4 Gi, min = max = 1 replica (the in-process scheduler must
#      not run twice). The app URL is only known after create, so a second
#      revision sets AGENTOS_URL and MCP_CONNECT_SECRET (chat-app OAuth,
#      generated into the env file when missing; JWT_VERIFICATION_KEY
#      rides along after the mint pause).
#
#    Overrides (env vars): AZURE_RESOURCE_GROUP (agentos),
#    AZURE_LOCATION (eastus). Generated once and persisted to the env
#    file: AZURE_ACR_NAME, AZURE_PG_NAME, DB_PASS, MCP_CONNECT_SECRET.
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${ORANGE}"
cat << 'BANNER'
     █████╗  ██████╗ ███╗   ██╗ ██████╗
    ██╔══██╗██╔════╝ ████╗  ██║██╔═══██╗
    ███████║██║  ███╗██╔██╗ ██║██║   ██║
    ██╔══██║██║   ██║██║╚██╗██║██║   ██║
    ██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝
    ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝
BANNER
echo -e "${NC}"

persist_env_var() {
    local key="$1" value="$2" file="$3" tmp
    if [[ -z "$file" ]]; then
        return
    fi
    [[ -f "$file" ]] || touch "$file"
    if grep -qE "^[#[:space:]]*${key}=" "$file"; then
        tmp="$(mktemp)"
        if sed -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$file" > "$tmp"; then
            cat "$tmp" > "$file"
        fi
        rm -f "$tmp"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

persist_multiline_env_var() {
    local key="$1" value="$2" file="$3" tmp line skipping=0 value_part
    if [[ -z "$file" ]]; then
        return
    fi
    if [[ ! -f "$file" ]]; then
        printf '%s="%s"\n' "$key" "$value" > "$file"
        return
    fi

    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$skipping" == 1 ]]; then
            [[ "$line" == *"-----END"* ]] && skipping=0
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            value_part="${line#*=}"
            if [[ "$value_part" == *"-----BEGIN"* && "$value_part" != *"-----END"* ]]; then
                skipping=1
            fi
            continue
        fi

        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

load_env_file() {
    local line current_key="" current_value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$current_key" ]]; then
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        fi

        if [[ -z "$current_key" ]]; then
            current_key="${line%%=*}"
            current_value="${line#*=}"
        else
            current_value="${current_value}
${line}"
        fi

        if [[ "$current_value" == *"-----BEGIN"* && "$current_value" != *"-----END"* ]]; then
            continue
        fi

        current_value="${current_value#\"}"
        current_value="${current_value%\"}"
        current_value="${current_value#\'}"
        current_value="${current_value%\'}"

        export "${current_key}=${current_value}"

        current_key=""
        current_value=""
    done < "$1"
}

capture_pasted_jwt_verification_key() {
    local line pasted="$1"

    pasted="${pasted#export JWT_VERIFICATION_KEY=}"
    pasted="${pasted#JWT_VERIFICATION_KEY=}"
    [[ "$pasted" != *"-----BEGIN"* ]] && return 1

    while [[ "$pasted" != *"-----END"* ]]; do
        if ! IFS= read -r line; then
            break
        fi
        pasted="${pasted}
${line}"
    done

    [[ "$pasted" != *"-----BEGIN"* || "$pasted" != *"-----END"* ]] && return 1

    pasted="${pasted#\"}"
    pasted="${pasted%\"}"
    pasted="${pasted#\'}"
    pasted="${pasted%\'}"

    JWT_VERIFICATION_KEY="$pasted"
    export JWT_VERIFICATION_KEY
}

ENV_FILE=""
[[ -f .env.production ]] && ENV_FILE=".env.production"
[[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"

if [[ -n "$ENV_FILE" ]]; then
    load_env_file "$ENV_FILE"
    echo -e "${DIM}Loaded ${ENV_FILE}${NC}"
fi

# Preflight
if ! command -v az &> /dev/null; then
    echo "Azure CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi
if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
    echo "Docker is required (the image is built locally). Start Docker and retry."
    exit 1
fi
if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "OPENAI_API_KEY not set. Add to .env (or .env.production) or export it."
    exit 1
fi
SUBSCRIPTION="$(az account show --query name -o tsv 2> /dev/null || true)"
if [[ -z "$SUBSCRIPTION" ]]; then
    echo "Not logged in to Azure. Run: az login"
    exit 1
fi

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-agentos}"
LOCATION="${AZURE_LOCATION:-eastus}"
APP_NAME="agent-os"
ENV_NAME="agentos-env"
VNET_NAME="agentos-vnet"

echo ""
echo -e "${BOLD}Deploying to subscription: ${SUBSCRIPTION}${NC}  ${DIM}(resource group ${RESOURCE_GROUP}, ${LOCATION})${NC}"
if [[ "$1" != "--yes" && -t 0 ]]; then
    printf "Continue? [y/N] "
    IFS= read -r GO
    if [[ "$GO" != "y" && "$GO" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Globally-unique names are minted once and persisted so re-runs reuse them.
if [[ -z "$AZURE_ACR_NAME" ]]; then
    AZURE_ACR_NAME="agentos$(openssl rand -hex 3)"
    ENV_FILE="${ENV_FILE:-.env.production}"
    persist_env_var AZURE_ACR_NAME "$AZURE_ACR_NAME" "$ENV_FILE"
fi
if [[ -z "$AZURE_PG_NAME" ]]; then
    AZURE_PG_NAME="agentos-db-$(openssl rand -hex 3)"
    ENV_FILE="${ENV_FILE:-.env.production}"
    persist_env_var AZURE_PG_NAME "$AZURE_PG_NAME" "$ENV_FILE"
fi
# Azure requires characters from 3 classes in the password — hex (lowercase
# + digits) is only 2, so derive from base64 for mixed case. Minted once:
# the server keeps the first password; regenerating would lock the app out.
if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    ENV_FILE="${ENV_FILE:-.env.production}"
    persist_env_var DB_PASS "$DB_PASS" "$ENV_FILE"
    echo -e "${DIM}Generated DB_PASS (saved to ${ENV_FILE})${NC}"
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Creating resource group${NC}"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Creating network (VNet + delegated subnets + private DNS)${NC}"
# Container Apps needs its own delegated infra subnet (/23 fits both env
# types); Flexible Server private access needs a subnet delegated to
# Microsoft.DBforPostgreSQL/flexibleServers and a private DNS zone — the
# CLI does not create any of these on its own.
az network vnet create --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" \
    --address-prefixes 10.0.0.0/16 --output none
az network vnet subnet create --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --name aca-infra --address-prefixes 10.0.0.0/23 \
    --delegations Microsoft.App/environments --output none
az network vnet subnet create --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --name db --address-prefixes 10.0.2.0/24 \
    --delegations Microsoft.DBforPostgreSQL/flexibleServers --output none
DNS_ZONE="agentos.private.postgres.database.azure.com"
az network private-dns zone create --resource-group "$RESOURCE_GROUP" \
    --name "$DNS_ZONE" --output none
az network private-dns link vnet create --resource-group "$RESOURCE_GROUP" \
    --zone-name "$DNS_ZONE" --name agentos-dns-link \
    --virtual-network "$VNET_NAME" --registration-enabled false --output none

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Creating container registry + pushing image${NC}"
az acr create --resource-group "$RESOURCE_GROUP" --name "$AZURE_ACR_NAME" \
    --sku Basic --admin-enabled true --output none
az acr login --name "$AZURE_ACR_NAME"
IMAGE="${AZURE_ACR_NAME}.azurecr.io/agentos:latest"
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Creating PostgreSQL Flexible Server (private, takes 5-10 min)${NC}"
DB_SUBNET_ID="$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name db --query id -o tsv)"
if ! az postgres flexible-server show --resource-group "$RESOURCE_GROUP" \
    --name "$AZURE_PG_NAME" &> /dev/null; then
    az postgres flexible-server create --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_PG_NAME" --location "$LOCATION" \
        --version 17 --tier Burstable --sku-name Standard_B1ms --storage-size 32 \
        --admin-user "${DB_USER:-ai}" --admin-password "$DB_PASS" \
        --database-name "${DB_DATABASE:-ai}" \
        --subnet "$DB_SUBNET_ID" --private-dns-zone "$DNS_ZONE" \
        --yes --output none
else
    echo -e "${DIM}Server ${AZURE_PG_NAME} already exists — reusing (password NOT rotated)${NC}"
fi
# pgvector must be allowlisted before CREATE EXTENSION works.
az postgres flexible-server parameter set --resource-group "$RESOURCE_GROUP" \
    --server-name "$AZURE_PG_NAME" --name azure.extensions --value VECTOR --output none
DB_FQDN="$(az postgres flexible-server show --resource-group "$RESOURCE_GROUP" \
    --name "$AZURE_PG_NAME" --query fullyQualifiedDomainName -o tsv)"

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Creating Container Apps environment (takes a few minutes)${NC}"
INFRA_SUBNET_ID="$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name aca-infra --query id -o tsv)"
if ! az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ENV_NAME" &> /dev/null; then
    az containerapp env create --resource-group "$RESOURCE_GROUP" --name "$ENV_NAME" \
        --location "$LOCATION" \
        --infrastructure-subnet-resource-id "$INFRA_SUBNET_ID" --output none
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Creating the agent-os app${NC}"
ACR_USER="$(az acr credential show --name "$AZURE_ACR_NAME" --query username -o tsv)"
ACR_PASS="$(az acr credential show --name "$AZURE_ACR_NAME" --query 'passwords[0].value' -o tsv)"

# Secret-shaped values ride Container Apps secrets; env vars reference them.
SECRET_ARGS=(openai-api-key="$OPENAI_API_KEY" db-pass="$DB_PASS")
ENV_ARGS=(
    "RUNTIME_ENV=${RUNTIME_ENV:-prd}"
    "WAIT_FOR_DB=True"
    "DB_HOST=${DB_FQDN}"
    "DB_PORT=5432"
    "DB_USER=${DB_USER:-ai}"
    "DB_DATABASE=${DB_DATABASE:-ai}"
    "DB_PASS=secretref:db-pass"
    "OPENAI_API_KEY=secretref:openai-api-key"
)
if [[ -n "$PARALLEL_API_KEY" ]]; then
    SECRET_ARGS+=(parallel-api-key="$PARALLEL_API_KEY")
    ENV_ARGS+=("PARALLEL_API_KEY=secretref:parallel-api-key")
fi
if [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_SIGNING_SECRET" ]]; then
    SECRET_ARGS+=(slack-bot-token="$SLACK_BOT_TOKEN" slack-signing-secret="$SLACK_SIGNING_SECRET")
    ENV_ARGS+=("SLACK_BOT_TOKEN=secretref:slack-bot-token" "SLACK_SIGNING_SECRET=secretref:slack-signing-secret")
fi

az containerapp create --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --environment "$ENV_NAME" --image "$IMAGE" \
    --registry-server "${AZURE_ACR_NAME}.azurecr.io" \
    --registry-username "$ACR_USER" --registry-password "$ACR_PASS" \
    --cpu 2 --memory 4Gi --min-replicas 1 --max-replicas 1 \
    --ingress external --target-port 8000 \
    --secrets "${SECRET_ARGS[@]}" \
    --env-vars "${ENV_ARGS[@]}" \
    --output none

APP_URL="https://$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --query properties.configuration.ingress.fqdn -o tsv)"

# The scheduler reaches AgentOS over its public URL; Container Apps only
# reveals the FQDN after create, so a second revision pins AGENTOS_URL.
if [[ -z "$AGENTOS_URL" ]]; then
    AGENTOS_URL="$APP_URL"
    persist_env_var AGENTOS_URL "$AGENTOS_URL" "$ENV_FILE"
fi

AUTH_REQUIRES_JWT=1
[[ "${RUNTIME_ENV:-prd}" == "dev" ]] && AUTH_REQUIRES_JWT=""

if [[ -n "$AUTH_REQUIRES_JWT" && -z "$JWT_VERIFICATION_KEY" && -z "$JWT_JWKS_FILE" && -t 0 ]]; then
    echo ""
    echo -e "${ORANGE}▸${NC} ${BOLD}JWT_VERIFICATION_KEY not set${NC} — AgentOS won't serve production traffic without auth."
    echo -e "  1. Open ${BOLD}https://os.agno.com${NC} -> Connect OS -> Live -> enter ${APP_URL}"
    echo -e "  2. Name it ${BOLD}Live AgentOS${NC}"
    echo -e "  3. Note: Live AgentOS Connections are a paid feature; use ${BOLD}PLATFORM30${NC} to get 1 month off"
    echo -e "  4. Go to Settings -> OS & Security -> turn ${BOLD}Token-Based Authorization (JWT)${NC} on"
    echo -e "  5. Copy the public key"
    echo -e "  6. Paste the full PEM block at the prompt below, or save it in ${ENV_FILE:-.env.production}"
    echo ""
    echo -e "  Paste JWT_VERIFICATION_KEY now, or press Enter after saving it:"
    JWT_INPUT=""
    IFS= read -r JWT_INPUT || true
    if [[ -n "$JWT_INPUT" ]]; then
        if capture_pasted_jwt_verification_key "$JWT_INPUT"; then
            ENV_FILE="${ENV_FILE:-.env.production}"
            persist_multiline_env_var JWT_VERIFICATION_KEY "$JWT_VERIFICATION_KEY" "$ENV_FILE"
            echo -e "${DIM}  Saved JWT_VERIFICATION_KEY to ${ENV_FILE}${NC}"
        else
            echo -e "${BOLD}Warning:${NC} couldn't parse the pasted JWT_VERIFICATION_KEY."
            echo -e "${DIM}  Save it to ${ENV_FILE:-.env.production} and run ./scripts/azure/env-sync.sh if auth is still missing.${NC}"
        fi
    fi
    [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] && load_env_file "$ENV_FILE"
fi

# MCP OAuth — claude.ai and ChatGPT (web) connect over OAuth only, and the
# consent page is gated by MCP_CONNECT_SECRET, so the user must create the secret manually.
# We generate a secret on behalf of the user when the env file doesn't have one
if [[ -z "$MCP_CONNECT_SECRET" && -n "$APP_URL" ]]; then
    MCP_CONNECT_SECRET="$(openssl rand -base64 32)"
    export MCP_CONNECT_SECRET
    ENV_FILE="${ENV_FILE:-.env.production}"
    persist_env_var MCP_CONNECT_SECRET "$MCP_CONNECT_SECRET" "$ENV_FILE"
    echo -e "${DIM}Generated MCP_CONNECT_SECRET -> ${ENV_FILE} + Container Apps (shown in the summary below)${NC}"
fi

# Revision 2: AGENTOS_URL (+ MCP connect secret and JWT key if present) — one revision roll.
REV2_ENVS=("AGENTOS_URL=${AGENTOS_URL}")
if [[ -n "$JWT_VERIFICATION_KEY" ]]; then
    az containerapp secret set --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
        --secrets jwt-verification-key="$JWT_VERIFICATION_KEY" --output none
    REV2_ENVS+=("JWT_VERIFICATION_KEY=secretref:jwt-verification-key")
elif [[ -n "$JWT_JWKS_FILE" ]]; then
    REV2_ENVS+=("JWT_JWKS_FILE=${JWT_JWKS_FILE}")
elif [[ -n "$AUTH_REQUIRES_JWT" ]]; then
    echo ""
    echo -e "${DIM}Deployed without JWT auth config — the app will refuse traffic until${NC}"
    echo -e "${DIM}you add JWT_VERIFICATION_KEY or JWT_JWKS_FILE to ${ENV_FILE:-.env.production} and run ./scripts/azure/env-sync.sh.${NC}"
fi
if [[ -n "$MCP_CONNECT_SECRET" ]]; then
    az containerapp secret set --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
        --secrets mcp-connect-secret="$MCP_CONNECT_SECRET" --output none
    REV2_ENVS+=("MCP_CONNECT_SECRET=secretref:mcp-connect-secret")
fi
az containerapp update --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --set-env-vars "${REV2_ENVS[@]}" --output none

echo ""
echo -e "${BOLD}Done.${NC} Give the revision a couple of minutes to converge."
echo -e "${DIM}URL:            ${APP_URL}  (docs at /docs, MCP at /mcp)${NC}"
echo -e "${DIM}Logs:           az containerapp logs show -g ${RESOURCE_GROUP} -n ${APP_NAME} --follow${NC}"
echo -e "${DIM}Sync env vars:  ./scripts/azure/env-sync.sh${NC}"
[[ -n "$APP_URL" ]] && echo -e "${DIM}Connect apps:   uvx agno connect --url ${APP_URL}${NC}"
if [[ -n "$APP_URL" && -n "$MCP_CONNECT_SECRET" ]]; then
    echo -e "${DIM}Chat apps:      add ${APP_URL}/mcp as a custom connector in claude.ai / ChatGPT${NC}"
    echo -e "${DIM}                (leave the optional OAuth client ID/secret fields empty).${NC}"
    echo -e "${DIM}                Then click Connect and approve the consent page with this secret:${NC}"
    echo -e "${BOLD}                ${MCP_CONNECT_SECRET}${NC}"
fi
echo -e "${DIM}Teardown:       ./scripts/azure/down.sh  (deletes the whole resource group)${NC}"
echo ""
