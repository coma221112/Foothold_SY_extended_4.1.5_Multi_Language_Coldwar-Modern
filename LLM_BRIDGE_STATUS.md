# Foothold LLM Bridge Status

## Current Architecture

The active bridge is the native DLL path:

```text
Mission Lua
  -> collects Foothold state
  -> loads llmbridge.dll with package.loadlib()
  -> calls llm.submit(state_json)
  -> records returned request ids
  -> polls llm.poll()
  -> displays only results matching this mission instance

llmbridge.dll
  -> owns one background worker thread
  -> uses WinHTTP for OpenAI-compatible chat completion requests
  -> returns result JSON to Mission Lua
```

The old Hook bridge, Python bridge, and LuaSec direct-HTTPS experiments have been removed from deployment.

## Dedicated Server Deployment

Target Saved Games directory:

```text
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease
```

Installed files:

```text
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\llmbridge.dll
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\.llmenv
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\llmbridge_README.md
```

`llmbridge.dll` in the dedicated-server directory is a hard link to:

```text
C:\Users\Drac\Saved Games\DCS\Scripts\LLM\llmbridge.dll
```

Windows symbolic-link creation required administrator privileges in this environment, so a hard link is used to avoid maintaining two separate DLL copies.

Log file:

```text
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\native.log
```

The DLL derives `.llmenv` and `native.log` from its own directory, so it should work under other Saved Games variants without recompilation.

## Configuration

Config file:

```text
Scripts\LLM\.llmenv
```

DLL request keys:

```text
LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
LLM_API_KEY=...
LLM_MODEL=gemini-3.1-flash-lite
LLM_TIMEOUT_MS=60000
LLM_RETRIES=2
LLM_MAX_TOKENS=220
LLM_TEMPERATURE=0.55
LLM_REASONING_ENABLED=false
LLM_REASONING_EFFORT=medium
LLM_DEBUG_IO=false
```

Mission exporter keys:

```text
FOOTHOLD_LLM_ENABLED=true
FOOTHOLD_LLM_TICK_INTERVAL=10
FOOTHOLD_LLM_SUBMIT_INTERVAL=300
FOOTHOLD_LLM_BROADCAST_DURATION=25
FOOTHOLD_LLM_BROADCAST_COALITION=blue
FOOTHOLD_LLM_DLL_PATH=
FOOTHOLD_LLM_MAX_JSON_BYTES=60000
FOOTHOLD_LLM_MAX_REPLY_CHARS=1200
FOOTHOLD_LLM_MAX_ZONES=120
FOOTHOLD_LLM_MAX_GROUPS=180
FOOTHOLD_LLM_MAX_PLAYERS=64
FOOTHOLD_LLM_INCLUDE_GROUPS=true
FOOTHOLD_LLM_INCLUDE_PLAYERS=true
```

Optional:

```text
LLM_SYSTEM_PROMPT=...
LLM_EXTRA_BODY_JSON=...
```

Reasoning is intentionally exposed as one switch plus one effort value. Local endpoints on `127.0.0.1` or `localhost` are mapped to `chat_template_kwargs.enable_thinking`; non-local OpenAI-style endpoints use `reasoning_effort` when reasoning is enabled.

Endpoint examples:

```text
# Gemini OpenAI-compatible
LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
LLM_MODEL=gemini-3.1-flash-lite

# DeepSeek
LLM_BASE_URL=https://api.deepseek.com
LLM_MODEL=deepseek-chat

# Local OpenAI-compatible server, such as vLLM, llama.cpp server, or LM Studio
LLM_BASE_URL=http://127.0.0.1:8000/v1
LLM_MODEL=local-model
```

The DLL also accepts `LLM_CHAT_COMPLETIONS_URL` when a provider needs an exact full URL ending in `/chat/completions`.

When `LLM_DEBUG_IO=true`, the DLL writes raw request and response bodies beside `native.log`:

```text
Scripts\LLM\inputoutput.log
```

## Mission-Side Files

Mission exporter:

```text
l10n\DEFAULT\Foothold_LLM_Export.lua
```

Mission resource registration:

```text
l10n\DEFAULT\mapResource
mission
```

Registered resource:

```text
ResKey_Action_662 = Foothold_LLM_Export.lua
```

The mission-side script:

- exports `_G.FootholdStateForLLM` for diagnostics
- loads `llmbridge.dll` directly from `Scripts\LLM`
- submits freshly collected state JSON every 300 seconds
- runs the LLM state-machine tick every 10 seconds
- polls native results during that tick only while a submitted request is pending
- displays matching results with `trigger.action.outText()` / coalition message

## Native DLL Source

Source and build files:

```text
native\llmbridge\llmbridge.cpp
native\llmbridge\build.ps1
native\llmbridge\README.md
native\llmbridge\build\llmbridge.dll
```

Exported Lua entry:

```c
int luaopen_llmbridge(lua_State* L);
```

Lua API:

```lua
local ok, request_id_or_error = llm.submit(payload)
llm.poll()
llm.status()
llm.shutdown()
```

Behavior:

- `submit()` is non-blocking.
- `submit()` returns `true, request_id` or `false, error`.
- DLL worker thread owns HTTPS calls.
- Mission Lua records request IDs and discards stale results from older mission instances.
- Worker uses WinHTTP, timeout, and retry settings from `.llmenv`.

## Verified

Native bridge was previously tested in normal DCS and reached Gemini successfully before the OpenAI-compatible protocol switch:

```text
DLL request response id=1 http_status=200
DLL request ok id=1
native poll ok: ...
```

Mission-direct DLL loading still needs validation after mission sandbox is relaxed.

## Cleaned Up

Removed old deployed remnants:

- Hook Lua bridge files
- Python bridge agent
- old `llmbridge_api_key.txt`
- old Python README

## Remaining Work

1. Test on the actual dedicated server profile.
   - Start/reload a mission under `DCS.dcs_serverrelease`.
   - Confirm mission sandbox changes allow `package.loadlib`.
   - Check `Scripts\LLM\native.log`.

2. Test with the modified Foothold mission, not Instant Action.
   - Confirm `Foothold_LLM_Export.lua` loads.
   - Confirm `_G.FootholdLLM` exists in mission state.
   - Confirm `native llmbridge loaded by mission` appears in DCS log.
   - Confirm LLM output is displayed by mission-side `trigger.action.outText`.

3. Reduce debug noise after validation.
   - Current `native.log` is intentionally verbose.
   - Later reduce repeated status/request logging or add log level support.

4. Add log rotation or truncation.
   - `Scripts\LLM\native.log` currently grows indefinitely.

5. Harden provider payload/prompt.
   - Current DLL sends the full submitted JSON with a fixed system prompt.
   - Consider prompt size limits, state summarization, and token budgeting.

6. Validate mission state size.
   - Confirm exported Foothold state stays under this limit during real server play.

7. Review API key handling.
   - `.llmenv` contains the key in plain text.
   - Acceptable for local server operation, but keep file permissions in mind.
