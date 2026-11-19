--[[ AVR - Augmented Virtual Reality for the 1.12 client.

	Draws lines, circles and markers on the 3D world by projecting world
	coordinates through a reconstruction of the game camera.

	What it needs from the client:
	  UnitPosition(unit)                 SuperWoW (x, y, z) and/or ClassicAPI
	                                     (west, north, z, map). World yards.
	  GetPlayerFacing()                  ClassicAPI, or the minimap arrow model.
	  SaveView(5) + cameraXxxD cvars     stock client; how the camera's pitch,
	                                     yaw and distance are read.

	Lua 5.0: no '#', no '%', handlers use this / event / arg1.
]]

AVR = {}
local AVR = AVR
AVR.version = "1.0"

local sin, cos, tan, abs, sqrt, floor = math.sin, math.cos, math.tan, math.abs, math.sqrt, math.floor
local PI = math.pi
local getn, tinsert, tremove = table.getn, table.insert, table.remove

local LINE_TEX = "Interface\\AddOns\\AVR\\Textures\\line"
local TRI_TEX = "Interface\\AddOns\\AVR\\Textures\\tri"

local NEAR = 0.3 -- near clip plane, yards

-------------------------------------------------------------------------------
-- Settings and saved data
-------------------------------------------------------------------------------

local defaults = {
	enabled = true,
	lineWidth = 3,     -- screen units
	fillAlpha = 0.3,   -- fill opacity relative to the outline
	maxDistance = 200, -- yards; pinned marks further away are skipped
	yawSign = 1,
	pitchSign = 1,
	share = "ask",     -- ask / never
	-- pivotHeight, fov: nil = automatic
}

-- Height of the point the camera orbits, above the character's feet.
local raceHeight = {
	Human = 2.0, Dwarf = 1.5, NightElf = 2.3, Gnome = 1.0,
	Orc = 2.1, Scourge = 1.85, Tauren = 2.6, Troll = 2.2,
	Goblin = 1.1, BloodElf = 2.0, HighElf = 2.0,
}

function AVR:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffAVR|r: " .. tostring(msg))
end

function AVR:InitDB()
	if type(AVR_DB) ~= "table" then AVR_DB = {} end
	local db = AVR_DB
	if type(db.settings) ~= "table" then db.settings = {} end
	for k, v in pairs(defaults) do
		if db.settings[k] == nil then db.settings[k] = v end
	end
	if type(db.scenes) ~= "table" then db.scenes = {} end
	if getn(db.scenes) == 0 then
		tinsert(db.scenes, { name = "Default", visible = true, meshes = {} })
	end
	if not db.current or not db.scenes[db.current] then db.current = 1 end
	self.db = db
	self.settings = db.settings
end

-------------------------------------------------------------------------------
-- Scenes and meshes
-------------------------------------------------------------------------------

AVR.types = {}     -- mesh type name -> definition
AVR.typeOrder = {}
AVR.temps = {}     -- unsaved, timed meshes (API / tools)

--[[ def = {
	label    = "Circle",
	defaults = { radius = 8, ... },
	fields   = { { key = "radius", label = "Radius", kind = "number" }, ... },
	absolute = true,   -- mesh carries its own world coordinates (no anchor)
	Draw     = function(m, x, y, z, facing) end,
	Summary  = function(m) return "8 yd" end,
} ]]
function AVR:RegisterMeshType(name, def)
	if not self.types[name] then tinsert(self.typeOrder, name) end
	self.types[name] = def
end

function AVR:GetScene()
	return self.db.scenes[self.db.current]
end

function AVR:NewScene(name)
	tinsert(self.db.scenes, { name = name or "Scene", visible = true, meshes = {} })
	self.db.current = getn(self.db.scenes)
	self:Changed()
	return self:GetScene()
end

function AVR:DeleteScene(index)
	index = index or self.db.current
	tremove(self.db.scenes, index)
	if getn(self.db.scenes) == 0 then
		tinsert(self.db.scenes, { name = "Default", visible = true, meshes = {} })
	end
	if self.db.current > getn(self.db.scenes) then self.db.current = getn(self.db.scenes) end
	self:Changed()
end

function AVR:FindScene(name)
	local lname = string.lower(name)
	for i, s in ipairs(self.db.scenes) do
		if string.lower(s.name) == lname then return i, s end
	end
end

