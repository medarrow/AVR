--[[ AVR scene sharing over the addon channel.

	A scene is serialized to text, cut into chunks and sent to the party or
	raid. Receivers are asked before anything is added. Incoming data is
	parsed, never executed, and only known mesh types and plain values get
	through.

	Wire format, one chunk:  <id>:<index>:<total>:<data>
	Serialized values:  n<number>;   s<length>:<text>   T   F   {<key><value>...}
]]

local AVR = AVR
local getn, tinsert, tremove = table.getn, table.insert, table.remove

local PREFIX = "AVR"
local CHUNK = 200
local MAX_CHUNKS = 150
local SEND_INTERVAL = 0.2

-------------------------------------------------------------------------------
-- Serialization
-------------------------------------------------------------------------------

local function Ser(v, out)
	local t = type(v)
	if t == "number" then
		if v == math.floor(v) then
			tinsert(out, "n" .. string.format("%d", v) .. ";")
		else
			tinsert(out, "n" .. string.format("%.2f", v) .. ";")
		end
	elseif t == "string" then
		tinsert(out, "s" .. string.len(v) .. ":" .. v)
	elseif t == "boolean" then
		tinsert(out, v and "T" or "F")
	elseif t == "table" then
		tinsert(out, "{")
		for k, x in pairs(v) do
			local tk, tx = type(k), type(x)
			if (tk == "number" or tk == "string")
				and (tx == "number" or tx == "string" or tx == "boolean" or tx == "table") then
				Ser(k, out)
				Ser(x, out)
			end
		end
		tinsert(out, "}")
	end
end

-- Returns value, nextPos; nil on malformed input.
local function Des(s, pos, depth)
	local c = string.sub(s, pos, pos)
	if c == "n" then
		local e = string.find(s, ";", pos, true)
		if not e then return nil end
		local n = tonumber(string.sub(s, pos + 1, e - 1))
		if not n then return nil end
		return n, e + 1
	elseif c == "s" then
		local e = string.find(s, ":", pos, true)
		if not e then return nil end
		local len = tonumber(string.sub(s, pos + 1, e - 1))
		if not len or len < 0 or e + len > string.len(s) then return nil end
		return string.sub(s, e + 1, e + len), e + len + 1
	elseif c == "T" then
		return true, pos + 1
	elseif c == "F" then
		return false, pos + 1
	elseif c == "{" then
		if depth > 4 then return nil end
		local t = {}
		pos = pos + 1
		while true do
			if pos > string.len(s) then return nil end
			if string.sub(s, pos, pos) == "}" then return t, pos + 1 end
			local k, v
			k, pos = Des(s, pos, depth + 1)
			if k == nil or type(k) == "table" or type(k) == "boolean" then return nil end
			v, pos = Des(s, pos, depth + 1)
			if v == nil then return nil end
			t[k] = v
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------

local queue = {}
local sender = CreateFrame("Frame")
local wait = 0
sender:Hide()
sender:SetScript("OnUpdate", function()
	wait = wait + arg1
	if wait < SEND_INTERVAL then return end
	wait = 0
	local item = tremove(queue, 1)
	if not item then
		sender:Hide()
		return
	end
	SendAddonMessage(PREFIX, item.msg, item.channel)
end)

function AVR:ShareScene(scene)
	scene = scene or self:GetScene()
	local channel
	if GetNumRaidMembers() > 0 then channel = "RAID"
	elseif GetNumPartyMembers() > 0 then channel = "PARTY" end
	if not channel then
		self:Print("You are not in a group - nobody to share with.")
		return
	end
	if getn(scene.meshes) == 0 then
		self:Print("Scene '" .. scene.name .. "' is empty.")
		return
	end

	local out = {}
	Ser({ name = scene.name, meshes = scene.meshes }, out)
	local data = table.concat(out)
	local len = string.len(data)
	local total = math.ceil(len / CHUNK)
	if total > MAX_CHUNKS then
		self:Print("Scene '" .. scene.name .. "' is too large to share.")
		return
	end
	local id = math.random(100000, 999999)
	for i = 1, total do
		tinsert(queue, {
			channel = channel,
			msg = id .. ":" .. i .. ":" .. total .. ":" .. string.sub(data, (i - 1) * CHUNK + 1, i * CHUNK),
		})
	end
	sender:Show()
	self:Print("Sharing scene '" .. scene.name .. "' with your " .. string.lower(channel) .. ".")
