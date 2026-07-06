#!/bin/bash

############################################################################
#
#    Agno Azure Environment Sync
#
#    Usage:
#      ./scripts/azure/env-sync.sh             # syncs .env.production
#      ./scripts/azure/env-sync.sh .env        # syncs .env instead
#
#    Reads the env file and pushes every variable to the agent-os
#    container app: secret-shaped keys (OPENAI_API_KEY, DB_PASS,
#    JWT_VERIFICATION_KEY, PARALLEL_API_KEY, SLACK_*) become Container
#    Apps secrets with secretref env vars; everything else becomes a plain
#    env var. One revision roll at the end applies it all. Multi-line
#    values (PEM-formatted JWT_VERIFICATION_KEY) are handled correctly.
#
#    Skipped keys: AZURE_* (provisioning config, not app env) and DB_HOST/
#    DB_PORT/DB_USER/DB_DATABASE when absent (up.sh wired them already).
#
#    Overrides (env vars): AZURE_RESOURCE_GROUP (agentos)
#
############################################################################

set -e

# Colors
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ENV_FILE="${1:-.env.production}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-agentos}"
APP_NAME="agent-os"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "File not found: $ENV_FILE"
    echo "Usage: $0 [path/to/env] (default: .env.production)"
    exit 1
fi

if ! command -v az &> /dev/null; then
    echo "Azure CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

if ! az containerapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" &> /dev/null; then
    echo "Container app '${APP_NAME}' not found in resource group '${RESOURCE_GROUP}'. Run ./scripts/azure/up.sh first."
    exit 1
fi

# Container Apps secret names: lowercase alphanumerics and dashes.
secret_name_for() {
    printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-'
}

is_secret_key() {
    case "$1" in
        OPENAI_API_KEY|DB_PASS|JWT_VERIFICATION_KEY|PARALLEL_API_KEY|SLACK_BOT_TOKEN|SLACK_SIGNING_SECRET) return 0 ;;
        *) return 1 ;;
    esac
}

echo ""
echo -e "${BOLD}Syncing env vars from ${ENV_FILE} to ${APP_NAME} (resource group ${RESOURCE_GROUP})...${NC}"
echo ""

SECRET_ARGS=()
ENV_ARGS=()
count=0
current_key=""
current_value=""

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

    case "$current_key" in
        AZURE_*)
            # Provisioning config for the scripts, not app environment.
            ;;
        *)
            if is_secret_key "$current_key"; then
                SECRET_ARGS+=("$(secret_name_for "$current_key")=${current_value}")
                ENV_ARGS+=("${current_key}=secretref:$(secret_name_for "$current_key")")
            else
                ENV_ARGS+=("${current_key}=${current_value}")
            fi
            echo -e "${DIM}  Setting ${current_key}${NC}"
            count=$((count + 1))
            ;;
    esac

    current_key=""
    current_value=""
done < "$ENV_FILE"

if [[ "${#SECRET_ARGS[@]}" -gt 0 ]]; then
    az containerapp secret set --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
        --secrets "${SECRET_ARGS[@]}" --output none
fi
# Secret updates alone don't roll the running revision; the env-var update
# below creates a new revision that picks everything up.
az containerapp update --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --set-env-vars "${ENV_ARGS[@]}" --output none

echo ""
echo -e "${BOLD}Done.${NC} Synced ${count} variable(s); a new revision is rolling out."
echo ""