-- Builds a mesh table of the given type; 'over' overrides the defaults.
function AVR:NewMesh(typeName, over)
	local def = self.types[typeName]
	if not def then return nil end
	local m = { type = typeName, r = 1, g = 0.82, b = 0, a = 0.9 }
	if def.defaults then
		for k, v in pairs(def.defaults) do m[k] = v end
	end
	if over then
		for k, v in pairs(over) do m[k] = v end
	end
	return m
end

-- Adds a mesh to the current scene (saved).
function AVR:AddMesh(typeName, over)
	local m = self:NewMesh(typeName, over)
	if not m then return nil end
	tinsert(self:GetScene().meshes, m)
	self:Changed()
	return m
end

-- Adds an unsaved mesh that disappears after 'duration' seconds (nil = until
-- ClearTemp or reload). Returns the mesh, which can be handed to RemoveTemp.
function AVR:AddTemp(typeName, over, duration)
	local m = self:NewMesh(typeName, over)
	if not m then return nil end
	if duration then m.expires = GetTime() + duration end
	tinsert(self.temps, m)
	return m
end

function AVR:RemoveTemp(m)
	for i = getn(self.temps), 1, -1 do
		if self.temps[i] == m then tremove(self.temps, i) end
	end
end

function AVR:ClearTemp()
	self.temps = {}
end

-- The options window hooks this to refresh itself.
function AVR:Changed()
	if self.RefreshGUI then self:RefreshGUI() end
end

-------------------------------------------------------------------------------
-- Units
-------------------------------------------------------------------------------

local groupUnits = {}
local groupDirty = true

function AVR:GroupUnits()
	if groupDirty then
		groupDirty = false
		for i = getn(groupUnits), 1, -1 do tremove(groupUnits, i) end
		local n = GetNumRaidMembers()
		if n > 0 then
			for i = 1, n do tinsert(groupUnits, "raid" .. i) end
		else
			for i = 1, GetNumPartyMembers() do tinsert(groupUnits, "party" .. i) end
		end
	end
	return groupUnits
end

local function IsToken(s)
	return s == "player" or s == "target" or s == "pet" or s == "mouseover"
		or s == "targettarget" or s == "pettarget"
		or s == "focus" or s == "focustarget"
		or string.find(s, "^nameplate%d+$") or string.find(s, "^0x%x+$")
		or string.find(s, "^party%d$") or string.find(s, "^raid%d+$")
		or string.find(s, "^partypet%d$") or string.find(s, "^raidpet%d+$")
end

-- Unit token for a token or a player name; nil when nobody matches right now.
function AVR:ResolveUnit(unit)
	if not unit or unit == "" then return nil end
	local l = string.lower(unit)
	if IsToken(l) then
		if UnitExists(l) then return l end
		return nil
	end
	if l == string.lower(UnitName("player") or "") then return "player" end
	for _, u in ipairs(self:GroupUnits()) do
		local n = UnitName(u)
		if n and string.lower(n) == l then return u end
	end
	if UnitExists("target") and string.lower(UnitName("target") or "") == l then return "target" end
	return nil
end

--[[ World position of a unit: x (north), y (west), z, mapID.

	Two sources, tried in turn:
	  SuperWoW's UnitPosition      x, y, z. Measured to answer for players only.
	  ClassicAPI's UnitPosition    posY, posX, posZ, instanceID - west first.
	                               Any visible unit, NPCs included. Always at
	                               C_PlayerInfo.UnitPosition; also the global
	                               when SuperWoW is absent or loads first.
	A fourth return tells the two shapes of the global apart.
]]
local capiSwap = true -- ClassicAPI order is (west, north); checked once below
local capiChecked = false

local function CapiPos(unit)
	local f = C_PlayerInfo and C_PlayerInfo.UnitPosition
	if not f then return nil end
	local ok, a, b, c, d = pcall(f, unit)
	if not ok or type(a) ~= "number" or type(b) ~= "number" then return nil end
	if capiSwap then return b, a, c, d end
	return a, b, c, d
end

local function GlobalPos(unit)
	if not UnitPosition then return nil end
	local ok, a, b, c, d = pcall(UnitPosition, unit)
	if not ok or type(a) ~= "number" or type(b) ~= "number" then return nil end
	if d ~= nil then return b, a, c, d, true end -- ClassicAPI's shape
	return a, b, c, nil, false
end

