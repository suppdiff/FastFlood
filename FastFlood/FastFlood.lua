-- Fast Flood v0.2.0
-- Original WoW 3.3.5a (12340) / Lua 5.1 / Interface 30300.
-- Independent implementation inspired by the concept of AutoFlood.

local addon = CreateFrame("Frame")
addon:RegisterEvent("ADDON_LOADED")

local MIN_INTERVAL = 10
local MAX_INTERVAL = 3600
local MAX_BYTES = 255
local MAX_CHANNELS = 2
local SECOND_CHANNEL_DELAY = 2 -- seconds between destinations within a cycle
local running = false
local elapsedSinceSend = 0
local secondaryPending = false
local sentCount = 0
local lastSendTime = nil
local db
local panel
local refreshPanel
local launcher
local refreshLauncherControls
local showPanel

-- Both the main window and launcher are children of UIParent. Store their
-- locations as offsets from UIParent's center, not absolute pixel positions.
local function saveCenterOffsets(frame, xKey, yKey)
    local cx, cy = frame:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if cx and cy and ux and uy then
        db[xKey] = math.floor(cx - ux + 0.5)
        db[yKey] = math.floor(cy - uy + 0.5)
    end
end

local function positionLauncher()
    if not launcher or not db then return end
    launcher:ClearAllPoints()
    if db.launcherDocked and Minimap then
        -- An independent UIParent child, not a child of the settings window.
        -- Docking to the minimap does not depend on the window being open.
        launcher:SetPoint("CENTER", Minimap, "BOTTOMLEFT", 8, 8)
    else
        launcher:SetPoint("CENTER", UIParent, "CENTER", db.launcherX, db.launcherY)
    end
end

local function setLauncherDocked(docked)
    if not db then return end
    if db.launcherDocked and not docked and launcher then
        saveCenterOffsets(launcher, "launcherX", "launcherY")
    end
    db.launcherDocked = docked and true or false
    positionLauncher()
    if refreshLauncherControls then refreshLauncherControls() end
end

local function setLauncherShown(shown)
    if not db then return end
    db.launcherVisible = shown and true or false
    if launcher then
        if db.launcherVisible then launcher:Show() else launcher:Hide() end
    end
    if refreshLauncherControls then refreshLauncherControls() end
end

local function createLauncher()
    launcher = CreateFrame("Button", "FastFloodLauncher", UIParent)
    launcher:SetSize(34, 34)
    launcher:SetFrameStrata("MEDIUM")
    launcher:SetFrameLevel(20)
    launcher:EnableMouse(true)
    launcher:SetMovable(true)
    launcher:SetClampedToScreen(true)
    launcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    launcher:RegisterForDrag("LeftButton")
    launcher:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    launcher:SetBackdropColor(0.06, 0.15, 0.22, 0.95)
    launcher:SetBackdropBorderColor(0.45, 0.78, 0.95, 1)
    local letters = launcher:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    letters:SetPoint("CENTER", launcher, "CENTER", 0, 1)
    letters:SetText("FF")
    launcher:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    launcher:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Fast Flood", 0.35, 0.85, 1)
        GameTooltip:AddLine("Left-click: open/close settings", 1, 1, 1)
        GameTooltip:AddLine("/fastflood - main panel", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("/fastfloodstart - start / stop", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    launcher:SetScript("OnLeave", function() GameTooltip:Hide() end)
    launcher:SetScript("OnMouseDown", function(self) self.wasDragged = false end)
    launcher:SetScript("OnDragStart", function(self)
        self.wasDragged = true
        -- Detach before moving: the button must not drag the minimap itself.
        if db.launcherDocked then setLauncherDocked(false) end
        self:StartMoving()
    end)
    launcher:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveCenterOffsets(self, "launcherX", "launcherY")
        positionLauncher()
    end)
    launcher:SetScript("OnClick", function(self, button)
        if self.wasDragged then return end
        if button == "LeftButton" then
            showPanel()
        elseif button == "RightButton" then
            -- Right-click always opens the editor; it never starts an ad.
            if panel and not panel:IsShown() then showPanel() end
        end
    end)
    positionLauncher()
    setLauncherShown(db.launcherVisible)
end

local CHANNELS = {
    { value = "SAY",          text = "Say" },
    { value = "YELL",         text = "Yell" },
    { value = "GUILD",        text = "Guild" },
    { value = "PARTY",        text = "Party" },
    { value = "RAID",         text = "Raid" },
    { value = "BATTLEGROUND", text = "Battleground" },
    { value = "OFFICER",      text = "Officer" },
    { value = "CHANNEL",      text = "Numbered channel" },
}

local function message(text, isError)
    if DEFAULT_CHAT_FRAME then
        if isError then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff6666Fast Flood:|r " .. text)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff5ad7ffFast Flood:|r " .. text)
        end
    end
