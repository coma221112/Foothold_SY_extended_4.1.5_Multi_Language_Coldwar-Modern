local FootholdLLM = {}
FootholdLLM.version = "0.2.0"

local defaultWriteDir = (lfs and lfs.writedir and lfs.writedir()) or [[C:\Users\Drac\Saved Games\DCS.dcs_serverrelease\]]
local defaultLlmDir = defaultWriteDir .. [[Missions\LLM\]]
local defaultWorkDir = defaultLlmDir
local defaultEnvPath = defaultLlmDir .. [[.llmenv]]

local function trim(value)
	value = tostring(value or "")
	value = value:gsub("^%s+", "")
	value = value:gsub("%s+$", "")
	return value
end

local function readEnvFile(path)
	local values = {}
	if not io or not io.open then return values end

	local file = io.open(path, "r")
	if not file then return values end

	for line in file:lines() do
		line = trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			if line:sub(1, 7) == "export " then line = trim(line:sub(8)) end
			local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
			if key then
				value = trim(value)
				local first, last = value:sub(1, 1), value:sub(-1)
				if #value >= 2 and ((first == '"' and last == '"') or (first == "'" and last == "'")) then
					value = value:sub(2, -2)
				end
				values[key] = value
			end
		end
	end

	file:close()
	return values
end

local llmEnv = readEnvFile(defaultEnvPath)

local function envString(key, defaultValue)
	local value = llmEnv[key]
	if value == nil or value == "" then return defaultValue end
	return value
end

local function envNumber(key, defaultValue)
	local value = tonumber(envString(key, ""))
	if value == nil then return defaultValue end
	return value
end

local function envBool(key, defaultValue)
	local value = envString(key, "")
	if value == "" then return defaultValue end
	value = value:lower()
	if value == "1" or value == "true" or value == "yes" or value == "on" then return true end
	if value == "0" or value == "false" or value == "no" or value == "off" then return false end
	return defaultValue
end

local function envCoalition(key, defaultValue)
	local value = envString(key, ""):lower()
	if value == "red" then return coalition.side.RED end
	if value == "blue" then return coalition.side.BLUE end
	if value == "all" or value == "both" then return 0 end
	return defaultValue
end

FootholdLLM.config = {
	enabled = envBool("FOOTHOLD_LLM_ENABLED", true),
	llmTickInterval = envNumber("FOOTHOLD_LLM_TICK_INTERVAL", 10),
	llmSubmitInterval = envNumber("FOOTHOLD_LLM_SUBMIT_INTERVAL", 300),
	broadcastDuration = envNumber("FOOTHOLD_LLM_BROADCAST_DURATION", 25),
	broadcastCoalition = envCoalition("FOOTHOLD_LLM_BROADCAST_COALITION", coalition.side.BLUE),
	dllPath = envString("FOOTHOLD_LLM_DLL_PATH", defaultLlmDir .. [[llmbridge.dll]]),
	maxJsonBytes = envNumber("FOOTHOLD_LLM_MAX_JSON_BYTES", 90000),
	maxReplyChars = envNumber("FOOTHOLD_LLM_MAX_REPLY_CHARS", 2400),
	maxZones = envNumber("FOOTHOLD_LLM_MAX_ZONES", 120),
	maxMissions = envNumber("FOOTHOLD_LLM_MAX_MISSIONS", envNumber("FOOTHOLD_LLM_MAX_OBJECTIVES", 16)),
	maxAirUnits = envNumber("FOOTHOLD_LLM_MAX_AIR_UNITS", envNumber("FOOTHOLD_LLM_MAX_ACTIVE_FORCES", 24)),
	radioMinInterval = envNumber("FOOTHOLD_LLM_RADIO_MIN_INTERVAL", 25),
	radioMaxInterval = envNumber("FOOTHOLD_LLM_RADIO_MAX_INTERVAL", 45),
	debugFiles = envBool("FOOTHOLD_LLM_DEBUG_FILES", false),
	debugDir = envString("FOOTHOLD_LLM_DEBUG_DIR", envString("FOOTHOLD_LLM_WORK_DIR", defaultWorkDir)),
}

FootholdLLM.config.maxObjectives = FootholdLLM.config.maxMissions
FootholdLLM.config.maxActiveForces = FootholdLLM.config.maxAirUnits
FootholdLLM.config.maxFrontlinePairs = envNumber("FOOTHOLD_LLM_MAX_FRONTLINE_PAIRS", 8)
FootholdLLM.config.maxPriorityZones = envNumber("FOOTHOLD_LLM_MAX_PRIORITY_ZONES", 18)
FootholdLLM.config.maxRecentEvents = envNumber("FOOTHOLD_LLM_MAX_RECENT_EVENTS", 12)

_G.FootholdStateForLLM = _G.FootholdStateForLLM or "{}"
_G.FootholdStateForLLMSeq = _G.FootholdStateForLLMSeq or 0
_G.FootholdLLM = FootholdLLM

local function log(message)
	if env and env.info then
		env.info("[FootholdLLM] " .. tostring(message))
	end
end

local function round(value)
	if type(value) ~= "number" then return nil end
	return math.floor(value + 0.5)
end

local function sideName(side)
	if side == coalition.side.RED then return "red" end
	if side == coalition.side.BLUE then return "blue" end
	if side == coalition.side.NEUTRAL then return "neutral" end
	return tostring(side or "unknown")
end

local function nmFromMeters(value)
	if type(value) ~= "number" then return nil end
	return math.floor((value / 1852) * 10 + 0.5) / 10