function AVR:UnitPos(unit)
	local x, y, z, map, isCapi = GlobalPos(unit)
	if not capiChecked and x and not isCapi and unit == "player" then
		-- Both libraries present: let SuperWoW's known order settle
		-- ClassicAPI's, in case a build returns north first.
		local a, b = CapiPos("player")
		if a then
			capiChecked = true
			if math.abs(a - x) > 1 and math.abs(b - x) < 1 and math.abs(a - y) < 1 then
				capiSwap = not capiSwap
			end
		end
	end
	if x then return x, y, z, map end
	return CapiPos(unit)
end

function AVR:HasPositions()
	return (UnitPosition or (C_PlayerInfo and C_PlayerInfo.UnitPosition)) and true or false
end

-- Map (continent / instance) the player is on, when ClassicAPI can say.
function AVR:CurrentMap()
	local _, _, _, map = CapiPos("player")
	return map
end

--[[ Height above the feet that the game camera orbits.

	ClassicAPI (newer builds) can report the real figure for a model through a
	ModelScene actor showing the player. Without it the per-race table in
	PivotHeight is the fallback.
]]
local pivotScene, pivotActor
local pivotValue, pivotNext = nil, 0

local function ProbePivot(dist)
	local now = GetTime()
	if now < pivotNext then return pivotValue end
	pivotNext = now + 1
	if pivotScene == false then return nil end
	if not pivotScene then
		local ok, scene = pcall(CreateFrame, "ModelScene", nil, UIParent)
		if not ok or not scene or not scene.CreateActor then
			pivotScene = false
			return nil
		end
		pivotScene = scene
		scene:SetWidth(1)
		scene:SetHeight(1)
		scene:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
		scene:SetAlpha(0)
		local ok2, actor = pcall(scene.CreateActor, scene)
		if not ok2 or not actor or not actor.GetCameraPivotHeight or not actor.SetModelByUnit then
			pivotScene = false
			return nil
		end
		pivotActor = actor
		pcall(actor.SetModelByUnit, actor, "player")
	end
	local ok, h = pcall(pivotActor.GetCameraPivotHeight, pivotActor, dist or 10)
	if ok and type(h) == "number" and h > 0 then pivotValue = h end
	return pivotValue
end

-- Shapeshifts and the like change the model the camera follows.
function AVR:ResetPivotProbe()
	if pivotActor then pcall(pivotActor.SetModelByUnit, pivotActor, "player") end
	pivotValue, pivotNext = nil, 0
end

local minimapArrow
function AVR:GetFacing()
	if GetPlayerFacing then
		local ok, f = pcall(GetPlayerFacing)
		if ok and type(f) == "number" then return f, "GetPlayerFacing" end
	end
	if not minimapArrow and Minimap and Minimap.GetChildren then
		for _, child in ipairs({ Minimap:GetChildren() }) do
			if child.IsObjectType and child:IsObjectType("Model") and not child:GetName() then
				local ok, model = pcall(child.GetModel, child)
				if ok and type(model) == "string"
					and string.find(string.lower(model), "minimaparrow", 1, true) then
					minimapArrow = child
					break
				end
			end
		end
	end
	if minimapArrow then
		local ok, f = pcall(minimapArrow.GetFacing, minimapArrow)
		if ok and type(f) == "number" then return f, "minimap arrow" end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Camera
-------------------------------------------------------------------------------

local C = { ok = false }
AVR.cam = C

-- Per-frame camera state, kept in upvalues for the projection hot path.
local camX, camY, camZ = 0, 0, 0
local fX, fY, fZ = 1, 0, 0 -- forward
local rX, rY = 0, -1       -- right (always horizontal)
local uX, uY, uZ = 0, 0, 1 -- up
local pScale = 1           -- screen units per unit of tan(angle)
local halfW, halfH = 512, 384
local scrW, scrH = 1024, 768

local function CVarNum(name)
	local ok, v = pcall(GetCVar, name)
	if ok and v then return tonumber(v) end
	return nil
end

-- Returns the height and where it came from: "manual", "model" or "race".
function AVR:PivotHeight()
	if self.settings.pivotHeight then return self.settings.pivotHeight, "manual" end
	local h = ProbePivot(C.dist)
	if h then return h, "model" end
	local _, race = UnitRace("player")
	return raceHeight[race or ""] or 2.0, "race"
end

-- Base field of view in radians, as the client stores it (1.5708 stock).
function AVR:BaseFov()
	local f = CVarNum("FoV") -- SuperWoW
	if f and f > 0.1 then
		if f > 3.2 then f = f * PI / 180 end
		return f
	end
	return 1.5708
end

