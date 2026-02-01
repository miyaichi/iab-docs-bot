#!/bin/bash
set -euo pipefail

# =============================================================================
# IAB Docs Bot - Deployment Script
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Load environment configuration
# =============================================================================

if [[ -f "$ENV_FILE" ]]; then
  log_info "Loading configuration from $ENV_FILE"
  set -a
  source "$ENV_FILE"
  set +a
else
  log_error "Configuration file not found: $ENV_FILE"
  echo "Please copy .env.sample to .env and fill in the values:"
  echo "  cp ${SCRIPT_DIR}/.env.sample ${SCRIPT_DIR}/.env"
  exit 1
fi

# =============================================================================
# Configuration (from .env)
# =============================================================================

PROJECT_ID="${GCP_PROJECT:-}"
REGION="${GCP_REGION:-asia-northeast1}"
TOPIC="${PUBSUB_TOPIC:-slack-events}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3-flash-preview}"
MCP_URL="${MCP_URL:-https://iab-docs.apti.jp/mcp}"

# Service account names
INGEST_SA="slack-ingest-sa"
WORKER_SA="slack-worker-sa"

# =============================================================================
# Validation
# =============================================================================

if [[ -z "$PROJECT_ID" ]]; then
  log_error "GCP_PROJECT is not set in $ENV_FILE"
  exit 1
fi

# =============================================================================
# Functions
# =============================================================================