end

-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------

local incoming = {} -- sender .. id -> { total = n, got = n, parts = {} }
local pending       -- scene waiting for the accept popup

-- Keeps only what a mesh may legitimately contain.
local function Sanitize(scene)
	if type(scene) ~= "table" or type(scene.meshes) ~= "table" then return nil end
	local clean = { name = "Shared", visible = true, meshes = {} }
	if type(scene.name) == "string" then clean.name = string.sub(scene.name, 1, 40) end
	for _, m in ipairs(scene.meshes) do
		if type(m) == "table" and type(m.type) == "string" and AVR.types[m.type] then
			local c = {}
			for k, v in pairs(m) do
				local tv = type(v)
				if type(k) == "string" and (tv == "number" or tv == "boolean") then
					c[k] = v
				elseif type(k) == "string" and tv == "string" then
					c[k] = string.sub(v, 1, 40)
				elseif k == "pts" and tv == "table" then
					local pts = {}
					for i, p in ipairs(v) do
						if type(p) ~= "number" or i > 600 then break end
						pts[i] = p
					end
					c.pts = pts
				end
			end
			tinsert(clean.meshes, c)
			if getn(clean.meshes) >= 100 then break end
		end
	end
	if getn(clean.meshes) == 0 then return nil end
	return clean
end

StaticPopupDialogs["AVR_ACCEPT_SCENE"] = {
	text = "%s wants to share the AVR scene '%s' with you. Accept?",
	button1 = TEXT(ACCEPT),
	button2 = TEXT(DECLINE),
	OnAccept = function()
		if not pending then return end
		local scene = pending.scene
		scene.name = scene.name .. " (" .. pending.from .. ")"
		local i = AVR:FindScene(scene.name)
		if i then
			AVR.db.scenes[i] = scene
			AVR.db.current = i
		else
			tinsert(AVR.db.scenes, scene)
			AVR.db.current = getn(AVR.db.scenes)
		end
		pending = nil
		AVR:Changed()
		AVR:Print("Added scene '" .. scene.name .. "'.")
	end,
	OnCancel = function() pending = nil end,
	timeout = 60,
	whileDead = 1,
	hideOnEscape = 1,
}

function AVR:OnAddonMessage(prefix, msg, channel, from)
	if prefix ~= PREFIX or not from or from == UnitName("player") then return end
	if channel ~= "RAID" and channel ~= "PARTY" then return end
	if not self.settings or self.settings.share == "never" then return end

	local _, _, id, idx, total, data = string.find(msg, "^(%d+):(%d+):(%d+):(.*)$")
	if not id then return end
	idx, total = tonumber(idx), tonumber(total)
	if total < 1 or total > MAX_CHUNKS or idx < 1 or idx > total then return end

	local key = from .. id
	local rec = incoming[key]
	if not rec then
		rec = { total = total, got = 0, parts = {} }
		incoming[key] = rec
	end
	if rec.total ~= total then
		incoming[key] = nil
		return
	end
	if not rec.parts[idx] then
		rec.parts[idx] = data
		rec.got = rec.got + 1
	end
	if rec.got < rec.total then return end

	incoming[key] = nil
	local value = Des(table.concat(rec.parts), 1, 0)
	local scene = Sanitize(value)
	if not scene then return end
	-- one offer at a time; an unanswered one lapses with its popup
	if pending and GetTime() - pending.time < 65 then return end
	pending = { scene = scene, from = from, time = GetTime() }
	StaticPopup_Show("AVR_ACCEPT_SCENE", from, scene.name)
end