-- Vertical field of view in radians.
function AVR:VerticalFov(aspect)
	if self.settings.fov then return self.settings.fov * PI / 180 end
	-- The client derives the vertical angle from its base FoV like this,
	-- which keeps the diagonal roughly constant across aspect ratios.
	return self:BaseFov() / sqrt(1 + aspect * aspect)
end

--[[ Reads the saved view: distance, pitch, yaw.

	Which cvar letter belongs to view slot 5 is not something the client
	documents (D or E), so both are watched until one of them is seen to
	follow the camera; that one is then used alone.
]]
local viewLast = {}
local viewLetters = { "D", "E" }
function AVR:ReadView()
	local sfx = self.viewSuffix
	if sfx then
		return CVarNum("cameraDistance" .. sfx) or 0,
			CVarNum("cameraPitch" .. sfx) or 0,
			CVarNum("cameraYaw" .. sfx) or 0
	end
	local guess, moved, nMoved
	nMoved = 0
	for _, s in ipairs(viewLetters) do
		local d = CVarNum("cameraDistance" .. s)
		if d then
			local p, y = CVarNum("cameraPitch" .. s) or 0, CVarNum("cameraYaw" .. s) or 0
			local key = d .. "/" .. p .. "/" .. y
			if viewLast[s] and viewLast[s] ~= key then
				moved = s
				nMoved = nMoved + 1
			end
			viewLast[s] = key
			if not guess then guess = s end
		end
	end
	if nMoved == 1 then
		self.viewSuffix = moved
		guess = moved
	end
	self.viewGuess = guess
	if not guess then return nil end
	return CVarNum("cameraDistance" .. guess) or 0,
		CVarNum("cameraPitch" .. guess) or 0,
		CVarNum("cameraYaw" .. guess) or 0
end

function AVR:UpdateCamera()
	C.ok = false
	if not self:HasPositions() then C.err = "no UnitPosition (needs SuperWoW or ClassicAPI)" return false end
	local px, py, pz, map = self:UnitPos("player")
	if not px or not py or not pz then C.err = "no player position" return false end
	if not map then map = self:CurrentMap() end
	local facing, src = self:GetFacing()
	if not facing then C.err = "no player facing" return false end

	-- SaveView writes the live camera into the cvars of view slot 5.
	SaveView(5)
	local dist, pitchDeg, yawDeg = self:ReadView()
	if not dist then C.err = "camera cvars unavailable" return false end

	local left, right = WorldFrame:GetLeft(), WorldFrame:GetRight()
	local bottom, top = WorldFrame:GetBottom(), WorldFrame:GetTop()
	if not left or not right or not bottom or not top then C.err = "no viewport" return false end
	scrW, scrH = right - left, top - bottom
	if scrW <= 0 or scrH <= 0 then C.err = "no viewport" return false end
	halfW, halfH = scrW * 0.5, scrH * 0.5

	local s = self.settings
	local pitch = pitchDeg * PI / 180 * (s.pitchSign or 1)
	local yaw = facing + yawDeg * PI / 180 * (s.yawSign or 1)

	-- Orbit: the camera sits 'dist' behind the pivot along the view direction.
	local cp, sp = cos(pitch), sin(pitch)
	local cy, sy = cos(yaw), sin(yaw)
	local h = self:PivotHeight()
	local xp = UnitXP_SP3_Addon
	if type(xp) == "table" and type(xp.cameraHeight) == "number" then h = h + xp.cameraHeight end
	camX = px - cy * cp * dist
	camY = py - sy * cp * dist
	camZ = pz + h + sp * dist

	-- UnitXP can tilt the view without moving the camera.
	if type(xp) == "table" and type(xp.cameraPitch) == "number" and xp.cameraPitch ~= 0 then
		pitch = pitch - xp.cameraPitch
		cp, sp = cos(pitch), sin(pitch)
	end
	fX, fY, fZ = cy * cp, sy * cp, -sp
	rX, rY = sy, -cy
	uX, uY, uZ = cy * sp, sy * sp, cp

	pScale = halfH / tan(self:VerticalFov(scrW / scrH) * 0.5)

	C.px, C.py, C.pz, C.facing, C.map = px, py, pz, facing, map
	C.x, C.y, C.z = camX, camY, camZ
	C.dist, C.pitch, C.yaw = dist, pitchDeg, yawDeg
	C.w, C.h, C.left, C.bottom = scrW, scrH, left, bottom
	C.facingSource = src
	C.err = nil
	C.ok = true
	return true