end

local function safeCall(fn, defaultValue)
	local ok, result = pcall(fn)
	if ok then return result end
	return defaultValue
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
	if depth > 10 then return "null" end
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
		for i = 1, #value do parts[#parts + 1] = encodeJson(value[i], depth + 1) end
		return "[" .. table.concat(parts, ",") .. "]"
	end

	for k, v in pairs(value) do
		parts[#parts + 1] = "\"" .. jsonEscape(k) .. "\":" .. encodeJson(v, depth + 1)
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

local function ensureDir(path)
	if not path or path == "" then return end
	if lfs and lfs.mkdir then
		pcall(lfs.mkdir, path)
	end
end

local function writeTextFile(path, body)
	if not FootholdLLM.config.debugFiles then return end
	if not io or not io.open then return end
	local file = io.open(path, "w")
	if not file then return end
	file:write(body or "")
	file:close()
end

local function debugPath(fileName)
	local dir = FootholdLLM.config.debugDir or defaultLlmDir
	if dir:sub(-1) ~= "\\" and dir:sub(-1) ~= "/" then dir = dir .. "\\" end
	return dir .. fileName
end

local function getSourceZones()
	if bc and bc.getZones then
		local ok, result = pcall(function() return bc:getZones() end)
		if ok and type(result) == "table" then return result end
	end
	if type(zones) == "table" then
		local out = {}
		for _, zone in pairs(zones) do out[#out + 1] = zone end
		return out
	end
	return {}
end

local function getZoneByName(name)
	if not name then return nil end
	if bc and bc.getZoneByName then
		local ok, result = pcall(function() return bc:getZoneByName(name) end)
		if ok then return result end
	end
	return nil
end

local function waypointFor(zoneName)
	if type(WaypointList) == "table" then return WaypointList[zoneName] end
	return nil
end

local function missionTagList(zoneName)
	local cur = type(ActiveCurrentMission) == "table" and ActiveCurrentMission[zoneName] or nil
	local out = {}
	if type(cur) == "table" then
		for tag, enabled in pairs(cur) do
			if enabled then out[#out + 1] = tostring(tag) end
		end
	elseif cur ~= nil then
		out[#out + 1] = tostring(cur)
	end
	table.sort(out)
	return out
end

local function addUniqueByKey(list, seen, key, item, maxItems)
	if not key or seen[key] then return end
	if maxItems and #list >= maxItems then return end
	seen[key] = true
	list[#list + 1] = item
end

local function normalizeObjectiveType(value)
	value = tostring(value or "")
	local lower = value:lower()
	if lower:find("resupply") then return "Resupply" end
	if lower:find("capture") then return "Capture" end
	if lower:find("sead") then return "SEAD" end
	if lower:find("dead") then return "DEAD" end
	if lower:find("recon") then return "Recon" end
	if lower:find("runway") or lower:find("bomb runway") then return "Bomb runway" end
	if lower:find("cap") then return "CAP" end
	if lower:find("cas") then return "CAS" end
	if lower:find("escort") then return "Escort" end
	if lower:find("strike") then return "Strike" end
	if lower:find("attack") then return "Attack" end
	return value ~= "" and value or "Objective"
end

local function objectivePriority(objectiveType)
	if objectiveType == "Attack" or objectiveType == "Capture" or objectiveType == "SEAD" or objectiveType == "DEAD" then return "high" end
	if objectiveType == "Resupply" or objectiveType == "Bomb runway" or objectiveType == "Recon" then return "normal" end
	return "normal"
end

local function collectObjectives()
	local out, seen = {}, {}

	local dynamicTargets = {
		{ type = "Attack", zone = _G.attackTarget1 },
		{ type = "Attack", zone = _G.attackTarget2 },
		{ type = "Resupply", zone = _G.resupplyTarget1 },
		{ type = "Resupply", zone = _G.resupplyTarget2 },
		{ type = "Capture", zone = _G.captureTarget },
		{ type = "SEAD", zone = _G.seadTarget },
		{ type = "DEAD", zone = _G.deadTarget },
		{ type = "Recon", zone = _G.reconMissionTarget },
		{ type = "Bomb runway", zone = _G.runwayTargetZone },
	}

	for _, row in ipairs(dynamicTargets) do
		local zoneName = row.zone
		local zone = getZoneByName(zoneName)
		if zoneName and zone and zone.active ~= false and not zone.isHidden then
			addUniqueByKey(out, seen, row.type .. "|" .. zoneName, {
				type = row.type,
				zone = zoneName,
				waypoint = waypointFor(zoneName),
				intel = "confirmed",
				priority = objectivePriority(row.type),
				source = "dynamic",
				side = sideName(zone.side),
			}, FootholdLLM.config.maxObjectives)
		end
	end

	if type(ActiveCurrentMission) == "table" then
		for zoneName, cur in pairs(ActiveCurrentMission) do
			local zone = getZoneByName(zoneName)
			if zone and zone.active ~= false and not zone.isHidden then
				local tags = missionTagList(zoneName)
				for _, tag in ipairs(tags) do
					local objectiveType = normalizeObjectiveType(tag)
					addUniqueByKey(out, seen, objectiveType .. "|" .. zoneName, {
						type = objectiveType,
						zone = zoneName,
						waypoint = waypointFor(zoneName),
						intel = "confirmed",
						priority = objectivePriority(objectiveType),
						source = "zoneTag",
						side = sideName(zone.side),
					}, FootholdLLM.config.maxObjectives)
				end
			end
		end
	end

	if mc and type(mc.missions) == "table" then
		for _, mission in ipairs(mc.missions) do
			if #out >= FootholdLLM.config.maxObjectives then break end
			if mission and mission.isRunning then
				local zoneName = mission.TargetZone or mission.targetZone or mission.zoneName or mission.zone
				local objectiveType = normalizeObjectiveType(mission.missionType or mission.MissionType or mission.title or mission.MainTitle)
				addUniqueByKey(out, seen, objectiveType .. "|" .. tostring(zoneName or mission.customFlagName or mission.flagName or #out + 1), {
					type = objectiveType,
					zone = zoneName,
					waypoint = waypointFor(zoneName),
					intel = "confirmed",
					priority = objectivePriority(objectiveType),
					source = "missionCommander",
				}, FootholdLLM.config.maxObjectives)
			end
		end
	end

	return out
end

local function zoneDistanceNm(a, b)
	if type(ZONE_DISTANCES) == "table" and ZONE_DISTANCES[a] and ZONE_DISTANCES[a][b] then
		return nmFromMeters(ZONE_DISTANCES[a][b])
	end
	local za = safeCall(function() return trigger.misc.getZone(a) end, nil)
	local zb = safeCall(function() return trigger.misc.getZone(b) end, nil)
	if za and zb and za.point and zb.point then
		local dx = za.point.x - zb.point.x
		local dz = za.point.z - zb.point.z
		return nmFromMeters(math.sqrt(dx * dx + dz * dz))
	end
	return nil
end

local function atan2Compat(y, x)
	if math.atan2 then return math.atan2(y, x) end
	if x > 0 then return math.atan(y / x) end
	if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
	if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
	if x == 0 and y > 0 then return math.pi / 2 end
	if x == 0 and y < 0 then return -math.pi / 2 end
	return 0
end

local function headingDirection(fromZone, toZone)
	local za = safeCall(function() return trigger.misc.getZone(fromZone) end, nil)
	local zb = safeCall(function() return trigger.misc.getZone(toZone) end, nil)
	if not (za and zb and za.point and zb.point) then return nil end
	local dx = zb.point.x - za.point.x
	local dz = zb.point.z - za.point.z
	local angle = math.deg(atan2Compat(dx, dz))
	if angle < 0 then angle = angle + 360 end
	local dirs = { "north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest" }
	local idx = math.floor((angle + 22.5) / 45) % 8 + 1
	return dirs[idx]
end

local function collectFrontline(objectives)
	local pairsOut, seen = {}, {}
	if bc and type(bc.connections) == "table" and bc.getConnectionZones then
		for _, connection in ipairs(bc.connections) do
			if #pairsOut >= FootholdLLM.config.maxFrontlinePairs then break end
			local from, to = safeCall(function() return bc:getConnectionZones(connection) end, nil)
			if from and to and from.active ~= false and to.active ~= false and not from.isHidden and not to.isHidden then
				local blue, red
				if from.side == coalition.side.BLUE and to.side == coalition.side.RED then
					blue, red = from, to
				elseif from.side == coalition.side.RED and to.side == coalition.side.BLUE then
					blue, red = to, from
				end
				if blue and red then
					local key = blue.zone .. "|" .. red.zone
					addUniqueByKey(pairsOut, seen, key, {
						blue = blue.zone,
						red = red.zone,
						distanceNm = zoneDistanceNm(blue.zone, red.zone),
						directionFromBlue = headingDirection(blue.zone, red.zone),
					}, FootholdLLM.config.maxFrontlinePairs)
				end
			end
		end
	end

	local primary = nil
	for _, obj in ipairs(objectives or {}) do
		if obj.zone and (obj.type == "Attack" or obj.type == "SEAD" or obj.type == "DEAD" or obj.type == "Capture") then
			local target = getZoneByName(obj.zone)
			if target then
				for _, pair in ipairs(pairsOut) do
					if pair.red == obj.zone or pair.blue == obj.zone then
						primary = {
							friendlyZone = pair.blue,
							enemyZone = pair.red,
							distanceNm = pair.distanceNm,
							direction = pair.directionFromBlue,
							reason = "activeObjective",
						}
						break
					end
				end
			end
		end
		if primary then break end
	end

	if not primary and pairsOut[1] then
		primary = {
			friendlyZone = pairsOut[1].blue,
			enemyZone = pairsOut[1].red,
			distanceNm = pairsOut[1].distanceNm,
			direction = pairsOut[1].directionFromBlue,
			reason = "nearestConnection",
		}
	end

	return { primaryAxis = primary, contestedPairs = pairsOut }
end

local function playerRole(unitType)
	unitType = tostring(unitType or "")
	if unitType:find("Hercules", 1, true) or unitType:find("C-130", 1, true) or unitType:find("CH-47", 1, true) then return "logistics" end
	if unitType:find("A-10", 1, true) or unitType:find("AV8", 1, true) then return "cas" end
	if unitType:find("F-14", 1, true) or unitType:find("F-15", 1, true) or unitType:find("F-16", 1, true) or unitType:find("F/A-18", 1, true) then return "strike" end
	return "aircraft"
end

local function collectPlayers(objectives, frontline)
	local objectiveZones = {}
	for _, obj in ipairs(objectives or {}) do
		if obj.zone then objectiveZones[obj.zone] = true end
	end
	local frontlineZones = {}
	if frontline and frontline.contestedPairs then
		for _, pair in ipairs(frontline.contestedPairs) do
			frontlineZones[pair.blue] = true
			frontlineZones[pair.red] = true
		end
	end

	local out = {}
	local summary = { nearFrontline = 0, nearObjectives = 0, logisticsAircraft = 0 }
	local ok, players = pcall(coalition.getPlayers, coalition.side.BLUE)
	if ok and type(players) == "table" then
		for _, unit in ipairs(players) do
			if #out >= FootholdLLM.config.maxPlayers then break end
			local name = safeCall(function() return unit:getPlayerName() end, nil)
			if name then
				local unitType = safeCall(function() return unit:getTypeName() end, nil)
				local point = safeCall(function() return unit:getPoint() end, nil)
				local zoneData = point and bc and bc.getZoneOfPoint and safeCall(function() return bc:getZoneOfPoint(point) end, nil) or nil
				local nearestZone = zoneData and zoneData.zone or nil
				local role = playerRole(unitType)
				local nearObjective = nearestZone and objectiveZones[nearestZone] == true or false
				local nearFrontline = nearestZone and frontlineZones[nearestZone] == true or false
				if nearObjective then summary.nearObjectives = summary.nearObjectives + 1 end
				if nearFrontline then summary.nearFrontline = summary.nearFrontline + 1 end
				if role == "logistics" then summary.logisticsAircraft = summary.logisticsAircraft + 1 end
				out[#out + 1] = {
					name = name,
					unitType = unitType,
					nearestZone = nearestZone,
					role = role,
					nearObjective = nearObjective,
					nearFrontline = nearFrontline,
				}
			end
		end
	end
	return { players = out, summary = summary }
end

local function collectLogistics()
	local zonesNeed, activeRuns = {}, {}
	for _, zone in ipairs(getSourceZones()) do
		if #zonesNeed >= FootholdLLM.config.maxPriorityZones then break end
		if zone and zone.side == coalition.side.BLUE and zone.active ~= false and not zone.suspended and not zone.isHidden then
			local needsSupply = safeCall(function() return zone:canRecieveSupply() end, false)
			if needsSupply then
				zonesNeed[#zonesNeed + 1] = {
					zone = zone.zone,
					reason = "damaged_or_incomplete_upgrades",
					priority = (ActiveCurrentMission and ActiveCurrentMission[zone.zone]) and "high" or "normal",
				}
			end
		end
	end

	for _, zone in ipairs(getSourceZones()) do
		for _, gc in ipairs((zone and zone.groups) or {}) do
			if #activeRuns >= FootholdLLM.config.maxActiveForces then break end
			if gc and gc.side == coalition.side.BLUE and gc.mission == "supply" then
				if gc.state == "takeoff" or gc.state == "inair" or gc.state == "landed" or gc.state == "enroute" or gc.state == "atdestination" then
					activeRuns[#activeRuns + 1] = {
						side = "blue",
						from = zone.zone,
						to = gc.targetzone,
						state = gc.state,
						intel = "confirmed",
					}
				end
			end
		end
	end

	return { zonesNeedingSupply = zonesNeed, activeSupplyRuns = activeRuns }
end

local function collectEnemyPressure()
	local zonesOut = {}
	local pressure = bc and bc._redReactivePressureByZone or nil
	if type(pressure) == "table" then
		for zoneName, value in pairs(pressure) do
			local zone = getZoneByName(zoneName)
			if zone and zone.side == coalition.side.RED and zone.active ~= false and not zone.isHidden then
				local level = "low"
				if value >= 12 then level = "high" elseif value >= 6 then level = "medium" end
				zonesOut[#zonesOut + 1] = { zone = zoneName, pressure = level, score = value, intel = "inferred" }
			end
		end
		table.sort(zonesOut, function(a, b) return (a.score or 0) > (b.score or 0) end)
	end
	while #zonesOut > 5 do table.remove(zonesOut) end

	local summary = nil
	if zonesOut[1] then
		summary = "red counterpressure signs near " .. zonesOut[1].zone
	else
		summary = "no major inferred red counterpressure"
	end

	return { summary = summary, pressureZones = zonesOut, knownEnemyActions = {} }
end

local function activeState(gc)
	return gc and (gc.state == "preparing" or gc.state == "takeoff" or gc.state == "inair" or gc.state == "landed" or gc.state == "enroute" or gc.state == "atdestination" or gc.Spawned == true)
end

local function zoneGrid(zoneName)
	local zone = safeCall(function() return trigger.misc.getZone(zoneName) end, nil)
	if not (zone and zone.point) then return nil end
	local gridMeters = 10000
	return {
		x = math.floor((zone.point.x or 0) / gridMeters + 0.5) * 10,
		z = math.floor((zone.point.z or 0) / gridMeters + 0.5) * 10,
		unit = "km_grid",
	}
end

local function groundStrength(zone)
	if not zone then return "unknown", 0 end
	local score = 0
	for _, builtName in pairs(zone.built or {}) do
		local group = Group.getByName(builtName)
		local static = StaticObject.getByName(builtName)
		if group and group:isExist() and group:getSize() > 0 then
			score = score + group:getSize()
		elseif static and static:isExist() then
			score = score + 1
		end
	end
	if score <= 0 then return "none", score end
	if score <= 3 then return "light", score end
	if score <= 8 then return "medium", score end
	return "heavy", score
end

local function zoneTags(zone)
	local tags = {}
	if zone.airbaseName then tags[#tags + 1] = "airbase" end
	if zone.LogisticCenter then tags[#tags + 1] = "logistics" end
	if zone.isHeloSpawn then tags[#tags + 1] = "helo_spawn" end
	if zone.side == coalition.side.BLUE and zone.zone == "Akrotiri" then tags[#tags + 1] = "blue_main_base" end
	local dist = Frontline and Frontline.ZoneDistToFrontNm and safeCall(function() return Frontline.ZoneDistToFrontNm(zone.zone) end, nil) or nil
	if type(dist) == "number" and math.abs(dist) <= 35 then tags[#tags + 1] = "near_frontline" end
	local missionTags = missionTagList(zone.zone)
	for _, tag in ipairs(missionTags) do tags[#tags + 1] = "mission_" .. tag end
	return tags
end

local function collectWorldZones()
	local out = {}
	for _, zone in ipairs(getSourceZones()) do
		if #out >= FootholdLLM.config.maxZones then break end
		if zone and zone.zone and zone.active ~= false and not zone.isHidden then
			local strength, roughCount = groundStrength(zone)
			out[#out + 1] = {
				name = zone.zone,
				side = sideName(zone.side),
				pos = zoneGrid(zone.zone),
				ground = strength,
				roughGroundCount = roughCount,
				tags = zoneTags(zone),
			}
		end
	end
	table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
	return out
end

local function forceRole(gc)
	local role = tostring(gc and gc.MissionType or "")
	if role ~= "" then return role end
	local mission = tostring(gc and gc.mission or "")
	if mission == "supply" then return "supply" end
	if mission == "patrol" then return "patrol" end
	if mission == "attack" then return "attack" end
	return "air"
end

local function airState(state)
	if state == "takeoff" or state == "preparing" then return "taking_off" end
	if state == "inair" then return "airborne" end
	if state == "landed" or state == "atdestination" then return "on_station" end
	if state == "enroute" then return "enroute" end
	return tostring(state or "active")
end

local function collectAirUnitsSimple()
	local out = {}
	for _, zone in ipairs(getSourceZones()) do
		for _, gc in ipairs((zone and zone.groups) or {}) do
			if #out >= FootholdLLM.config.maxAirUnits then break end
			if gc and activeState(gc) and (gc.type == "air" or gc.type == "carrier_air") then
				local side = sideName(gc.side)
				local role = forceRole(gc)
				out[#out + 1] = {
					side = side,
					role = role,
					origin = zone.zone,
					area = gc.targetzone,
					state = airState(gc.state),
					intel = gc.side == coalition.side.BLUE and "confirmed" or "inferred",
					display = (side == "blue" and "蓝方 " or "疑似红方 ") .. role,
				}
			end
		end
	end
	return out
end

local function collectMissionsSimple()
	local out, seen = {}, {}
	local objectives = collectObjectives()
	for _, obj in ipairs(objectives or {}) do
		if #out >= FootholdLLM.config.maxMissions then break end
		if obj.zone then
			addUniqueByKey(out, seen, tostring(obj.type) .. "|" .. tostring(obj.zone), {
				type = obj.type,
				zone = obj.zone,
				waypoint = obj.waypoint,
				status = "active",
				intel = "confirmed",
			}, FootholdLLM.config.maxMissions)
		end
	end
	return out
end

local function collectRadioPlayersSimple()
	local out = {}
	local ok, players = pcall(coalition.getPlayers, coalition.side.BLUE)
	if ok and type(players) == "table" then
		for _, unit in ipairs(players) do
			local name = safeCall(function() return unit:getPlayerName() end, nil)
			if name then
				local unitType = safeCall(function() return unit:getTypeName() end, nil)
				local point = safeCall(function() return unit:getPoint() end, nil)
				local zoneData = point and bc and bc.getZoneOfPoint and safeCall(function() return bc:getZoneOfPoint(point) end, nil) or nil
				out[#out + 1] = {
					name = name,
					unitType = unitType,
					nearestZone = zoneData and zoneData.zone or nil,
					role = playerRole(unitType),
				}
			end
		end
	end
	return out
end

local function collectActiveForces()
	local forces = {}
	for _, zone in ipairs(getSourceZones()) do
		for _, gc in ipairs((zone and zone.groups) or {}) do
			if #forces >= FootholdLLM.config.maxActiveForces then break end
			if gc and activeState(gc) then
				forces[#forces + 1] = {
					name = gc.name,
					side = sideName(gc.side),
					origin = zone.zone,
					target = gc.targetzone,
					mission = gc.mission,
					missionType = gc.MissionType,
					state = gc.state,
					type = gc.type,
					intel = gc.side == coalition.side.BLUE and "confirmed" or "inferred",
				}
			end
		end
	end
	return forces
end

local function collectFriendlySupport()
	if not bc then return { cap = 0, cas = 0, sead = 0, supply = 0 } end
	return {
		cap = safeCall(function() return (bc:getActiveCAPCount(coalition.side.BLUE, "patrol") or 0) + (bc:getActiveCAPCount(coalition.side.BLUE, "attack") or 0) end, 0),
		cas = safeCall(function() return bc:getActiveStrikeCount(coalition.side.BLUE, "attack", "CAS", nil) end, 0),
		sead = safeCall(function() return bc:getActiveStrikeCount(coalition.side.BLUE, "attack", "SEAD", nil) end, 0),
		supply = 0,
	}
end

local function collectCampaign()
	local counts = { blueZones = 0, redZones = 0, neutralZones = 0, activeBluePlayers = 0 }
	for _, zone in ipairs(getSourceZones()) do
		if zone and zone.active ~= false and not zone.isHidden then
			if zone.side == coalition.side.BLUE then counts.blueZones = counts.blueZones + 1
			elseif zone.side == coalition.side.RED then counts.redZones = counts.redZones + 1
			elseif zone.side == coalition.side.NEUTRAL then counts.neutralZones = counts.neutralZones + 1 end
		end
	end
	counts.blueCredits = bc and bc.accounts and round(bc.accounts[coalition.side.BLUE] or 0) or nil
	counts.activeBluePlayers = safeCall(function()
		local players = coalition.getPlayers(coalition.side.BLUE) or {}
		return #players
	end, 0)
	return counts
end

local function makeSnapshotKey(state)
	local parts = {}
	for _, obj in ipairs(state.activeObjectives or {}) do parts[#parts + 1] = "obj:" .. tostring(obj.type) .. ":" .. tostring(obj.zone) end
	for _, z in ipairs((state.logisticsStatus and state.logisticsStatus.zonesNeedingSupply) or {}) do parts[#parts + 1] = "sup:" .. tostring(z.zone) end
	if state.frontlineFocus and state.frontlineFocus.primaryAxis then
		parts[#parts + 1] = "axis:" .. tostring(state.frontlineFocus.primaryAxis.friendlyZone) .. ":" .. tostring(state.frontlineFocus.primaryAxis.enemyZone)
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

local function collectRecentEvents(state)
	local events = {}
	local previous = FootholdLLM.lastSemanticState
	if previous then
		local oldObj = {}
		for _, obj in ipairs(previous.activeObjectives or {}) do oldObj[tostring(obj.type) .. "|" .. tostring(obj.zone)] = true end
		for _, obj in ipairs(state.activeObjectives or {}) do
			local key = tostring(obj.type) .. "|" .. tostring(obj.zone)
			if not oldObj[key] then
				events[#events + 1] = { type = "objective_started", objective = obj.type, zone = obj.zone, timeAgoSec = 0 }
			end
		end

		local oldSupply = {}
		for _, z in ipairs((previous.logisticsStatus and previous.logisticsStatus.zonesNeedingSupply) or {}) do oldSupply[z.zone] = true end
		for _, z in ipairs((state.logisticsStatus and state.logisticsStatus.zonesNeedingSupply) or {}) do
			if not oldSupply[z.zone] then
				events[#events + 1] = { type = "supply_needed", zone = z.zone, timeAgoSec = 0 }
			end
		end

		local oldAxis = previous.frontlineFocus and previous.frontlineFocus.primaryAxis
		local newAxis = state.frontlineFocus and state.frontlineFocus.primaryAxis
		if oldAxis and newAxis and (oldAxis.friendlyZone ~= newAxis.friendlyZone or oldAxis.enemyZone ~= newAxis.enemyZone) then
			events[#events + 1] = { type = "frontline_focus_changed", from = oldAxis.friendlyZone .. "-" .. oldAxis.enemyZone, to = newAxis.friendlyZone .. "-" .. newAxis.enemyZone, timeAgoSec = 0 }
		end
	end
	while #events > FootholdLLM.config.maxRecentEvents do table.remove(events) end
	return events
end

local function collectState()
	local zonesSimple = collectWorldZones()
	local missionsSimple = collectMissionsSimple()
	local airUnitsSimple = collectAirUnitsSimple()
	local state = {
		meta = {
			schemaVersion = 2,
			exporterVersion = FootholdLLM.version,
			seq = (_G.FootholdStateForLLMSeq or 0) + 1,
			missionTimeSec = round(timer.getTime()),
			absTimeSec = round(timer.getAbsTime()),
			map = env and env.mission and env.mission.theatre or "unknown",
			era = Era,
			audience = "blue",
		},
		world = {
			zones = zonesSimple,
			summary = collectCampaign(),
		},
		missions = missionsSimple,
		airUnits = airUnitsSimple,
		players = collectRadioPlayersSimple(),
		radioMemory = FootholdLLM.radioMemory or {
			lastPrimaryFocus = nil,
			lastTone = "unknown",
			lastMentionedZones = {},
			lastBatchSummary = nil,
		},
	}
	state.stateKey = encodeJson({ missions = missionsSimple, airUnits = airUnitsSimple })
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
		state.airUnits = {}
		state.truncated = true
		state.truncatedReason = "maxJsonBytes_airUnits"
		json = encodeJson(state)
	end
	if maxBytes and #json > maxBytes then
		state.players = {}
		state.truncated = true
		state.truncatedReason = "maxJsonBytes_players"
		json = encodeJson(state)
	end
	if maxBytes and #json > maxBytes then
		state.world.zones = {}
		state.truncated = true
		state.truncatedReason = "maxJsonBytes_zones"
		json = encodeJson(state)
	end

	_G.FootholdStateForLLMSeq = state.meta.seq
	_G.FootholdStateForLLM = json
	FootholdLLM.lastSemanticState = state

	if FootholdLLM.config.debugFiles then
		ensureDir(FootholdLLM.config.debugDir)
		writeTextFile(debugPath("FootholdLLM_state.json"), json)
	end
end

FootholdLLM.llm = nil
FootholdLLM.pendingRequestIds = {}
FootholdLLM.lastStateSubmitTime = timer.getTime() - FootholdLLM.config.llmSubmitInterval
FootholdLLM.radioQueue = FootholdLLM.radioQueue or {}
FootholdLLM.nextRadioAt = FootholdLLM.nextRadioAt or 0
FootholdLLM.radioMemory = FootholdLLM.radioMemory or nil
FootholdLLM.lastBatch = FootholdLLM.lastBatch or nil

local function hasPendingRequests()
	for _, _ in pairs(FootholdLLM.pendingRequestIds) do return true end
	return false
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
	body = tostring(body or "")
	local keyStart = body:find('"' .. name .. '"', 1, true)
	if not keyStart then return nil end
	local colon = body:find(":", keyStart + #name + 2, true)
	if not colon then return nil end
	local quote = body:find('"', colon + 1, true)
	if not quote then return nil end
	local raw = {}
	local escape = false
	for i = quote + 1, #body do
		local c = body:sub(i, i)
		if escape then
			raw[#raw + 1] = "\\"
			raw[#raw + 1] = c
			escape = false
		elseif c == "\\" then
			escape = true
		elseif c == '"' then
			return decodeJsonString(table.concat(raw))
		else
			raw[#raw + 1] = c
		end
	end
	return nil
end

local function jsonNumber(body, name)
	local value = tostring(body or ""):match('"' .. name .. '"%s*:%s*(%-?%d+)')
	return value and tonumber(value) or nil
end

local function jsonBool(body, name)
	local value = tostring(body or ""):match('"' .. name .. '"%s*:%s*(true)') or tostring(body or ""):match('"' .. name .. '"%s*:%s*(false)')
	return value == "true"
end

local function stripCodeFence(text)
	text = tostring(text or "")
	text = text:gsub("^%s*```json%s*", "")
	text = text:gsub("^%s*```%s*", "")
	text = text:gsub("%s*```%s*$", "")
	return trim(text)
end

local function extractJsonObjectsFromArray(text)
	text = stripCodeFence(text)
	local startIndex = text:find("%[")
	local endIndex = text:match(".*()%]")
	if not startIndex or not endIndex or endIndex <= startIndex then return nil end
	local body = text:sub(startIndex + 1, endIndex - 1)
	local objects = {}
	local depth, inString, escape = 0, false, false
	local objectStart = nil
	for i = 1, #body do
		local c = body:sub(i, i)
		if inString then
			if escape then
				escape = false
			elseif c == "\\" then
				escape = true
			elseif c == "\"" then
				inString = false
			end
		else
			if c == "\"" then
				inString = true
			elseif c == "{" then
				if depth == 0 then objectStart = i end
				depth = depth + 1
			elseif c == "}" then
				depth = depth - 1
				if depth == 0 and objectStart then
					objects[#objects + 1] = body:sub(objectStart, i)
					objectStart = nil
				end
			end
		end
	end
	return objects
end

local allowedSpeakers = {
	["AWACS"] = true,
	["蓝方战区指挥部"] = true,
	["前线管制"] = true,
	["JTAC"] = true,
	["友军飞机"] = true,
	["地面部队"] = true,
	["后勤频道"] = true,
	["塔台"] = true,
}

local allowedPriority = { high = true, normal = true, flavor = true }

local function parseRadioBatch(text)
	local objects = extractJsonObjectsFromArray(text)
	if not objects or #objects == 0 then return nil, "no json array objects" end
	local items = {}
	for _, object in ipairs(objects) do
		local speaker = jsonString(object, "speaker") or "蓝方战区指挥部"
		local priority = jsonString(object, "priority") or "normal"
		local msg = jsonString(object, "text")
		if msg and msg ~= "" then
			if not allowedSpeakers[speaker] then speaker = "蓝方战区指挥部" end
			if not allowedPriority[priority] then priority = "normal" end
			items[#items + 1] = { speaker = speaker, priority = priority, text = msg }
		end
	end
	if #items == 0 then return nil, "no valid radio items" end
	return items
end

local function displayRadioText(text, duration, coalitionSide)
	if not text or text == "" then return end
	if #text > FootholdLLM.config.maxReplyChars then
		text = text:sub(1, FootholdLLM.config.maxReplyChars)
	end

	coalitionSide = coalitionSide or FootholdLLM.config.broadcastCoalition
	duration = duration or FootholdLLM.config.broadcastDuration

	if coalitionSide == coalition.side.RED or coalitionSide == coalition.side.BLUE then
		trigger.action.outTextForCoalition(coalitionSide, text, duration)
	else
		trigger.action.outText(text, duration)
	end
end

local function formatRadioItem(item)
	if not item then return nil end
	return string.format("%s：%s", tostring(item.speaker or "蓝方战区指挥部"), tostring(item.text or ""))
end

local function nextRadioDelay()
	local minInterval = FootholdLLM.config.radioMinInterval or 25
	local maxInterval = FootholdLLM.config.radioMaxInterval or 45
	if maxInterval < minInterval then maxInterval = minInterval end
	return math.random(minInterval, maxInterval)
end

local function updateRadioMemory(items)
	local zones = {}
	local state = FootholdLLM.lastSemanticState
	if state and state.frontlineFocus and state.frontlineFocus.primaryAxis then
		local axis = state.frontlineFocus.primaryAxis
		FootholdLLM.radioMemory = FootholdLLM.radioMemory or {}
		FootholdLLM.radioMemory.lastPrimaryFocus = tostring(axis.friendlyZone or "") .. "-" .. tostring(axis.enemyZone or "")
		FootholdLLM.radioMemory.lastTone = "offensive"
		if axis.friendlyZone then zones[#zones + 1] = axis.friendlyZone end
		if axis.enemyZone then zones[#zones + 1] = axis.enemyZone end
	end
	FootholdLLM.radioMemory = FootholdLLM.radioMemory or {}
	FootholdLLM.radioMemory.lastMentionedZones = zones
	local summary = {}
	for i = 1, math.min(#items, 3) do
		summary[#summary + 1] = items[i].text
	end
	FootholdLLM.radioMemory.lastBatchSummary = table.concat(summary, " ")
end

local function enqueueRadioBatch(items)
	if not items or #items == 0 then return end
	FootholdLLM.radioQueue = {}
	for _, item in ipairs(items) do
		if item.priority == "high" then FootholdLLM.radioQueue[#FootholdLLM.radioQueue + 1] = item end
	end
	for _, item in ipairs(items) do
		if item.priority ~= "high" then FootholdLLM.radioQueue[#FootholdLLM.radioQueue + 1] = item end
	end
	FootholdLLM.lastBatch = items
	FootholdLLM.nextRadioAt = timer.getTime()
	updateRadioMemory(items)
	if FootholdLLM.config.debugFiles then
		writeTextFile(debugPath("FootholdLLM_batch.json"), encodeJson(items))
	end
	log("queued radio batch items=" .. tostring(#items))
end

local function fallbackBatchFromText(text)
	text = stripCodeFence(text)
	if text == "" then return nil end
	return { { speaker = "蓝方战区指挥部", priority = "normal", text = text } }
end

function FootholdLLM.displayDueRadio()
	local now = timer.getTime()
	if now < (FootholdLLM.nextRadioAt or 0) then return end
	if not FootholdLLM.radioQueue or #FootholdLLM.radioQueue == 0 then return end
	local item = table.remove(FootholdLLM.radioQueue, 1)
	local text = formatRadioItem(item)
	displayRadioText(text, FootholdLLM.config.broadcastDuration, FootholdLLM.config.broadcastCoalition)
	FootholdLLM.nextRadioAt = now + nextRadioDelay()
end

function FootholdLLM.loadBridge()
	if FootholdLLM.llm then return true end
	if not (package and package.loadlib) then
		log("package.loadlib unavailable; mission sandbox may still be enabled")
		return false
	end

	local open, err = package.loadlib(FootholdLLM.config.dllPath, "luaopen_llmbridge")
	if not open then
		log("load llmbridge failed: " .. tostring(err))
		return false
	end

	local ok, mod = pcall(open)
	if not ok or type(mod) ~= "table" then
		log("open llmbridge failed: " .. tostring(mod))
		return false
	end

	FootholdLLM.llm = mod
	log("native llmbridge loaded by mission")
	return true
end

function FootholdLLM.submit(payload, kind)
	if not FootholdLLM.loadBridge() then return false end
	local ok, requestIdOrErr = FootholdLLM.llm.submit(payload)
	local requestId = tonumber(requestIdOrErr)
	if ok and requestId then
		FootholdLLM.pendingRequestIds[requestId] = kind or "state"
		log("submitted native LLM request id=" .. tostring(requestIdOrErr) .. " kind=" .. tostring(kind or "state") .. " bytes=" .. tostring(#payload))
		return true
	end
	log("native submit failed: " .. tostring(requestIdOrErr))
	return false
end

function FootholdLLM.submitStateIfReady()
	if not FootholdLLM.loadBridge() then return end
	local status = FootholdLLM.llm.status()
	if status == "busy" then return end

	local now = timer.getTime()
	if now - FootholdLLM.lastStateSubmitTime < FootholdLLM.config.llmSubmitInterval then return end

	FootholdLLM.exportNow()
	local json = _G.FootholdStateForLLM
	if type(json) ~= "string" or json == "" or json == "{}" then return end
	if FootholdLLM.submit(json, "radioBatch") then
		FootholdLLM.lastStateSubmitTime = now
	end
end

function FootholdLLM.poll()
	if not FootholdLLM.llm then return end
	local result = FootholdLLM.llm.poll()
	if not result then return end

	local requestId = jsonNumber(result, "id")
	local kind = requestId and FootholdLLM.pendingRequestIds[requestId] or nil
	if not kind then
		log("discarded stale native LLM result id=" .. tostring(requestId))
		return
	end
	FootholdLLM.pendingRequestIds[requestId] = nil

	if not jsonBool(result, "ok") then
		local err = jsonString(result, "error") or "unknown"
		log("native LLM request failed id=" .. tostring(requestId) .. ": " .. err)
		return
	end

	local text = jsonString(result, "text")
	if not text or text == "" then return end
	if FootholdLLM.config.debugFiles then
		writeTextFile(debugPath("FootholdLLM_raw_response.txt"), text)
	end

	local items, parseErr = parseRadioBatch(text)
	if not items then
		log("radio batch parse failed: " .. tostring(parseErr) .. "; using single-text fallback")
		items = fallbackBatchFromText(text)
	end
	if items then
		enqueueRadioBatch(items)
		FootholdLLM.displayDueRadio()
	end
end

timer.scheduleFunction(function(_, time)
	local ok, err = pcall(function()
		FootholdLLM.displayDueRadio()
		if hasPendingRequests() then FootholdLLM.poll() end
		FootholdLLM.submitStateIfReady()
	end)
	if not ok then log("native LLM tick failed: " .. tostring(err)) end
	return time + FootholdLLM.config.llmTickInterval
end, {}, timer.getTime() + 5)

FootholdLLM.exportNow()
log("mission native LLM semantic radio started")
