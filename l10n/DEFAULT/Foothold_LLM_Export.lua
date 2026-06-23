FootholdLLMConfig = FootholdLLMConfig or {}

local FootholdLLM = {}
FootholdLLM.version = "0.1.0"
FootholdLLM.config = {
	enabled = FootholdLLMConfig.enabled ~= false,
	exportInterval = FootholdLLMConfig.exportInterval or 15,
	radioPollInterval = FootholdLLMConfig.radioPollInterval or 3,
	broadcastDuration = FootholdLLMConfig.broadcastDuration or 25,
	broadcastCoalition = FootholdLLMConfig.broadcastCoalition or coalition.side.BLUE,
	maxJsonBytes = FootholdLLMConfig.maxJsonBytes or 60000,
	maxZones = FootholdLLMConfig.maxZones or 120,
	maxGroups = FootholdLLMConfig.maxGroups or 180,
	maxPlayers = FootholdLLMConfig.maxPlayers or 64,
	includeGroups = FootholdLLMConfig.includeGroups ~= false,
	includePlayers = FootholdLLMConfig.includePlayers ~= false,
}

_G.FootholdStateForHook = _G.FootholdStateForHook or "{}"
_G.FootholdStateForHookSeq = _G.FootholdStateForHookSeq or 0
_G.FootholdPendingRadioText = _G.FootholdPendingRadioText or nil
_G.FootholdLLM = FootholdLLM

local function log(message)
	if env and env.info then
		env.info("[FootholdLLM] " .. tostring(message))
	end
end

local function sideName(side)
	if side == coalition.side.RED then return "red" end
	if side == coalition.side.BLUE then return "blue" end
	if side == coalition.side.NEUTRAL then return "neutral" end
	return tostring(side or "unknown")
end

local function round(value)
	if type(value) ~= "number" then return nil end
	return math.floor(value + 0.5)
end

local function jsonEscape(value)
	value = tostring(value or "")
	value = value:gsub("\\", "\\\\")
	value = value:gsub("\"", "\\\"")
	value = value:gsub("\b", "\\b")
	value = value:gsub("\f", "\\f")
	value = value:gsub("\n", "\\n")
	value = value:gsub("\r", "\\r")
	value = value:gsub("\t", "\\t")
	value = value:gsub("[%z\1-\31]", function(c)
		return string.format("\\u%04x", string.byte(c))
	end)
	return value
end

local function isArray(t)
	if type(t) ~= "table" then return false end
	local max, count = 0, 0
	for k, _ in pairs(t) do
		if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
		if k > max then max = k end
		count = count + 1
	end
	return max == count
end

