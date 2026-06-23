-- Install to: Saved Games\DCS\Scripts\Hooks\FootholdLLMHook.lua
-- Native DLL bridge mode. Requires Scripts\LLM\llmbridge.dll.

local writeDir = (lfs and lfs.writedir and lfs.writedir()) or [[C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\]]

local cfg = {
	enabled = true,
	pollIntervalSec = 2,
	stateExportIntervalSec = 15,
	minBroadcastIntervalSec = 180,
	maxStateChars = 60000,
	maxReplyChars = 1200,
	repeatStartupSec = 600,
	repeatEverySec = 8,

	dllPath = writeDir .. [[Scripts\LLM\llmbridge.dll]],
	envPath = writeDir .. [[Scripts\LLM\.llmenv]],
	logPath = writeDir .. [[Scripts\LLM\native.log]],
	apiKey = (os and os.getenv and os.getenv("GEMINI_API_KEY")) or "",
}

local llm = nil
local lastStateExport = 0
local lastBroadcast = 0
local lastSeq = nil
local lastPoll = 0
local lastStatusLog = 0
local startupSubmitted = false
local startupPendingResult = false
local startupRepeat = nil
local displaySelfTestDone = false
local missionDisplayFailureLogged = false
local missionPollerMissingLogged = false
local ensureDir

local function log(message)
	if ensureDir then ensureDir(writeDir .. [[Scripts\LLM]]) end
	local f = io.open(cfg.logPath, "ab")
	if f then
		f:write(os.date("%Y-%m-%d %H:%M:%S"), " HOOK ", tostring(message), "\r\n")
		f:close()
	end
	if net and net.log then
		net.log("[FootholdLLMHook] " .. tostring(message))
	end
end

local function now()
	if DCS and DCS.getRealTime then return DCS.getRealTime() end
	return os.clock()
end

ensureDir = function(path)
	if not (lfs and lfs.mkdir) then return end
	local current = ""
	for part in tostring(path):gmatch("[^\\]+") do
		if current == "" then current = part else current = current .. "\\" .. part end
		if not current:match(":$") then pcall(lfs.mkdir, current) end
	end
end

local function writeAllAtomic(path, text)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "wb")
	if not f then return false end
	f:write(text or "")
	f:close()
	os.remove(path)
	return os.rename(tmp, path) == true
end

local function luaStringLiteral(value)
	value = tostring(value or "")
	value = value:gsub("\\", "\\\\")
	value = value:gsub("\r", "\\r")
	value = value:gsub("\n", "\\n")
	value = value:gsub("\"", "\\\"")
	return '"' .. value .. '"'
end

local function directMissionOutText(text, duration, coalitionSide)
	if not text or text == "" then return end
	duration = tonumber(duration) or 10
	coalitionSide = tonumber(coalitionSide)

	local script
	if coalitionSide == 1 or coalitionSide == 2 then
		script = "trigger.action.outTextForCoalition(" .. tostring(coalitionSide) .. "," .. luaStringLiteral(text) .. "," .. tostring(duration) .. "); return true"
	else
		script = "trigger.action.outText(" .. luaStringLiteral(text) .. "," .. tostring(duration) .. "); return true"
	end
	local ok, result = pcall(net.dostring_in, "mission", script)
	if ok and result == true then
		log("direct mission outText displayed duration=" .. tostring(duration) .. " coalition=" .. tostring(coalitionSide or "all") .. " text=" .. tostring(text):sub(1, 120))
	elseif not missionDisplayFailureLogged then
		missionDisplayFailureLogged = true
		log("direct mission outText unavailable: " .. tostring(result) .. " script=" .. script:sub(1, 220))
	end

	if not (ok and result == true) and net and net.send_chat then
		local chatOk, chatErr = pcall(net.send_chat, tostring(text), true)
		log("fallback net.send_chat ok=" .. tostring(chatOk) .. " result=" .. tostring(chatErr))
	end
end

local function setMissionRadioText(text, duration, coalitionSide)
	if not text or text == "" then return end
	local pendingScript =
		"_G.FootholdPendingRadioText = {text=" .. luaStringLiteral(text)
		.. ",duration=" .. tostring(tonumber(duration) or 10)
		.. ",coalition=" .. tostring(tonumber(coalitionSide) or 0)
		.. "}; return true"
	local ok, result = pcall(net.dostring_in, "mission", pendingScript)
	log("pending radio set ok=" .. tostring(ok) .. " result=" .. tostring(result))
	local pollerOk, pollerResult = pcall(net.dostring_in, "mission", "return _G.FootholdLLM and true or false")
	if (not pollerOk or pollerResult ~= true) and not missionPollerMissingLogged then
		missionPollerMissingLogged = true
		log("mission-side FootholdLLM poller not detected; pending radio text will not display unless Foothold_LLM_Export.lua is loaded in this mission")
	end
	directMissionOutText(text, duration, coalitionSide)
end

local function decodeJsonString(value)
	value = tostring(value or "")
	value = value:gsub("\\u(%x%x%x%x)", function(hex)
		local code = tonumber(hex, 16)
		if not code then return "" end
		if code < 128 then return string.char(code) end
		if code < 2048 then return string.char(192 + math.floor(code / 64), 128 + (code % 64)) end
		return string.char(224 + math.floor(code / 4096), 128 + (math.floor(code / 64) % 64), 128 + (code % 64))
	end)
	value = value:gsub('\\"', '"')
	value = value:gsub("\\\\", "\\")
	value = value:gsub("\\/", "/")
	value = value:gsub("\\b", "\b")
	value = value:gsub("\\f", "\f")
	value = value:gsub("\\n", "\n")
	value = value:gsub("\\r", "\r")
	value = value:gsub("\\t", "\t")
	return value
