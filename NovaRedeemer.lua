local cloneref = cloneref or function(object) return object end
local Players           = cloneref(game:GetService("Players"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local RunService        = cloneref(game:GetService("RunService"))
local UserInputService  = cloneref(game:GetService("UserInputService"))
local HttpService       = cloneref(game:GetService("HttpService"))
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

if getgenv and getgenv().StopAura then pcall(getgenv().StopAura) end

-- CONFIGURATION SYSTEM --
local CONFIG_FILE = "ace_code_sniper_auto_redeem_test_config.json"
local savedConfig = {
    codeSniper = true,
    autoSubmit = true,
    submitAfter = 3,
    retypeInvalid = false,
}
pcall(function()
    if type(isfile) == "function" and type(readfile) == "function"
    and isfile(CONFIG_FILE) then
        local decoded = HttpService:JSONDecode(readfile(CONFIG_FILE))
        if type(decoded) == "table" then
            if type(decoded.codeSniper) == "boolean" then savedConfig.codeSniper = decoded.codeSniper end
            if type(decoded.autoSubmit) == "boolean" then savedConfig.autoSubmit = decoded.autoSubmit end
            if type(decoded.submitAfter) == "number" then savedConfig.submitAfter = math.max(1, math.floor(decoded.submitAfter)) end
            if type(decoded.retypeInvalid) == "boolean" then savedConfig.retypeInvalid = decoded.retypeInvalid end
        end
    end
end)

local function saveConfig()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode({
            codeSniper = savedConfig.codeSniper,
            autoSubmit = savedConfig.autoSubmit,
            submitAfter = savedConfig.submitAfter,
            retypeInvalid = savedConfig.retypeInvalid,
        }))
    end)
end

-- STATE VARIABLES --
local _enabled              = savedConfig.codeSniper
local _seen                 = {}
local _focused              = nil
local _lastBox              = nil
local _autoAccept           = savedConfig.autoSubmit
local _submitAfter          = savedConfig.submitAfter
local _capturedParts        = {}
local _lastWatchedBox       = nil
local _boxTextConn          = nil
local _boxAncestryConn      = nil
local _boxVisibilityConns   = {}
local _retypeInvalid        = savedConfig.retypeInvalid
local _lastNonBlankBoxText  = ""
local _pendingRejectedText  = nil
local _pendingRejectedBox   = nil
local _pendingRejectedUntil = 0
local _pendingRejectedToken = 0
local ACE_CASE_MODE         = "EXACT"
local ACE_WORD_COUNT        = 1

local getupvalues = (debug and debug.getupvalues) or getupvalues
local getconns    = getconnections or (debug and debug.getconnections)
local setupv      = (debug and debug.setupvalue) or setupvalue

local setStatus, flashCode, appendToBox
local rememberPendingSubmission, clearPendingSubmission, handleRedemptionFeedback
local clearAceCapture
local aceListenConnection = nil
local _lastStatusMsg = nil

-- UTILITY & REDEEM LOGIC --
local function isOurGui(instance)
    local p = instance
    for _ = 1, 10 do
        if not p then break end
        if p.Name == "ACECodeSniperUI" or p.Name == "SourcesHubRedeemerGui" or p.Name == "NovaRedeemerUI" then return true end
        p = p.Parent
    end
    return false
end

local function isVisibleChain(inst)
    local current = inst
    while current do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("ScreenGui") then return current.Enabled end
        current = current.Parent
    end
    return true
end

