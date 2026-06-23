# Foothold LLM Bridge Status

## Current Architecture

The active bridge is the native DLL path:

```text
Mission Lua
  -> exports _G.FootholdStateForHook

DCS Hook Lua
  -> loads llmbridge.dll with package.loadlib()
  -> calls llm.submit(state_json)
  -> polls llm.poll()
  -> writes _G.FootholdPendingRadioText back into mission

llmbridge.dll
  -> owns one background worker thread
  -> uses WinHTTP for Gemini HTTPS requests
  -> returns result JSON to Hook Lua
```

The old Python bridge and LuaSec direct-HTTPS Hook experiments have been removed from deployment.

## Dedicated Server Deployment

Target Saved Games directory:

```text
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease
```

Installed files:

```text
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\FootholdLLMHook.lua
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\llmbridge.dll
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\.llmenv
C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\Scripts\LLM\llmbridge_README.md
```

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

Current keys:

```text
GEMINI_API_KEY=...
FOOTHOLD_LLM_MODEL=gemini-3.1-flash-lite
FOOTHOLD_LLM_HTTP_TIMEOUT_MS=60000
FOOTHOLD_LLM_RETRIES=2
```

Optional:

```text
FOOTHOLD_LLM_SYSTEM_PROMPT=...
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

- exports `_G.FootholdStateForHook`
- polls `_G.FootholdPendingRadioText`
- displays pending text with `trigger.action.outText()` / coalition message

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
llm.submit(payload)
llm.poll()
llm.status()
llm.shutdown()
```

Behavior:

- `submit()` is non-blocking.
- DLL worker thread owns HTTPS calls.
- Hook polls completed results.
- Worker uses WinHTTP, timeout, and retry settings from `.llmenv`.

## Verified

Native bridge was tested in normal DCS and reached Gemini successfully:

```text
DLL request response id=1 http_status=200
DLL request ok id=1
HOOK native poll ok: ...
```

Instant Action testing confirmed:

- Hook can load DLL.
- DLL can call Gemini.
- Hook can receive result.
- Hook cannot directly use `trigger.action.outText()` in arbitrary Instant Action because `trigger` is nil in that Hook/dostring context.

For actual right-side mission text, use the modified Foothold mission with `Foothold_LLM_Export.lua` loaded.

## Cleaned Up

Removed from single-player Saved Games deployment:

```text
C:\Users\Drac\Saved Games\DCS\Scripts\Hooks\FootholdLLMHook.lua
C:\Users\Drac\Saved Games\DCS\Scripts\LLM\llmbridge.dll
C:\Users\Drac\Saved Games\DCS\Scripts\LLM\.llmenv
C:\Users\Drac\Saved Games\DCS\Scripts\LLM\native.log
```

Removed old deployed remnants:

- Hook `.bak-*` files
- Python bridge agent
- old `llmbridge_api_key.txt`
- old Python README

## Remaining Work

1. Test on the actual dedicated server profile.
   - Start/reload a mission under `DCS.dcs_serverrelease`.
   - Confirm Hook loads from `DCS.dcs_serverrelease\Scripts\Hooks`.
   - Check `Scripts\LLM\native.log`.

2. Test with the modified Foothold mission, not Instant Action.
   - Confirm `Foothold_LLM_Export.lua` loads.
   - Confirm `_G.FootholdLLM` exists in mission state.
   - Confirm `_G.FootholdPendingRadioText` is displayed by mission-side polling.

3. Decide final fallback display behavior.
   - Current Hook uses `net.send_chat()` fallback when direct mission outText is unavailable.
   - For dedicated server, mission-side display should be the primary path.

4. Reduce debug noise after validation.
   - Current `native.log` is intentionally verbose.
   - Later reduce repeated `native status: idle` logging or add log level support.

5. Add log rotation or truncation.
   - `Scripts\LLM\native.log` currently grows indefinitely.

6. Harden Gemini payload/prompt.
   - Current DLL sends the full submitted JSON with a fixed system prompt.
   - Consider prompt size limits, state summarization, and token budgeting.

7. Validate mission state size.
   - Hook currently rejects state JSON above `maxStateChars`.
   - Confirm exported Foothold state stays under this limit during real server play.

8. Review API key handling.
   - `.llmenv` contains the key in plain text.
   - Acceptable for local server operation, but keep file permissions in mind.

9. Optional: remove `net.send_chat()` fallback if dedicated-only deployment does not need Instant Action diagnostics.
