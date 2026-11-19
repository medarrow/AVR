--[[ AVR options window and slash commands. ]]

local AVR = AVR
local getn, tinsert, tremove = table.getn, table.insert, table.remove
local floor = math.floor

local ROWS = 6       -- visible rows in the mesh list
local SLOTS = 12     -- editor field slots
local WIDTH = 400

local gui
local selected       -- index into the current scene's meshes
local listOffset = 0
local loading = false

-- Fields every anchored mesh has, after its own.
local anchorFields = {
	{ key = "unit", label = "Unit / name", kind = "text" },
	{ key = "followRotation", label = "Follow facing", kind = "bool" },
	{ key = "ox", label = "Forward (yd)", kind = "number" },
	{ key = "oy", label = "Right (yd)", kind = "number" },
}
local commonFields = {
	{ key = "color", label = "Colour", kind = "color" },
	{ key = "width", label = "Line width", kind = "number" },
	{ key = "hidden", label = "Hidden", kind = "bool" },
}

local function SelectedMesh()
	if not selected then return nil end
	return AVR:GetScene().meshes[selected]
end

local function FieldsFor(m)
	local def = AVR.types[m.type]
	local list = {}
	if def and def.fields then
		for _, f in ipairs(def.fields) do tinsert(list, f) end
	end
	if def and not def.absolute then
		for _, f in ipairs(anchorFields) do tinsert(list, f) end
	end
	for _, f in ipairs(commonFields) do tinsert(list, f) end
	return list
end

local function Button(parent, text, width, onClick)
	gui.count = (gui.count or 0) + 1
	local b = CreateFrame("Button", "AVRGuiButton" .. gui.count, parent, "UIPanelButtonTemplate")
	b:SetWidth(width)
	b:SetHeight(22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function Check(parent, text, onClick)
	gui.count = (gui.count or 0) + 1
	local name = "AVRGuiCheck" .. gui.count
	local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	c:SetWidth(24)
	c:SetHeight(24)
	getglobal(name .. "Text"):SetText(text or "")
	c:SetScript("OnClick", onClick)
	return c
end

-------------------------------------------------------------------------------
-- Colour picker
-------------------------------------------------------------------------------

local function PickColor(m)
	local r, g, b, a = m.r or 1, m.g or 1, m.b or 1, m.a or 1
	local function Apply()
		m.r, m.g, m.b = ColorPickerFrame:GetColorRGB()
		m.a = 1 - OpacitySliderFrame:GetValue()
		AVR:RefreshGUI()
	end
	ColorPickerFrame.func = Apply
	ColorPickerFrame.opacityFunc = Apply
	ColorPickerFrame.cancelFunc = function()
		m.r, m.g, m.b, m.a = r, g, b, a
		AVR:RefreshGUI()
	end
	ColorPickerFrame.hasOpacity = true
	ColorPickerFrame.opacity = 1 - a
	ColorPickerFrame:SetColorRGB(r, g, b)
	ShowUIPanel(ColorPickerFrame)
end

-------------------------------------------------------------------------------
-- Editor slots
-------------------------------------------------------------------------------

local function ApplyEdit(slot)
	local m, f = SelectedMesh(), slot.field
	if not m or not f then return end
	local text = slot.edit:GetText()
	if f.kind == "number" then
		local n = tonumber(text)
		if f.key == "width" and (not n or n <= 0) then n = nil end
		if n or f.key == "width" then m[f.key] = n end
	elseif f.key == "unit" then
		if text == "" then
			-- no unit: fix it to the ground where it is now
			if m.unit and not AVR:PinMesh(m) then
				AVR:Print("Cannot pin: the mesh has no position right now.")
			end
		else
			m.unit = text
		end
	else
		if text == "" then text = nil end
		m[f.key] = text
	end
	AVR:RefreshGUI()
end

local function CreateSlot(parent, i)
	local slot = {}
	local col = math.mod(i - 1, 2)
	local row = floor((i - 1) / 2)
	local x, y = 16 + col * 190, -280 - row * 26

	slot.label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	slot.label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 5)
	slot.label:SetWidth(90)
	slot.label:SetJustifyH("LEFT")

	slot.edit = CreateFrame("EditBox", "AVRGuiEdit" .. i, parent, "InputBoxTemplate")
	slot.edit:SetWidth(70)
	slot.edit:SetHeight(20)
	slot.edit:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 100, y)
	slot.edit:SetAutoFocus(false)
	slot.edit:SetScript("OnEnterPressed", function()
		ApplyEdit(slot)
		this:ClearFocus()
	end)
	slot.edit:SetScript("OnEscapePressed", function()
		this:ClearFocus()
		AVR:RefreshGUI()
	end)

	slot.check = Check(parent, nil, function()
		local m = SelectedMesh()
		if m and slot.field then
			m[slot.field.key] = this:GetChecked() and true or nil
			AVR:RefreshGUI()
		end
	end)
	slot.check:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 94, y + 2)

	slot.swatch = CreateFrame("Button", nil, parent)
	slot.swatch:SetWidth(40)
	slot.swatch:SetHeight(16)
	slot.swatch:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 96, y - 2)
	slot.swatch.tex = slot.swatch:CreateTexture(nil, "ARTWORK")
	slot.swatch.tex:SetAllPoints(slot.swatch)
	slot.swatch.tex:SetTexture(1, 1, 1)
	slot.swatch:SetScript("OnClick", function()
		local m = SelectedMesh()
		if m then PickColor(m) end
	end)
	return slot
