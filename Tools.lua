--[[ AVR mouse tools: freehand drawing on the ground, and measuring.

	While a tool is active a full-screen frame takes the mouse, so the camera
	cannot be turned with it; right-click leaves the tool.
]]

local AVR = AVR
local sqrt = math.sqrt
local getn, tinsert = table.getn, table.insert

local MAX_POINTS = 150 -- per stroke
local MIN_STEP = 0.6   -- yards between stored points

local overlay = CreateFrame("Frame", "AVRToolOverlay", UIParent)
overlay:SetAllPoints(WorldFrame)
overlay:SetFrameStrata("BACKGROUND")
overlay:EnableMouse(true)
overlay:Hide()

local hint = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
hint:SetPoint("TOP", overlay, "TOP", 0, -120)

local mode          -- "draw" / "measure" / nil
local stroke        -- flat x,y,z list being drawn
local startX, startY, startZ, endX, endY

local function Dist(x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	return sqrt(dx * dx + dy * dy)
end

local function SetHint()
	if mode == "draw" then
		hint:SetText("AVR: drag with the left button to draw - right-click to finish")
	elseif mode == "measure" then
		hint:SetText("AVR: drag with the left button to measure - right-click to finish")
	end
end

function AVR:StartTool(which)
	if not self.cam.ok then
		self:Print("Cannot start: " .. (self.cam.err or "drawing is disabled") .. ".")
		return
	end
	mode = which
	stroke, startX = nil, nil
	SetHint()
	overlay:Show()
end

function AVR:StopTool()
	mode, stroke, startX = nil, nil, nil
	overlay:Hide()
end

function AVR:ActiveTool()
	return mode
end

overlay:SetScript("OnMouseDown", function()
	if arg1 == "RightButton" then
		AVR:StopTool()
		return
	end
	local x, y, z = AVR:CursorToWorld()
	if not x then return end
	if mode == "draw" then
		stroke = { x, y, z }
	elseif mode == "measure" then
		startX, startY, startZ, endX, endY = x, y, z, x, y
	end
end)

overlay:SetScript("OnMouseUp", function()
	if arg1 ~= "LeftButton" then return end
	if mode == "draw" and stroke then
		if getn(stroke) >= 6 then
			AVR:AddMesh("path", { pts = stroke, map = AVR.cam.map })
		end
		stroke = nil
	elseif mode == "measure" and startX then
		local d = Dist(startX, startY, endX, endY)
		if d > 0.1 then
			AVR:Print(string.format("Distance: %.1f yards", d))
			AVR:AddTemp("path", {
				pts = { startX, startY, startZ, endX, endY, startZ },
				map = AVR.cam.map,
				r = 0.4, g = 1, b = 1,
			}, 15)
		end
		startX = nil
		SetHint()
	end
end)

-- Called by the core every frame, with the camera current.
function AVR:DrawTool()
	if not mode then return end
	if mode == "draw" and stroke then
		local n = getn(stroke)
		local x, y, z = self:CursorToWorld(stroke[3])
		if x and n < MAX_POINTS * 3 and Dist(stroke[n - 2], stroke[n - 1], x, y) >= MIN_STEP then
			tinsert(stroke, x)
			tinsert(stroke, y)
			tinsert(stroke, z)
			n = n + 3
		end
		self:SetColor(1, 1, 1, 0.9)
		self:SetLineWidth()
		for i = 1, n - 5, 3 do
			self:Line3D(stroke[i], stroke[i + 1], stroke[i + 2], stroke[i + 3], stroke[i + 4], stroke[i + 5])
		end
	elseif mode == "measure" and startX then
		local x, y = self:CursorToWorld(startZ)
		if x then endX, endY = x, y end
		self:SetColor(0.4, 1, 1, 0.9)
		self:SetLineWidth()
		self:Line3D(startX, startY, startZ, endX, endY, startZ)
		hint:SetText(string.format("%.1f yards", Dist(startX, startY, endX, endY)))
	end
end