end

local function normalizeInterval(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    number = math.floor(number)
    if number < MIN_INTERVAL or number > MAX_INTERVAL then
        return nil
    end
    return number
end

local function normalizeChannelNumber(value)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) or number < 1 or number > 99 then
        return nil
    end
    return number
end

local function channelIsSupported(kind)
    for _, entry in ipairs(CHANNELS) do
        if entry.value == kind then
            return true
        end
    end
    return false
end

local function channelLabel(kind)
    for _, entry in ipairs(CHANNELS) do
        if entry.value == kind then
            return entry.text
        end
    end
    return kind
end

-- v0.1.x stored channel/channelNumber as scalar fields. v0.2.0 stores up
-- to two destinations. Keep the scalar mirror for safe backwards downgrades.
local function syncLegacyChannel()
    if db and db.channels and db.channels[1] then
        db.channel = db.channels[1].kind
        db.channelNumber = db.channels[1].number
    end
end

local function normalizeDestinations()
    local cleaned = {}
    if type(db.channels) == "table" then
        for i = 1, MAX_CHANNELS do
            local source = db.channels[i]
            if type(source) == "table" and channelIsSupported(source.kind) then
                cleaned[#cleaned + 1] = {
                    kind = source.kind,
                    number = normalizeChannelNumber(source.number) or 1,
                }
            end
        end
    end
    if #cleaned == 0 then
        cleaned[1] = {
            kind = channelIsSupported(db.channel) and db.channel or "SAY",
            number = normalizeChannelNumber(db.channelNumber) or 1,
        }
    end
    db.channels = cleaned
    syncLegacyChannel()
end

