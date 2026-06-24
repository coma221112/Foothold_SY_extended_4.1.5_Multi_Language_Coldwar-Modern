# llmbridge

`llmbridge.dll` is a x64 Lua C module for DCS Lua.

Lua API:

```lua
local open = package.loadlib([[C:\path\llmbridge.dll]], "luaopen_llmbridge")
local llm = open()

local ok, request_id_or_error = llm.submit(state_json)
local result_json = llm.poll()
local status, status_err = llm.status()
llm.shutdown()
```

Behavior:

- `submit(payload)` returns immediately with `true, request_id` or `false, error`.
- A single background worker thread owns OpenAI-compatible HTTP(S) chat completion requests.
- `poll()` returns `nil` when no result is ready.
- `poll()` returns JSON text like `{"id":1,"ok":true,"text":"..."}` or `{"id":1,"ok":false,"error":"..."}`.
- `status()` returns `idle`, `busy`, `error`, or `shutdown`.
- `shutdown()` stops and joins the worker.

Config, DLL, logs, and runtime work files live in the same directory:

- DLL is loaded from `C:\Users\Drac\Saved Games\DCS\Missions\LLM\llmbridge.dll`.
- Config is read from `C:\Users\Drac\Saved Games\DCS\Missions\LLM\.llmenv`.
- Logs are written to `LLM_LOG_DIR` / `LLM_WORK_DIR` when set, otherwise beside `llmbridge.dll`.
- `LLM_BASE_URL` defaults to Google Gemini's OpenAI-compatible endpoint.
- `LLM_API_KEY` is sent as `Authorization: Bearer ...` when non-empty.
- `LLM_MODEL` defaults to `gemini-3.1-flash-lite`.
- `LLM_TIMEOUT_MS` defaults to `12000`.
- `LLM_RETRIES` defaults to `2`.
- `LLM_SYSTEM_PROMPT` overrides the default radio-controller prompt.
- `LLM_REASONING_ENABLED` enables provider-specific reasoning/thinking when supported.
- `LLM_REASONING_EFFORT` is passed to OpenAI-style endpoints as `reasoning_effort`.
- For local endpoints on `127.0.0.1` or `localhost`, the DLL maps `LLM_REASONING_ENABLED` to `chat_template_kwargs.enable_thinking`.
- `LLM_DEBUG_IO=true` writes raw request and response bodies to `inputoutput.log` in the same log/work directory.
- `LLM_EXTRA_BODY_JSON` is an advanced escape hatch merged into the top-level chat completion body.

Legacy DLL keys such as `GEMINI_API_KEY`, `FOOTHOLD_LLM_MODEL`, `FOOTHOLD_LLM_HTTP_TIMEOUT_MS`, `FOOTHOLD_LLM_RETRIES`, and `FOOTHOLD_LLM_SYSTEM_PROMPT` are still accepted as fallbacks.

Example `.llmenv`:

```text
# Gemini OpenAI-compatible:
LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
LLM_API_KEY=your-google-api-key
LLM_MODEL=gemini-3.1-flash-lite

# DeepSeek:
# LLM_BASE_URL=https://api.deepseek.com
# LLM_API_KEY=your-deepseek-api-key
# LLM_MODEL=deepseek-chat

# Local OpenAI-compatible server, such as vLLM, llama.cpp server, or LM Studio:
# LLM_BASE_URL=http://127.0.0.1:8000/v1
# LLM_API_KEY=
# LLM_MODEL=local-model

LLM_TIMEOUT_MS=60000
LLM_RETRIES=2
LLM_MAX_TOKENS=220
LLM_TEMPERATURE=0.55
LLM_REASONING_ENABLED=false
LLM_REASONING_EFFORT=medium
LLM_DEBUG_IO=false
LLM_WORK_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
LLM_LOG_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
# Advanced provider-specific override, normally leave empty:
LLM_EXTRA_BODY_JSON=

# Mission-side Foothold semantic radio exporter:
FOOTHOLD_LLM_ENABLED=true
FOOTHOLD_LLM_DLL_PATH=C:\Users\Drac\Saved Games\DCS\Missions\LLM\llmbridge.dll
FOOTHOLD_LLM_TICK_INTERVAL=10
FOOTHOLD_LLM_SUBMIT_INTERVAL=300
FOOTHOLD_LLM_BROADCAST_DURATION=30
FOOTHOLD_LLM_BROADCAST_COALITION=blue
FOOTHOLD_LLM_MAX_JSON_BYTES=90000
FOOTHOLD_LLM_MAX_REPLY_CHARS=2400
FOOTHOLD_LLM_MAX_ZONES=120
FOOTHOLD_LLM_MAX_MISSIONS=16
FOOTHOLD_LLM_MAX_AIR_UNITS=24
FOOTHOLD_LLM_RADIO_MIN_INTERVAL=25
FOOTHOLD_LLM_RADIO_MAX_INTERVAL=45
FOOTHOLD_LLM_DEBUG_FILES=false
FOOTHOLD_LLM_WORK_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
FOOTHOLD_LLM_DEBUG_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
```

Build:

```powershell
.\build.ps1
```

Output:

```text
native\llmbridge\build\llmbridge.dll
```

Mission example:

```text
l10n\DEFAULT\Foothold_LLM_Export.lua
```
