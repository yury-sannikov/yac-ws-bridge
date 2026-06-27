#!/usr/bin/env bash
#
# Deploy Home Assistant WebSocket relay to Yandex Cloud
#
# Prerequisites:
#   - yc CLI configured and authenticated
#   - jq installed
#   - javascript-obfuscator installed (npm i -g javascript-obfuscator) — optional
#
# Usage:
#   ./deploy-yandex.sh              # full deploy (SA + function + API gateway)
#   ./deploy-yandex.sh function     # redeploy function only
#   ./deploy-yandex.sh spec         # update API gateway spec only
#
# Auth token is auto-generated on first run and saved to deploy/.secret.
# Override: export YAC_BRIDGE_SECRET="custom-token"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLOUD_DIR="$SCRIPT_DIR/bridge-cloud"

# --- Configuration ---
# All values are loaded from deploy/.env (gitignored).
# See deploy/.env.example for reference.
ENV_FILE="$SCRIPT_DIR/deploy/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

FOLDER_ID="${YC_FOLDER_ID:?Set YC_FOLDER_ID in deploy/.env}"
AGW_ID="${YAC_AGW_ID:?Set YAC_AGW_ID in deploy/.env}"
FUNCTION_NAME="${YAC_FUNCTION_NAME:-hass-ws-relay}"
SA_NAME="${YAC_SA_NAME:-hass-relay-sa}"
POD_IP="${POD_IP:?Set POD_IP in deploy/.env}"
POD_PORT="${POD_PORT:-3001}"
AGW_DOMAIN="${AGW_DOMAIN:?Set AGW_DOMAIN in deploy/.env}"

# Shared auth token
SECRET_FILE="$SCRIPT_DIR/deploy/.secret"
if [[ -n "${YAC_BRIDGE_SECRET:-}" ]]; then
    BRIDGE_SECRET="$YAC_BRIDGE_SECRET"
elif [[ -f "$SECRET_FILE" ]]; then
    BRIDGE_SECRET="$(cat "$SECRET_FILE")"
else
    BRIDGE_SECRET=""
fi

ORIGIN_BASE="${YAC_ORIGIN_BASE:?Set YAC_ORIGIN_BASE in deploy/.env}"

# --- Helpers ---
info()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
error() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

check_secret() {
    if [[ -z "$BRIDGE_SECRET" ]]; then
        info "No token found. Generating..."
        BRIDGE_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
        echo -n "$BRIDGE_SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        info "Token saved to deploy/.secret"
        echo ""
        echo "  TOKEN=$BRIDGE_SECRET"
        echo ""
    fi
}

# --- Service Account ---
ensure_service_account() {
    info "Ensuring service account: $SA_NAME"

    SA_ID=$(yc iam service-account list --format json | jq -r ".[] | select(.name==\"$SA_NAME\") | .id")

    if [[ -z "$SA_ID" ]]; then
        info "Creating service account..."
        yc iam service-account create --name "$SA_NAME" --description "HA relay service account"
        SA_ID=$(yc iam service-account get "$SA_NAME" --format json | jq -r .id)

        info "Granting roles..."
        yc resource-manager folder add-access-binding "$FOLDER_ID" \
            --role serverless.functions.invoker \
            --subject "serviceAccount:$SA_ID"

        yc resource-manager folder add-access-binding "$FOLDER_ID" \
            --role api-gateway.websocketBroadcaster \
            --subject "serviceAccount:$SA_ID"
    fi

    echo "  SA_ID=$SA_ID"
}

