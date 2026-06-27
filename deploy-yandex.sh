#!/usr/bin/env bash
#
# Deploy yac-ws-bridge to Yandex Cloud
#
# Prerequisites:
#   - yc CLI configured and authenticated
#   - jq installed
#   - javascript-obfuscator installed (npm i -g javascript-obfuscator) — optional
#
# Usage:
#   ./deploy-yandex.sh              # full deploy (SA + function + AGW spec update)
#   ./deploy-yandex.sh function     # redeploy function only
#   ./deploy-yandex.sh spec         # update AGW spec only
#
# Secret is auto-generated on first run and saved to deploy/.secret.
# Override: export YAC_BRIDGE_SECRET="custom-secret"
# The same secret must go into adapter.config.yaml → bridge.authToken
#
# After first run the script prints the function ID and SA ID.
# These are baked into the AGW spec automatically.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLOUD_DIR="$SCRIPT_DIR/bridge-cloud"

# --- Configuration ---
# All environment-specific values are loaded from deploy/.env (gitignored).
# Copy deploy/.env.example to deploy/.env and fill in your values.
ENV_FILE="$SCRIPT_DIR/deploy/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

FOLDER_ID="${YC_FOLDER_ID:?Set YC_FOLDER_ID in deploy/.env}"
AGW_ID="${YAC_AGW_ID:?Set YAC_AGW_ID in deploy/.env}"
FUNCTION_NAME="${YAC_FUNCTION_NAME:-hass-ws-relay}"
SA_NAME="${YAC_SA_NAME:-hass-relay-sa}"

# Pod IP where adapter wakeup + HA decoy nginx will run
POD_IP="${POD_IP:?Set POD_IP in deploy/.env}"

# Custom domain attached to the AGW
AGW_DOMAIN="${AGW_DOMAIN:?Set AGW_DOMAIN in deploy/.env}"

# Shared secret between CF and adapter
# Generated automatically on first deploy if not set; stored in deploy/.secret
SECRET_FILE="$SCRIPT_DIR/deploy/.secret"
if [[ -n "${YAC_BRIDGE_SECRET:-}" ]]; then
    BRIDGE_SECRET="$YAC_BRIDGE_SECRET"
elif [[ -f "$SECRET_FILE" ]]; then
    BRIDGE_SECRET="$(cat "$SECRET_FILE")"
else
    BRIDGE_SECRET=""
fi

# Adapter wakeup base URL (CF uses this for fallback POST and cold-start GET)
# CF env var: HA_ORIGIN_BASE
ORIGIN_BASE="${YAC_ORIGIN_BASE:?Set YAC_ORIGIN_BASE in deploy/.env}"

# --- Helpers ---
info()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
error() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

check_secret() {
    if [[ -z "$BRIDGE_SECRET" ]]; then
        info "No secret found. Generating a new one..."
        BRIDGE_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
        echo -n "$BRIDGE_SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        info "Secret saved to deploy/.secret (gitignored)"
        info "Use this same secret in adapter.config.yaml → bridge.authToken"
        echo ""
        echo "  BRIDGE_SECRET=$BRIDGE_SECRET"
        echo ""
    fi
}

# --- Step 1: Service Account ---
ensure_service_account() {
    info "Ensuring service account: $SA_NAME"

    SA_ID=$(yc iam service-account list --format json | jq -r ".[] | select(.name==\"$SA_NAME\") | .id")

    if [[ -z "$SA_ID" ]]; then
        info "Creating service account..."
        yc iam service-account create --name "$SA_NAME" --description "yac-ws-bridge Cloud Function SA"
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

# --- Step 2: Cloud Function ---
deploy_function() {
    check_secret
    info "Deploying Cloud Function: $FUNCTION_NAME"

    FUNCTION_ID=$(yc serverless function list --format json | jq -r ".[] | select(.name==\"$FUNCTION_NAME\") | .id")

    if [[ -z "$FUNCTION_ID" ]]; then
        info "Creating function..."
        yc serverless function create --name "$FUNCTION_NAME" --description "yac-ws-bridge relay"
        FUNCTION_ID=$(yc serverless function get "$FUNCTION_NAME" --format json | jq -r .id)
    fi

    echo "  FUNCTION_ID=$FUNCTION_ID"

    # Package the function
    info "Packaging function..."
    TMPZIP=$(mktemp /tmp/bridge-fn-XXXXXX.zip)
    rm -f "$TMPZIP"  # zip needs a fresh file, not an empty one from mktemp
    trap "rm -f $TMPZIP" EXIT

    # Obfuscate if javascript-obfuscator is available
    if command -v javascript-obfuscator &>/dev/null; then
        info "Obfuscating index.js..."
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
        info "javascript-obfuscator not found, deploying plain (consider: npm i -g javascript-obfuscator)"
        (cd "$CLOUD_DIR" && zip -q "$TMPZIP" index.js package.json)
    fi

    info "Creating function version..."
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

# --- Step 3: AGW Spec ---
update_agw_spec() {
    info "Updating API Gateway spec: $AGW_ID"

    # Resolve IDs if not already set
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

    # Generate spec from template
    SPEC_FILE=$(mktemp /tmp/agw-spec-XXXXXX.yaml)
    trap "rm -f $SPEC_FILE" EXIT

    sed -e "s|\${FUNCTION_ID}|$FUNCTION_ID|g" \
        -e "s|\${SERVICE_ACCOUNT_ID}|$SA_ID|g" \
        -e "s|\${POD_IP}|$POD_IP|g" \
        -e "s|\${AGW_DOMAIN}|$AGW_DOMAIN|g" \
        "$SCRIPT_DIR/deploy/agw-spec.yaml" > "$SPEC_FILE"

    info "Applying spec..."
    yc serverless api-gateway update "$AGW_ID" \
        --spec "$SPEC_FILE"

    info "AGW updated. Domain: ha.unablue.com"
}

# --- Main ---
case "${1:-all}" in
    all)
        check_secret
        ensure_service_account
        deploy_function
        update_agw_spec
        info "Done! All components deployed."
        echo ""
        echo "Summary:"
        echo "  Function ID: $FUNCTION_ID"
        echo "  Service Account ID: $SA_ID"
        echo "  AGW ID: $AGW_ID"
        echo "  Origin Base: $ORIGIN_BASE"
        echo ""
        echo "Next steps:"
        echo "  1. Deploy adapter on pod (ansible) — use secret from deploy/.secret"
        echo "  2. Set up nginx HA decoy on pod (:80)"
        echo "  3. Test: wss://ha.unablue.com/<path>"
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