local function encodeJson(value, depth)
	depth = depth or 0
	if depth > 8 then return "null" end
	local valueType = type(value)
	if valueType == "nil" then return "null" end
	if valueType == "boolean" then return value and "true" or "false" end
	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return "null" end
		return tostring(value)
	end
	if valueType == "string" then return "\"" .. jsonEscape(value) .. "\"" end
	if valueType ~= "table" then return "null" end

	local parts = {}
	if isArray(value) then
		for i = 1, #value do
			parts[#parts + 1] = encodeJson(value[i], depth + 1)
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end

	for k, v in pairs(value) do
		parts[#parts + 1] = "\"" .. jsonEscape(k) .. "\":" .. encodeJson(v, depth + 1)
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

local function getZonePoint(zoneName)
	local ok, zone = pcall(trigger.misc.getZone, zoneName)
	if ok and zone and zone.point then
		return { x = round(zone.point.x), z = round(zone.point.z), radius = round(zone.radius) }
	end
	return nil
end

local function collectZones()
	local out = {}
	local sourceZones = {}
	if bc and bc.getZones then
		local ok, result = pcall(function() return bc:getZones() end)
		if ok and type(result) == "table" then sourceZones = result end
	elseif type(zones) == "table" then
		for _, zone in pairs(zones) do
			sourceZones[#sourceZones + 1] = zone
		end
	end

	for _, z in ipairs(sourceZones) do
		if #out >= FootholdLLM.config.maxZones then break end
		if z and z.zone and z.active ~= false and not z.isHidden then
			local builtCount = 0
			for _, _ in pairs(z.built or {}) do builtCount = builtCount + 1 end
			out[#out + 1] = {
				name = z.zone,
				side = z.side or 0,
				sideName = sideName(z.side),
				level = z.level,
				size = z.size,
				active = z.active ~= false,
				suspended = z.suspended == true,
				airbase = z.airbaseName,
				income = z.income,
				upgradesBuilt = builtCount,
				upgradesUsed = z.upgradesUsed,
				blueNear = z.BlueIsNear == true,
				redNear = z.RedIsNear == true,
				point = getZonePoint(z.zone),
			}
		end
	end
	return out
end

local function collectGroups()
	if not FootholdLLM.config.includeGroups then return {} end
	local out = {}
	local sourceZones = (bc and bc.getZones and bc:getZones()) or {}
	for _, z in ipairs(sourceZones) do
		for _, gc in ipairs((z and z.groups) or {}) do
			if #out >= FootholdLLM.config.maxGroups then return out end
			out[#out + 1] = {
				name = gc.name,
				homeZone = z.zone,
				side = gc.side,
				sideName = sideName(gc.side),
				mission = gc.mission,
				missionType = gc.MissionType,
				unitCategory = gc.unitCategory,
				type = gc.type,
				state = gc.state,
				targetZone = gc.targetzone,
				urgent = gc.urgent == true,
			}
		end
	end
	return out
end

local function collectPlayers()
	if not FootholdLLM.config.includePlayers then return {} end
	local out = {}
	for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
		local ok, players = pcall(coalition.getPlayers, side)
		if ok and type(players) == "table" then
			for _, unit in ipairs(players) do
				if #out >= FootholdLLM.config.maxPlayers then return out end
				local okName, playerName = pcall(function() return unit:getPlayerName() end)
				if okName and playerName then
					local okPoint, point = pcall(function() return unit:getPoint() end)
					local okType, typeName = pcall(function() return unit:getTypeName() end)
					local okGroup, group = pcall(function() return unit:getGroup() end)
					local groupName = nil
					if okGroup and group then
						pcall(function() groupName = group:getName() end)
					end
					out[#out + 1] = {
						name = playerName,
						side = side,
						sideName = sideName(side),
						unit = okType and typeName or nil,
						group = groupName,
						point = okPoint and point and { x = round(point.x), z = round(point.z), alt = round(point.y) } or nil,
					}
				end
			end
		end
	end
	return out
end

local function collectState()
	local state = {
		version = FootholdLLM.version,
		seq = (_G.FootholdStateForHookSeq or 0) + 1,
		missionTime = round(timer.getTime()),
		absTime = round(timer.getAbsTime()),
		theatre = env and env.mission and env.mission.theatre,
		era = Era,
		zones = collectZones(),
		players = collectPlayers(),
		groups = collectGroups(),
		accounts = (bc and bc.accounts) and {
			red = round(bc.accounts[coalition.side.RED] or 0),
			blue = round(bc.accounts[coalition.side.BLUE] or 0),
		} or nil,
	}
	state.counts = { zones = #state.zones, players = #state.players, groups = #state.groups }
	return state
end

function FootholdLLM.exportNow()
	if not FootholdLLM.config.enabled then return end
	local ok, state = pcall(collectState)
	if not ok then
		log("state export failed: " .. tostring(state))
		return
	end

	local json = encodeJson(state)
	local maxBytes = FootholdLLM.config.maxJsonBytes
	if maxBytes and #json > maxBytes then
		state.groups = {}
		state.truncated = true
		state.truncatedReason = "maxJsonBytes"
		state.counts.groups = 0
		json = encodeJson(state)
	end

	if maxBytes and #json > maxBytes then
		state.players = {}
		state.truncated = true
		state.counts.players = 0
		json = encodeJson(state)
	end

	_G.FootholdStateForHookSeq = state.seq
	_G.FootholdStateForHook = json
end

local function broadcastPendingRadio()
	local pending = _G.FootholdPendingRadioText
	if pending == nil or pending == "" then return end
	_G.FootholdPendingRadioText = nil

	local text, coalitionSide, duration
	if type(pending) == "table" then
		text = pending.text
		coalitionSide = pending.coalition or FootholdLLM.config.broadcastCoalition
		duration = pending.duration or FootholdLLM.config.broadcastDuration
	else
		text = tostring(pending)
		coalitionSide = FootholdLLM.config.broadcastCoalition
		duration = FootholdLLM.config.broadcastDuration
	end

	if text and text ~= "" then
		if coalitionSide == coalition.side.RED or coalitionSide == coalition.side.BLUE then
			trigger.action.outTextForCoalition(coalitionSide, text, duration)
		else
			trigger.action.outText(text, duration)
		end
	end
end

timer.scheduleFunction(function(_, time)
	FootholdLLM.exportNow()
	return time + FootholdLLM.config.exportInterval
end, {}, timer.getTime() + 2)

timer.scheduleFunction(function(_, time)
	local ok, err = pcall(broadcastPendingRadio)
	if not ok then log("radio poll failed: " .. tostring(err)) end
	return time + FootholdLLM.config.radioPollInterval
end, {}, timer.getTime() + 3)

FootholdLLM.exportNow()
log("mission export started")
