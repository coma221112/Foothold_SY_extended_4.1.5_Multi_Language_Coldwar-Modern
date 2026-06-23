# llmbridge

`llmbridge.dll` is a x64 Lua C module for DCS Hook Lua.

Lua API:

```lua
local open = package.loadlib([[C:\path\llmbridge.dll]], "luaopen_llmbridge")
local llm = open()

local ok, err = llm.submit(state_json)
local result_json = llm.poll()
local status, status_err = llm.status()
llm.shutdown()
```

Behavior:

- `submit(payload)` returns immediately.
- A single background worker thread owns HTTPS requests.
- `poll()` returns `nil` when no result is ready.
- `poll()` returns JSON text like `{"id":1,"ok":true,"text":"..."}` or `{"id":1,"ok":false,"error":"..."}`.
- `status()` returns `idle`, `busy`, `error`, or `shutdown`.
- `shutdown()` stops and joins the worker.

Config and log files live beside `llmbridge.dll`:

- Config is read from `Scripts\LLM\.llmenv`.
- Logs are written to `Scripts\LLM\native.log`.
- `GEMINI_API_KEY` is required.
- `FOOTHOLD_LLM_MODEL` defaults to `gemini-2.0-flash`.
- `FOOTHOLD_LLM_HTTP_TIMEOUT_MS` defaults to `12000`.
- `FOOTHOLD_LLM_RETRIES` defaults to `2`.
- `FOOTHOLD_LLM_SYSTEM_PROMPT` overrides the default radio-controller prompt.

Example `.llmenv`:

```text
GEMINI_API_KEY=your-key
FOOTHOLD_LLM_MODEL=gemini-2.0-flash
FOOTHOLD_LLM_HTTP_TIMEOUT_MS=12000
FOOTHOLD_LLM_RETRIES=2
```

Build:

```powershell
.\build.ps1
```

Output:

```text
native\llmbridge\build\llmbridge.dll
```

Hook example:

```text
Scripts\Hooks\FootholdLLMHook_native.lua
```
