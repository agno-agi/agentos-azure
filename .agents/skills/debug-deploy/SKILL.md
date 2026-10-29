---
name: debug-deploy
description: Diagnose and recover a failed or unhealthy Azure deployment of this AgentOS — provider registration, region restrictions, PostgreSQL create errors, partial reruns, stale secrets, JWT startup failures, and unhealthy revisions. Use when ./scripts/azure/up.sh, redeploy.sh, env-sync.sh or down.sh fails, or the deployed app does not come up.
---

# Debug an Azure Deployment

Read `scripts/azure/` and the README deployment section first. Find the failing
command and its exact error before changing anything. Never print credentials,
`DB_PASS`, `MCP_CONNECT_SECRET`, or bearer tokens. Ask before deleting resources,
re-creating a database, or running `down.sh`; it deletes the whole resource group
and all database data.

## 1. Establish the state

```sh
az account show --query "{name:name, id:id}" -o table
az group show -n "${AZURE_RESOURCE_GROUP:-agentos}" --query "{location:location, state:properties.provisioningState}" -o table
az resource list -g "${AZURE_RESOURCE_GROUP:-agentos}" --query "[].{type:type, name:name, state:provisioningState}" -o table
```

Confirm the subscription, resource group, and region are the ones the user meant.
An authentication or network error does not mean resources are absent. If a
resource shows `Creating`, `Updating`, or `Dropping`, wait for it to settle; do not
rerun the script on top of it.

Only `up.sh` reads `AZURE_*` values from `.env.production` / `.env`. `down.sh`,
`redeploy.sh`, and `env-sync.sh` read `AZURE_RESOURCE_GROUP` from the shell. If the
user set a custom group only in the env file, export it before running those
scripts, or they act on the default `agentos` group.

## 2. Match the error

| Symptom | Cause | Fix |
| --- | --- | --- |
| `MissingSubscriptionRegistration`, or "not registered to use namespace" | Resource provider not registered on a new subscription | Run `az provider register --namespace <ns> --wait` for each of `Microsoft.Network`, `Microsoft.ContainerRegistry`, `Microsoft.DBforPostgreSQL`, `Microsoft.App`, `Microsoft.OperationalInsights`, then rerun `up.sh`. |
| PostgreSQL create fails with "location is restricted" or a quota/offer error | The subscription cannot create Flexible Servers in that region | Check `az postgres flexible-server list-skus --location <region> --query "[0].supportedFeatures[?name=='OfferRestricted'].status" -o tsv`. If `Enabled`, choose another region. A resource group's region cannot change: use a new `AZURE_RESOURCE_GROUP` with the new `AZURE_LOCATION`, or remove the old group with the user's approval. |
| `--version 18` rejected | Old Azure CLI or region without PostgreSQL 18 | Run `az upgrade`, confirm `az postgres flexible-server create -h` lists 18, and check the region's supported versions. |
| PostgreSQL create fails in `getPrivateDnsZoneSuffix` | Azure CLI bug when the private DNS zone already exists | Upgrade the CLI and retry. If it persists, create the server through ARM with explicit IDs: write the request body to a temp file (keep `DB_PASS` out of command arguments, delete the file afterwards) with `version: "18"`, `Standard_B1ms`/`Burstable`, 32 GB storage, `publicNetworkAccess: Disabled`, the `db` subnet ID, and the zone ID from `az network private-dns zone show`, then `az resource create --resource-type Microsoft.DBforPostgreSQL/flexibleServers --is-full-object --properties @<file>`. Create the `ai` database and rerun `up.sh`. |
| Rerun fails on a resource that already exists (VNet, subnet, DNS zone/link, ACR, Container App) | `up.sh` creates those without checking first | Do not delete anything to get past it. List what exists, then either finish the remaining steps manually with the same names, or, with approval, run `down.sh` and deploy fresh. Keep `AZURE_ACR_NAME`, `AZURE_PG_NAME`, and `DB_PASS` in the env file for the same deployment. |
| `az group create` fails with "already exists in location" | `AZURE_LOCATION` changed after the group was created | Use the group's original region or a new group name. |
| Existing server stays on PostgreSQL 17 | `up.sh` reuses an existing server as-is | Expected. A major-version upgrade is a separate, approved operation with a backup plan. |
| Secret changed, app still uses the old value | Updating a secret does not roll the running revision when env references are unchanged | `az containerapp revision restart -g <group> -n agent-os --revision <latest>` or `az containerapp update -g <group> -n agent-os --revision-suffix env$(date +%s)`. |
| App exits on startup mentioning JWT | Missing key, or the wrong value pasted at the prompt | Paste the full **PUBLIC KEY** PEM with its BEGIN/END lines, not the USER JWT TOKEN or SECURITY KEY. Save it as a quoted multiline `JWT_VERIFICATION_KEY` and run `./scripts/azure/env-sync.sh`. Never disable auth to pass the health check. |
| Docker or `az acr login` fails | Daemon not running, or not signed in | Start Docker; run `az login` in the user's terminal. |

## 3. Check the app

```sh
az containerapp revision list -g <group> -n agent-os --query "[].{name:name, active:properties.active, health:properties.healthState, running:properties.runningState, traffic:properties.trafficWeight}" -o table
az containerapp logs show -g <group> -n agent-os --type system --tail 50
az containerapp logs show -g <group> -n agent-os --type console --tail 100
```

The latest revision must be healthy and receive traffic. Database connection
errors usually mean wrong `DB_*` values or a server still provisioning; a missing
`vector` extension means the `azure.extensions` allowlist step did not run.

## 4. Report

State the root cause, what you changed, and what is still unverified. Then hand
back to [deploy-platform](../deploy-platform/SKILL.md) for verification: `/health`
succeeds, unauthenticated `/agents` is rejected, and the UI connects.
