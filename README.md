# iab-docs-bot

Mintlify でホストしている IAB Tech Lab 日本語ドキュメント（MCP Server）を参照し、Slack の `@mention`（`app_mention`）で質問すると **スレッド返信**で回答する Bot です。

- Docs (Mintlify): https://iab-docs.apti.jp
- MCP Endpoint: https://iab-docs.apti.jp/mcp
- Runtime: Google Cloud Run (region: `asia-northeast1`)
- Queue: Pub/Sub（Slack 3秒ACK制約を回避するため受信と処理を分離）
- LLM: Vertex AI Gemini（既存の Google Cloud 基盤を流用）

---

## Architecture

Slack の Events API は **3秒以内に 2xx を返す必要**があるため、受信(ingest)と重い処理(worker)を分けます。

```text
Slack (app_mention)
   |
   |  HTTP Event (signed)
   v
Cloud Run: slack-ingest  ---->  Pub/Sub topic: slack-events  ---->  Cloud Run: slack-worker
(verify + ACK 200)              (queue / retry)                    (MCP -> Gemini -> Slack thread reply)
```

### Worker does

1. イベント重複排除（Slack retry 対策）
2. MCP（Mintlify `/mcp`）に問い合わせて関連ページ/抜粋を取得（上位1〜3件）
3. Gemini に「抜粋のみを根拠に、短く、参照リンク付きで回答」させる
4. Slack に **スレッド返信**（`thread_ts` 指定）する

---

## Repository structure (suggested)

```text
.
├── services/
│   ├── ingest/        # Slack Events receiver: verify + ACK + publish to Pub/Sub
│   └── worker/        # Pub/Sub consumer: MCP -> Gemini -> Slack postMessage (thread reply)
├── infra/             # (optional) scripts / terraform / gcloud helpers
└── README.md
```

---

## Prerequisites

- Google Cloud project with billing enabled
- gcloud CLI installed & authenticated
- APIs enabled:
  - Cloud Run
  - Pub/Sub
  - Secret Manager
  - Vertex AI
  - Firestore (recommended for dedupe/cache)
- Slack App (Bot) created
- Mintlify MCP endpoint accessible: https://iab-docs.apti.jp/mcp

---

## Slack App setup

1. Create a Slack App (from scratch)
2. Enable **Event Subscriptions**
   - Subscribe to bot events: `app_mention`
   - Request URL will be:
     - `https://<CLOUD_RUN_INGEST_URL>/slack/events`
3. OAuth Scopes (Bot Token Scopes):
   - `chat:write`
   - (optional) `channels:history` / `groups:history` if you want to parse context beyond the mention text
4. Install the app to your workspace
5. Copy:
   - **Bot User OAuth Token** (`xoxb-...`)
   - **Signing Secret**

> NOTE: During initial Event Subscriptions setup, Slack sends `url_verification` with a `challenge`.
> The ingest service must return the `challenge` string as plain text.

---

## Google Cloud setup

### 1) Set common variables

```bash
export PROJECT_ID="YOUR_GCP_PROJECT"
export REGION="asia-northeast1"
export TOPIC="slack-events"
```

```bash
gcloud config set project "$PROJECT_ID"
```

### 2) Enable APIs

```bash
gcloud services enable \
  run.googleapis.com \
  pubsub.googleapis.com \
  secretmanager.googleapis.com \
  aiplatform.googleapis.com \
  firestore.googleapis.com
```

### 3) Create Pub/Sub topic

```bash
gcloud pubsub topics create "$TOPIC"
```

### 4) Create secrets (Slack)

```bash
echo -n "xoxb-..." | gcloud secrets create SLACK_BOT_TOKEN --data-file=-
echo -n "your-signing-secret" | gcloud secrets create SLACK_SIGNING_SECRET --data-file=-
```

> Gemini (Vertex AI) uses Cloud Run service account auth, so API key is not required.
> You still need to set model/location via env vars.

### 5) Firestore (recommended)

Use Firestore for:
- Dedup: `event_id` processed flag
- Cache: question -> passages/answer (optional)

Create Firestore in Native mode (if not already):
- Console: Firestore -> Create database -> Native mode -> choose location close to `asia-northeast1`

---

## Deploy

You will deploy 2 Cloud Run services:

- `slack-ingest`: public HTTP endpoint for Slack
- `slack-worker`: Pub/Sub triggered (push subscription or Eventarc)

### Service Accounts (recommended)

Create dedicated service accounts:

```bash
gcloud iam service-accounts create slack-ingest-sa
gcloud iam service-accounts create slack-worker-sa
```

Grant minimum roles:

```bash
# ingest publishes to Pub/Sub and reads secrets
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# worker reads secrets, uses Vertex AI, (optionally) uses Firestore
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/datastore.user"
```

