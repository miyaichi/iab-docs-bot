
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="iab-docs-bot"
DEPLOY_SA="github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"
INGEST_SA="slack-ingest-sa@${PROJECT_ID}.iam.gserviceaccount.com"
WORKER_SA="slack-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com"
PROJECT_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
CLOUD_BUILD_SA="${PROJECT_NUM}@cloudbuild.gserviceaccount.com"

check_roles() {
  local sa="$1"
  shift
  local roles=("$@")
  echo "== ${sa} on project ${PROJECT_ID}"
  for r in "${roles[@]}"; do
    if gcloud projects get-iam-policy "$PROJECT_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.members:serviceAccount:${sa} AND bindings.role:
${r}" \
        --format="value(bindings.role)" >/dev/null; then
      echo "  [OK] ${r}"
    else
      echo "  [MISSING] ${r}"
    fi
  done
}

check_sauser() {
  local target_sa="$1"
  local caller_sa="$2"
  echo "== ${caller_sa} as serviceAccountUser on ${target_sa}"
  if gcloud iam service-accounts get-iam-policy "$target_sa" \
      --flatten="bindings[].members" \
      --filter="bindings.members:serviceAccount:${caller_sa} AND
bindings.role:roles/iam.serviceAccountUser" \
      --format="value(bindings.role)" >/dev/null; then
    echo "  [OK] roles/iam.serviceAccountUser"
  else
    echo "  [MISSING] roles/iam.serviceAccountUser"
  fi
}

project_roles=(
  roles/run.admin
  roles/artifactregistry.writer
  roles/storage.admin
  roles/secretmanager.admin
  roles/cloudbuild.builds.editor
  roles/serviceusage.serviceUsageConsumer
  roles/pubsub.admin
)

check_roles "$DEPLOY_SA" "${project_roles[@]}"
check_roles "$CLOUD_BUILD_SA" roles/storage.admin roles/serviceusage.serviceUsageConsumer

check_sauser "$DEPLOY_SA" "$DEPLOY_SA"
check_sauser "$INGEST_SA" "$DEPLOY_SA"
check_sauser "$WORKER_SA" "$DEPLOY_SA"