# --- Cloud Function ---
deploy_function() {
    check_secret
    info "Deploying function: $FUNCTION_NAME"

    FUNCTION_ID=$(yc serverless function list --format json | jq -r ".[] | select(.name==\"$FUNCTION_NAME\") | .id")

    if [[ -z "$FUNCTION_ID" ]]; then
        info "Creating function..."
        yc serverless function create --name "$FUNCTION_NAME" --description "HA WebSocket relay"
        FUNCTION_ID=$(yc serverless function get "$FUNCTION_NAME" --format json | jq -r .id)
    fi

    echo "  FUNCTION_ID=$FUNCTION_ID"

    info "Packaging..."
    TMPZIP=$(mktemp /tmp/bridge-fn-XXXXXX.zip)
    rm -f "$TMPZIP"
    trap "rm -f $TMPZIP" EXIT

    if command -v javascript-obfuscator &>/dev/null; then
        info "Obfuscating..."
        TMPDIR_OBF=$(mktemp -d /tmp/bridge-obf-XXXXXX)
        javascript-obfuscator "$CLOUD_DIR/index.js" \
            --output "$TMPDIR_OBF/index.js" \
            --compact true \
            --string-array true \
            --string-array-encoding base64 \
            --dead-code-injection false \
            --self-defending false
        cp "$CLOUD_DIR/package.json" "$TMPDIR_OBF/"
        (cd "$TMPDIR_OBF" && zip -q "$TMPZIP" index.js package.json)
        rm -rf "$TMPDIR_OBF"
    else
        info "javascript-obfuscator not found, deploying plain"
        (cd "$CLOUD_DIR" && zip -q "$TMPZIP" index.js package.json)
    fi

    info "Creating version..."
    yc serverless function version create \
        --function-name "$FUNCTION_NAME" \
        --runtime nodejs18 \
        --entrypoint index.handler \
        --memory 128m \
        --execution-timeout 10s \
        --concurrency 4 \
        --source-path "$TMPZIP" \
        --service-account-id "$SA_ID" \
        --environment "HASS_RELAY_SECRET=$BRIDGE_SECRET,HA_ORIGIN_BASE=$ORIGIN_BASE"

    info "Function deployed: $FUNCTION_ID"
}

# --- API Gateway ---
update_agw_spec() {
    info "Updating API gateway: $AGW_ID"

    if [[ -z "${SA_ID:-}" ]]; then
        SA_ID=$(yc iam service-account get "$SA_NAME" --format json | jq -r .id)
    fi
    if [[ -z "${FUNCTION_ID:-}" ]]; then
        FUNCTION_ID=$(yc serverless function get "$FUNCTION_NAME" --format json | jq -r .id)
    fi

    if [[ -z "$SA_ID" || -z "$FUNCTION_ID" ]]; then
        error "Cannot resolve SA_ID or FUNCTION_ID. Run full deploy first."
    fi

    info "  SA_ID=$SA_ID"
    info "  FUNCTION_ID=$FUNCTION_ID"

    SPEC_FILE=$(mktemp /tmp/agw-spec-XXXXXX.yaml)
    trap "rm -f $SPEC_FILE" EXIT

    sed -e "s|\${FUNCTION_ID}|$FUNCTION_ID|g" \
        -e "s|\${SERVICE_ACCOUNT_ID}|$SA_ID|g" \
        -e "s|\${POD_IP}|$POD_IP|g" \
        -e "s|\${POD_PORT}|$POD_PORT|g" \
        -e "s|\${AGW_DOMAIN}|$AGW_DOMAIN|g" \
        "$SCRIPT_DIR/deploy/agw-spec.yaml" > "$SPEC_FILE"

    yc serverless api-gateway update "$AGW_ID" \
        --spec "$SPEC_FILE"

    info "API gateway updated."
}

# --- Main ---
case "${1:-all}" in
    all)
        check_secret
        ensure_service_account
        deploy_function
        update_agw_spec
        info "Done."
        echo ""
        echo "  Function: $FUNCTION_ID"
        echo "  SA: $SA_ID"
        echo "  Gateway: $AGW_ID"
        ;;
    function|fn)
        check_secret
        ensure_service_account
        deploy_function
        ;;
    spec|agw)
        update_agw_spec
        ;;
    *)
        echo "Usage: $0 [all|function|spec]"
        exit 1
        ;;
esac