end

local function ShowSlot(slot, m, f)
	slot.field = f
	slot.edit:Hide()
	slot.check:Hide()
	slot.swatch:Hide()
	if not f then
		slot.label:SetText("")
		return
	end
	slot.label:SetText(f.label)
	if f.kind == "bool" then
		slot.check:SetChecked(m[f.key] and 1 or nil)
		slot.check:Show()
	elseif f.kind == "color" then
		slot.swatch.tex:SetVertexColor(m.r or 1, m.g or 1, m.b or 1, m.a or 1)
		slot.swatch:Show()
	else
		local v = m[f.key]
		if type(v) == "number" then
			if v == floor(v) then v = string.format("%d", v) else v = string.format("%.2f", v) end
		end
		slot.edit:SetText(v or "")
		slot.edit:Show()
	end
end

-------------------------------------------------------------------------------
-- Add menu
-------------------------------------------------------------------------------

-- Places a new mesh on a unit, or pins it where the player stands ("here").
local function Place(typeName, over, unit)
	if unit == "here" then
		over.unit = "player"
		local m = AVR:AddMesh(typeName, over)
		if m and not AVR:PinMesh(m) then AVR:Print("No position available to pin to.") end
		AVR:Changed()
		return m
	end
	if unit and unit ~= "" then over.unit = unit end
	return AVR:AddMesh(typeName, over)
end

local addMenu
local function AddMenu_Initialize()
	for _, name in ipairs(AVR.typeOrder) do
		if name ~= "path" then
			local info = {}
			info.text = AVR.types[name].label
			info.value = name
			info.notCheckable = 1
			info.func = function()
				-- types without a default unit start pinned at your feet
				local def = AVR.types[this.value]
				Place(this.value, {}, not (def.defaults and def.defaults.unit) and "here" or nil)
				selected = getn(AVR:GetScene().meshes)
				AVR:RefreshGUI()
			end
			UIDropDownMenu_AddButton(info)
		end
	end
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