end

-- World position under a screen point (canvas units), on the horizontal
-- plane at height z. nil when the ray does not hit the plane ahead.
function AVR:ScreenToWorld(sx, sy, z)
	if not C.ok then return nil end
	local xn, yn = (sx - halfW) / pScale, (sy - halfH) / pScale
	local dx = fX + rX * xn + uX * yn
	local dy = fY + rY * xn + uY * yn
	local dz = fZ + uZ * yn
	if dz > -0.001 then return nil end
	local t = (z - camZ) / dz
	if t <= 0 or t > 500 then return nil end
	return camX + dx * t, camY + dy * t, z
end

-- World position under the mouse cursor on the plane at height z.
function AVR:CursorToWorld(z)
	if not C.ok then return nil end
	local mx, my = GetCursorPosition()
	return self:ScreenToWorld(mx - C.left, my - C.bottom, z or C.pz)
end

-------------------------------------------------------------------------------
-- Renderer
-------------------------------------------------------------------------------

local canvas = CreateFrame("Frame", "AVRCanvas", WorldFrame)
canvas:SetAllPoints(WorldFrame)
canvas:SetFrameStrata("BACKGROUND")
AVR.canvas = canvas

local lines, tris = {}, {}
local nLines, nTris = 0, 0
local shownLines, shownTris = 0, 0

local colR, colG, colB, colA = 1, 1, 1, 1
local fillA = 0.3
local lineW = 3

function AVR:SetColor(r, g, b, a)
	colR, colG, colB, colA = r or 1, g or 1, b or 1, a or 1
	fillA = colA * (self.settings.fillAlpha or 0.3)
end

function AVR:SetLineWidth(w)
	lineW = w or self.settings.lineWidth or 3
end

-- Liang-Barsky step.
local function ClipT(p, q, t0, t1)
	if p == 0 then
		if q < 0 then return nil end
		return t0, t1
	end
	local r = q / p
	if p < 0 then
		if r > t1 then return nil end
		if r > t0 then t0 = r end
	else
		if r < t0 then return nil end
		if r < t1 then t1 = r end
	end
	return t0, t1
end

-- A line between two screen points: one texture over the segment's bounding
-- box, with texture coordinates skewed so the band in line.tga lies along it.
local function Line2D(x1, y1, x2, y2)
	-- clip to the screen (plus a margin) so the texture stays bounded
	local dx, dy = x2 - x1, y2 - y1
	local t0, t1 = ClipT(-dx, x1 + 20, 0, 1)
	if not t0 then return end
	t0, t1 = ClipT(dx, scrW + 20 - x1, t0, t1)
	if not t0 then return end
	t0, t1 = ClipT(-dy, y1 + 20, t0, t1)
	if not t0 then return end
	t0, t1 = ClipT(dy, scrH + 20 - y1, t0, t1)
	if not t0 then return end
	if t1 < 1 then x2, y2 = x1 + dx * t1, y1 + dy * t1 end
	if t0 > 0 then x1, y1 = x1 + dx * t0, y1 + dy * t0 end
	dx, dy = x2 - x1, y2 - y1

	local len2 = dx * dx + dy * dy
	if len2 < 0.25 then return end
	local len = sqrt(len2)
	local w = lineW
	local hx, hy = abs(dx) * 0.5 + w, abs(dy) * 0.5 + w

	nLines = nLines + 1
	local t = lines[nLines]
	if not t then
		t = canvas:CreateTexture(nil, "ARTWORK")
		t:SetTexture(LINE_TEX)
		lines[nLines] = t
	end
	t:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", (x1 + x2) * 0.5 - hx, (y1 + y2) * 0.5 - hy)
	t:SetWidth(hx * 2)
	t:SetHeight(hy * 2)

	-- u runs along the line (30 of 32 texels are opaque), v across it (the
	-- band is 12 of 32 texels wide).
	local ku = 0.9375 / len2
	local kv = 0.375 / (w * len)
	local ax, ay = dx * ku * hx, dy * ku * hy
	local bx, by = -dy * kv * hx, dx * kv * hy
	t:SetTexCoord(
		0.5 - ax + ay, 0.5 - bx + by, -- upper left
		0.5 - ax - ay, 0.5 - bx - by, -- lower left
		0.5 + ax + ay, 0.5 + bx + by, -- upper right
		0.5 + ax - ay, 0.5 + bx - by) -- lower right
	t:SetVertexColor(colR, colG, colB, colA)
	t:Show()