local function validateSend()
    if not db then return nil, "Settings not loaded yet." end
    local text = db.message or ""
    if text == "" or not string.find(text, "%S") then
        return nil, "Enter a message first."
    end
    if string.len(text) > MAX_BYTES then
        return nil, "Message exceeds 255 bytes. Shorten it before sending."
    end
    if string.find(text, "[\r\n]") then
        return nil, "Only one line of chat text is supported."
    end

    if #db.channels < 1 or #db.channels > MAX_CHANNELS then
        return nil, "Select one or two channels."
    end
    local destinations = {}
    local seen = {}
    for slot, destination in ipairs(db.channels) do
        if not channelIsSupported(destination.kind) then
            return nil, "Channel " .. slot .. " is not supported."
        end
        local kind = destination.kind
        local target
        local key = kind
        if kind == "CHANNEL" then
            local number = normalizeChannelNumber(destination.number)
            if not number then
                return nil, "Channel " .. slot .. ": enter a number from 1 to 99."
            end
            local id, name = GetChannelName(number)
            if not id or id == 0 or not name then
                return nil, "You are not joined to chat channel /" .. number .. "."
            end
            target = id
            key = "CHANNEL:" .. id
        elseif kind == "GUILD" or kind == "OFFICER" then
            if not IsInGuild() then return nil, "You are not in a guild." end
            -- Officer permission remains server-enforced.
        elseif kind == "PARTY" then
            if GetNumPartyMembers() == 0 and GetNumRaidMembers() == 0 then
                return nil, "You are not in a party or raid."
            end
        elseif kind == "RAID" then
            if GetNumRaidMembers() == 0 then return nil, "You are not in a raid." end
        elseif kind == "BATTLEGROUND" then
            local _, instanceType = IsInInstance()
            if instanceType ~= "pvp" then
                return nil, "You are not in a battleground."
            end
        end
        if seen[key] then
            return nil, "Select two different channels to avoid duplicate messages."
        end
        seen[key] = true
        destinations[#destinations + 1] = { kind = kind, target = target }
    end
    return text, destinations
end

local function stop(note)
    if not running then return end
    running = false
    elapsedSinceSend = 0
    secondaryPending = false
    addon:SetScript("OnUpdate", nil) -- no per-frame work while stopped
    if refreshPanel then refreshPanel() end
    if note then message(note) end
end

local function sendSlot(slot)
    -- Check all configured destinations again before *each* transmission;
    -- loss of a channel cannot result in an unchecked additional send.
    local text, destinations = validateSend()
    if not text then return false, destinations end
    local destination = destinations[slot]
    if not destination then return false, "The configured channels have changed." end
    SendChatMessage(text, destination.kind, nil, destination.target)
    sentCount = sentCount + 1 -- client-side attempts, not server receipts
    lastSendTime = date("%H:%M:%S")
    if refreshPanel then refreshPanel() end
    return true
end

local function onUpdate(self, delta)
    elapsedSinceSend = elapsedSinceSend + delta
    if secondaryPending and elapsedSinceSend >= SECOND_CHANNEL_DELAY then
        secondaryPending = false
        local ok, reason = sendSlot(2)
        if not ok then
            stop()
            message(reason .. " Automatic sending stopped.", true)
            return
        end
        -- Avoid a catch-up burst when one frame spans an entire cycle.
        if elapsedSinceSend >= db.interval then
            elapsedSinceSend = 0
        end
        return
    end
    if elapsedSinceSend < db.interval then return end
    elapsedSinceSend = 0 -- never accumulate missed cycles
    local ok, reason = sendSlot(1)
    if not ok then
        stop()
        message(reason .. " Automatic sending stopped.", true)
        return
    end
    secondaryPending = #db.channels == 2
end

local function start()
    if running then return end
    local interval = normalizeInterval(db and db.interval)
    if not interval then
        message("Interval must be between 10 and 3600 seconds.", true)
        return
    end
    local text, destinations = validateSend()
    if not text then
        message(destinations, true)
        return
    end
    running = true
    elapsedSinceSend = 0
    secondaryPending = false
    addon:SetScript("OnUpdate", onUpdate)
    local ok, reason = sendSlot(1) -- first channel immediately
    if not ok then
        stop()
        message(reason, true)
        return
    end
    secondaryPending = #destinations == 2 -- second channel after two seconds
    if refreshPanel then refreshPanel() end
    message("Started (" .. #destinations .. " channel(s), every " .. interval .. " seconds).")
end

local function toggleRunning()
    if running then stop("Stopped.") else start() end
end

local function textLabel(parent, content, x, y, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetText(content)
    label:SetJustifyH("LEFT")
    return label
end

local function makeButton(parent, content, width, x, y, callback)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 27)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetText(content)
    button:SetScript("OnClick", callback)
    return button
end

local function createPanel()
    panel = CreateFrame("Frame", "FastFloodPanel", UIParent)
    panel:SetWidth(500)
    panel:SetHeight(506)
    panel:SetPoint("CENTER", UIParent, "CENTER", db.windowX or 0, db.windowY or 0)
    panel:SetFrameStrata("DIALOG")
    panel:SetToplevel(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 11, bottom = 11 },
    })
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveCenterOffsets(self, "windowX", "windowY")
    end)
    panel:Hide()
    table.insert(UISpecialFrames, "FastFloodPanel")

    textLabel(panel, "Fast Flood", 20, -18, "GameFontNormalLarge")
    textLabel(panel, "Repeating chat announcements   |cffaaaaaaWoW 3.3.5a|r", 20, -45, "GameFontHighlightSmall")
    local closeButton = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -5)

    textLabel(panel, "Chat message", 20, -73)
    local messageBox = CreateFrame("EditBox", "FastFloodMessageBox", panel, "InputBoxTemplate")
    messageBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -95)
    messageBox:SetWidth(448)
    messageBox:SetHeight(26)
    messageBox:SetAutoFocus(false)
    messageBox:SetMaxLetters(MAX_BYTES)
    messageBox:SetMaxBytes(MAX_BYTES)
    messageBox:SetText(db.message)
    messageBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    messageBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    messageBox:SetScript("OnTextChanged", function(self)
        if db then db.message = self:GetText() end
    end)
    textLabel(panel, "Single line; up to 255 bytes, including item links.", 20, -128, "GameFontDisableSmall")

    textLabel(panel, "Destinations (max 2)", 20, -157)
    local rows = {}
    local plusButton
    local minusButton
    local function onDestinationsChanged()
        if running then stop("Destinations changed; press Start to resume.") end
        syncLegacyChannel()
    end
    local function refreshDestinations()
        for slot = 1, MAX_CHANNELS do
            local row = rows[slot]
            local destination = db.channels[slot]
            if destination then
                row.dropdown:Show()
                UIDropDownMenu_SetSelectedValue(row.dropdown, destination.kind)
                UIDropDownMenu_SetText(row.dropdown, channelLabel(destination.kind))
                row.numberBox:SetText(tostring(destination.number))
                if destination.kind == "CHANNEL" then
                    row.numberLabel:Show()
                    row.numberBox:Show()
                else
                    row.numberLabel:Hide()
                    row.numberBox:Hide()
                end
            else
                row.dropdown:Hide()
                row.numberLabel:Hide()
                row.numberBox:Hide()
            end
        end
        if #db.channels == 1 then
            plusButton:Show()
            minusButton:Hide()
        else
            plusButton:Hide()
            minusButton:Show()
        end
    end
    for slot = 1, MAX_CHANNELS do
        local y = -180 - (slot - 1) * 42
        local row = {}
        rows[slot] = row
        row.dropdown = CreateFrame("Frame", "FastFloodChannelDropdown" .. slot, panel, "UIDropDownMenuTemplate")
        row.dropdown:SetPoint("TOPLEFT", panel, "TOPLEFT", 3, y)
        UIDropDownMenu_SetWidth(row.dropdown, 205)
        row.numberLabel = textLabel(panel, "Channel #", 288, y - 2)
        row.numberBox = CreateFrame("EditBox", "FastFloodChannelNumber" .. slot, panel, "InputBoxTemplate")
        row.numberBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 378, y - 2)
        row.numberBox:SetWidth(38)
        row.numberBox:SetHeight(24)
        row.numberBox:SetAutoFocus(false)
        row.numberBox:SetNumeric(true)
        row.numberBox:SetMaxLetters(2)
        row.numberBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        row.numberBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        row.numberBox:SetScript("OnEditFocusLost", function(self)
            local destination = db.channels[slot]
            if not destination then return end
            local number = normalizeChannelNumber(self:GetText())
            if number then
                if destination.number ~= number then
                    destination.number = number
                    onDestinationsChanged()
                end
            else
                self:SetText(tostring(destination.number))
                message("Channel number must be 1 to 99.", true)
            end
        end)
        UIDropDownMenu_Initialize(row.dropdown, function(self, level)
            if level ~= 1 then return end
            for _, entry in ipairs(CHANNELS) do
                local kind = entry.value -- capture value, do not share a reused iterator
                local info = UIDropDownMenu_CreateInfo()
                info.text = entry.text
                info.value = kind
                info.checked = db.channels[slot] and db.channels[slot].kind == kind
                info.func = function()
                    local destination = db.channels[slot]
                    if destination and destination.kind ~= kind then
                        destination.kind = kind
                        onDestinationsChanged()
                        refreshDestinations()
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end
    plusButton = makeButton(panel, "+", 28, 442, -185, function()
        if #db.channels < MAX_CHANNELS then
            db.channels[2] = { kind = "CHANNEL", number = 2 }
            onDestinationsChanged()
            refreshDestinations()
        end
    end)
    minusButton = makeButton(panel, "-", 28, 442, -227, function()
        if #db.channels > 1 then
            db.channels[2] = nil
            onDestinationsChanged()
            refreshDestinations()
        end
    end)
    refreshDestinations()
    textLabel(panel, "One message to each destination; second sends 2 sec later.", 20, -272, "GameFontDisableSmall")

    textLabel(panel, "Repeat every", 20, -301)
    local intervalBox = CreateFrame("EditBox", "FastFloodInterval", panel, "InputBoxTemplate")
    intervalBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 112, -307)
    intervalBox:SetWidth(58)
    intervalBox:SetHeight(24)
    intervalBox:SetAutoFocus(false)
    intervalBox:SetNumeric(true)
    intervalBox:SetMaxLetters(4)
    intervalBox:SetText(tostring(db.interval))
    textLabel(panel, "seconds (10-3600)", 180, -314, "GameFontHighlightSmall")
    intervalBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    intervalBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    intervalBox:SetScript("OnEditFocusLost", function(self)
        local value = normalizeInterval(self:GetText())
        if value then
            if db.interval ~= value then
                db.interval = value
                elapsedSinceSend = 0
            end
        else
            self:SetText(tostring(db.interval))
            message("Interval must be 10 to 3600 seconds.", true)
        end
    end)

    local showLauncherBox = CreateFrame("CheckButton", "FastFloodShowLauncher", panel, "UICheckButtonTemplate")
    showLauncherBox:SetSize(24, 24)
    showLauncherBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -340)
    textLabel(panel, "Show quick button", 47, -346, "GameFontHighlightSmall")
    showLauncherBox:SetScript("OnClick", function(self)
        setLauncherShown(self:GetChecked() and true or false)
    end)
    local dockLauncherBox = CreateFrame("CheckButton", "FastFloodDockLauncher", panel, "UICheckButtonTemplate")
    dockLauncherBox:SetSize(24, 24)
    dockLauncherBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 242, -340)
    textLabel(panel, "Dock to minimap", 271, -346, "GameFontHighlightSmall")
    dockLauncherBox:SetScript("OnClick", function(self)
        setLauncherDocked(self:GetChecked() and true or false)
    end)
    refreshLauncherControls = function()
        showLauncherBox:SetChecked(db.launcherVisible)
        dockLauncherBox:SetChecked(db.launcherDocked)
    end
    refreshLauncherControls()
    textLabel(panel, "/fastflood - open panel   |   /fastfloodstart - start / stop", 20, -379, "GameFontDisableSmall")

    local statusLabel = textLabel(panel, "Status: Stopped", 20, -408, "GameFontHighlight")
    local countLabel = textLabel(panel, "Send attempts: 0", 20, -428, "GameFontHighlightSmall")
    local function commitInputs()
        messageBox:ClearFocus()
        intervalBox:ClearFocus()
        for _, row in ipairs(rows) do row.numberBox:ClearFocus() end
    end
    local startButton = makeButton(panel, "Start", 210, 20, -457, function()
        commitInputs()
        start()
    end)
    local stopButton = makeButton(panel, "Stop", 210, 252, -457, function()
        stop("Stopped.")
    end)
    refreshPanel = function()
        if running then
            statusLabel:SetText("Status: |cff52ef81Running|r   (" .. #db.channels .. " channel" .. (#db.channels == 1 and "" or "s") .. ", " .. db.interval .. " sec)")
            startButton:Disable()
            stopButton:Enable()
        else
            statusLabel:SetText("Status: |cffffbb55Stopped|r")
            startButton:Enable()
            stopButton:Disable()
        end
        local timestamp = lastSendTime and ("   Last attempt: " .. lastSendTime) or ""
        countLabel:SetText("Send attempts: " .. sentCount .. timestamp)
    end
    refreshPanel()

    -- Preserve the optional shift-click insertion helper from v0.1.x.
    if type(ChatEdit_InsertLink) == "function" and type(hooksecurefunc) == "function" then
        hooksecurefunc("ChatEdit_InsertLink", function(link)
            if messageBox:HasFocus() and type(link) == "string" then
                messageBox:Insert(link)
            end
        end)
    end
end

showPanel = function()
    if not panel then return end
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        panel:Raise()
    end
end

local function initSettings()
    if type(FastFloodDB) ~= "table" then FastFloodDB = {} end
    db = FastFloodDB
    if type(db.message) ~= "string" then db.message = "" end
    if not channelIsSupported(db.channel) then db.channel = "SAY" end
    db.interval = normalizeInterval(db.interval) or 30
    db.channelNumber = normalizeChannelNumber(db.channelNumber) or 1
    normalizeDestinations() -- migration from v0.1.x and malformed-data recovery
    if type(db.windowX) ~= "number" or db.windowX ~= db.windowX or math.abs(db.windowX) > 5000 then db.windowX = 0 end
    if type(db.windowY) ~= "number" or db.windowY ~= db.windowY or math.abs(db.windowY) > 5000 then db.windowY = 0 end
    if type(db.launcherVisible) ~= "boolean" then db.launcherVisible = true end
    if type(db.launcherDocked) ~= "boolean" then db.launcherDocked = true end
    if type(db.launcherX) ~= "number" or db.launcherX ~= db.launcherX or math.abs(db.launcherX) > 5000 then db.launcherX = 0 end
    if type(db.launcherY) ~= "number" or db.launcherY ~= db.launcherY or math.abs(db.launcherY) > 5000 then db.launcherY = 0 end
    -- Running state intentionally never persists across /reload or login.
    createLauncher()
    createPanel()
end

addon:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon == "FastFlood" then
        self:UnregisterEvent("ADDON_LOADED")
        initSettings()
    end
end)

-- Canonical commands. Keep /ff and the old subcommands as compatibility aliases.
SLASH_FASTFLOOD1 = "/fastflood"
SLASH_FASTFLOOD2 = "/ff"
SlashCmdList.FASTFLOOD = function(input)
    if not db then return end
    input = string.lower((input or ""):match("^%s*(.-)%s*$"))
    if input == "on" or input == "start" then
        start()
    elseif input == "off" or input == "stop" then
        stop("Stopped.")
    elseif input == "button" then
        setLauncherShown(not db.launcherVisible)
        message("Quick button " .. (db.launcherVisible and "shown." or "hidden."))
    elseif input == "button on" then
        setLauncherShown(true)
    elseif input == "button off" then
        setLauncherShown(false)
    elseif input == "dock" then
        setLauncherDocked(true)
    elseif input == "float" then
        setLauncherDocked(false)
    elseif input == "help" then
        message("/fastflood - panel; /fastfloodstart - toggle. /ff is an alias.")
    else
        showPanel()
    end
end

SLASH_FASTFLOODSTART1 = "/fastfloodstart"
SlashCmdList.FASTFLOODSTART = function()
    if not db then return end
    toggleRunning()
end
