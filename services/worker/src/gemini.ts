import { GoogleGenerativeAI, Tool } from '@google/generative-ai';
import { callMcpTool, getGeminiTools } from './mcp.js';

const GEMINI_API_KEY = process.env.GEMINI_API_KEY || '';
const MODEL_NAME = process.env.GEMINI_MODEL || 'gemini-1.5-flash';

let genAI: GoogleGenerativeAI | null = null;

const SYSTEM_PROMPT = `あなたは IAB Tech Lab ドキュメントの質問に答えるアシスタントです。

## ルール
1. 利用可能なツール検索ツールを使用して、ドキュメントを検索し、質問に答えてください。
2. ユーザーの質問に対して、適切なキーワードで検索を行ってください。
3. ツールから得られた情報のみを根拠に回答してください。情報がない場合は正直にそう伝えてください。
4. 回答は日本語で、簡潔に行ってください。
5. 回答の末尾に、参照したドキュメントのURLを必ずリストアップしてください。
`;

interface GenerateAnswerResult {
  answer: string;
  success: boolean;
}

function getModel(tools: Tool[]) {
  if (!GEMINI_API_KEY) {
    throw new Error('GEMINI_API_KEY is not set');
  }

  if (!genAI) {
    genAI = new GoogleGenerativeAI(GEMINI_API_KEY);
  }

  return genAI.getGenerativeModel({
    model: MODEL_NAME,
    systemInstruction: SYSTEM_PROMPT,
    tools: tools
  });
}

/**
 * Gemini Agent Loop to process question with tools
 */
export async function generateAnswer(question: string): Promise<GenerateAnswerResult> {
  if (!GEMINI_API_KEY) {
    console.error('GEMINI_API_KEY is not set');
    return { answer: '設定エラー: GEMINI_API_KEYが設定されていません', success: false };
  }

  try {
    // Get tools from MCP
    const toolDeclarations = await getGeminiTools();
    const tools: Tool[] = [{ functionDeclarations: toolDeclarations }];

    // Initialize model with tools
    const model = getModel(tools);

    const chat = model.startChat({
      history: [],
    });

    console.log(`Agent processing question: "${question}" with model ${MODEL_NAME}`);
    let result = await chat.sendMessage(question);

    const MAX_ITERATIONS = 10;
    let iteration = 0;

    // Tool execution loop
    while (iteration < MAX_ITERATIONS) {
      const response = result.response;

      // Check for function calls
      // In newer SDKs, use functionCalls() helper
      const functionCalls = response.functionCalls();

      if (functionCalls && functionCalls.length > 0) {
        console.log(`Tool usage detected: ${functionCalls.length} calls`);
        const parts: any[] = [];

        // Execute all requested tools
        for (const call of functionCalls) {
          try {
            const toolResult = await callMcpTool(call.name, call.args);
            parts.push({
              functionResponse: {
                name: call.name,
                response: { content: toolResult.content }
              }
            });
          } catch (err: any) {
            console.error(`Tool execution error for ${call.name}:`, err);
            parts.push({
              functionResponse: {
                name: call.name,
                response: { error: err.message }
              }
            });
          }
        }

        // Send tool outputs back to Gemini to continue generation
        result = await chat.sendMessage(parts);
      } else {
        // No more tool calls, we have the final text response
        break;
      }
      iteration++;
    }

    const answer = result.response.text();
    return { answer, success: true };

  } catch (err: any) {
    console.error('Gemini Agent error:', err);
    return { answer: '回答の生成中にエラーが発生しました。', success: false };
  }
}
