import type { EngineInterface, McpToolName, On, ToolCallResult } from 'claude-code'

// Every jr reply also notifies the user in Slack and jr's inbox. When Claude asked the question,
// Claude reads the answer, so those replies are marked read in jr to spare the user a second copy.
// The user's own conversations are never touched: a conversation counts only after Claude starts it
// or sends to it, and only the messages from then on that are Claude's or answer Claude.

// The jr connector's server id differs per account, so its tools are matched by name.
const JR_TOOL = /^(mcp__.+?)__(createConversation|sendMessage|getConversation|listConversationMessages)$/
const KEY = 'jrRead:'
// A reply can come days later (the next sync), but the store is capped, so old entries go.
const KEEP_MS = 14 * 24 * 60 * 60 * 1000

type Message = { seq?: unknown; messageId?: unknown; role?: unknown }
// `from`: the newest seq before Claude's first message; `read`: the last seq marked read.
type Orchestrated = { server: McpToolName; from: number | null; sent: string[]; read: number; at: number }

function parse(r: { text?: string; result?: unknown }): Record<string, unknown> | null {
  try {
    const v = JSON.parse(r.text ?? '')
    if (v && typeof v === 'object') return v as Record<string, unknown>
  } catch {}
  const sc = (r.result as { structuredContent?: unknown } | undefined)?.structuredContent
  return sc && typeof sc === 'object' ? (sc as Record<string, unknown>) : null
}

// A cursor is `<base64url JSON>.<signature>` holding the seq it points after. It is jr's own
// format, so a cursor that does not decode falls back to the seq of Claude's message once seen.
function cursorSeq(cursor: unknown): number | null {
  if (typeof cursor !== 'string') return null
  try {
    const b64 = (cursor.split('.')[0] ?? '').replace(/-/g, '+').replace(/_/g, '/')
    const body = JSON.parse(atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, '='))) as { seq?: unknown }
    return typeof body.seq === 'number' ? body.seq : null
  } catch {
    return null
  }
}

const ids = (out: Record<string, unknown>) =>
  [out.messageId, ...(Array.isArray(out.pendingMessages) ? out.pendingMessages.map(m => (m as Message).messageId) : [])].filter(
    (id): id is string => typeof id === 'string',
  )

// jr names each assistant message after the message its turn answers: `turn_<id, ':' as '_'>:…`.
const isClaudes = (m: Message, sent: string[]) =>
  typeof m.messageId === 'string' && sent.some(id => m.messageId === id || (m.messageId as string).startsWith(`turn_${id.replace(/:/g, '_')}:`))

async function prune($: EngineInterface, now: number) {
  for (const key of await $.store.keys()) {
    if (!key.startsWith(KEY)) continue
    const v = (await $.store.get(key)) as Orchestrated | undefined
    if (!v || now - v.at > KEEP_MS) await $.store.delete(key)
  }
}

async function remember($: EngineInterface, server: McpToolName, conversationId: string, out: Record<string, unknown>) {
  const now = Date.now()
  const key = KEY + conversationId
  const was = (await $.store.get(key)) as Orchestrated | undefined
  const from = cursorSeq(out.cursor)
  await $.store.set(key, {
    server,
    // A later send keeps the earlier start, so replies to the first message still count.
    from: was?.from ?? from,
    sent: [...new Set([...(was?.sent ?? []), ...ids(out)])],
    read: was?.read ?? -1,
    at: now,
  } satisfies Orchestrated)
  await prune($, now)
}

async function markRead($: EngineInterface, server: McpToolName, conversationId: string, out: Record<string, unknown>) {
  const key = KEY + conversationId
  const v = (await $.store.get(key)) as Orchestrated | undefined
  if (!v || v.server !== server) return
  const messages = [...(Array.isArray(out.messages) ? out.messages : []), ...(out.lastReply ? [out.lastReply] : [])] as Message[]
  const seen = messages.filter((m): m is Message & { seq: number } => typeof m.seq === 'number').sort((a, b) => a.seq - b.seq)
  const first = seen.find(m => isClaudes(m, v.sent))
  const from = v.from ?? (first ? first.seq - 1 : null)
  if (from === null) return
  let upTo = v.read
  let handedBack = false
  for (const m of seen) {
    if (m.seq <= from) continue
    // A message Claude did not cause (the user typing in Slack, a reply to them) hands the
    // conversation back: it and everything after it stay unread for the user.
    if (!isClaudes(m, v.sent)) {
      handedBack = true
      break
    }
    upTo = Math.max(upTo, m.seq)
  }
  if (upTo > v.read) {
    const r = await $.tool.call({ tool: `${server}__markConversationRead` as McpToolName, conversationId, lastReadSeq: upTo }).catch(() => null)
    if (r && !r.deny && !r.isError) v.read = upTo
  }
  if (handedBack) await $.store.delete(key)
  else await $.store.set(key, { ...v, from, at: Date.now() } satisfies Orchestrated)
}

// `server` is the tool name less its last part, so the mark goes to the same jr connector.
async function note($: EngineInterface, tool: string, input: { conversationId?: unknown }, r: ToolCallResult) {
  const [, server, name] = tool.match(JR_TOOL) ?? []
  const out = parse(r)
  const conversationId = typeof input.conversationId === 'string' ? input.conversationId : out?.conversationId
  // jr answers each of these with a cursor (a list, with nextCursor); another server's
  // tool of the same name does not.
  const isJr = typeof out?.cursor === 'string' || (name === 'listConversationMessages' && Array.isArray(out?.messages))
  if (!server || !out || !isJr || typeof conversationId !== 'string') return
  if (name === 'createConversation' || name === 'sendMessage') await remember($, server as McpToolName, conversationId, out)
  else await markRead($, server as McpToolName, conversationId, out)
}

export function registerJrRead(on: On) {
  on('tool.call', { tool: JR_TOOL }, async ($, e, next) => {
    const r = await next(e)
    if (r.deny || r.isError) return r
    // Read state is a convenience; the model gets its answer whatever happens here.
    await note($, e.tool, e as { conversationId?: unknown }, r).catch(err =>
      $.ui.log(`taskboard: jr read state not updated: ${String((err as Error).message ?? err)}`),
    )
    return r
  })
}