end

-- A filled triangle between three screen points: tri.tga holds a right
-- triangle, and any triangle is an affine image of it.
local TRI_M, TRI_S = 3 / 64, 58 / 64
local function Tri2D(ax, ay, bx, by, cx, cy)
	local minx, maxx, miny, maxy = ax, ax, ay, ay
	if bx < minx then minx = bx elseif bx > maxx then maxx = bx end
	if cx < minx then minx = cx elseif cx > maxx then maxx = cx end
	if by < miny then miny = by elseif by > maxy then maxy = by end
	if cy < miny then miny = cy elseif cy > maxy then maxy = cy end
	minx, maxx, miny, maxy = minx - 1, maxx + 1, miny - 1, maxy + 1
	if minx < 0 then minx = 0 end
	if miny < 0 then miny = 0 end
	if maxx > scrW then maxx = scrW end
	if maxy > scrH then maxy = scrH end
	if maxx <= minx or maxy <= miny then return end

	local e1x, e1y, e2x, e2y = bx - ax, by - ay, cx - ax, cy - ay
	local det = e1x * e2y - e1y * e2x
	if abs(det) < 0.5 then return end
	-- texture coordinates as a function of screen position p:
	--   tu = M + S * ( e2y*(px-ax) - e2x*(py-ay)) / det
	--   tv = M + S * (-e1y*(px-ax) + e1x*(py-ay)) / det
	local k = TRI_S / det
	local ux, uy, vx, vy = e2y * k, -e2x * k, -e1y * k, e1x * k
	local x0, x1, y0, y1 = minx - ax, maxx - ax, miny - ay, maxy - ay

	nTris = nTris + 1
	local t = tris[nTris]
	if not t then
		t = canvas:CreateTexture(nil, "BORDER")
		t:SetTexture(TRI_TEX)
		tris[nTris] = t
	end
	t:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", minx, miny)
	t:SetWidth(maxx - minx)
	t:SetHeight(maxy - miny)
	t:SetTexCoord(
		TRI_M + ux * x0 + uy * y1, TRI_M + vx * x0 + vy * y1, -- upper left
		TRI_M + ux * x0 + uy * y0, TRI_M + vx * x0 + vy * y0, -- lower left
		TRI_M + ux * x1 + uy * y1, TRI_M + vx * x1 + vy * y1, -- upper right
		TRI_M + ux * x1 + uy * y0, TRI_M + vx * x1 + vy * y0) -- lower right
	t:SetVertexColor(colR, colG, colB, fillA)
	t:Show()
end

-- A line between two world points, in the current colour and width.
local function Line3D(x1, y1, z1, x2, y2, z2)
	local dx, dy, dz = x1 - camX, y1 - camY, z1 - camZ
	local za = dx * fX + dy * fY + dz * fZ
	local xa = dx * rX + dy * rY
	local ya = dx * uX + dy * uY + dz * uZ
	dx, dy, dz = x2 - camX, y2 - camY, z2 - camZ
	local zb = dx * fX + dy * fY + dz * fZ
	local xb = dx * rX + dy * rY
	local yb = dx * uX + dy * uY + dz * uZ

	if za < NEAR then
		if zb < NEAR then return end
		local t = (NEAR - za) / (zb - za)
		xa, ya, za = xa + (xb - xa) * t, ya + (yb - ya) * t, NEAR
	elseif zb < NEAR then
		local t = (NEAR - zb) / (za - zb)
		xb, yb, zb = xb + (xa - xb) * t, yb + (ya - yb) * t, NEAR
	end
	Line2D(halfW + xa / za * pScale, halfH + ya / za * pScale,
		halfW + xb / zb * pScale, halfH + yb / zb * pScale)
end

