import { FunctionDeclaration, SchemaType } from '@google/generative-ai';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const MCP_URL = process.env.MCP_URL || 'https://iab-docs.apti.jp/mcp';

let client: Client | null = null;

async function getClient(): Promise<Client> {
  if (client) {
    return client;
  }

  const transport = new StreamableHTTPClientTransport(new URL(MCP_URL));
  client = new Client({ name: 'iab-docs-bot', version: '1.0.0' });

  await client.connect(transport);
  console.log(`Connected to MCP server: ${MCP_URL}`);

  return client;
}

function mapSchemaType(type: string): SchemaType {
  switch (type?.toLowerCase()) {
    case 'string': return SchemaType.STRING;
    case 'number': return SchemaType.NUMBER;
    case 'integer': return SchemaType.INTEGER;
    case 'boolean': return SchemaType.BOOLEAN;
    case 'array': return SchemaType.ARRAY;
    case 'object': return SchemaType.OBJECT;
    default: return SchemaType.STRING;
  }
}

// Convert MCP JSON Schema to Gemini Schema
function convertSchema(schema: any): any {
  if (!schema) return undefined;

  const result: any = {
    type: mapSchemaType(schema.type),
    description: schema.description,
    nullable: schema.nullable,
  };

  if (schema.properties) {
    result.properties = {};
    for (const [key, prop] of Object.entries(schema.properties as Record<string, any>)) {
      result.properties[key] = convertSchema(prop);
    }
  }

  if (schema.required) {
    result.required = schema.required;
  }

  if (schema.items) {
    result.items = convertSchema(schema.items);
  }

  if (schema.enum) {
    result.enum = schema.enum;
  }

  return result;
}

/**
 * Get MCP tools converted to Gemini FunctionDeclarations
 */
export async function getGeminiTools(): Promise<FunctionDeclaration[]> {
  const mcpClient = await getClient();
  const { tools } = await mcpClient.listTools();

  console.log(`Discovered ${tools.length} MCP tools`);

  return tools.map((t) => ({
    name: t.name,
    description: t.description || '',
    parameters: convertSchema(t.inputSchema),
  }));
}

/**
 * Call an MCP tool
 */
export async function callMcpTool(name: string, args: any): Promise<any> {
  const mcpClient = await getClient();
  console.log(`Calling MCP tool: ${name} with args:`, args);

  const result = await mcpClient.callTool({
    name,
    arguments: args,
  });

  // Extract text content for easier consumption by Gemini
  const textContent = (result as any).content
    .filter((c: any) => c.type === 'text')
    .map((c: any) => c.text)
    .join('\n\n');

  return {
    content: textContent || JSON.stringify(result.content),
    isError: result.isError
  };
}

export async function closeClient(): Promise<void> {
  if (client) {
    await client.close();
    client = null;
  }
}
