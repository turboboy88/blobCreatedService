#!/usr/bin/env bash
set -euo pipefail

# =============================================
# Azure Functions (Python, Linux) + Event Grid
# One-click deployment script
# ---------------------------------------------
# USAGE:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Override values via env or .env:
#   RG=blob-func-rg LOC=westeurope RUNTIME_VERSION=3.10 ./deploy.sh
#   SA_NAME=myuniquestorage APP_NAME=my-func-app-123 FUNC_NAME=BlobCreatedHandler ./deploy.sh
#   CONTAINER_NAME=incoming-files ./deploy.sh
#   SUB_ID=<subscription-id> ./deploy.sh
#
# Use a custom env file:
#   ENV_FILE=deploy.env ./deploy.sh   # defaults to ./.env
#
# Requirements: Azure CLI (az), Azure Functions Core Tools (func), active subscription (az login).
# =============================================

# -------- Load environment variables from file (if present) --------
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then
  echo "Loading environment from '$ENV_FILE' ..."
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  echo "No env file found at '$ENV_FILE' (this is fine)."
fi

# -------- Defaults (can be overridden via env/.env) --------
RG="${RG:-blob-func-rg}"
LOC="${LOC:-westeurope}"
RUNTIME_VERSION="${RUNTIME_VERSION:-3.10}"     # 3.10 or 3.11
FUNC_NAME="${FUNC_NAME:-BlobCreatedHandler}"   # must match function name in code

# Unique suffix for resource names
SUFFIX="${SUFFIX:-$RANDOM$RANDOM}"

# Storage Account name: 3-24, lowercase letters/numbers only
SA_PREFIX="${SA_PREFIX:-blobfunc}"
SA_NAME="${SA_NAME:-${SA_PREFIX}${SUFFIX}}"
SA_NAME="$(echo "$SA_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z]//g' | cut -c1-24)"

# Function App name: up to ~60, [a-z0-9-]
APP_PREFIX="${APP_PREFIX:-blobcreated-func-}"
APP_NAME="${APP_NAME:-${APP_PREFIX}${SUFFIX}}"
APP_NAME="$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z-]//g' | cut -c1-60)"

# Event Grid subscription name
EG_SUB_NAME="${EG_SUB_NAME:-blobcreated-subscription}"

# Blob container name: 3-63, [a-z0-9-], no leading/trailing hyphen, no consecutive hyphens
CONTAINER_NAME="${CONTAINER_NAME:-incoming-blobs}"
CONTAINER_NAME="$(echo "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z-]//g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//' | cut -c1-63)"
if [ -z "$CONTAINER_NAME" ] || [ "${#CONTAINER_NAME}" -lt 3 ]; then
  echo "Container name invalid after sanitization. Falling back to 'incoming-blobs'."
  CONTAINER_NAME="incoming-blobs"
fi

# -------- Tooling checks --------
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Install and run 'az login'."; exit 1; }
command -v func >/dev/null 2>&1 || { echo "ERROR: Azure Functions Core Tools (func) not found."; exit 1; }

# -------- Subscription detection --------
SUB_ID="${SUB_ID:-$(az account show --query id -o tsv 2>/dev/null || true)}"
if [ -z "${SUB_ID:-}" ]; then
  echo "ERROR: No active subscription detected. Run 'az login' and 'az account set --subscription <ID/Name>'."
  exit 1
fi

echo "Using subscription: $SUB_ID"
echo "Resource Group:     $RG"
echo "Location:           $LOC"
echo "Storage Account:    $SA_NAME"
echo "Function App:       $APP_NAME"
echo "Function Name:      $FUNC_NAME"
echo "EventGrid Sub:      $EG_SUB_NAME"
echo "Blob Container:     $CONTAINER_NAME"
echo

# -------- Register resource providers (with wait) --------
register_provider() {
  local NS="$1"
  echo "Registering provider: $NS"
  az provider register --namespace "$NS" --subscription "$SUB_ID" >/dev/null 2>&1 || true

  # Wait until registration completes (max ~100s)
  for _ in {1..20}; do
    local STATE
    STATE="$(az provider show --namespace "$NS" --subscription "$SUB_ID" --query registrationState -o tsv 2>/dev/null || echo "Unknown")"
    echo "  $NS => $STATE"
    [ "$STATE" = "Registered" ] && break
    sleep 5
  done
}

for NS in Microsoft.Web Microsoft.Storage Microsoft.EventGrid Microsoft.Insights; do
  register_provider "$NS"
done

# -------- Create Resource Group --------
echo "Creating resource group..."
az group create --name "$RG" --location "$LOC" --subscription "$SUB_ID" -o none

# -------- Create Storage Account --------
echo "Creating storage account: $SA_NAME ..."
az storage account create \
  --name "$SA_NAME" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --subscription "$SUB_ID" -o none

# -------- Enable Blob Versioning on the Storage Account --------
echo "Enabling Blob Versioning on storage account: $SA_NAME ..."
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG" \
  --enable-versioning true \
  --subscription "$SUB_ID" -o none

# -------- Create a dedicated Blob Container --------
echo "Creating blob container: $CONTAINER_NAME ..."
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$SA_NAME" \
  --auth-mode login \
  --subscription "$SUB_ID" -o none

# -------- Create Linux Function App (Consumption) --------
echo "Creating Linux Function App: $APP_NAME ..."
az functionapp create \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --consumption-plan-location "$LOC" \
  --runtime python \
  --runtime-version "$RUNTIME_VERSION" \
  --functions-version 4 \
  --storage-account "$SA_NAME" \
  --os-type Linux \
  --subscription "$SUB_ID" -o none


# -------- Enable system-assigned managed identity --------
PRINCIPAL_ID=$(az functionapp identity assign \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --query principalId -o tsv)

# -------- Get the storage account resource scope (ID) --------
SA_ID=$(az storage account show \
  --name "$SA_NAME" \
  --resource-group "$RG" \
  --query id -o tsv)

# -------- Assign a role on the storage account (to read metadata and versions) --------
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope "$SA_ID"

# -------- Publish function code from current directory --------
echo "Publishing function code to $APP_NAME ..."
func azure functionapp publish "$APP_NAME"

echo "Creating Event Grid subscription to BlobCreated (Azure Function endpoint) ..."
SA_ID=$(
  az resource show \
    --resource-group "$RG" \
    --name "$SA_NAME" \
    --resource-type Microsoft.Storage/storageAccounts \
    --api-version 2025-06-01 \
    --query id -o tsv
)
FUNC_RES_ID="/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/${APP_NAME}/functions/${FUNC_NAME}"

az eventgrid event-subscription create \
  --name "$EG_SUB_NAME" \
  --source-resource-id "$SA_ID" \
  --endpoint-type azurefunction \
  --endpoint "$FUNC_RES_ID" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subscription "$SUB_ID" -o none

echo
echo "============================================="
echo "Deployment completed successfully!"
echo "Function App:        $APP_NAME"
echo "Resource Group:      $RG"
echo "Storage Account:     $SA_NAME"
echo "Blob Container:      $CONTAINER_NAME"
echo "Location:            $LOC"
echo "EventGrid Sub:       $EG_SUB_NAME"
