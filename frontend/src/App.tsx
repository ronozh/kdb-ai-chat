import { useEffect, useRef, useState } from 'react'

type Message =
  | { role: 'user'; text: string }
  | { role: 'assistant'; text: string; sql: string[]; durationMs: number }
  | { role: 'error'; text: string }

const USERS = ['demo', 'alice', 'bob']

async function ask(sessionId: string, user: string, question: string) {
  const res = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Demo-User': user },
    body: JSON.stringify({ session_id: sessionId, question }),
  })
  const body = await res.json().catch(() => null)
  if (!res.ok) {
    const reason = body?.error ?? `HTTP ${res.status}`
    const hint = res.status === 504 ? 'The agent took too long to answer.' : res.status === 502 ? 'The agent or model is unavailable.' : 'Request failed.'
    throw new Error(`${hint} (${reason})`)
  }
  return body as { session_id: string; answer: string; sql: string[]; duration_ms: number }
}

export default function App() {
  const [sessionId, setSessionId] = useState(() => crypto.randomUUID())
  const [user, setUser] = useState(USERS[0])
  const [messages, setMessages] = useState<Message[]>([])
  const [input, setInput] = useState('')
  const [loading, setLoading] = useState(false)
  const endRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, loading])

  async function send() {
    const question = input.trim()
    if (!question || loading) return
    setInput('')
    setMessages((m) => [...m, { role: 'user', text: question }])
    setLoading(true)
    try {
      const r = await ask(sessionId, user, question)
      setMessages((m) => [...m, { role: 'assistant', text: r.answer, sql: r.sql, durationMs: r.duration_ms }])
    } catch (e) {
      setMessages((m) => [...m, { role: 'error', text: e instanceof Error ? e.message : String(e) }])
    } finally {
      setLoading(false)
    }
  }

  function newConversation() {
    setSessionId(crypto.randomUUID())
    setMessages([])
  }

  return (
    <div className="app">
      <header>
        <h1>KDB AI Chat</h1>
        <label>
          User{' '}
          <select value={user} onChange={(e) => setUser(e.target.value)}>
            {USERS.map((u) => <option key={u}>{u}</option>)}
          </select>
        </label>
        <button onClick={newConversation}>New conversation</button>
      </header>

      <main className="messages">
        {messages.length === 0 && <p className="hint">Ask about simulated prices for tickers T001–T100, e.g. "What was the close of T001 on 2026-06-15?"</p>}
        {messages.map((m, i) => (
          <div key={i} className={`msg ${m.role}`}>
            <div className="text">{m.text}</div>
            {m.role === 'assistant' && (
              <details>
                <summary>Show SQL ({m.sql.length}) · {(m.durationMs / 1000).toFixed(1)}s</summary>
                {m.sql.length ? m.sql.map((q, j) => <pre key={j}>{q}</pre>) : <p>No query was run.</p>}
              </details>
            )}
          </div>
        ))}
        {loading && <div className="msg assistant loading">Thinking…</div>}
        <div ref={endRef} />
      </main>

      <footer>
        <textarea
          value={input}
          placeholder="Ask a question (Enter to send, Shift+Enter for a new line)"
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              send()
            }
          }}
          rows={2}
        />
        <button onClick={send} disabled={loading || !input.trim()}>Send</button>
      </footer>
    </div>
  )
}
