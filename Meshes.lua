--[[ AVR mesh types.

	Every mesh is a plain table (so it can be saved and shared) with a 'type'
	naming one of the definitions registered here. Anchored types are handed
	the resolved position and facing; 'absolute' types carry world coordinates
	of their own.
]]

local AVR = AVR
local sin, cos, sqrt = math.sin, math.cos, math.sqrt
local PI = math.pi
local getn = table.getn

local function Where(m)
	if m.unit then return "@" .. m.unit end
	return "pinned"
end

local function Num(v)
	if not v then return "?" end
	if v == math.floor(v) then return string.format("%d", v) end
	return string.format("%.1f", v)
end

-------------------------------------------------------------------------------
-- Circle
-------------------------------------------------------------------------------

AVR:RegisterMeshType("circle", {
	label = "Circle",
	defaults = { radius = 8, unit = "player" },
	fields = {
		{ key = "radius", label = "Radius (yd)", kind = "number" },
		{ key = "filled", label = "Filled", kind = "bool" },
	},
	Draw = function(m, x, y, z)
		AVR:Circle(x, y, z, m.radius or 8, m.segments, m.filled)
	end,
	Summary = function(m) return Num(m.radius) .. " yd " .. Where(m) end,
})

-------------------------------------------------------------------------------
-- Cone
-------------------------------------------------------------------------------

AVR:RegisterMeshType("cone", {
	label = "Cone",
	defaults = { radius = 10, angle = 90, dir = 0, unit = "player", followRotation = true },
	fields = {
		{ key = "radius", label = "Length (yd)", kind = "number" },
		{ key = "angle", label = "Angle (deg)", kind = "number" },
		{ key = "dir", label = "Turn (deg)", kind = "number" },
		{ key = "filled", label = "Filled", kind = "bool" },
	},
	Draw = function(m, x, y, z, f)
		local half = (m.angle or 90) * PI / 360
		local mid = f - (m.dir or 0) * PI / 180 -- positive turn = clockwise
		AVR:Sector(x, y, z, m.radius or 10, mid - half, mid + half, nil, m.filled)
	end,
	Summary = function(m) return Num(m.radius) .. " yd, " .. Num(m.angle) .. " deg " .. Where(m) end,
})

-------------------------------------------------------------------------------
-- Marker: a cross inside a hexagon
-------------------------------------------------------------------------------

local function Hexagon(x, y, z, size)
	AVR:Circle(x, y, z, size, 6, false)
end

AVR:RegisterMeshType("marker", {
	label = "Marker",
	defaults = { size = 1.5 },
	fields = {
		{ key = "size", label = "Size (yd)", kind = "number" },
	},
	Draw = function(m, x, y, z)
		local s = m.size or 1.5
		if not AVR:InRange(x, y, z, s) then return end
		local d = s * 0.6
		AVR:Line3D(x - d, y - d, z, x + d, y + d, z)
		AVR:Line3D(x - d, y + d, z, x + d, y - d, z)
		Hexagon(x, y, z, s)
	end,
	Summary = function(m) return Where(m) end,
})

-------------------------------------------------------------------------------
-- Arrow: from the anchor along its facing
-------------------------------------------------------------------------------

AVR:RegisterMeshType("arrow", {
	label = "Arrow",
	defaults = { length = 10, dir = 0, unit = "player", followRotation = true },
	fields = {
		{ key = "length", label = "Length (yd)", kind = "number" },
		{ key = "dir", label = "Turn (deg)", kind = "number" },
	},
	Draw = function(m, x, y, z, f)
		local len = m.length or 10
		if not AVR:InRange(x, y, z, len) then return end
		local a = f - (m.dir or 0) * PI / 180
		local ca, sa = cos(a), sin(a)
		local tx, ty = x + ca * len, y + sa * len
		AVR:Line3D(x, y, z, tx, ty, z)
		-- head: two barbs swept back 150 degrees either side
		local h = len * 0.2
		if h > 3 then h = 3 end
		local b1, b2 = a + PI * 5 / 6, a - PI * 5 / 6
		AVR:Line3D(tx, ty, z, tx + cos(b1) * h, ty + sin(b1) * h, z)
		AVR:Line3D(tx, ty, z, tx + cos(b2) * h, ty + sin(b2) * h, z)
	end,
	Summary = function(m) return Num(m.length) .. " yd " .. Where(m) end,
})