StaticPopupDialogs["AVR_NEW_SCENE"] = {
	text = "Name of the new scene:",
	button1 = TEXT(ACCEPT),
	button2 = TEXT(CANCEL),
	hasEditBox = 1,
	maxLetters = 30,
	OnAccept = function()
		local text = getglobal(this:GetParent():GetName() .. "EditBox"):GetText()
		if text and text ~= "" then
			AVR:NewScene(text)
			selected = nil
		end
	end,
	EditBoxOnEnterPressed = function()
		local text = this:GetText()
		if text and text ~= "" then
			AVR:NewScene(text)
			selected = nil
		end
		this:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function() this:GetParent():Hide() end,
	OnShow = function() getglobal(this:GetName() .. "EditBox"):SetFocus() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local function Slider(parent, name, label, lo, hi, step, onChange)
	local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
	s:SetWidth(110)
	s:SetMinMaxValues(lo, hi)
	s:SetValueStep(step)
	getglobal(name .. "Low"):SetText("")
	getglobal(name .. "High"):SetText("")
	s.title = label
	s:SetScript("OnValueChanged", function()
		local v = this:GetValue()
		getglobal(this:GetName() .. "Text"):SetText(this.title .. ": " .. string.format("%.1f", v))
		if not loading then onChange(v) end
	end)
	return s
end

local function CreateGUI()
	gui = CreateFrame("Frame", "AVRGui", UIParent)
	gui:SetWidth(WIDTH)
	gui:SetHeight(520)
	gui:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	gui:SetFrameStrata("DIALOG")
	gui:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	gui:EnableMouse(true)
	gui:SetMovable(true)
	gui:RegisterForDrag("LeftButton")
	gui:SetScript("OnDragStart", function() this:StartMoving() end)
	gui:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	gui:Hide()
	tinsert(UISpecialFrames, "AVRGui")

	local title = gui:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", gui, "TOP", 0, -18)
	title:SetText("AVR " .. AVR.version)

	local close = CreateFrame("Button", nil, gui, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", gui, "TOPRIGHT", -6, -6)

	gui.enable = Check(gui, "Draw on the world", function()
		AVR.settings.enabled = this:GetChecked() and true or false
	end)
	gui.enable:SetPoint("TOPLEFT", gui, "TOPLEFT", 16, -40)

	gui.status = gui:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	gui.status:SetPoint("TOPRIGHT", gui, "TOPRIGHT", -20, -46)

	-- scene row
	local prev = Button(gui, "<", 24, function()
		local n = getn(AVR.db.scenes)
		AVR.db.current = AVR.db.current - 1
		if AVR.db.current < 1 then AVR.db.current = n end
		selected, listOffset = nil, 0
		AVR:RefreshGUI()
	end)
	prev:SetPoint("TOPLEFT", gui, "TOPLEFT", 16, -70)
	gui.sceneName = gui:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	gui.sceneName:SetPoint("LEFT", prev, "RIGHT", 4, 0)
	gui.sceneName:SetWidth(150)
	local nextb = Button(gui, ">", 24, function()
		local n = getn(AVR.db.scenes)
		AVR.db.current = AVR.db.current + 1
		if AVR.db.current > n then AVR.db.current = 1 end
		selected, listOffset = nil, 0
		AVR:RefreshGUI()
	end)
	nextb:SetPoint("LEFT", gui.sceneName, "RIGHT", 4, 0)
	local newb = Button(gui, "New", 50, function() StaticPopup_Show("AVR_NEW_SCENE") end)
	newb:SetPoint("LEFT", nextb, "RIGHT", 6, 0)
	local delb = Button(gui, "Delete", 60, function()
		AVR:DeleteScene()
		selected, listOffset = nil, 0
		AVR:RefreshGUI()
	end)
	delb:SetPoint("LEFT", newb, "RIGHT", 4, 0)

	gui.visible = Check(gui, "Scene visible", function()
		AVR:GetScene().visible = this:GetChecked() and true or false
	end)
	gui.visible:SetPoint("TOPLEFT", gui, "TOPLEFT", 16, -94)
	local share = Button(gui, "Share with group", 130, function() AVR:ShareScene() end)
	share:SetPoint("TOPRIGHT", gui, "TOPRIGHT", -20, -95)

	-- mesh list
	local list = CreateFrame("Frame", nil, gui)
	list:SetPoint("TOPLEFT", gui, "TOPLEFT", 16, -122)
	list:SetWidth(WIDTH - 32)
	list:SetHeight(ROWS * 18 + 8)
	list:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	list:SetBackdropColor(0, 0, 0, 0.6)
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function()
		listOffset = listOffset - arg1
		AVR:RefreshGUI()
	end)
	gui.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, list)
		row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (i - 1) * 18)
		row:SetWidth(WIDTH - 40)
		row:SetHeight(18)
		row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.hl = row:CreateTexture(nil, "BACKGROUND")
		row.hl:SetAllPoints(row)
		row.hl:SetTexture(1, 0.82, 0, 0.25)
		row:SetScript("OnClick", function()
			selected = this.index
			AVR:RefreshGUI()
		end)
		gui.rows[i] = row
	end

	-- actions
	addMenu = CreateFrame("Frame", "AVRGuiAddMenu", gui, "UIDropDownMenuTemplate")
	local add = Button(gui, "Add...", 60, function()
		UIDropDownMenu_Initialize(addMenu, AddMenu_Initialize, "MENU")
		ToggleDropDownMenu(1, nil, addMenu, this:GetName(), 0, 0)
	end)
	add:SetPoint("TOPLEFT", gui, "TOPLEFT", 16, -244)
	local remove = Button(gui, "Remove", 66, function()
		if selected then
			tremove(AVR:GetScene().meshes, selected)
			selected = nil
			AVR:RefreshGUI()
		end
	end)
	remove:SetPoint("LEFT", add, "RIGHT", 4, 0)
	local pin = Button(gui, "Pin here", 70, function()
		local m = SelectedMesh()
		if m and m.unit then
			if not AVR:PinMesh(m) then AVR:Print("Cannot pin: the mesh has no position right now.") end
			AVR:RefreshGUI()
		end
	end)
	pin:SetPoint("LEFT", remove, "RIGHT", 4, 0)
	local draw = Button(gui, "Draw", 56, function() AVR:StartTool("draw") end)
	draw:SetPoint("LEFT", pin, "RIGHT", 4, 0)
	local measure = Button(gui, "Measure", 70, function() AVR:StartTool("measure") end)
	measure:SetPoint("LEFT", draw, "RIGHT", 4, 0)

	-- editor
	gui.slots = {}
	for i = 1, SLOTS do gui.slots[i] = CreateSlot(gui, i) end

	-- calibration
	local cal = gui:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	cal:SetPoint("TOPLEFT", gui, "TOPLEFT", 16, -444)
	cal:SetText("Calibration - adjust until a circle sits flat around your feet")

	gui.height = Slider(gui, "AVRGuiHeight", "Camera height", 0, 5, 0.1, function(v)
		AVR.settings.pivotHeight = v
	end)
	gui.height:SetPoint("TOPLEFT", gui, "TOPLEFT", 20, -474)
	gui.fov = Slider(gui, "AVRGuiFov", "Vertical FoV", 20, 90, 0.5, function(v)
		AVR.settings.fov = v
	end)
	gui.fov:SetPoint("LEFT", gui.height, "RIGHT", 14, 0)
	local auto = Button(gui, "Auto", 50, function()
		AVR.settings.pivotHeight, AVR.settings.fov = nil, nil
		AVR:RefreshGUI()
	end)
	auto:SetPoint("LEFT", gui.fov, "RIGHT", 14, 0)
	local swap = Button(gui, "Flip yaw", 64, function()
		AVR.settings.yawSign = -(AVR.settings.yawSign or 1)
	end)
	swap:SetPoint("LEFT", auto, "RIGHT", 4, 0)
