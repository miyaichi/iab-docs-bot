# iab-docs-bot

Mintlify でホストしている IAB Tech Lab 日本語ドキュメント（MCP Server）を参照し、Slack の `@mention`（`app_mention`）で質問すると **スレッド返信**で回答する Bot です。

| 項目            | 値                                   |
| --------------- | ------------------------------------ |
| Docs (Mintlify) | https://iab-docs.apti.jp             |
| MCP Endpoint    | https://iab-docs.apti.jp/mcp         |
| Runtime         | Google Cloud Run (`asia-northeast1`) |
| Queue           | Pub/Sub（Slack 3秒ACK制約回避）      |
| LLM             | Google AI Studio (Gemini API)        |
| Language        | **TypeScript** (Node.js 20+)         |

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

1. イベント重複排除（Firestore で Slack retry 対策）
2. MCP（Mintlify `/mcp`）に問い合わせて関連ページ/抜粋を取得
3. Gemini に「抜粋のみを根拠に、短く、参照リンク付きで回答」させる
4. Slack に **スレッド返信**（`thread_ts` 指定）する

---

## MCP integration

Mintlify は公開ドキュメントに対して自動的に MCP Server を生成します。`/mcp` エンドポイントで [Model Context Protocol](https://modelcontextprotocol.io/) に準拠した検索ツールを提供します。

### MCP SDK

```bash
npm install @modelcontextprotocol/sdk
```

### 接続方法

```typescript
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const MCP_URL = 'https://iab-docs.apti.jp/mcp';

const transport = new StreamableHTTPClientTransport(new URL(MCP_URL));
const client = new Client({ name: 'iab-docs-bot', version: '1.0.0' });
await client.connect(transport);

// 利用可能なツールを確認
const { tools } = await client.listTools();
console.log(tools.map((t) => t.name)); // => ["SearchIabTechLabDocs"]
```

### SearchIabTechLabDocs ツール

Mintlify MCP Server は `SearchIabTechLabDocs` ツールを公開し、ドキュメント内を検索できます。

**呼び出し例**:

```typescript
const result = await client.callTool({
  name: 'SearchIabTechLabDocs',
  arguments: {
    query: 'OpenRTBとは',
  },
});

// result.content にはドキュメントの抜粋とリンクが含まれる
```

**レスポンス例** (content フィールド):

```json
[
  {
    "type": "text",
    "text": "Title: ads.txt 1.1\nLink: https://iab-docs.apti.jp/docs/ja/ads-txt-1.1\nContent: ..."
  }
]
```

### 参考リンク

- [MCP Specification](https://modelcontextprotocol.io/)
- [Mintlify MCP docs](https://www.mintlify.com/docs/ai/model-context-protocol)
- [@modelcontextprotocol/sdk](https://www.npmjs.com/package/@modelcontextprotocol/sdk)

---

## Repository structure

```text
.
├── assets/
│   └── app-icon.png           # Slack App icon
├── services/
│   ├── ingest/                 # Slack Events receiver
│   │   ├── src/
│   │   │   └── index.ts        # Express server: verify + ACK + Pub/Sub publish
│   │   ├── Dockerfile
│   │   ├── package.json
│   │   └── tsconfig.json
│   └── worker/                 # Pub/Sub consumer
│       ├── src/
│       │   ├── index.ts        # Express server: Pub/Sub push handler
│       │   ├── mcp.ts          # MCP client (Mintlify docs search)
│       │   └── gemini.ts       # Google AI Studio Gemini client
│       ├── Dockerfile
│       ├── package.json
│       └── tsconfig.json
├── infra/
│   └── deploy.sh               # Deployment script
└── README.md
```

---

## Prerequisites

- **Node.js** 20+ and npm
- **Google Cloud** project with billing enabled
- **gcloud CLI** installed & authenticated
- **Google AI Studio** API Key (https://aistudio.google.com/app/apikey)
- **APIs enabled**:
  - Cloud Run
  - Pub/Sub
  - Secret Manager
  - Firestore
- **Slack App** (Bot) created
- **Mintlify MCP endpoint**: https://iab-docs.apti.jp/mcp

---

## Slack App setup

1. https://api.slack.com/apps で **Create New App** → **From scratch**
2. App名: `IAB Docs Bot`、Workspace を選択
3. **Basic Information** → **Display Information** → App icon に `assets/app-icon.png` をアップロード
4. **OAuth & Permissions** → Bot Token Scopes:
   - `chat:write`
   - `app_mentions:read`
5. **Event Subscriptions** → Enable Events を **ON**
   - Request URL: `https://<CLOUD_RUN_INGEST_URL>/slack/events`
   - Subscribe to bot events: `app_mention`
6. **Install App** → Install to Workspace
7. 以下をコピー:
   - **Bot User OAuth Token** (`xoxb-...`) - OAuth & Permissions ページ
   - **Signing Secret** - Basic Information ページ

> NOTE: Event Subscriptions設定時、Slack は `url_verification` を送信します。
> ingest サービスは `challenge` 文字列をそのまま返す必要があります。

---

## Google Cloud setup

### 1) Set common variables

```bash
export PROJECT_ID="iab-docs-bot"
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
  firestore.googleapis.com
```

### 3) Create Pub/Sub topic

```bash
gcloud pubsub topics create "$TOPIC"
```

### 4) Create secrets

```bash
# Slack Bot Token
echo -n "xoxb-..." | gcloud secrets create SLACK_BOT_TOKEN --data-file=-

# Slack Signing Secret
echo -n "your-signing-secret" | gcloud secrets create SLACK_SIGNING_SECRET --data-file=-

# Google AI Studio API Key
echo -n "your-gemini-api-key" | gcloud secrets create GEMINI_API_KEY --data-file=-
```

### 5) Firestore

Create Firestore in Native mode:

- Console: Firestore -> Create database -> Native mode -> location: `asia-northeast1`

**Collection schema**:

```text
processed_events/
  {event_id}/
    processed_at: Timestamp
    channel: string
    ts: string
```

---

## Deploy

### 1) 環境設定ファイルの作成

```bash
# サンプルをコピーして編集
cp infra/.env.sample infra/.env

# .env を編集して実際の値を設定
vi infra/.env
```

### 2) デプロイスクリプトを使用

```bash
cd infra

# 初回セットアップ (API有効化、サービスアカウント作成、IAM設定)
./deploy.sh setup

# シークレットを作成
./deploy.sh secrets

# ingest と worker をデプロイ
./deploy.sh all

# デプロイ状況を確認
./deploy.sh status
```

### 手動デプロイ

#### Service Accounts

```bash
gcloud iam service-accounts create slack-ingest-sa
gcloud iam service-accounts create slack-worker-sa

# ingest: Pub/Sub publisher + Secret accessor
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# worker: Secret accessor + Firestore user
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/datastore.user"
```

#### Deploy ingest

```bash
cd services/ingest

gcloud run deploy slack-ingest \
  --region "$REGION" \
  --source . \
  --allow-unauthenticated \
  --service-account "slack-ingest-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --set-env-vars "PUBSUB_TOPIC=$TOPIC" \
  --memory 256Mi \
  --timeout 10s

gcloud run services update slack-ingest \
  --region "$REGION" \
  --update-secrets "SLACK_SIGNING_SECRET=SLACK_SIGNING_SECRET:latest"
```

#### Deploy worker

```bash
cd services/worker

gcloud run deploy slack-worker \
  --region "$REGION" \
  --source . \
  --no-allow-unauthenticated \
  --service-account "slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --set-env-vars "GCP_PROJECT=$PROJECT_ID,GEMINI_MODEL=gemini-3-flash-preview,MCP_URL=https://iab-docs.apti.jp/mcp" \
  --memory 512Mi \
  --timeout 60s

gcloud run services update slack-worker \
  --region "$REGION" \
  --update-secrets "SLACK_BOT_TOKEN=SLACK_BOT_TOKEN:latest,GEMINI_API_KEY=GEMINI_API_KEY:latest"
```

#### Pub/Sub subscription

```bash
WORKER_URL=$(gcloud run services describe slack-worker --region "$REGION" --format='value(status.url)')

gcloud pubsub subscriptions create slack-events-push \
  --topic "$TOPIC" \
  --push-endpoint "$WORKER_URL/pubsub/push" \
  --push-auth-service-account "slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --ack-deadline 60

gcloud run services add-iam-policy-binding slack-worker \
  --region "$REGION" \
  --member="serviceAccount:slack-worker-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

---

## Environment variables

### Ingest

| 変数                   | 説明                                      |
| ---------------------- | ----------------------------------------- |
| `PUBSUB_TOPIC`         | Pub/Sub topic name                        |
| `SLACK_SIGNING_SECRET` | Slack signing secret (via Secret Manager) |

### Worker

| 変数              | 説明                                          |
| ----------------- | --------------------------------------------- |
| `GCP_PROJECT`     | GCP project id                                |
| `GEMINI_MODEL`    | e.g. `gemini-2.0-flash`                       |
| `GEMINI_API_KEY`  | Google AI Studio API Key (via Secret Manager) |
| `MCP_URL`         | `https://iab-docs.apti.jp/mcp`                |
| `SLACK_BOT_TOKEN` | Slack bot token (via Secret Manager)          |

---

## Troubleshooting

### Cloud Run で allUsers が設定できない

組織ポリシーでドメイン制限がある場合:

```bash
# プロジェクトレベルでポリシーを緩和
gcloud services enable orgpolicy.googleapis.com

cat <<EOF | gcloud org-policies set-policy --project=$PROJECT_ID /dev/stdin
name: projects/$PROJECT_ID/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
  - allowAll: true
EOF

# 30秒待ってから再試行
gcloud run services add-iam-policy-binding slack-ingest \
  --region=$REGION \
  --member=allUsers \
  --role=roles/run.invoker
```

### Slack retries / duplicate replies

- ingest が 200 を素早く返していることを確認
- Firestore の `processed_events` コレクションで重複排除が動作しているか確認

### Slack Event Subscriptions "URL verification" fails

- ingest が `challenge` 文字列をそのまま返していることを確認
- Cloud Run logs で署名検証エラーがないか確認

### No response in Slack

確認事項:

- Slack app が workspace にインストールされているか
- 正しい scopes (`chat:write`, `app_mentions:read`)
- 正しい Request URL
- Cloud Run logs (ingest + worker)
- Pub/Sub subscription の配信状況

### Gemini model not found

Google AI Studio API を使用しているため、`GEMINI_API_KEY` が正しく設定されていることを確認。
利用可能なモデル: `gemini-3-flash-preview` `gemini-2.0-flash`, `gemini-1.5-flash`, `gemini-1.5-pro` など。

---

## Security notes

- Slack署名を検証 (Signing Secret)
- worker は公開しない (Pub/Sub OIDC push auth を使用)
- シークレットは Secret Manager にのみ保存
- ログにトークンを出力しない

---

# Features to add

1. レスポンスキャッシュ: Firestore に TTL 付きで保存し、同じ質問への再回答を高速化しつつドキュメント更新時の無効化手順を整備
2. エラー通知とフォールバック: worker 失敗時に Slack スレッドへ簡易返信し、Sentry 等へのアラート通知を追加
3. テストとローカル検証: Slack 署名検証・Pub/Sub push・MCP/Gemini をモックした単体/統合テストとローカル実行手順
4. モニタリングと運用: 構造化ログ、メトリクス/ダッシュボード、Pub/Sub DLQ、Cloud Monitoring アラートの整備
5. レート制限と防御: ユーザー/チャネル単位の QPS 制御、Gemini 呼び出しのリトライとバックオフ  


---

## License

MIT