### Deploy ingest

From `services/ingest`:

```bash
gcloud run deploy slack-ingest \
  --region "$REGION" \
  --source . \
  --allow-unauthenticated \
  --service-account "slack-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --set-env-vars "PUBSUB_TOPIC=$TOPIC"
```

Bind secrets as env vars:

```bash
gcloud run services update slack-ingest \
  --region "$REGION" \
  --update-secrets "SLACK_BOT_TOKEN=SLACK_BOT_TOKEN:latest,SLACK_SIGNING_SECRET=SLACK_SIGNING_SECRET:latest"
```

Get the URL:

```bash
gcloud run services describe slack-ingest --region "$REGION" --format='value(status.url)'
```

Set this URL in Slack Event Subscriptions:
- `https://<INGEST_URL>/slack/events`

### Deploy worker (Pub/Sub push subscription + OIDC)

Deploy worker:

```bash
gcloud run deploy slack-worker \
  --region "$REGION" \
  --source ./services/worker \
  --no-allow-unauthenticated \
  --service-account "slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --set-env-vars "GCP_PROJECT=$PROJECT_ID,GCP_LOCATION=$REGION,GEMINI_MODEL=gemini-2.0-flash,MCP_URL=https://iab-docs.apti.jp/mcp"
```

Bind secrets:

```bash
gcloud run services update slack-worker \
  --region "$REGION" \
  --update-secrets "SLACK_BOT_TOKEN=SLACK_BOT_TOKEN:latest"
```

Create Pub/Sub push subscription with OIDC token:

```bash
WORKER_URL=$(gcloud run services describe slack-worker --region "$REGION" --format='value(status.url)')

gcloud pubsub subscriptions create slack-events-push \
  --push-endpoint "$WORKER_URL/pubsub/push" \
  --push-auth-service-account "slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com"

# Allow the service account to invoke the worker service
gcloud run services add-iam-policy-binding slack-worker \
  --region "$REGION" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

> The worker should validate the Pub/Sub push JWT (recommended) and parse the Pub/Sub message body.

Alternative:
- You can also trigger Cloud Run from Pub/Sub via Eventarc if you already use Eventarc in your stack.

---

## Environment variables

### Ingest
- `PUBSUB_TOPIC`: Pub/Sub topic name
- `SLACK_SIGNING_SECRET`: Slack signing secret (via Secret Manager)
- `SLACK_BOT_TOKEN`: Slack bot token (via Secret Manager)
- (optional) `ALLOWED_CHANNELS`: comma-separated channel IDs to limit responses (e.g. `C0123,C0456`)

### Worker
- `GCP_PROJECT`: GCP project id
- `GCP_LOCATION`: Vertex AI location (e.g. `asia-northeast1`)
- `GEMINI_MODEL`: e.g. `gemini-2.0-flash` (cost-optimized starter)
- `MCP_URL`: `https://iab-docs.apti.jp/mcp`
- `SLACK_BOT_TOKEN`: Slack bot token (via Secret Manager)
- (optional) `CACHE_TTL_SECONDS`: default 3600
- (optional) `MAX_PASSAGES`: default 3
- (optional) `MAX_OUTPUT_TOKENS`: default 512

---

## Prompting policy (recommended)

- The answer **must be grounded only in MCP excerpts**.
- If the excerpts do not contain the information, reply:
  - `ドキュメント内で該当箇所を見つけられませんでした。別キーワードで探しますか？`
- Always include reference links at the end.

---

## Cost controls

- Respond only on `app_mention` (no full channel monitoring)
- Restrict to a dedicated channel (e.g. `#docs-qa`)
- Cache:
  - question -> passages (and/or final answer)
- Keep response short by default; allow "詳しく" to expand
- Use a cost-optimized Gemini model for first pass; escalate only if needed

---

## Troubleshooting

### Slack retries / duplicate replies
- Ensure ingest returns 200 quickly
- Implement Firestore dedupe:
  - key: `event_id`
  - value: processed timestamp

### Slack Event Subscriptions "URL verification" fails
- Ingest must respond with the `challenge` string exactly.

### No response in Slack
- Check:
  - Slack app installed to workspace
  - correct scopes (`chat:write`)
  - correct Request URL
  - Cloud Run logs (ingest + worker)
  - Pub/Sub subscription delivery

### MCP errors
- Confirm MCP endpoint is reachable:
  - https://iab-docs.apti.jp/mcp
- Add retry with backoff (cap retries to avoid cost blowups)

---

## Security notes

- Verify Slack signatures (Signing Secret)
- Do not expose worker publicly; require Pub/Sub OIDC push auth
- Store secrets only in Secret Manager
- Log redaction: avoid printing tokens in logs

---

## License

MIT