local function findAllTextBoxes(pg)
    local boxes = {}
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and not isOurGui(gui) then
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextBox") and not isOurGui(d) then
                    boxes[#boxes+1] = d
                end
            end
        end
    end
    return boxes
end

local function findCodeButtons(pg)
    local btns = {}
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and not isOurGui(gui) then
            for _, d in ipairs(gui:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOurGui(d) then
                    local n  = d.Name:lower()
                    local pn = (d.Parent and d.Parent.Name or ""):lower()
                    if (n:find("code") or n:find("redeem") or pn:find("code") or pn:find("redeem"))
                        and isVisibleChain(d) then
                        btns[#btns+1] = d
                    end
                end
            end
        end
    end
    return btns
end

local function clickButton(btn)
    if not btn then return false end
    local methods = {}
    
    methods[#methods+1] = function() btn.MouseButton1Click:Fire() end
    methods[#methods+1] = function() btn.Activated:Fire() end
    
    if typeof(firesignal) == "function" then
        methods[#methods+1] = function() firesignal(btn.MouseButton1Click) end
        methods[#methods+1] = function() firesignal(btn.Activated) end
    end
    
    if typeof(getconns) == "function" then
        methods[#methods+1] = function()
            local ok, cs = pcall(getconns, btn.MouseButton1Click)
            if ok and type(cs) == "table" then
                for _, c in ipairs(cs) do pcall(function() c:Fire() end) end
            end
            local ok2, cs2 = pcall(getconns, btn.Activated)
            if ok2 and type(cs2) == "table" then
                for _, c in ipairs(cs2) do pcall(function() c:Fire() end) end
            end
        end
    end
    
    if typeof(fireclick) == "function" then
        methods[#methods+1] = function() fireclick(btn) end
    end
    
    local anyOk = false
    for _, fn in ipairs(methods) do
        local ok = pcall(fn)
        anyOk = anyOk or ok
    end
    return anyOk
end

local function fireBoxFocusLost(box)
    if not box then return false end
    local anyFired = false
    
    if typeof(firesignal) == "function" then
        local ok = pcall(firesignal, box.FocusLost, true)
        anyFired = anyFired or ok
    end
    
    if typeof(getconns) == "function" then
        local ok, cs = pcall(getconns, box.FocusLost)
        if ok and type(cs) == "table" then
            for _, c in ipairs(cs) do
                local fn
                pcall(function() fn = c.Function end)
                if fn and typeof(getupvalues) == "function" and typeof(setupv) == "function" then
                    local uOk, ups = pcall(getupvalues, fn)
                    if uOk and type(ups) == "table" then
                        for i, v in pairs(ups) do
                            if type(v) == "boolean" and v == true then
                                pcall(setupv, fn, i, false)
                            end
                        end
                    end
                end
                local fOk = pcall(function()
                    if c.Enabled ~= false then c:Fire(true) end
                end)
                anyFired = anyFired or fOk
            end
        end
    end
    
    return anyFired
end

local function typeAndSubmitCode(code)
    local pg = playerGui or player:FindFirstChildOfClass("PlayerGui")
    if not pg then return false, "no PlayerGui" end

    -- Strategy 1: Known UI path
    local codesGui = pg:FindFirstChild("Codes")
    if codesGui then
        if codesGui:IsA("ScreenGui") then codesGui.Enabled = true end
        local codesFrame = codesGui:FindFirstChild("Codes") or codesGui
        if codesFrame then
            if codesFrame:IsA("GuiObject") then codesFrame.Visible = true end
            local cur = codesFrame
            while cur and cur ~= codesGui do
                if cur:IsA("GuiObject") then cur.Visible = true end
                cur = cur.Parent
            end

            local box = nil
            for _, d in ipairs(codesFrame:GetDescendants()) do
                if d:IsA("TextBox") and not isOurGui(d) then
                    box = d
                    break
                end
            end

            local submitBtn = nil
            for _, d in ipairs(codesFrame:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOurGui(d) then
                    local n = d.Name:lower()
                    local txt = ""
                    pcall(function() txt = d.Text:lower() end)
                    if n:find("submit") or txt:find("submit") or n:find("redeem") or txt:find("redeem") or n:find("claim") or txt:find("confirm") or n:find("enter") then
                        submitBtn = d
                        break
                    end
                end
            end
            if not submitBtn then
                for _, d in ipairs(codesFrame:GetDescendants()) do
                    if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOurGui(d) then
                        local n = d.Name:lower()
                        if not n:find("close") and not n:find("x") and not n:find("toggle") then
                            submitBtn = d
                            break
                        end
                    end
                end
            end

            if box then
                pcall(function() box.Text = code end)
                task.wait(0.05)
                if submitBtn then clickButton(submitBtn) end
                fireBoxFocusLost(box)
                return true, "submitted via PlayerGui.Codes"
            end
        end
    end

    -- Strategy 2: Dynamic Search
    local btns = findCodeButtons(pg)
    for _, btn in ipairs(btns) do
        clickButton(btn)
        task.wait(0.05)
    end

    task.wait(0.2)

    local box = nil
    local deadline = tick() + 2
    while tick() < deadline do
        local allBoxes = findAllTextBoxes(pg)
        for _, d in ipairs(allBoxes) do
            if isVisibleChain(d) then
                local n  = d.Name:lower()
                local pn = (d.Parent and d.Parent.Name or ""):lower()
                if n:find("code") or pn:find("code") or n:find("redeem") or pn:find("redeem") or n:find("input") or pn:find("textbox") or n:find("enter") then
                    box = d
                    break
                end
            end
        end
        if not box then
            for _, d in ipairs(allBoxes) do
                if isVisibleChain(d) then box = d; break end
            end
        end
        if box then break end
        task.wait(0.1)
    end

    if not box then return false, "no codebox visible" end

    pcall(function() box.Text = code end)
    task.wait(0.05)

    local redeemBtn = nil
    local searchNames = {"submit","redeem","claim","confirm","enter","send","apply","ok","use","go","check"}
    local p = box.Parent
    for _ = 1, 8 do
        if not p then break end
        for _, d in ipairs(p:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOurGui(d) and d ~= box then
                local n = d.Name:lower()
                local txt = ""
                pcall(function() txt = d.Text:lower() end)
                for _, sn in ipairs(searchNames) do
                    if n:find(sn) or txt:find(sn) then
                        if isVisibleChain(d) then
                            redeemBtn = d
                            break
                        end
                    end
                end
                if redeemBtn then break end
            end
        end
        if redeemBtn then break end
        p = p.Parent
    end

    if redeemBtn then clickButton(redeemBtn) end
    fireBoxFocusLost(box)

    return true, "submitted via dynamic search"
end

local function aceCodeBox()
    local pg = playerGui
    local allBoxes = findAllTextBoxes(pg)
    for _, box in ipairs(allBoxes) do
        if isVisibleChain(box) then return box end
    end
    return nil
end

-- NOVA UI / PERFORMANCE LAYER --
local COLORS = {
    Window = Color3.fromRGB(9, 10, 14),
    Surface = Color3.fromRGB(15, 17, 23),
    Surface2 = Color3.fromRGB(20, 23, 31),
    Control = Color3.fromRGB(27, 31, 41),
    Border = Color3.fromRGB(48, 54, 70),
    White = Color3.fromRGB(245, 247, 250),
    Text = Color3.fromRGB(179, 186, 201),
    Dim = Color3.fromRGB(102, 110, 128),
    Accent = Color3.fromRGB(132, 94, 255),
    Accent2 = Color3.fromRGB(84, 204, 255),
    Green = Color3.fromRGB(71, 224, 138),
    Red = Color3.fromRGB(246, 91, 108),
    Amber = Color3.fromRGB(247, 183, 89),
}

local function addCorner(parent, radius)
    local value = Instance.new("UICorner")
    value.CornerRadius = UDim.new(0, radius)
    value.Parent = parent
    return value
end

local function addStroke(parent, color, thickness, transparency)
    local value = Instance.new("UIStroke")
    value.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    value.Color = color
    value.Thickness = thickness or 1
    value.Transparency = transparency or 0
    value.Parent = parent
    return value
end

local function makeLabel(parent, name, text, size, position, textSize, color, font)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.Size = size
    label.Position = position
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextSize = textSize
    label.TextColor3 = color
    label.Font = font or Enum.Font.GothamMedium
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Parent = parent
    return label
end

local function makeButton(parent, name, text, size, position, textSize)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = COLORS.Control
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Text = text
    button.TextSize = textSize or 10
    button.TextColor3 = COLORS.Text
    button.Font = Enum.Font.GothamBold
    button.Parent = parent
    addCorner(button, 10)
    addStroke(button, COLORS.Border, 1, 0.15)
    return button
end

-- CLEANUP OLD GUIS
pcall(function()
    for _, name in ipairs({"ACECodeSniperUI", "AutoTypeCodesUI", "ACEPaste", "NovaRedeemerUI"}) do
        local previous = game.CoreGui:FindFirstChild(name)
        if previous then previous:Destroy() end
    end
end)
for _, name in ipairs({"ACECodeSniperUI", "AutoTypeCodesUI", "ACEPaste", "NovaRedeemerUI"}) do
    local previous = playerGui:FindFirstChild(name)
    if previous then previous:Destroy() end
end

-- MAIN GUI
local GUI = Instance.new("ScreenGui")
GUI.Name = "NovaRedeemerUI"
GUI.ResetOnSpawn = false
GUI.IgnoreGuiInset = true
GUI.DisplayOrder = 999
if not pcall(function() GUI.Parent = game.CoreGui end) then GUI.Parent = playerGui end

local Window = Instance.new("Frame")
Window.Name = "Window"
Window.Size = UDim2.fromOffset(372, 430)
Window.AnchorPoint = Vector2.new(1, 0)
Window.Position = UDim2.new(1, -16, 0, 16)
Window.BackgroundColor3 = COLORS.Window
Window.BorderSizePixel = 0
Window.ClipsDescendants = true
Window.Parent = GUI
addCorner(Window, 20)
addStroke(Window, COLORS.Border, 1, 0.05)

local InterfaceScale = Instance.new("UIScale")
InterfaceScale.Name = "InterfaceScale"
InterfaceScale.Scale = 1
InterfaceScale.Parent = Window

-- Window controls: minimize/restore and close
local windowCollapsed = false
local normalWindowSize = UDim2.fromOffset(372, 430)
local collapsedWindowSize = UDim2.fromOffset(372, 78)

-- 1x -> 0.9x -> ... -> 0.5x
local scaleSteps = {1, 0.9, 0.8, 0.7, 0.6, 0.5}
local scaleIndex = 1
local selectedScale = scaleSteps[scaleIndex]
local viewportConnection

local function updateInterfaceScale()
    local camera = workspace.CurrentCamera
    if not camera then
        InterfaceScale.Scale = selectedScale
        return
    end

    local viewport = camera.ViewportSize
    local fitScale = math.min((viewport.X - 28) / 372, (viewport.Y - 28) / 430)
    if UserInputService.TouchEnabled then
        InterfaceScale.Scale = math.max(0.5, math.min(selectedScale, fitScale))
    else
        InterfaceScale.Scale = selectedScale
    end
end

local function watchViewport()
    if viewportConnection then viewportConnection:Disconnect(); viewportConnection = nil end
    local camera = workspace.CurrentCamera
    if camera then
        viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateInterfaceScale)
    end
    updateInterfaceScale()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)
watchViewport()

-- Accent line
local AccentStrip = Instance.new("Frame")
AccentStrip.Name = "AccentStrip"
AccentStrip.Size = UDim2.new(1, 0, 0, 3)
AccentStrip.BackgroundColor3 = COLORS.Accent
AccentStrip.BorderSizePixel = 0
AccentStrip.Parent = Window

-- HEADER / BRAND
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 72)
Header.BackgroundTransparency = 1
Header.Active = true
Header.ZIndex = 5
Header.Parent = Window

local Brand = Instance.new("Frame")
Brand.Size = UDim2.fromOffset(42, 42)
Brand.Position = UDim2.fromOffset(16, 15)
Brand.BackgroundColor3 = COLORS.Surface2
Brand.BorderSizePixel = 0
Brand.Parent = Header
addCorner(Brand, 13)
addStroke(Brand, COLORS.Border, 1, 0.2)

local BrandDot = Instance.new("Frame")
BrandDot.Size = UDim2.fromOffset(10, 10)
BrandDot.Position = UDim2.new(0.5, -5, 0.5, -5)
BrandDot.BackgroundColor3 = COLORS.Accent2
BrandDot.BorderSizePixel = 0
BrandDot.Parent = Brand
addCorner(BrandDot, 5)

makeLabel(Header, "Title", "NOVA REDEEMER", UDim2.fromOffset(214, 22), UDim2.fromOffset(69, 13), 16, COLORS.White, Enum.Font.GothamBlack)
makeLabel(Header, "Subtitle", "lightweight code control", UDim2.fromOffset(170, 18), UDim2.fromOffset(69, 36), 10, COLORS.Dim, Enum.Font.GothamMedium)

local MinimizeButton = makeButton(Header, "Minimize", "−", UDim2.fromOffset(30, 28), UDim2.new(1, -112, 0, 21), 18)
MinimizeButton.ZIndex = 8
local CloseButton = makeButton(Header, "Close", "×", UDim2.fromOffset(30, 28), UDim2.new(1, -76, 0, 21), 18)
CloseButton.ZIndex = 8
CloseButton.TextColor3 = COLORS.Red

-- MAIN ENABLE SWITCH
local AutoWriteButton = Instance.new("TextButton")
AutoWriteButton.Name = "AutoWrite"
AutoWriteButton.Size = UDim2.fromOffset(54, 28)
AutoWriteButton.Position = UDim2.new(1, -148, 0, 21)
AutoWriteButton.BackgroundColor3 = COLORS.Control
AutoWriteButton.BorderSizePixel = 0
AutoWriteButton.AutoButtonColor = false
AutoWriteButton.Text = ""
AutoWriteButton.ZIndex = 7
AutoWriteButton.Parent = Header
addCorner(AutoWriteButton, 14)
local AutoWriteStroke = addStroke(AutoWriteButton, COLORS.Border, 1, 0.05)

local AutoWriteKnob = Instance.new("Frame")
AutoWriteKnob.Name = "Knob"
AutoWriteKnob.Size = UDim2.fromOffset(22, 22)
AutoWriteKnob.Position = UDim2.new(0, 3, 0.5, -11)
AutoWriteKnob.BackgroundColor3 = COLORS.White
AutoWriteKnob.BorderSizePixel = 0
AutoWriteKnob.ZIndex = 8
AutoWriteKnob.Parent = AutoWriteButton
addCorner(AutoWriteKnob, 11)

local Console, ConsoleOutput, updateConsoleCanvas
local featureStates = {}
local CONSOLE_COLORS = {
    Dim = "rgb(102,110,128)",
    Amber = "rgb(247,183,89)",
    Green = "rgb(71,224,138)",
    Red = "rgb(246,91,108)",
    Cyan = "rgb(84,204,255)",
}

local function scrollConsoleToBottom()
    task.defer(function()
        if not Console then return end
        if updateConsoleCanvas then updateConsoleCanvas() end
        local bottom = math.max(0, Console.AbsoluteCanvasSize.Y - Console.AbsoluteWindowSize.Y)
        Console.CanvasPosition = Vector2.new(0, bottom)
    end)
end

local function appendConsoleStatus(name, activated)
    if not ConsoleOutput then return end
    local state = activated and "ON" or "OFF"
    local stateColor = activated and CONSOLE_COLORS.Green or CONSOLE_COLORS.Red
    local line = '<font color="' .. CONSOLE_COLORS.Dim .. '">[setting]</font> '
        .. '<font color="' .. CONSOLE_COLORS.Amber .. '">' .. name .. "</font> "
        .. '<font color="' .. CONSOLE_COLORS.Dim .. '">-&gt;</font> '
        .. '<font color="' .. stateColor .. '">' .. state .. "</font>"
    if ConsoleOutput.Text == "" then
        ConsoleOutput.Text = line
    else
        ConsoleOutput.Text = ConsoleOutput.Text .. "\n\n" .. line
    end
    scrollConsoleToBottom()
end

local autoWriteEnabled = _enabled
local function refreshMainToggle()
    AutoWriteButton.BackgroundColor3 = autoWriteEnabled and COLORS.Accent or COLORS.Control
    AutoWriteStroke.Color = autoWriteEnabled and COLORS.Accent2 or COLORS.Border
    AutoWriteKnob.BackgroundColor3 = autoWriteEnabled and COLORS.Window or COLORS.White
    AutoWriteKnob.Position = autoWriteEnabled
        and UDim2.new(1, -25, 0.5, -11)
        or UDim2.new(0, 3, 0.5, -11)
end
refreshMainToggle()

local lastToggleTime = 0
local function toggleAutoWrite()
    local now = os.clock()
    if now - lastToggleTime < 0.12 then return end
    lastToggleTime = now
    autoWriteEnabled = not autoWriteEnabled
    _enabled = autoWriteEnabled
    if not autoWriteEnabled and clearAceCapture then clearAceCapture() end
    savedConfig.codeSniper = autoWriteEnabled
    saveConfig()
    _lastStatusMsg = nil
    refreshMainToggle()

    if ConsoleOutput then
        if autoWriteEnabled then
            ConsoleOutput.Text = '<font color="' .. CONSOLE_COLORS.Green .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner online</font>'
            for _, featureName in ipairs({"Auto submit", "Retype invalid"}) do
                if featureStates[featureName] then appendConsoleStatus(featureName, true) end
            end
        else
            ConsoleOutput.Text = '<font color="' .. CONSOLE_COLORS.Red .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner paused</font>'
        end
        scrollConsoleToBottom()
    end
end
AutoWriteButton.Activated:Connect(toggleAutoWrite)

local HeaderLine = Instance.new("Frame")
HeaderLine.Size = UDim2.new(1, -32, 0, 1)
HeaderLine.Position = UDim2.fromOffset(16, 64)
HeaderLine.BackgroundColor3 = COLORS.Border
HeaderLine.BackgroundTransparency = 0.15
HeaderLine.BorderSizePixel = 0
HeaderLine.Parent = Header

-- TABS
local Tabs = Instance.new("Frame")
Tabs.Name = "Tabs"
Tabs.Size = UDim2.new(1, -32, 0, 44)
Tabs.Position = UDim2.fromOffset(16, 77)
Tabs.BackgroundColor3 = COLORS.Surface
Tabs.BorderSizePixel = 0
Tabs.Parent = Window
addCorner(Tabs, 12)
addStroke(Tabs, COLORS.Border, 1, 0.2)

local function makeTab(name, text, x)
    local button = makeButton(Tabs, name, text, UDim2.fromOffset(162, 34), UDim2.fromOffset(x, 5), 10)
    button.TextColor3 = COLORS.Dim
    return button
end

local ConsoleTab = makeTab("ConsoleTab", "CONSOLE", 5)
local SnipeTab = makeTab("SnipeTab", "SNIPE", 169)

local ConsolePage = Instance.new("Frame")
ConsolePage.Name = "ConsolePage"
ConsolePage.Size = UDim2.new(1, -32, 1, -138)
ConsolePage.Position = UDim2.fromOffset(16, 129)
ConsolePage.BackgroundTransparency = 1
ConsolePage.Parent = Window

local SnipePage = Instance.new("Frame")
SnipePage.Name = "SnipePage"
SnipePage.Size = UDim2.new(1, -32, 1, -138)
SnipePage.Position = UDim2.fromOffset(16, 129)
SnipePage.BackgroundTransparency = 1
SnipePage.Parent = Window

local function setTabVisual(button, active)
    button.BackgroundColor3 = active and COLORS.Accent or COLORS.Control
    button.TextColor3 = active and COLORS.White or COLORS.Dim
    local stroke = button:FindFirstChildOfClass("UIStroke")
    if stroke then stroke.Color = active and COLORS.Accent2 or COLORS.Border end
end

local function activatePage(page)
    ConsolePage.Visible = page == ConsolePage
    SnipePage.Visible = page == SnipePage
    setTabVisual(ConsoleTab, ConsolePage.Visible)
    setTabVisual(SnipeTab, SnipePage.Visible)
end
ConsoleTab.Activated:Connect(function() activatePage(ConsolePage) end)
SnipeTab.Activated:Connect(function() activatePage(SnipePage) end)

-- CONSOLE PAGE: console only + compact controls
local ConsoleHeader = Instance.new("Frame")
ConsoleHeader.Size = UDim2.new(1, 0, 0, 48)
ConsoleHeader.BackgroundTransparency = 1
ConsoleHeader.Parent = ConsolePage
makeLabel(ConsoleHeader, "Title", "LIVE CONSOLE", UDim2.fromOffset(190, 20), UDim2.fromOffset(2, 2), 12, COLORS.White, Enum.Font.GothamBold)
makeLabel(ConsoleHeader, "Hint", "runtime events & captured codes", UDim2.fromOffset(245, 17), UDim2.fromOffset(2, 22), 9, COLORS.Dim, Enum.Font.GothamMedium)

local LiveChip = makeButton(ConsoleHeader, "LiveChip", "●  LIVE", UDim2.fromOffset(72, 28), UDim2.new(1, -72, 0, 7), 9)
LiveChip.TextColor3 = COLORS.Green
LiveChip.BackgroundColor3 = Color3.fromRGB(17, 39, 28)
local liveStroke = LiveChip:FindFirstChildOfClass("UIStroke")
if liveStroke then liveStroke.Color = COLORS.Green end

Console = Instance.new("ScrollingFrame")
Console.Name = "Console"
Console.Size = UDim2.new(1, 0, 1, -58)
Console.Position = UDim2.fromOffset(0, 50)
Console.BackgroundColor3 = Color3.fromRGB(7, 8, 11)
Console.BorderSizePixel = 0
Console.ClipsDescendants = true
Console.Active = true
Console.ScrollingEnabled = true
Console.ScrollingDirection = Enum.ScrollingDirection.Y
Console.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
Console.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
Console.CanvasSize = UDim2.new(0, 0, 0, 0)
Console.AutomaticCanvasSize = Enum.AutomaticSize.None
Console.ScrollBarThickness = 3
Console.ScrollBarImageColor3 = COLORS.Dim
Console.ZIndex = 3
Console.Parent = ConsolePage
addCorner(Console, 14)
addStroke(Console, COLORS.Border, 1, 0.25)

local ConsoleTopLine = Instance.new("Frame")
ConsoleTopLine.Size = UDim2.new(1, 0, 0, 1)
ConsoleTopLine.BackgroundColor3 = COLORS.Accent
ConsoleTopLine.BorderSizePixel = 0
ConsoleTopLine.Parent = Console

ConsoleOutput = Instance.new("TextLabel")
ConsoleOutput.Name = "ConsoleOutput"
ConsoleOutput.Size = UDim2.new(1, -20, 0, 90)
ConsoleOutput.AutomaticSize = Enum.AutomaticSize.Y
ConsoleOutput.Position = UDim2.fromOffset(10, 10)
ConsoleOutput.BackgroundTransparency = 1
ConsoleOutput.RichText = true
ConsoleOutput.Text = autoWriteEnabled
    and '<font color="' .. CONSOLE_COLORS.Green .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner online</font>'
    or '<font color="' .. CONSOLE_COLORS.Red .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner paused</font>'
ConsoleOutput.TextSize = 12
ConsoleOutput.Font = Enum.Font.Code
ConsoleOutput.TextColor3 = COLORS.Dim
ConsoleOutput.TextXAlignment = Enum.TextXAlignment.Left
ConsoleOutput.TextYAlignment = Enum.TextYAlignment.Top
ConsoleOutput.TextWrapped = true
ConsoleOutput.ZIndex = 4
ConsoleOutput.Parent = Console

local ClearConsole = makeButton(ConsolePage, "ClearConsole", "CLEAR", UDim2.fromOffset(66, 28), UDim2.new(1, -66, 0, 6), 9)
ClearConsole.Visible = false
ClearConsole.Activated:Connect(function()
    if ConsoleOutput then
        ConsoleOutput.Text = autoWriteEnabled
            and '<font color="' .. CONSOLE_COLORS.Green .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner online</font>'
            or '<font color="' .. CONSOLE_COLORS.Red .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner paused</font>'
        scrollConsoleToBottom()
    end
end)

local CONSOLE_BOTTOM_PADDING = 24
updateConsoleCanvas = function()
    if not Console or not ConsoleOutput then return end
    local contentHeight = ConsoleOutput.Position.Y.Offset + ConsoleOutput.AbsoluteSize.Y + CONSOLE_BOTTOM_PADDING
    Console.CanvasSize = UDim2.new(0, 0, 0, contentHeight)
end
ConsoleOutput:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateConsoleCanvas)
task.defer(updateConsoleCanvas)

-- SNIPE PAGE
local SnipeHero = Instance.new("Frame")
SnipeHero.Size = UDim2.new(1, 0, 0, 68)
SnipeHero.BackgroundColor3 = COLORS.Surface
SnipeHero.BorderSizePixel = 0
SnipeHero.Parent = SnipePage
addCorner(SnipeHero, 14)
addStroke(SnipeHero, COLORS.Border, 1, 0.2)

makeLabel(SnipeHero, "Title", "SNIPE ENGINE", UDim2.fromOffset(190, 20), UDim2.fromOffset(14, 10), 12, COLORS.White, Enum.Font.GothamBold)
makeLabel(SnipeHero, "Hint", "capture → assemble → submit", UDim2.fromOffset(210, 18), UDim2.fromOffset(14, 33), 9, COLORS.Dim, Enum.Font.GothamMedium)

local StatePill = makeButton(SnipeHero, "State", autoWriteEnabled and "READY" or "PAUSED", UDim2.fromOffset(76, 28), UDim2.new(1, -90, 0.5, -14), 9)
local stateStroke = StatePill:FindFirstChildOfClass("UIStroke")

local function refreshStatePill()
    StatePill.Text = autoWriteEnabled and "READY" or "PAUSED"
    StatePill.TextColor3 = autoWriteEnabled and COLORS.Green or COLORS.Dim
    StatePill.BackgroundColor3 = autoWriteEnabled and Color3.fromRGB(16, 38, 27) or COLORS.Control
    if stateStroke then stateStroke.Color = autoWriteEnabled and COLORS.Green or COLORS.Border end
end
refreshStatePill()

AutoWriteButton.Activated:Connect(refreshStatePill)

local Settings = Instance.new("Frame")
Settings.Name = "Settings"
Settings.Size = UDim2.new(1, 0, 0, 202)
Settings.Position = UDim2.fromOffset(0, 78)
Settings.BackgroundTransparency = 1
Settings.Parent = SnipePage

local function makeCard(name, position, size)
    local card = Instance.new("Frame")
    card.Name = name
    card.Position = position
    card.Size = size
    card.BackgroundColor3 = COLORS.Surface
    card.BorderSizePixel = 0
    card.Parent = Settings
    addCorner(card, 12)
    addStroke(card, COLORS.Border, 1, 0.25)
    return card
end

local function makeStateButton(parent, enabled, consoleName, onToggle)
    local button = makeButton(parent, "State", enabled and "ON" or "OFF", UDim2.fromOffset(52, 26), UDim2.new(1, -64, 0.5, -13), 9)
    featureStates[consoleName] = enabled
    button.BackgroundColor3 = enabled and COLORS.Accent or COLORS.Control
    button.TextColor3 = enabled and COLORS.White or COLORS.Dim
    local outline = button:FindFirstChildOfClass("UIStroke")
    if outline then outline.Color = enabled and COLORS.Accent2 or COLORS.Border end

    local last = 0
    local function toggleState()
        local now = os.clock()
        if now - last < 0.1 then return end
        last = now
        enabled = not enabled
        featureStates[consoleName] = enabled
        button.Text = enabled and "ON" or "OFF"
        button.BackgroundColor3 = enabled and COLORS.Accent or COLORS.Control
        button.TextColor3 = enabled and COLORS.White or COLORS.Dim
        if outline then outline.Color = enabled and COLORS.Accent2 or COLORS.Border end
        if autoWriteEnabled then appendConsoleStatus(consoleName, enabled) end
        if onToggle then onToggle(enabled) end
    end
    button.Activated:Connect(toggleState)
    return button
end

local AutoCard = makeCard("AutoSubmit", UDim2.fromOffset(0, 0), UDim2.fromOffset(163, 56))
makeLabel(AutoCard, "Title", "Auto submit", UDim2.new(1, -78, 0, 18), UDim2.fromOffset(13, 8), 11, COLORS.White, Enum.Font.GothamMedium)
makeLabel(AutoCard, "Hint", "submit captured code", UDim2.new(1, -78, 0, 16), UDim2.fromOffset(13, 29), 8, COLORS.Dim, Enum.Font.GothamMedium)
makeStateButton(AutoCard, _autoAccept, "Auto submit", function(state)
    _autoAccept = state
    savedConfig.autoSubmit = state
    saveConfig()
end)

local RetypeCard = makeCard("RetypeInvalid", UDim2.fromOffset(171, 0), UDim2.fromOffset(163, 56))
makeLabel(RetypeCard, "Title", "Retype invalid", UDim2.new(1, -78, 0, 18), UDim2.fromOffset(13, 8), 11, COLORS.White, Enum.Font.GothamMedium)
makeLabel(RetypeCard, "Hint", "restore rejected text", UDim2.new(1, -78, 0, 16), UDim2.fromOffset(13, 29), 8, COLORS.Dim, Enum.Font.GothamMedium)
makeStateButton(RetypeCard, _retypeInvalid, "Retype invalid", function(state)
    _retypeInvalid = state
    savedConfig.retypeInvalid = state
    saveConfig()
end)

local DelayCard = makeCard("SubmitAfter", UDim2.fromOffset(0, 66), UDim2.fromOffset(334, 67))
makeLabel(DelayCard, "Title", "Submit after", UDim2.fromOffset(160, 20), UDim2.fromOffset(13, 8), 11, COLORS.White, Enum.Font.GothamMedium)
makeLabel(DelayCard, "Hint", "captured parts", UDim2.fromOffset(160, 18), UDim2.fromOffset(13, 31), 8, COLORS.Dim, Enum.Font.GothamMedium)

local CounterShell = Instance.new("Frame")
CounterShell.Name = "Counter"
CounterShell.Size = UDim2.fromOffset(126, 40)
CounterShell.Position = UDim2.new(1, -139, 0.5, -20)
CounterShell.BackgroundColor3 = COLORS.Control
CounterShell.BorderSizePixel = 0
CounterShell.Parent = DelayCard
addCorner(CounterShell, 10)
addStroke(CounterShell, COLORS.Border, 1, 0.15)

local Minus = makeButton(CounterShell, "Minus", "−", UDim2.fromOffset(32, 32), UDim2.fromOffset(4, 4), 18)
Minus.TextColor3 = COLORS.White
local Count = makeLabel(CounterShell, "Count", tostring(_submitAfter), UDim2.fromOffset(50, 32), UDim2.fromOffset(38, 4), 15, COLORS.White, Enum.Font.GothamBlack)
Count.TextXAlignment = Enum.TextXAlignment.Center
local Plus = makeButton(CounterShell, "Plus", "+", UDim2.fromOffset(32, 32), UDim2.new(1, -36, 0, 4), 16)
Plus.TextColor3 = COLORS.White

local function decr()
    _submitAfter = math.max(1, _submitAfter - 1)
    Count.Text = tostring(_submitAfter)
    savedConfig.submitAfter = _submitAfter
    clearAceCapture()
    saveConfig()
end

local function incr()
    _submitAfter += 1
    Count.Text = tostring(_submitAfter)
    savedConfig.submitAfter = _submitAfter
    clearAceCapture()
    saveConfig()
end
Minus.Activated:Connect(decr)
Plus.Activated:Connect(incr)

local InfoCard = makeCard("Info", UDim2.fromOffset(0, 143), UDim2.fromOffset(334, 59))
makeLabel(InfoCard, "Title", "MODE", UDim2.fromOffset(64, 18), UDim2.fromOffset(13, 8), 8, COLORS.Dim, Enum.Font.GothamBold)
makeLabel(InfoCard, "Mode", "SNIPE / AUTO", UDim2.fromOffset(130, 20), UDim2.fromOffset(13, 25), 11, COLORS.White, Enum.Font.GothamBold)
makeLabel(InfoCard, "ScaleLabel", "UI SCALE", UDim2.fromOffset(70, 18), UDim2.fromOffset(174, 8), 8, COLORS.Dim, Enum.Font.GothamBold)

local ScaleShell = Instance.new("Frame")
ScaleShell.Name = "ScaleShell"
ScaleShell.Size = UDim2.fromOffset(132, 34)
ScaleShell.Position = UDim2.new(1, -145, 0.5, -17)
ScaleShell.BackgroundColor3 = COLORS.Control
ScaleShell.BorderSizePixel = 0
ScaleShell.Parent = InfoCard
addCorner(ScaleShell, 9)

local ScaleMinus = makeButton(ScaleShell, "Minus", "−", UDim2.fromOffset(30, 28), UDim2.fromOffset(3, 3), 16)
local ScaleText = makeLabel(ScaleShell, "Value", "1x", UDim2.fromOffset(60, 28), UDim2.fromOffset(36, 3), 12, COLORS.White, Enum.Font.GothamBlack)
ScaleText.TextXAlignment = Enum.TextXAlignment.Center
local ScalePlus = makeButton(ScaleShell, "Plus", "+", UDim2.fromOffset(30, 28), UDim2.new(1, -33, 0, 3), 14)

local function refreshScaleText()
    local value = scaleSteps[scaleIndex]
    ScaleText.Text = tostring(value):gsub("%.0+$", "") .. "x"
    selectedScale = value
    updateInterfaceScale()

    local atMin = scaleIndex == #scaleSteps
    local atMax = scaleIndex == 1
    ScaleMinus.TextColor3 = atMin and COLORS.Dim or COLORS.White
    ScalePlus.TextColor3 = atMax and COLORS.Dim or COLORS.White
end

ScaleMinus.Activated:Connect(function()
    if scaleIndex < #scaleSteps then
        scaleIndex += 1
        refreshScaleText()
    end
end)

ScalePlus.Activated:Connect(function()
    if scaleIndex > 1 then
        scaleIndex -= 1
        refreshScaleText()
    end
end)
refreshScaleText()

-- FOOTER / MICRO STATUS
local FooterLine = Instance.new("Frame")
FooterLine.Size = UDim2.new(1, -32, 0, 1)
FooterLine.Position = UDim2.new(0, 16, 1, -30)
FooterLine.BackgroundColor3 = COLORS.Border
FooterLine.BackgroundTransparency = 0.35
FooterLine.BorderSizePixel = 0
FooterLine.Parent = Window

local Footer = makeLabel(Window, "Footer", "NOVA • READY", UDim2.fromOffset(190, 18), UDim2.new(0, 16, 1, -27), 8, COLORS.Dim, Enum.Font.GothamBold)
makeLabel(Window, "Version", "v2 UI", UDim2.fromOffset(60, 18), UDim2.new(1, -76, 1, -27), 8, COLORS.Dim, Enum.Font.GothamBold).TextXAlignment = Enum.TextXAlignment.Right

local CollapsibleItems = { Content, Footer }
local function setWindowCollapsed(collapsed)
    windowCollapsed = collapsed
    for _, item in ipairs(CollapsibleItems) do
        if item then item.Visible = not collapsed end
    end
    Window.Size = collapsed and collapsedWindowSize or normalWindowSize
    MinimizeButton.Text = collapsed and "+" or "−"
    updateInterfaceScale()
end
MinimizeButton.Activated:Connect(function()
    setWindowCollapsed(not windowCollapsed)
end)
CloseButton.Activated:Connect(function()
    pcall(function()
        if aceListenConnection then aceListenConnection:Disconnect(); aceListenConnection = nil end
        if viewportConnection then viewportConnection:Disconnect(); viewportConnection = nil end
        if getgenv and getgenv().ACECodeSniperNotifyConnection then
            getgenv().ACECodeSniperNotifyConnection = nil
        end
    end)
    GUI:Destroy()
end)

-- Keep the first screen focused on the sniping controls.
activatePage(SnipePage)

-- WINDOW DRAGGING: one input path, desktop + touch
 do
    local dragging = false
    local activeInput
    local dragStart
    local startPosition
    local DRAG_THRESHOLD = UserInputService.TouchEnabled and 10 or 3

    Header.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local function inside(control)
            return input.Position.X >= control.AbsolutePosition.X - 8
                and input.Position.X <= control.AbsolutePosition.X + control.AbsoluteSize.X + 8
                and input.Position.Y >= control.AbsolutePosition.Y - 8
                and input.Position.Y <= control.AbsolutePosition.Y + control.AbsoluteSize.Y + 8
        end
        if inside(AutoWriteButton) or inside(MinimizeButton) or inside(CloseButton) then
            return
        end

        dragging = true
        activeInput = input
        dragStart = Vector2.new(input.Position.X, input.Position.Y)
        startPosition = Window.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End
                or input.UserInputState == Enum.UserInputState.Cancel then
                dragging = false
                activeInput = nil
            end
        end)
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging or not activeInput then return end
        local trackedMouse = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement
        local trackedTouch = activeInput.UserInputType == Enum.UserInputType.Touch
            and input == activeInput
        if not trackedMouse and not trackedTouch then return end

        local current = Vector2.new(input.Position.X, input.Position.Y)
        local delta = current - dragStart
        if delta.Magnitude < DRAG_THRESHOLD then return end

        Window.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end)
end

local function col3ToRich(col)
    if col == COLORS.Green then return CONSOLE_COLORS.Green end
    if col == COLORS.Red then return CONSOLE_COLORS.Red end
    if col == COLORS.Text then return CONSOLE_COLORS.Amber end
    if col == COLORS.White then return CONSOLE_COLORS.Cyan end
    if col == COLORS.Dim then return CONSOLE_COLORS.Dim end
    return string.format("rgb(%d,%d,%d)", math.floor(col.R * 255 + 0.5), math.floor(col.G * 255 + 0.5), math.floor(col.B * 255 + 0.5))
end

function setStatus(msg, col)
    if not ConsoleOutput or not _enabled then return end
    if msg == _lastStatusMsg then return end
    _lastStatusMsg = msg
    col = col or COLORS.Dim
    local line = '<font color="' .. CONSOLE_COLORS.Cyan .. '">(NOVA)</font> <font color="' .. col3ToRich(col) .. '">' .. tostring(msg) .. "</font>"
    if ConsoleOutput.Text == "" then ConsoleOutput.Text = line
    else ConsoleOutput.Text = ConsoleOutput.Text .. "\n\n" .. line end
    scrollConsoleToBottom()
end

function flashCode(code, col)
    if not code or code == "" or code == "—" then return end
    setStatus(tostring(code), col or COLORS.White)
end

local function resetPasteCounter() _capturedParts = {} end
clearAceCapture = function() _capturedParts = {} end

local function clearBoxWatchers()
    if _boxTextConn then pcall(function() _boxTextConn:Disconnect() end) end
    if _boxAncestryConn then pcall(function() _boxAncestryConn:Disconnect() end) end
    for _, connection in ipairs(_boxVisibilityConns) do pcall(function() connection:Disconnect() end) end
    _boxTextConn = nil
    _boxAncestryConn = nil
    _boxVisibilityConns = {}
    _lastWatchedBox = nil
end

local function watchBoxForBlankReset(box)
    if not box or _lastWatchedBox == box then return end
    clearBoxWatchers()
    _lastWatchedBox = box
    if box.Text ~= "" then _lastNonBlankBoxText = box.Text end
    _boxTextConn = box:GetPropertyChangedSignal("Text"):Connect(function()
        if box.Text == "" then resetPasteCounter()
        else _lastNonBlankBoxText = box.Text end
    end)
    _boxAncestryConn = box.AncestryChanged:Connect(function(_, parent)
        if not parent then resetPasteCounter(); clearBoxWatchers() end
    end)
end
local function col3ToRich(col)
    if col == COLORS.Green then return CONSOLE_COLORS.Green end
    if col == COLORS.Red then return CONSOLE_COLORS.Red end
    if col == COLORS.Text then return CONSOLE_COLORS.Amber end
    if col == COLORS.White then return CONSOLE_COLORS.Cyan end
    if col == COLORS.Dim then return CONSOLE_COLORS.Dim end
    return string.format("rgb(%d,%d,%d)", math.floor(col.R * 255 + 0.5), math.floor(col.G * 255 + 0.5), math.floor(col.B * 255 + 0.5))
end

function setStatus(msg, col)
    if not ConsoleOutput or not _enabled then return end
    if msg == _lastStatusMsg then return end
    _lastStatusMsg = msg
    col = col or COLORS.Dim
    local line = '<font color="' .. CONSOLE_COLORS.Cyan .. '">(NOVA)</font> <font color="' .. col3ToRich(col) .. '">' .. tostring(msg) .. "</font>"
    if ConsoleOutput.Text == "" then ConsoleOutput.Text = line
    else ConsoleOutput.Text = ConsoleOutput.Text .. "\n\n" .. line end
    scrollConsoleToBottom()
end

function flashCode(code, col)
    if not code or code == "" or code == "—" then return end
    setStatus(tostring(code), col or COLORS.White)
end

local function resetPasteCounter() _capturedParts = {} end
clearAceCapture = function() _capturedParts = {} end

local function clearBoxWatchers()
    if _boxTextConn then pcall(function() _boxTextConn:Disconnect() end) end
    if _boxAncestryConn then pcall(function() _boxAncestryConn:Disconnect() end) end
    for _, connection in ipairs(_boxVisibilityConns) do pcall(function() connection:Disconnect() end) end
    _boxTextConn = nil
    _boxAncestryConn = nil
    _boxVisibilityConns = {}
    _lastWatchedBox = nil
end

local function watchBoxForBlankReset(box)
    if not box or _lastWatchedBox == box then return end
    clearBoxWatchers()
    _lastWatchedBox = box
    if box.Text ~= "" then _lastNonBlankBoxText = box.Text end
    _boxTextConn = box:GetPropertyChangedSignal("Text"):Connect(function()
        if box.Text == "" then resetPasteCounter()
        else _lastNonBlankBoxText = box.Text end
    end)
    _boxAncestryConn = box.AncestryChanged:Connect(function(_, parent)
        if not parent then resetPasteCounter(); clearBoxWatchers() end
    end)
end

UserInputService.TextBoxFocused:Connect(function(box)
    if box:IsDescendantOf(GUI) then return end
    if box ~= aceCodeBox() then return end
    _focused = box
    _lastBox = box
    watchBoxForBlankReset(box)
    if _enabled then setStatus("Ready", COLORS.Green) end
end)

UserInputService.TextBoxFocusReleased:Connect(function(box)
    if box:IsDescendantOf(GUI) then return end
    local codeBox = aceCodeBox()
    if box ~= codeBox and box ~= _lastBox then return end
    if _retypeInvalid and rememberPendingSubmission and (box == codeBox or box == _lastBox) then
        local submittedText = box.Text ~= "" and box.Text or _lastNonBlankBoxText
        rememberPendingSubmission(box, submittedText, false)
    end
    if _focused == box then
        _focused = nil
        if _enabled then
            setStatus((_lastBox and _lastBox.Parent) and "Ready" or "Click code box first", (_lastBox and _lastBox.Parent) and COLORS.Green or COLORS.Dim)
        end
    end
end)

clearPendingSubmission = function()
    _pendingRejectedToken += 1
    _pendingRejectedText = nil
    _pendingRejectedBox = nil
    _pendingRejectedUntil = 0
end

rememberPendingSubmission = function(box, text, replaceExisting)
    if not _retypeInvalid or not text or text == "" then return end
    if not replaceExisting and _pendingRejectedText and os.clock() <= _pendingRejectedUntil then return end
    _pendingRejectedToken += 1
    local token = _pendingRejectedToken
    _pendingRejectedText = text
    _pendingRejectedBox = box
    _pendingRejectedUntil = os.clock() + 8
    task.delay(8, function()
        if token == _pendingRejectedToken then clearPendingSubmission() end
    end)
end

local function restoreRejectedText(box, previousText)
    if not _retypeInvalid or not previousText or previousText == "" then return false end
    RunService.Heartbeat:Wait()
    local repasteBox = aceCodeBox() or box
    if not repasteBox or not isVisibleChain(repasteBox) then return false end
    local restored = pcall(function() repasteBox.Text = previousText end)
    if restored then
        _lastBox = repasteBox
        watchBoxForBlankReset(repasteBox)
    end
    return restored
end

handleRedemptionFeedback = function(text, feedbackObject)
    if not _retypeInvalid or not _pendingRejectedText then return end
    if os.clock() > _pendingRejectedUntil then clearPendingSubmission(); return end
    if feedbackObject and feedbackObject:IsDescendantOf(GUI) then return end
    local lower = tostring(text or ""):lower()
    local rejected = lower:find("invalid code", 1, true)
        or lower:find("code is invalid", 1, true)
        or lower:find("expired", 1, true)
        or lower:find("already redeemed", 1, true)
        or lower:find("already used", 1, true)
        or lower:find("doesn't exist", 1, true)
        or lower:find("does not exist", 1, true)
        or lower:find("not found", 1, true)
        or lower:find("rejected", 1, true)
    if not rejected then return end
    local previousText = _pendingRejectedText
    local previousBox = _pendingRejectedBox
    local restored = restoreRejectedText(previousBox, previousText)
    clearPendingSubmission()
    if restored then
        setStatus("Invalid - repasted: " .. previousText, COLORS.Text)
        flashCode(previousText, COLORS.Red)
    end
end

function appendToBox(text)
    if not text or text == "" then return end
    if _lastWatchedBox and not isVisibleChain(_lastWatchedBox) then
        resetPasteCounter()
        clearBoxWatchers()
    end
    local box = aceCodeBox()
    _capturedParts[#_capturedParts + 1] = text
    local combinedCode = table.concat(_capturedParts)
    local capturedCount = #_capturedParts

    if box then
        _lastBox = box
        watchBoxForBlankReset(box)
        local boxWasFocused = UserInputService:GetFocusedTextBox() == box
        box.Text = combinedCode
        if boxWasFocused then
            pcall(function()
                local caretEnd = #combinedCode + 1
                box.CursorPosition = caretEnd
                box.SelectionStart = caretEnd
            end)
        end
    else
        setStatus("Captured; opening & searching UI...", COLORS.Text)
    end

    setStatus("Pasted " .. tostring(capturedCount) .. "/" .. tostring(_submitAfter), COLORS.Green)
    flashCode(combinedCode, COLORS.Green)

    if capturedCount >= _submitAfter then
        _capturedParts = {}
        if _autoAccept then
            rememberPendingSubmission(box, combinedCode, true)
            
            local ok, statusMsg = typeAndSubmitCode(combinedCode)
            
            if ok then
                setStatus("Redeemed: " .. combinedCode, COLORS.Green)
            else
                local restored = restoreRejectedText(box, combinedCode)
                clearPendingSubmission()
                if restored then
                    setStatus("Invalid - repasted: " .. combinedCode, COLORS.Text)
                    flashCode(combinedCode, COLORS.Red)
                else
                    setStatus("Failed: " .. tostring(statusMsg), COLORS.Red)
                end
            end
        end
    end
end

local function watchRedemptionFeedbackObject(obj)
    if not (obj:IsA("TextLabel") or obj:IsA("TextButton")) then return end
    handleRedemptionFeedback(obj.Text or "", obj)
    obj:GetPropertyChangedSignal("Text"):Connect(function()
        handleRedemptionFeedback(obj.Text or "", obj)
    end)
end

for _, obj in ipairs(playerGui:GetDescendants()) do watchRedemptionFeedbackObject(obj) end
playerGui.DescendantAdded:Connect(function(obj)
    task.wait(0.04)
    watchRedemptionFeedbackObject(obj)
end)

-- ANNOUNCEMENT NOTIFICATION LISTENER --
local function resolveNotifyRemote()
    if _G.PhiNotifyRemote then return _G.PhiNotifyRemote end
    local Net = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Net")
    local getinfo = debug and (debug.getinfo or debug.info)
    if getgc and getinfo and getconnections then
        for _, d in ipairs(Net:GetDescendants()) do
            if d:IsA("RemoteEvent") then
                local ok, cs = pcall(getconnections, d.OnClientEvent)
                if ok then
                    for _, c in ipairs(cs) do
                        local f, fn = pcall(function() return c.Function end)
                        if f and type(fn) == "function" then
                            local i, info = pcall(getinfo, fn)
                            if i and tostring(info.short_src or info.source or ""):find("NotificationController", 1, true) then
                                return d
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function aceStripRich(text)
    if type(text) ~= "string" then return tostring(text) end
    return (text:gsub("<[^>]->", ""))
end

local function aceTokenize(text)
    local words = {}
    for word in text:gmatch("[%w_]+") do
        words[#words + 1] = word
    end
    return words
end

local aceCollectBuffer = {}
local function onAceAnnouncement(...)
    local text = aceStripRich(tostring((...) or ""))
    text = text:match("^%s*(.-)%s*$") or ""
    if text == "" then return end
    setStatus(text, COLORS.White)
    if text:find("%s") then return end
    
    for _, word in ipairs(aceTokenize(text)) do
        aceCollectBuffer[#aceCollectBuffer + 1] = word
    end
    
    local parts = {}
    for index = 1, math.min(#aceCollectBuffer, ACE_WORD_COUNT) do
        parts[index] = aceCollectBuffer[index]
    end
    if #aceCollectBuffer < ACE_WORD_COUNT then return end
    aceCollectBuffer = {}
    
    local captured = table.concat(parts)
    if captured == "" or _seen[captured] then return end
    _seen[captured] = true
    task.delay(1.25, function() _seen[captured] = nil end)
    appendToBox(captured)
end

local aceNotifyRemote = resolveNotifyRemote()
if aceNotifyRemote then
    if getgenv then
        local previous = getgenv().ACECodeSniperNotifyConnection
        if previous then pcall(function() previous:Disconnect() end) end
    end
    aceListenConnection = aceNotifyRemote.OnClientEvent:Connect(function(...)
        if not _enabled then return end
        pcall(onAceAnnouncement, ...)
    end)
    if getgenv then getgenv().ACECodeSniperNotifyConnection = aceListenConnection end
end

if getgenv then
    getgenv().StopAura = function()
        if aceListenConnection then
            pcall(function() aceListenConnection:Disconnect() end)
            aceListenConnection = nil
        end
        if getgenv().ACECodeSniperNotifyConnection then
            pcall(function() getgenv().ACECodeSniperNotifyConnection:Disconnect() end)
            getgenv().ACECodeSniperNotifyConnection = nil
        end
        if GUI then GUI:Destroy() end
    end
end