end

function AVR:RefreshGUI()
	if not gui or not gui:IsShown() then return end
	local scene = self:GetScene()
	local meshes = scene.meshes
	local n = getn(meshes)
	if selected and selected > n then selected = nil end

	gui.enable:SetChecked(self.settings.enabled and 1 or nil)
	gui.sceneName:SetText(scene.name .. "  (" .. self.db.current .. "/" .. getn(self.db.scenes) .. ")")
	gui.visible:SetChecked(scene.visible and 1 or nil)
	if self.cam.ok or not self.settings.enabled then
		gui.status:SetText("")
	else
		gui.status:SetText("|cffff4040" .. (self.cam.err or "") .. "|r")
	end

	if listOffset > n - ROWS then listOffset = n - ROWS end
	if listOffset < 0 then listOffset = 0 end
	for i = 1, ROWS do
		local row = gui.rows[i]
		local idx = i + listOffset
		local m = meshes[idx]
		if m then
			local def = self.types[m.type]
			local text = (def and def.label or m.type)
			if def and def.Summary then text = text .. " - " .. def.Summary(m) end
			if m.hidden then text = "|cff808080" .. text .. " (hidden)|r" end
			row.text:SetText(idx .. ". " .. text)
			row.index = idx
			if idx == selected then row.hl:Show() else row.hl:Hide() end
			row:Show()
		else
			row:Hide()
		end
	end

	local m = SelectedMesh()
	local fields = m and FieldsFor(m) or {}
	for i = 1, SLOTS do ShowSlot(gui.slots[i], m, fields[i]) end

	loading = true
	gui.height:SetValue((self:PivotHeight()))
	local w, h = self.cam.w or 4, self.cam.h or 3
	gui.fov:SetValue(self:VerticalFov(w / h) * 180 / math.pi)
	loading = false
end

function AVR:ToggleGUI()
	if not gui then CreateGUI() end
	if gui:IsShown() then
		gui:Hide()
	else
		gui:Show()
		self:RefreshGUI()
	end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local help = {
	"/avr - open the options window",
	"/avr on | off - enable or disable drawing",
	"/avr circle [radius] [unit|here] - circle (fcircle = filled)",
	"/avr cone [length] [angle] [unit] - cone in front of a unit",
	"/avr mark - marker on the ground where you stand",
	"/avr blink - marker 20 yards ahead of you",
	"/avr range [radius] - range warning circle around you",
	"/avr groupmarks [range] - mark nearby group members",
	"/avr draw | measure - mouse tools (right-click to finish)",
	"/avr scene <name> - switch to a scene, creating it if needed",
	"/avr clear - empty the current scene",
	"/avr share - send the current scene to your group",
	"/avr height <yd|auto>, fov <deg|auto>, yawsign, width <n> - calibration",
	"/avr status - what the camera maths is seeing",
}