-- A filled triangle between three world points, in the current colour.
local tvx, tvy, tvz = {}, {}, {}
local osx, osy = {}, {}
local function Tri3D(x1, y1, z1, x2, y2, z2, x3, y3, z3)
	local dx, dy, dz = x1 - camX, y1 - camY, z1 - camZ
	tvz[1] = dx * fX + dy * fY + dz * fZ
	tvx[1] = dx * rX + dy * rY
	tvy[1] = dx * uX + dy * uY + dz * uZ
	dx, dy, dz = x2 - camX, y2 - camY, z2 - camZ
	tvz[2] = dx * fX + dy * fY + dz * fZ
	tvx[2] = dx * rX + dy * rY
	tvy[2] = dx * uX + dy * uY + dz * uZ
	dx, dy, dz = x3 - camX, y3 - camY, z3 - camZ
	tvz[3] = dx * fX + dy * fY + dz * fZ
	tvx[3] = dx * rX + dy * rY
	tvy[3] = dx * uX + dy * uY + dz * uZ

	-- clip against the near plane; leaves 0, 3 or 4 vertices
	local n = 0
	for i = 1, 3 do
		local j = i + 1
		if j > 3 then j = 1 end
		local zi, zj = tvz[i], tvz[j]
		local inI, inJ = zi >= NEAR, zj >= NEAR
		if inI then
			n = n + 1
			osx[n] = halfW + tvx[i] / zi * pScale
			osy[n] = halfH + tvy[i] / zi * pScale
		end
		if inI ~= inJ then
			local t = (NEAR - zi) / (zj - zi)
			n = n + 1
			osx[n] = halfW + (tvx[i] + (tvx[j] - tvx[i]) * t) / NEAR * pScale
			osy[n] = halfH + (tvy[i] + (tvy[j] - tvy[i]) * t) / NEAR * pScale
		end
	end
	if n < 3 then return end
	Tri2D(osx[1], osy[1], osx[2], osy[2], osx[3], osy[3])
	if n == 4 then Tri2D(osx[1], osy[1], osx[3], osy[3], osx[4], osy[4]) end
end

function AVR:Line3D(x1, y1, z1, x2, y2, z2) Line3D(x1, y1, z1, x2, y2, z2) end
function AVR:Tri3D(x1, y1, z1, x2, y2, z2, x3, y3, z3) Tri3D(x1, y1, z1, x2, y2, z2, x3, y3, z3) end

-- Roughly: could anything within 'radius' of this point be in front of the
-- camera and inside the draw distance?
function AVR:InRange(x, y, z, radius)
	local dx, dy, dz = x - camX, y - camY, z - camZ
	local lim = (self.settings.maxDistance or 200) + (radius or 0)
	if dx * dx + dy * dy + dz * dz > lim * lim then return false end
	return dx * fX + dy * fY + dz * fZ > -(radius or 0)
end

-- A flat circle. 'segs' defaults by radius.
function AVR:Circle(x, y, z, radius, segs, filled)
	if not self:InRange(x, y, z, radius) then return end
	if not segs or segs < 3 then
		segs = 24
		if radius > 12 then segs = 36 end
		if radius > 30 then segs = 48 end
		if radius < 2 then segs = 12 end
	end
	local step = 2 * PI / segs
	local lx, ly = x + radius, y
	for i = 1, segs do
		local a = i * step
		local nx, ny = x + radius * cos(a), y + radius * sin(a)
		Line3D(lx, ly, z, nx, ny, z)
		if filled then Tri3D(x, y, z, lx, ly, z, nx, ny, z) end
		lx, ly = nx, ny
	end
end

-- A circular sector from angle a0 to a1 (radians, counter-clockwise from
-- north), with its two edges.
function AVR:Sector(x, y, z, radius, a0, a1, segs, filled)
	if not self:InRange(x, y, z, radius) then return end
	local span = a1 - a0
	if not segs or segs < 1 then
		segs = floor(abs(span) / (2 * PI) * 36 + 0.5)
		if segs < 2 then segs = 2 end
	end
	local step = span / segs
	local lx, ly = x + radius * cos(a0), y + radius * sin(a0)
	Line3D(x, y, z, lx, ly, z)
	for i = 1, segs do
		local a = a0 + i * step
		local nx, ny = x + radius * cos(a), y + radius * sin(a)
		Line3D(lx, ly, z, nx, ny, z)
		if filled then Tri3D(x, y, z, lx, ly, z, nx, ny, z) end
		lx, ly = nx, ny
	end
	Line3D(lx, ly, z, x, y, z)
end

-------------------------------------------------------------------------------
-- Drawing meshes
-------------------------------------------------------------------------------

function AVR:UnitFacing(unit)
	if UnitIsUnit(unit, "player") then return C.facing end
	if UnitFacing then
		local ok, f = pcall(UnitFacing, unit)
		if ok and type(f) == "number" then return f end
	end
	return nil
end