end

local function jsonString(body, name)
	local value = tostring(body or ""):match('"' .. name .. '"%s*:%s*"(.-)"')
	return value and decodeJsonString(value) or nil
end

local function jsonBool(body, name)
	local value = tostring(body or ""):match('"' .. name .. '"%s*:%s*(true)') or tostring(body or ""):match('"' .. name .. '"%s*:%s*(false)')
	return value == "true"
end

local function loadBridge()
	if llm then return true end
	ensureDir(writeDir .. [[Scripts\LLM]])
	if cfg.apiKey and cfg.apiKey ~= "" then
		local existing = nil
		local f = io.open(cfg.envPath, "rb")
		if f then existing = f:read("*a"); f:close() end
		if not existing or not existing:match("GEMINI_API_KEY%s*=") then
			writeAllAtomic(cfg.envPath, table.concat({
				"# Foothold LLM native bridge config",
				"GEMINI_API_KEY=" .. tostring(cfg.apiKey),
				"FOOTHOLD_LLM_MODEL=gemini-2.0-flash",
				"FOOTHOLD_LLM_HTTP_TIMEOUT_MS=12000",
				"FOOTHOLD_LLM_RETRIES=2",
				"",
			}, "\r\n"))
		end
	end

	local open, err = package.loadlib(cfg.dllPath, "luaopen_llmbridge")
	if not open then
		log("load llmbridge failed: " .. tostring(err))
		return false
	end
	local ok, mod = pcall(open)
	if not ok or type(mod) ~= "table" then
		log("open llmbridge failed: " .. tostring(mod))
		return false
	end
	llm = mod
	log("loaded native llmbridge")
	return true
end

local function submitStartupTest()
	if startupSubmitted or not llm then return end
	startupSubmitted = true
	local ok, err = llm.submit('{"test":"Reply with one short sentence: Gemini API test successful."}')
	if ok then
		startupPendingResult = true
		log("startup test submitted")
	else
		setMissionRadioText("[Foothold LLM] native submit failed: " .. tostring(err), 12, 0)
	end
end

local function submitStateIfReady()
	if not llm then return end
	local status = llm.status()
	if status == "busy" then return end

	local t = now()
	if t - lastBroadcast < cfg.minBroadcastIntervalSec then return end
	if t - lastStateExport < cfg.stateExportIntervalSec then return end
	lastStateExport = t

	local ok, stateJson = pcall(net.dostring_in, "mission", "return _G.FootholdStateForHook or '{}'")
	if not ok or type(stateJson) ~= "string" or stateJson == "" or stateJson == "{}" then return end
	if #stateJson > cfg.maxStateChars then
		log("state JSON too large for native bridge: " .. tostring(#stateJson))
		return
	end
	local seq = stateJson:match('"seq"%s*:%s*(%d+)')
	if seq and seq == lastSeq then return end

	local submitted, err = llm.submit(stateJson)
	if submitted then
		lastSeq = seq
		lastBroadcast = t
	else
		log("native submit failed: " .. tostring(err))
	end
end

local function pollResult()
	if not llm then return end
	local result = llm.poll()
	if not result then return end

	local ok = jsonBool(result, "ok")
	if not ok then
		local err = jsonString(result, "error") or "unknown"
		log("native poll error: " .. err)
		setMissionRadioText("[Foothold LLM] native request failed: " .. err, 12, 0)
		return
	end

	local text = jsonString(result, "text")
	if not text or text == "" then return end
	log("native poll ok: " .. text:sub(1, 160))
	if #text > cfg.maxReplyChars then text = text:sub(1, cfg.maxReplyChars) end

	if startupPendingResult then
		startupPendingResult = false
		text = "[Foothold LLM] native Gemini test OK: " .. text
		startupRepeat = { text = text, untilTime = now() + cfg.repeatStartupSec, lastShown = 0 }
		setMissionRadioText(text, 11, 0)
	else
		setMissionRadioText(text, 25, 2)
	end
end

local function logStatus()
	if not llm then return end
	local t = now()
	if t - lastStatusLog < 10 then return end
	lastStatusLog = t
	local ok, status, err = pcall(llm.status)
	if ok then
		if err then
			log("native status: " .. tostring(status) .. " / " .. tostring(err):sub(1, 220))
		else
			log("native status: " .. tostring(status))
		end
	else
		log("native status call failed: " .. tostring(status))
	end
end

local function tickStartupRepeat()
	if not startupRepeat then return end
	local t = now()
	if t > startupRepeat.untilTime then startupRepeat = false return end
	if t - startupRepeat.lastShown < cfg.repeatEverySec then return end
	startupRepeat.lastShown = t
	setMissionRadioText(startupRepeat.text, 11, 0)
end

local callbacks = {}

function callbacks.onSimulationStart()
	if not cfg.enabled then return end
	if not displaySelfTestDone then
		displaySelfTestDone = true
		directMissionOutText("[Foothold LLM] Hook display self-test", 30, 0)
	end
	if loadBridge() then
		submitStartupTest()
	end
end

function callbacks.onSimulationStop()
	if llm then pcall(llm.shutdown) end
end

function callbacks.onSimulationFrame()
	if not cfg.enabled then return end
	local t = now()
	tickStartupRepeat()
	logStatus()
	if t - lastPoll < cfg.pollIntervalSec then return end
	lastPoll = t
	pollResult()
	submitStateIfReady()
end

DCS.setUserCallbacks(callbacks)
