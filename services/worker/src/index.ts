import { Firestore, Timestamp } from '@google-cloud/firestore';
import { WebClient } from '@slack/web-api';
import express, { Request, Response } from 'express';
import { generateAnswer } from './gemini.js';

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8081;
const SLACK_BOT_TOKEN = process.env.SLACK_BOT_TOKEN || '';

// Slack client
const slack = new WebClient(SLACK_BOT_TOKEN);

// Firestore client (for dedup)
const firestore = new Firestore();
const PROCESSED_EVENTS_COLLECTION = 'processed_events';

interface SlackEvent {
  event_id: string;
  event_time: number;
  team_id: string;
  channel: string;
  user: string;
  text: string;
  ts: string;
  thread_ts: string;
}

interface PubSubMessage {
  message: {
    data: string; // base64 encoded
    messageId: string;
    publishTime: string;
  };
  subscription: string;
}

/**
 * イベントが既に処理済みかチェック
 */
async function isEventProcessed(eventId: string): Promise<boolean> {
  try {
    const doc = await firestore.collection(PROCESSED_EVENTS_COLLECTION).doc(eventId).get();
    return doc.exists;
  } catch (err) {
    console.error('Firestore read error:', err);
    return false; // エラー時は処理を続行
  }
}

/**
 * イベントを処理済みとしてマーク
 */
async function markEventProcessed(eventId: string, channel: string, ts: string): Promise<void> {
  try {
    await firestore.collection(PROCESSED_EVENTS_COLLECTION).doc(eventId).set({
      processed_at: Timestamp.now(),
      channel,
      ts,
    });
  } catch (err) {
    console.error('Firestore write error:', err);
  }
}

/**
 * Slackにスレッド返信を送信
 */
async function replyToSlack(channel: string, threadTs: string, text: string): Promise<void> {
  await slack.chat.postMessage({
    channel,
    thread_ts: threadTs,
    text,
  });
}

/**
 * Pub/Sub push エンドポイント
 */
app.post('/pubsub/push', async (req: Request, res: Response) => {
  const pubsubMessage = req.body as PubSubMessage;

  if (!pubsubMessage.message?.data) {
    console.error('Invalid Pub/Sub message format');
    res.status(400).send('Invalid message');
    return;
  }

  // Base64デコード
  let event: SlackEvent;
  try {
    const decoded = Buffer.from(pubsubMessage.message.data, 'base64').toString('utf-8');
    event = JSON.parse(decoded) as SlackEvent;
  } catch (err) {
    console.error('Failed to decode message:', err);
    res.status(400).send('Invalid message encoding');
    return;
  }

  console.log(`Processing event: ${event.event_id}`);

  // 重複チェック
  if (await isEventProcessed(event.event_id)) {
    console.log(`Event already processed: ${event.event_id}`);
    res.status(200).send('Already processed');
    return;
  }

  try {
    // メンションテキストからボットIDを除去して質問を抽出
    const question = event.text.replace(/<@[A-Z0-9]+>/g, '').trim();

    if (!question) {
      await replyToSlack(event.channel, event.thread_ts, '質問を入力してください。例: `@bot OpenRTBとは？`');
      await markEventProcessed(event.event_id, event.channel, event.ts);
      res.status(200).send('OK');
      return;
    }

    console.log(`Question: "${question}"`);

    // Agentic RAG: Gemini decides which tools to use and answers
    const geminiResult = await generateAnswer(question);
    const replyText = geminiResult.answer;

    await replyToSlack(event.channel, event.thread_ts, replyText);
    console.log(`Reply sent: event_id=${event.event_id}`);

    // 処理済みとしてマーク
    await markEventProcessed(event.event_id, event.channel, event.ts);

    res.status(200).send('OK');
  } catch (err) {
    console.error('Failed to process event:', err);
    // 500を返すとPub/Subがリトライする
    res.status(500).send('Processing failed');
  }
});

// Health check
app.get('/health', (_req: Request, res: Response) => {
  res.status(200).send('healthy');
});

app.listen(PORT, () => {
  console.log(`slack-worker listening on port ${PORT}`);
});
