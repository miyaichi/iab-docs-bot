import { GoogleGenerativeAI } from '@google/generative-ai';

const GEMINI_API_KEY = process.env.GEMINI_API_KEY || '';
const MODEL = process.env.GEMINI_MODEL || 'gemini-3-flash-preview';

let genAI: GoogleGenerativeAI | null = null;

const SYSTEM_PROMPT = `あなたは IAB Tech Lab ドキュメントの質問に答えるアシスタントです。

## ルール
1. 以下の【参照ドキュメント】のみを根拠に回答してください
2. 参照ドキュメントに情報がない場合は「ドキュメント内で該当箇所を見つけられませんでした」と回答してください
3. 回答は日本語で、簡潔に（3〜5文程度）
4. 回答の末尾に参照リンクを必ず含めてください
5. 技術用語は正確に使用してください

## 出力フォーマット
[回答本文]

参照:
- [ページタイトル](URL)
`;

interface GenerateAnswerResult {
  answer: string;
  success: boolean;
}

function getModel() {
  if (!GEMINI_API_KEY) {
    throw new Error('GEMINI_API_KEY is not set');
  }

  if (!genAI) {
    genAI = new GoogleGenerativeAI(GEMINI_API_KEY);
  }

  return genAI.getGenerativeModel({ model: MODEL });
}

/**
 * Geminiで回答を生成
 */
export async function generateAnswer(question: string, passages: string): Promise<GenerateAnswerResult> {
  if (!GEMINI_API_KEY) {
    console.error('GEMINI_API_KEY is not set');
    return { answer: '設定エラー: GEMINI_API_KEYが設定されていません', success: false };
  }

  const model = getModel();

  const userPrompt = `## 質問
${question}

## 参照ドキュメント
${passages}`;

  console.log(`Generating answer with Gemini (${MODEL}) for: "${question}"`);

  try {
    const chat = model.startChat({
      history: [
        {
          role: 'user',
          parts: [{ text: 'あなたの役割を説明してください。' }],
        },
        {
          role: 'model',
          parts: [{ text: SYSTEM_PROMPT }],
        },
      ],
    });

    const result = await chat.sendMessage(userPrompt);
    const answer = result.response.text();

    if (!answer) {
      console.error('Empty response from Gemini');
      return { answer: '回答を生成できませんでした', success: false };
    }

    console.log(`Gemini response length: ${answer.length}`);
    return { answer, success: true };
  } catch (err) {
    console.error('Gemini API error:', err);
    return { answer: '回答の生成中にエラーが発生しました', success: false };
  }
}