setup_gcp() {
  log_info "Setting up GCP project: $PROJECT_ID"

  gcloud config set project "$PROJECT_ID"

  log_info "Enabling required APIs..."
  gcloud services enable \
    run.googleapis.com \
    pubsub.googleapis.com \
    secretmanager.googleapis.com \
    firestore.googleapis.com

  log_info "Creating Pub/Sub topic..."
  gcloud pubsub topics describe "$TOPIC" 2>/dev/null || \
    gcloud pubsub topics create "$TOPIC"

  log_info "Creating service accounts..."
  gcloud iam service-accounts describe "${INGEST_SA}@${PROJECT_ID}.iam.gserviceaccount.com" 2>/dev/null || \
    gcloud iam service-accounts create "$INGEST_SA" --display-name="Slack Ingest Service Account"

  gcloud iam service-accounts describe "${WORKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com" 2>/dev/null || \
    gcloud iam service-accounts create "$WORKER_SA" --display-name="Slack Worker Service Account"

  log_info "Granting IAM roles..."

  # Ingest: Pub/Sub publisher + Secret accessor
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${INGEST_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/pubsub.publisher" \
    --condition=None --quiet

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${INGEST_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None --quiet

  # Worker: Secret accessor + Firestore user
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${WORKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None --quiet

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${WORKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/datastore.user" \
    --condition=None --quiet

  log_info "Setup complete!"
  log_warn "Next steps:"
  echo "  1. Create Firestore database in Native mode (if not exists)"
  echo "  2. Run: ./deploy.sh secrets"
  echo "  3. Run: ./deploy.sh all"
}

create_secrets() {
  log_info "Creating secrets in Secret Manager..."

  # Check required values
  if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
    log_error "SLACK_BOT_TOKEN is not set in $ENV_FILE"
    exit 1
  fi
  if [[ -z "${SLACK_SIGNING_SECRET:-}" ]]; then
    log_error "SLACK_SIGNING_SECRET is not set in $ENV_FILE"
    exit 1
  fi
  if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    log_error "GEMINI_API_KEY is not set in $ENV_FILE"
    exit 1
  fi

  # SLACK_BOT_TOKEN
  if gcloud secrets describe SLACK_BOT_TOKEN 2>/dev/null; then
    log_info "Updating SLACK_BOT_TOKEN..."
    echo -n "$SLACK_BOT_TOKEN" | gcloud secrets versions add SLACK_BOT_TOKEN --data-file=-
  else
    log_info "Creating SLACK_BOT_TOKEN..."
    echo -n "$SLACK_BOT_TOKEN" | gcloud secrets create SLACK_BOT_TOKEN --data-file=-
  fi

  # SLACK_SIGNING_SECRET
  if gcloud secrets describe SLACK_SIGNING_SECRET 2>/dev/null; then
    log_info "Updating SLACK_SIGNING_SECRET..."
    echo -n "$SLACK_SIGNING_SECRET" | gcloud secrets versions add SLACK_SIGNING_SECRET --data-file=-
  else
    log_info "Creating SLACK_SIGNING_SECRET..."
    echo -n "$SLACK_SIGNING_SECRET" | gcloud secrets create SLACK_SIGNING_SECRET --data-file=-
  fi

  # GEMINI_API_KEY
  if gcloud secrets describe GEMINI_API_KEY 2>/dev/null; then
    log_info "Updating GEMINI_API_KEY..."
    echo -n "$GEMINI_API_KEY" | gcloud secrets versions add GEMINI_API_KEY --data-file=-
  else
    log_info "Creating GEMINI_API_KEY..."
    echo -n "$GEMINI_API_KEY" | gcloud secrets create GEMINI_API_KEY --data-file=-
  fi

  log_info "Secrets created/updated successfully!"
}

deploy_ingest() {
  log_info "Deploying slack-ingest to Cloud Run..."
  cd "$ROOT_DIR/services/ingest"

  gcloud run deploy slack-ingest \
    --region "$REGION" \
    --source . \
    --allow-unauthenticated \
    --service-account "${INGEST_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --set-env-vars "PUBSUB_TOPIC=$TOPIC" \
    --memory 256Mi \
    --cpu 1 \
    --min-instances 0 \
    --max-instances 10 \
    --timeout 10s

  log_info "Binding secrets to slack-ingest..."
  gcloud run services update slack-ingest \
    --region "$REGION" \
    --update-secrets "SLACK_SIGNING_SECRET=SLACK_SIGNING_SECRET:latest"

  INGEST_URL=$(gcloud run services describe slack-ingest --region "$REGION" --format='value(status.url)')
  log_info "Ingest URL: $INGEST_URL"
  log_info "Set this in Slack Event Subscriptions: ${INGEST_URL}/slack/events"
}

deploy_worker() {
  log_info "Deploying slack-worker to Cloud Run..."
  cd "$ROOT_DIR/services/worker"

  gcloud run deploy slack-worker \
    --region "$REGION" \
    --source . \
    --no-allow-unauthenticated \
    --service-account "${WORKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --set-env-vars "GCP_PROJECT=$PROJECT_ID,GEMINI_MODEL=$GEMINI_MODEL,MCP_URL=$MCP_URL" \
    --memory 512Mi \
    --cpu 1 \
    --min-instances 0 \
    --max-instances 10 \
    --timeout 60s

  log_info "Binding secrets to slack-worker..."
  gcloud run services update slack-worker \
    --region "$REGION" \
    --update-secrets "SLACK_BOT_TOKEN=SLACK_BOT_TOKEN:latest,GEMINI_API_KEY=GEMINI_API_KEY:latest"

  WORKER_URL=$(gcloud run services describe slack-worker --region "$REGION" --format='value(status.url)')

  log_info "Creating Pub/Sub push subscription..."
  gcloud pubsub subscriptions describe slack-events-push 2>/dev/null && \
    gcloud pubsub subscriptions delete slack-events-push --quiet || true

  gcloud pubsub subscriptions create slack-events-push \
    --topic "$TOPIC" \
    --push-endpoint "${WORKER_URL}/pubsub/push" \
    --push-auth-service-account "${WORKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --ack-deadline 60

  log_info "Granting invoker role to worker service account..."
  gcloud run services add-iam-policy-binding slack-worker \
    --region "$REGION" \
    --member="serviceAccount:${WORKER_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/run.invoker"

  log_info "Worker deployed: $WORKER_URL"
}

show_status() {
  log_info "Current deployment status:"
  echo ""
  echo "Project: $PROJECT_ID"
  echo "Region:  $REGION"
  echo ""

  echo "Services:"
  gcloud run services list --region "$REGION" --format="table(SERVICE,URL,LAST_DEPLOYED_BY)" 2>/dev/null || echo "  (none)"
  echo ""

  echo "Pub/Sub Subscriptions:"
  gcloud pubsub subscriptions list --format="table(name.basename(),topic.basename(),pushConfig.pushEndpoint)" 2>/dev/null || echo "  (none)"
  echo ""

  echo "Secrets:"
  gcloud secrets list --format="table(name)" 2>/dev/null || echo "  (none)"
}

show_usage() {
  echo "Usage: ./deploy.sh [command]"
  echo ""
  echo "Commands:"
  echo "  setup    - Initial GCP setup (APIs, service accounts, IAM)"
  echo "  secrets  - Create/update secrets in Secret Manager"
  echo "  ingest   - Deploy ingest service"
  echo "  worker   - Deploy worker service"
  echo "  all      - Deploy both ingest and worker"
  echo "  status   - Show current deployment status"
  echo ""
  echo "Configuration:"
  echo "  Edit $ENV_FILE to set your environment values."
  echo "  Copy from .env.sample if .env does not exist."
}

# =============================================================================
# Main
# =============================================================================

case "${1:-}" in
  setup)
    setup_gcp
    ;;
  secrets)
    create_secrets
    ;;
  ingest)
    deploy_ingest
    ;;
  worker)
    deploy_worker
    ;;
  all)
    deploy_ingest
    deploy_worker
    ;;
  status)
    show_status
    ;;
  *)
    show_usage
    exit 0
    ;;
esac