SLASH_AVR1 = "/avr"
SlashCmdList["AVR"] = function(msg)
	local _, _, cmd, rest = string.find(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	local args = {}
	for w in string.gfind(rest or "", "%S+") do tinsert(args, w) end
	local s = AVR.settings

	if cmd == "" then
		AVR:ToggleGUI()
	elseif cmd == "on" or cmd == "off" or cmd == "toggle" then
		if cmd == "toggle" then s.enabled = not s.enabled else s.enabled = (cmd == "on") end
		AVR:Print("Drawing " .. (s.enabled and "enabled" or "disabled") .. ".")
		AVR:Changed()
	elseif cmd == "circle" or cmd == "fcircle" then
		Place("circle", { radius = tonumber(args[1]) or 8, filled = (cmd == "fcircle") or nil }, args[2])
	elseif cmd == "cone" then
		Place("cone", { radius = tonumber(args[1]) or 10, angle = tonumber(args[2]) or 90 }, args[3])
	elseif cmd == "mark" then
		Place("marker", {}, "here")
	elseif cmd == "blink" then
		AVR:AddMesh("marker", { unit = "player", followRotation = true, ox = 20 })
	elseif cmd == "range" then
		AVR:AddMesh("range", { radius = tonumber(args[1]) or 10 })
	elseif cmd == "groupmarks" then
		AVR:AddMesh("groupmarks", { range = tonumber(args[1]) or 40 })
	elseif cmd == "draw" or cmd == "measure" then
		if AVR:ActiveTool() == cmd then AVR:StopTool() else AVR:StartTool(cmd) end
	elseif cmd == "scene" then
		if rest == "" then
			AVR:Print("Current scene: " .. AVR:GetScene().name)
		else
			local i = AVR:FindScene(rest)
			if i then
				AVR.db.current = i
				AVR:Changed()
			else
				AVR:NewScene(rest)
			end
			AVR:Print("Scene: " .. AVR:GetScene().name)
		end
	elseif cmd == "clear" then
		AVR:GetScene().meshes = {}
		AVR:ClearTemp()
		selected = nil
		AVR:Changed()
		AVR:Print("Scene '" .. AVR:GetScene().name .. "' cleared.")
	elseif cmd == "share" then
		AVR:ShareScene()
	elseif cmd == "height" then
		s.pivotHeight = tonumber(args[1])
		AVR:Print(string.format("Camera height: %.2f yd%s", AVR:PivotHeight(), s.pivotHeight and "" or " (auto)"))
		AVR:Changed()
	elseif cmd == "fov" then
		s.fov = tonumber(args[1])
		AVR:Print("Vertical FoV: " .. (s.fov and (s.fov .. " deg") or "auto"))
		AVR:Changed()
	elseif cmd == "yawsign" then
		s.yawSign = -(s.yawSign or 1)
		AVR:Print("Camera yaw sign: " .. s.yawSign)
	elseif cmd == "pitchsign" then
		s.pitchSign = -(s.pitchSign or 1)
		AVR:Print("Camera pitch sign: " .. s.pitchSign)
	elseif cmd == "width" then
		s.lineWidth = tonumber(args[1]) or 3
		AVR:Print("Line width: " .. s.lineWidth)
	elseif cmd == "status" then
		local c = AVR.cam
		local capi = C_PlayerInfo and C_PlayerInfo.UnitPosition
		AVR:Print("positions: " .. (UnitPosition and "UnitPosition" or "")
			.. ((UnitPosition and capi) and " + " or "") .. (capi and "ClassicAPI" or "")
			.. ((UnitPosition or capi) and "" or "MISSING")
			.. ", facing: " .. (c.facingSource or "none")
			.. ", view cvars: " .. (AVR.viewSuffix and ("camera*" .. AVR.viewSuffix)
				or (AVR.viewGuess and ("camera*" .. AVR.viewGuess .. " (unconfirmed - move the camera)") or "none")))
		if c.ok then
			AVR:Print(string.format("player %.1f %.1f %.1f facing %.2f | camera dist %.1f pitch %.1f yaw %.1f",
				c.px, c.py, c.pz, c.facing, c.dist, c.pitch, c.yaw))
			local ph, phSource = AVR:PivotHeight()
			AVR:Print(string.format("viewport %.0fx%.0f, vertical FoV %.1f deg, pivot height %.2f yd (%s), map %s",
				c.w, c.h, AVR:VerticalFov(c.w / c.h) * 180 / math.pi, ph, phSource, tostring(c.map)))
		else
			AVR:Print("Not drawing: " .. (s.enabled and (c.err or "unknown") or "disabled"))
		end
	else
		for _, line in ipairs(help) do AVR:Print(line) end
	end
end