-------------------------------------------------------------------------------
-- Range warning: a circle that turns red while a group member is inside it
-------------------------------------------------------------------------------

AVR:RegisterMeshType("range", {
	label = "Range warning",
	defaults = { radius = 10, unit = "player", markSize = 1.5, r = 0.2, g = 1, b = 0.2, a = 0.8 },
	fields = {
		{ key = "radius", label = "Radius (yd)", kind = "number" },
		{ key = "markSize", label = "Mark size (yd)", kind = "number" },
	},
	Draw = function(m, x, y, z)
		local radius = m.radius or 10
		local r2 = radius * radius
		local me = AVR:ResolveUnit(m.unit or "player")
		local inside = false
		local size = m.markSize or 0
		for _, u in ipairs(AVR:GroupUnits()) do
			if not (me and UnitIsUnit(u, me)) and not UnitIsDeadOrGhost(u) then
				local ux, uy, uz = AVR:UnitPos(u)
				if ux then
					local dx, dy = ux - x, uy - y
					if dx * dx + dy * dy <= r2 then
						if not inside then
							inside = true
							AVR:SetColor(1, 0.1, 0.1, m.a)
						end
						if size > 0 then Hexagon(ux, uy, uz or z, size) end
					end
				end
			end
		end
		AVR:Circle(x, y, z, radius, m.segments, inside)
	end,
	Summary = function(m) return Num(m.radius) .. " yd " .. Where(m) end,
})

-------------------------------------------------------------------------------
-- Group marks: a hexagon under every group member near the anchor
-------------------------------------------------------------------------------

AVR:RegisterMeshType("groupmarks", {
	label = "Group marks",
	defaults = { range = 40, size = 1.5, unit = "player", r = 0.3, g = 0.6, b = 1, a = 0.8 },
	fields = {
		{ key = "range", label = "Within (yd)", kind = "number" },
		{ key = "size", label = "Size (yd)", kind = "number" },
		{ key = "filled", label = "Filled", kind = "bool" },
	},
	Draw = function(m, x, y, z)
		local range = m.range or 40
		local r2 = range * range
		local size = m.size or 1.5
		local me = AVR:ResolveUnit(m.unit or "player")
		for _, u in ipairs(AVR:GroupUnits()) do
			if not (me and UnitIsUnit(u, me)) and not UnitIsDeadOrGhost(u) then
				local ux, uy, uz = AVR:UnitPos(u)
				if ux then
					local dx, dy = ux - x, uy - y
					if dx * dx + dy * dy <= r2 then
						AVR:Circle(ux, uy, uz or z, size, 6, m.filled)
					end
				end
			end
		end
	end,
	Summary = function(m) return "within " .. Num(m.range) .. " yd" end,
})

-------------------------------------------------------------------------------
-- Path: a freehand line, stored as flat world coordinates x1,y1,z1,x2,...
-------------------------------------------------------------------------------

AVR:RegisterMeshType("path", {
	label = "Drawing",
	absolute = true,
	defaults = { r = 1, g = 1, b = 1, a = 0.9 },
	fields = {
		{ key = "closed", label = "Closed", kind = "bool" },
	},
	Draw = function(m)
		local p = m.pts
		if not p then return end
		local n = getn(p)
		if n < 6 then return end
		if not AVR:InRange(p[1], p[2], p[3], 100) then return end
		for i = 1, n - 5, 3 do
			AVR:Line3D(p[i], p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5])
		end
		if m.closed and n >= 9 then
			AVR:Line3D(p[n - 2], p[n - 1], p[n], p[1], p[2], p[3])
		end
	end,
	Summary = function(m)
		local p = m.pts
		local len = 0
		if p then
			for i = 1, getn(p) - 5, 3 do
				local dx, dy = p[i + 3] - p[i], p[i + 4] - p[i + 1]
				len = len + sqrt(dx * dx + dy * dy)
			end
		end
		return Num(len) .. " yd long"
	end,
})
