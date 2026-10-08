# Setup: KDB-X licence and Gemini API key

You need two things before Phase 1 can run:

1. A **KDB-X Community Edition licence** (`kc.lic`). The KDB-X container and the MCP server (pykx) both need it.
2. A **Gemini API key** for the agent (free tier).

Neither costs money.

---

## 1. KDB-X Community Edition licence

### 1.1 Sign up

1. Go to the KX Developer Center: <https://developer.kx.com/products/kdb-x/install>
2. Sign up for **KDB-X Community Edition** (free for personal and commercial use).
3. Check your inbox for the **welcome email**. It contains your licence key as one long **base64 string**. This is your `kc.lic`, encoded.

Community Edition limits: max 16 GB RAM, a single instance, and max 4 secondary threads per q process. Our ~26k-row demo is far below these.

### 1.2 Collect your licence key and download token

Log in to the Developer Center again and open the KDB-X install page. It shows a ready-made install command with two values filled in:

```bash
curl -sSLO --fail-with-body --oauth2-bearer <AUTH_TOKEN> \
  https://portal.dl.kx.com/assets/raw/kdb-x/install_kdb/~latest~/install_kdb.sh && \
  bash install_kdb.sh --b64lic <LICENSE_KEY>
```

- `<LICENSE_KEY>`: the base64 licence (the same one as in the email)
- `<AUTH_TOKEN>`: a bearer token that lets you download KDB-X

**You don't have to run this command on your Mac.** We install KDB-X inside Docker. Copy out the two values instead.

> KX says to paste the licence key exactly as given: no quotes, no added spaces, no reformatting.

### 1.3 Save them to `~/qlic`

Keep the secrets outside the repo, in `~/qlic`:

```bash
mkdir -p ~/qlic && chmod 700 ~/qlic

# 1. Decode the base64 licence into kc.lic
#    (paste the key between the single quotes, exactly as given)
echo '<LICENSE_KEY>' | base64 -d > ~/qlic/kc.lic

chmod 600 ~/qlic/*
```

Then point `QLIC` at that directory. Add this line to `~/.zshrc` or `~/.bash_profile`:

```bash
export QLIC=$HOME/qlic
```

Check:

```bash
echo $QLIC        # /Users/<you>/qlic
ls -l ~/qlic      # kc.lic
```

How the project uses these files:

| File | Used by |
|---|---|
| `~/qlic/kc.lic` | Mounted read-only into the KDB-X container (`QLIC`). Also read by the MCP server's pykx on the host. |

The Docker build downloads the KDB-X binaries without the token. If KX starts requiring it (HTTP 401 during `make kdb`), the download step in `kdb/Dockerfile` will need it.

### 1.4 (Optional) Quick check on the Mac

To confirm the licence works before Docker is set up, run the install command from the Developer Center natively. KDB-X supports macOS on Apple Silicon. It installs into `~/.kx`. Then:

```bash
q
# KDB-X <version> <date> Copyright (C) 1993-2026 Kx Systems ...
q)1+1
2
q)\\
```

This step is optional, since the project doesn't need q on the host.

### 1.5 Troubleshooting

- **`licence error` or `k4.lic` missing:** `QLIC` must point at the *directory* that holds `kc.lic`, not at the file itself.
- **Base64 decode fails:** the key was probably reformatted when copied. Copy it again from the email or Developer Center as a single line.

### References

- KDB-X install guide: <https://code.kx.com/get_started/kdb-x-install.html>
- Licence installation: <https://code.kx.com/licensing/installing.html>
- Developer Center: <https://developer.kx.com/products/kdb-x/install>
- KDB-X MCP server: <https://github.com/KxSystems/kdb-x-mcp-server>

---

## 2. Gemini API key (free tier)

1. Go to Google AI Studio: <https://aistudio.google.com/apikey> and sign in with a Google account.
2. Click **Create API key**. No credit card is needed for the free tier.
3. Put the key in `kdb-ai-chat/agent/.env`:

   ```bash
   GOOGLE_API_KEY=<your key>
   ```

Notes:
- A Google AI Pro / Gemini app subscription does **not** add API quota. The API free tier is separate.
- Free-tier limits are per project, and Google shows them only in the AI Studio rate-limit console. Expect a few requests per minute. One chat question takes 2–3 model calls.
- Google may use free-tier traffic to improve its products. That's fine here, because all the price data is fictional.
- To switch to Claude or a paid tier later, change `AGENT_MODEL` (and set the matching key) in `agent/.env`. No code changes are needed.

References:
- Gemini API pricing and free-tier models: <https://ai.google.dev/gemini-api/docs/pricing>
- Pydantic AI Google models: <https://pydantic.dev/docs/ai/models/google/>