-- Where a mesh is right now: x, y, z, facing. nil when it cannot be placed
-- (unit not found, out of range, no position).
function AVR:Locate(m)
	local x, y, z, f
	if m.unit then
		local u = self:ResolveUnit(m.unit)
		if not u then return nil end
		x, y, z = self:UnitPos(u)
		if not x or not y then return nil end
		z = z or C.pz
		f = m.followRotation and self:UnitFacing(u) or (m.rot or 0)
	else
		x, y, z, f = m.x, m.y, m.z, m.rot or 0
		if not x or not y or not z then return nil end
		-- pinned on another continent or in another instance
		if m.map and C.map and m.map ~= C.map then return nil end
	end
	local ox, oy = m.ox or 0, m.oy or 0
	if ox ~= 0 or oy ~= 0 then
		local cf, sf = cos(f), sin(f)
		x = x + cf * ox + sf * oy -- forward, then right
		y = y + sf * ox - cf * oy
	end
	return x, y, z, f
end

-- Turns a unit-anchored mesh into one fixed to the ground where it is now.
function AVR:PinMesh(m)
	local x, y, z, f = self:Locate(m)
	if not x then return false end
	m.x, m.y, m.z, m.rot, m.map = x, y, z, f, C.map
	m.unit, m.ox, m.oy, m.followRotation = nil, nil, nil, nil
	return true
end

function AVR:DrawMesh(m)
	if m.hidden then return end
	local def = self.types[m.type]
	if not def then return end
	self:SetColor(m.r, m.g, m.b, m.a)
	self:SetLineWidth(m.width)
	if def.absolute then
		if m.map and C.map and m.map ~= C.map then return end
		def.Draw(m)
		return
	end
	local x, y, z, f = self:Locate(m)
	if not x then return end
	def.Draw(m, x, y, z, f)
end

local function HideUnused()
	for i = nLines + 1, shownLines do lines[i]:Hide() end
	for i = nTris + 1, shownTris do tris[i]:Hide() end
	shownLines, shownTris = nLines, nTris
end

function AVR:OnFrame()
	nLines, nTris = 0, 0
	if self.db and self.settings.enabled and self:UpdateCamera() then
		for _, scene in ipairs(self.db.scenes) do
			if scene.visible then
				for _, m in ipairs(scene.meshes) do self:DrawMesh(m) end
			end
		end
		local temps = self.temps
		local now = GetTime()
		for i = getn(temps), 1, -1 do
			local m = temps[i]
			if m.expires and m.expires < now then
				tremove(temps, i)
			else
				self:DrawMesh(m)
			end
		end
		if self.DrawTool then self:DrawTool() end
	end
	HideUnused()
end

canvas:SetScript("OnUpdate", function() AVR:OnFrame() end)

-------------------------------------------------------------------------------
-- Public API for other addons (boss mods and the like)
-------------------------------------------------------------------------------

-- Circle around a unit for 'duration' seconds. Returns the mesh.
function AVR:MarkUnit(unit, radius, duration, r, g, b, a, filled)
	return self:AddTemp("circle", {
		unit = unit, radius = radius or 5, filled = filled,
		r = r or 1, g = g or 0, b = b or 0, a = a or 0.9,
	}, duration)
end

-- Circle fixed at a world position (default: where the unit stands now).
function AVR:MarkPosition(x, y, z, radius, duration, r, g, b, a, filled)
	if type(x) == "string" then
		local u = self:ResolveUnit(x)
		if not u then return nil end
		x, y, z = self:UnitPos(u)
		if not x then return nil end
	end
	return self:AddTemp("circle", {
		x = x, y = y, z = z or C.pz, map = C.map, radius = radius or 5, filled = filled,
		r = r or 1, g = g or 0, b = b or 0, a = a or 0.9,
	}, duration)
end

-- Range check circle around the player that turns red when a group member
-- stands inside it.
function AVR:RangeWarning(radius, duration)
	return self:AddTemp("range", { unit = "player", radius = radius or 10 }, duration)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("UNIT_MODEL_CHANGED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function()
	if event == "VARIABLES_LOADED" then
		AVR:InitDB()
		if not AVR:HasPositions() then
			AVR:Print("No UnitPosition (SuperWoW or ClassicAPI) - nothing can be drawn.")
		end
	elseif event == "UNIT_MODEL_CHANGED" then
		if arg1 == "player" then AVR:ResetPivotProbe() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		AVR:ResetPivotProbe()
	elseif event == "CHAT_MSG_ADDON" then
		if AVR.OnAddonMessage then AVR:OnAddonMessage(arg1, arg2, arg3, arg4) end
	else
		groupDirty = true
	end
end)
