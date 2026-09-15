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
    Window = Color3.fromRGB(10, 11, 16),
    Surface = Color3.fromRGB(17, 19, 27),
    Surface2 = Color3.fromRGB(23, 26, 36),
    Control = Color3.fromRGB(29, 33, 44),
    Border = Color3.fromRGB(47, 53, 69),
    White = Color3.fromRGB(246, 248, 252),
    Text = Color3.fromRGB(185, 191, 205),
    Dim = Color3.fromRGB(108, 116, 135),
    Accent = Color3.fromRGB(125, 91, 255),
    Accent2 = Color3.fromRGB(82, 207, 255),
    Green = Color3.fromRGB(67, 224, 137),
    Red = Color3.fromRGB(246, 91, 108),
    Amber = Color3.fromRGB(247, 183, 89),
}

local function addCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = parent
    return c
end

local function addStroke(parent, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Color = color
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0
    s.Parent = parent
    return s
end

local function makeLabel(parent, name, text, size, position, textSize, color, font)
    local l = Instance.new("TextLabel")
    l.Name = name
    l.Size = size
    l.Position = position
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextSize = textSize
    l.TextColor3 = color
    l.Font = font or Enum.Font.GothamMedium
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Center
    l.Parent = parent
    return l
end

local function makeButton(parent, name, text, size, position, textSize)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Size = size
    b.Position = position
    b.BackgroundColor3 = COLORS.Control
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.Text = text
    b.TextSize = textSize or 10
    b.TextColor3 = COLORS.Text
    b.Font = Enum.Font.GothamBold
    b.Active = true
    b.ZIndex = 20
    b.Parent = parent
    addCorner(b, 10)
    addStroke(b, COLORS.Border, 1, 0.12)
    return b
end

-- CLEANUP OLD GUIS
pcall(function()
    for _, name in ipairs({"ACECodeSniperUI", "AutoTypeCodesUI", "ACEPaste", "NovaRedeemerUI"}) do
        local old = game.CoreGui:FindFirstChild(name)
        if old then old:Destroy() end
    end
end)
for _, name in ipairs({"ACECodeSniperUI", "AutoTypeCodesUI", "ACEPaste", "NovaRedeemerUI"}) do
    local old = playerGui:FindFirstChild(name)
    if old then old:Destroy() end
end

-- MAIN GUI
local GUI = Instance.new("ScreenGui")
GUI.Name = "NovaRedeemerUI"
GUI.ResetOnSpawn = false
GUI.IgnoreGuiInset = true
GUI.DisplayOrder = 999
if not pcall(function() GUI.Parent = game.CoreGui end) then GUI.Parent = playerGui end

-- Compact by default: designed for small phone screens.
local NORMAL_SIZE = UDim2.fromOffset(300, 340)
local COLLAPSED_SIZE = UDim2.fromOffset(300, 54)

local Window = Instance.new("Frame")
Window.Name = "Window"
Window.Size = NORMAL_SIZE
Window.AnchorPoint = Vector2.new(1, 0)
Window.Position = UDim2.new(1, -10, 0, 10)
Window.BackgroundColor3 = COLORS.Window
Window.BorderSizePixel = 0
Window.ClipsDescendants = true
Window.Parent = GUI
addCorner(Window, 17)
addStroke(Window, COLORS.Border, 1, 0.02)

local InterfaceScale = Instance.new("UIScale")
InterfaceScale.Name = "InterfaceScale"
InterfaceScale.Scale = 1
InterfaceScale.Parent = Window

local scaleSteps = {1, 0.9, 0.8, 0.7, 0.6, 0.5}
local scaleIndex = 1
local selectedScale = scaleSteps[1]
local viewportConnection
local windowCollapsed = false

local function updateInterfaceScale()
    local camera = workspace.CurrentCamera
    if not camera then
        InterfaceScale.Scale = selectedScale
        return
    end
    local viewport = camera.ViewportSize
    local baseHeight = windowCollapsed and 54 or 340
    local fit = math.min((viewport.X - 12) / 300, (viewport.Y - 12) / baseHeight)
    if UserInputService.TouchEnabled then
        InterfaceScale.Scale = math.max(0.5, math.min(selectedScale, fit))
    else
        InterfaceScale.Scale = selectedScale
    end
end

local function watchViewport()
    if viewportConnection then viewportConnection:Disconnect() end
    local camera = workspace.CurrentCamera
    if camera then
        viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateInterfaceScale)
    end
    updateInterfaceScale()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)
watchViewport()

local AccentStrip = Instance.new("Frame")
AccentStrip.Size = UDim2.new(1, 0, 0, 2)
AccentStrip.BackgroundColor3 = COLORS.Accent
AccentStrip.BorderSizePixel = 0
AccentStrip.ZIndex = 4
AccentStrip.Parent = Window

-- HEADER
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 54)
Header.BackgroundTransparency = 1
Header.Active = true
Header.Selectable = false
Header.ZIndex = 5
Header.Parent = Window

local Brand = Instance.new("Frame")
Brand.Size = UDim2.fromOffset(34, 34)
Brand.Position = UDim2.fromOffset(10, 10)
Brand.BackgroundColor3 = COLORS.Surface2
Brand.BorderSizePixel = 0
Brand.ZIndex = 6
Brand.Parent = Header
addCorner(Brand, 11)
addStroke(Brand, COLORS.Border, 1, 0.15)

local BrandDot = Instance.new("Frame")
BrandDot.Size = UDim2.fromOffset(8, 8)
BrandDot.Position = UDim2.new(0.5, -4, 0.5, -4)
BrandDot.BackgroundColor3 = COLORS.Accent2
BrandDot.BorderSizePixel = 0
BrandDot.ZIndex = 7
BrandDot.Parent = Brand
addCorner(BrandDot, 4)

makeLabel(Header, "Title", "NOVA", UDim2.fromOffset(100, 18), UDim2.fromOffset(54, 7), 14, COLORS.White, Enum.Font.GothamBlack).ZIndex = 6
makeLabel(Header, "Subtitle", "REDEEMER  •  FAST", UDim2.fromOffset(125, 15), UDim2.fromOffset(54, 26), 8, COLORS.Dim, Enum.Font.GothamBold).ZIndex = 6

-- Header actions: only minimize and close. The SNIPE toggle lives inside SNIPE.
local MinimizeButton = makeButton(Header, "Minimize", "−", UDim2.fromOffset(42, 36), UDim2.new(1, -90, 0, 9), 17)
MinimizeButton.BackgroundColor3 = COLORS.Surface2
MinimizeButton.TextColor3 = COLORS.White
MinimizeButton.ZIndex = 30

local CloseButton = makeButton(Header, "Close", "×", UDim2.fromOffset(42, 36), UDim2.new(1, -46, 0, 9), 18)
CloseButton.BackgroundColor3 = COLORS.Surface2
CloseButton.TextColor3 = COLORS.Red
CloseButton.ZIndex = 30

local Console, ConsoleOutput, updateConsoleCanvas
local autoWriteEnabled = _enabled
local featureStates = {}
local CONSOLE_COLORS = {
    Dim = "rgb(108,116,135)",
    Amber = "rgb(247,183,89)",
    Green = "rgb(67,224,137)",
    Red = "rgb(246,91,108)",
    Cyan = "rgb(82,207,255)",
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
    local color = activated and CONSOLE_COLORS.Green or CONSOLE_COLORS.Red
    local line = '<font color="' .. CONSOLE_COLORS.Cyan .. '">(NOVA)</font> '
        .. '<font color="' .. CONSOLE_COLORS.Dim .. '">' .. tostring(name) .. '</font>  '
        .. '<font color="' .. color .. '">' .. state .. '</font>'
    if ConsoleOutput.Text == "" then ConsoleOutput.Text = line else ConsoleOutput.Text = ConsoleOutput.Text .. "\n" .. line end
    scrollConsoleToBottom()
end

-- TABS
local Tabs = Instance.new("Frame")
Tabs.Name = "Tabs"
Tabs.Size = UDim2.new(1, -20, 0, 38)
Tabs.Position = UDim2.fromOffset(10, 62)
Tabs.BackgroundColor3 = COLORS.Surface
Tabs.BorderSizePixel = 0
Tabs.Parent = Window
addCorner(Tabs, 11)
addStroke(Tabs, COLORS.Border, 1, 0.18)

local function makeTab(name, text, x)
    local b = makeButton(Tabs, name, text, UDim2.new(0.5, -6, 1, -8), UDim2.fromOffset(x, 4), 9)
    b.TextColor3 = COLORS.Dim
    return b
end
local ConsoleTab = makeTab("ConsoleTab", "CONSOLE", 4)
local SnipeTab = makeTab("SnipeTab", "SNIPE", 0)
SnipeTab.Position = UDim2.new(0.5, 2, 0, 4)

local function newPage(name)
    local p = Instance.new("Frame")
    p.Name = name
    p.Size = UDim2.new(1, -20, 1, -112)
    p.Position = UDim2.fromOffset(10, 108)
    p.BackgroundTransparency = 1
    p.Parent = Window
    return p
end
local ConsolePage = newPage("ConsolePage")
local SnipePage = newPage("SnipePage")

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

-- CONSOLE: dedicated scrolling log
local ConsoleFrame = Instance.new("Frame")
ConsoleFrame.Size = UDim2.new(1, 0, 1, 0)
ConsoleFrame.BackgroundColor3 = COLORS.Surface
ConsoleFrame.BorderSizePixel = 0
ConsoleFrame.Parent = ConsolePage
addCorner(ConsoleFrame, 13)
addStroke(ConsoleFrame, COLORS.Border, 1, 0.2)

local ConsoleTitle = makeLabel(ConsoleFrame, "Title", "CONSOLE", UDim2.fromOffset(150, 18), UDim2.fromOffset(12, 8), 11, COLORS.White, Enum.Font.GothamBold)
ConsoleTitle.ZIndex = 3
local ConsoleHint = makeLabel(ConsoleFrame, "Hint", "events • codes • status", UDim2.fromOffset(160, 14), UDim2.fromOffset(12, 25), 7, COLORS.Dim, Enum.Font.GothamMedium)
ConsoleHint.ZIndex = 3

Console = Instance.new("ScrollingFrame")
Console.Name = "Console"
Console.Size = UDim2.new(1, -20, 1, -88)
Console.Position = UDim2.fromOffset(10, 47)
Console.BackgroundColor3 = Color3.fromRGB(7, 8, 11)
Console.BorderSizePixel = 0
Console.ClipsDescendants = true
Console.Active = true
Console.ScrollingEnabled = true
Console.ScrollingDirection = Enum.ScrollingDirection.Y
Console.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
Console.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
Console.ScrollBarThickness = 3
Console.ScrollBarImageColor3 = COLORS.Dim
Console.CanvasSize = UDim2.new(0, 0, 0, 0)
Console.Parent = ConsoleFrame
addCorner(Console, 10)
addStroke(Console, COLORS.Border, 1, 0.3)

ConsoleOutput = Instance.new("TextLabel")
ConsoleOutput.Name = "ConsoleOutput"
ConsoleOutput.Size = UDim2.new(1, -18, 0, 20)
ConsoleOutput.AutomaticSize = Enum.AutomaticSize.Y
ConsoleOutput.Position = UDim2.fromOffset(9, 9)
ConsoleOutput.BackgroundTransparency = 1
ConsoleOutput.RichText = true
ConsoleOutput.Text = autoWriteEnabled
    and '<font color="' .. CONSOLE_COLORS.Green .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner online</font>'
    or '<font color="' .. CONSOLE_COLORS.Red .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner paused</font>'
ConsoleOutput.TextSize = 10
ConsoleOutput.Font = Enum.Font.Code
ConsoleOutput.TextColor3 = COLORS.Dim
ConsoleOutput.TextXAlignment = Enum.TextXAlignment.Left
ConsoleOutput.TextYAlignment = Enum.TextYAlignment.Top
ConsoleOutput.TextWrapped = true
ConsoleOutput.ZIndex = 4
ConsoleOutput.Parent = Console

local ConsoleFooter = Instance.new("Frame")
ConsoleFooter.Name = "ConsoleFooter"
ConsoleFooter.Size = UDim2.new(1, -20, 0, 25)
ConsoleFooter.Position = UDim2.new(0, 10, 1, -34)
ConsoleFooter.BackgroundTransparency = 1
ConsoleFooter.Parent = ConsoleFrame

local ConsoleFooterLabel = makeLabel(ConsoleFooter, "Hint", "LOG", UDim2.fromOffset(100, 18), UDim2.fromOffset(2, 4), 7, COLORS.Dim, Enum.Font.GothamBold)
local ClearConsole = makeButton(ConsoleFooter, "ClearConsole", "CLEAR", UDim2.fromOffset(58, 23), UDim2.new(1, -58, 0, 0), 7)
ClearConsole.Activated:Connect(function()
    ConsoleOutput.Text = autoWriteEnabled
        and '<font color="' .. CONSOLE_COLORS.Green .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner online</font>'
        or '<font color="' .. CONSOLE_COLORS.Red .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner paused</font>'
    scrollConsoleToBottom()
end)

updateConsoleCanvas = function()
    if not Console or not ConsoleOutput then return end
    Console.CanvasSize = UDim2.new(0, 0, 0, ConsoleOutput.Position.Y.Offset + ConsoleOutput.AbsoluteSize.Y + 18)
end
ConsoleOutput:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateConsoleCanvas)
task.defer(updateConsoleCanvas)

-- SNIPE: a real scrolling settings page, compact and mobile-friendly.
local SnipeScroll = Instance.new("ScrollingFrame")
SnipeScroll.Name = "SnipeScroll"
SnipeScroll.Size = UDim2.new(1, 0, 1, 0)
SnipeScroll.BackgroundTransparency = 1
SnipeScroll.BorderSizePixel = 0
SnipeScroll.ScrollBarThickness = 3
SnipeScroll.ScrollBarImageColor3 = COLORS.Dim
SnipeScroll.ScrollingDirection = Enum.ScrollingDirection.Y
SnipeScroll.ScrollingEnabled = true
SnipeScroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
SnipeScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
SnipeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
SnipeScroll.Parent = SnipePage

local SnipeContent = Instance.new("Frame")
SnipeContent.Name = "SnipeContent"
SnipeContent.Size = UDim2.new(1, -8, 0, 1)
SnipeContent.BackgroundTransparency = 1
SnipeContent.Parent = SnipeScroll

local contentLayout = Instance.new("UIListLayout")
contentLayout.Padding = UDim.new(0, 8)
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Parent = SnipeContent

local contentPadding = Instance.new("UIPadding")
contentPadding.PaddingLeft = UDim.new(0, 1)
contentPadding.PaddingRight = UDim.new(0, 5)
contentPadding.PaddingBottom = UDim.new(0, 12)
contentPadding.Parent = SnipeContent

local function makeSection(height)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, height)
    f.BackgroundColor3 = COLORS.Surface
    f.BorderSizePixel = 0
    f.LayoutOrder = 1
    f.Parent = SnipeContent
    addCorner(f, 12)
    addStroke(f, COLORS.Border, 1, 0.22)
    return f
end

local Hero = makeSection(64)
makeLabel(Hero, "Eyebrow", "SNIPE ENGINE", UDim2.fromOffset(140, 15), UDim2.fromOffset(12, 8), 8, COLORS.Dim, Enum.Font.GothamBold)
makeLabel(Hero, "Title", "Capture  →  Assemble  →  Submit", UDim2.fromOffset(220, 20), UDim2.fromOffset(12, 25), 10, COLORS.White, Enum.Font.GothamBold)
-- Main script control lives inside SNIPE, so the header stays clean.

local EnableCard = makeSection(58)
EnableCard.LayoutOrder = 2
makeLabel(EnableCard, "Title", "SNIPE STATUS", UDim2.fromOffset(130, 18), UDim2.fromOffset(12, 7), 10, COLORS.White, Enum.Font.GothamMedium)
makeLabel(EnableCard, "Hint", "enable / pause scanner", UDim2.fromOffset(145, 15), UDim2.fromOffset(12, 30), 7, COLORS.Dim, Enum.Font.GothamMedium)

local AutoWriteButton = Instance.new("TextButton")
AutoWriteButton.Name = "EnableSnipe"
AutoWriteButton.Size = UDim2.fromOffset(82, 30)
AutoWriteButton.Position = UDim2.new(1, -94, 0.5, -15)
AutoWriteButton.BackgroundColor3 = COLORS.Control
AutoWriteButton.BorderSizePixel = 0
AutoWriteButton.AutoButtonColor = false
AutoWriteButton.Text = autoWriteEnabled and "ENABLED" or "OFF"
AutoWriteButton.TextSize = 8
AutoWriteButton.Font = Enum.Font.GothamBold
AutoWriteButton.TextColor3 = autoWriteEnabled and COLORS.White or COLORS.Dim
AutoWriteButton.ZIndex = 20
AutoWriteButton.Parent = EnableCard
addCorner(AutoWriteButton, 10)
local AutoWriteStroke = addStroke(AutoWriteButton, autoWriteEnabled and COLORS.Accent2 or COLORS.Border, 1, 0.05)

local function refreshMainToggle()
    AutoWriteButton.Text = autoWriteEnabled and "ENABLED" or "OFF"
    AutoWriteButton.BackgroundColor3 = autoWriteEnabled and COLORS.Accent or COLORS.Control
    AutoWriteButton.TextColor3 = autoWriteEnabled and COLORS.White or COLORS.Dim
    AutoWriteStroke.Color = autoWriteEnabled and COLORS.Accent2 or COLORS.Border
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
        ConsoleOutput.Text = autoWriteEnabled
            and '<font color="' .. CONSOLE_COLORS.Green .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner online</font>'
            or '<font color="' .. CONSOLE_COLORS.Red .. '">●</font> <font color="' .. CONSOLE_COLORS.Dim .. '">scanner paused</font>'
        scrollConsoleToBottom()
    end
end
AutoWriteButton.Activated:Connect(toggleAutoWrite)

local function makeStateRow(title, hint, enabled, key, onToggle)
    local row = makeSection(58)
    row.LayoutOrder = (key == "Auto submit") and 3 or 4
    makeLabel(row, "Title", title, UDim2.new(1, -78, 0, 18), UDim2.fromOffset(12, 7), 10, COLORS.White, Enum.Font.GothamMedium)
    makeLabel(row, "Hint", hint, UDim2.new(1, -78, 0, 15), UDim2.fromOffset(12, 29), 7, COLORS.Dim, Enum.Font.GothamMedium)
    local b = makeButton(row, "State", enabled and "ON" or "OFF", UDim2.fromOffset(48, 25), UDim2.new(1, -60, 0.5, -12), 8)
    featureStates[key] = enabled
    local outline = b:FindFirstChildOfClass("UIStroke")
    local function paint()
        b.Text = enabled and "ON" or "OFF"
        b.BackgroundColor3 = enabled and COLORS.Accent or COLORS.Control
        b.TextColor3 = enabled and COLORS.White or COLORS.Dim
        if outline then outline.Color = enabled and COLORS.Accent2 or COLORS.Border end
    end
    paint()
    b.Activated:Connect(function()
        enabled = not enabled
        featureStates[key] = enabled
        paint()
        if autoWriteEnabled then appendConsoleStatus(key, enabled) end
        if onToggle then onToggle(enabled) end
    end)
end

makeStateRow("Auto submit", "submit captured code", _autoAccept, "Auto submit", function(state)
    _autoAccept = state
    savedConfig.autoSubmit = state
    saveConfig()
end)

makeStateRow("Retype invalid", "restore rejected text", _retypeInvalid, "Retype invalid", function(state)
    _retypeInvalid = state
    savedConfig.retypeInvalid = state
    saveConfig()
end)

local Delay = makeSection(62)
Delay.LayoutOrder = 5
makeLabel(Delay, "Title", "SUBMIT AFTER", UDim2.fromOffset(130, 18), UDim2.fromOffset(12, 8), 9, COLORS.Dim, Enum.Font.GothamBold)
makeLabel(Delay, "Hint", "captured parts", UDim2.fromOffset(120, 15), UDim2.fromOffset(12, 30), 7, COLORS.Dim, Enum.Font.GothamMedium)

local Counter = Instance.new("Frame")
Counter.Size = UDim2.fromOffset(118, 38)
Counter.Position = UDim2.new(1, -130, 0.5, -19)
Counter.BackgroundColor3 = COLORS.Control
Counter.BorderSizePixel = 0
Counter.Parent = Delay
addCorner(Counter, 10)

local Minus = makeButton(Counter, "Minus", "−", UDim2.fromOffset(29, 30), UDim2.fromOffset(4, 4), 15)
local Count = makeLabel(Counter, "Count", tostring(_submitAfter), UDim2.fromOffset(48, 30), UDim2.fromOffset(35, 4), 13, COLORS.White, Enum.Font.GothamBlack)
Count.TextXAlignment = Enum.TextXAlignment.Center
local Plus = makeButton(Counter, "Plus", "+", UDim2.fromOffset(29, 30), UDim2.new(1, -33, 0, 4), 14)

Minus.Activated:Connect(function()
    _submitAfter = math.max(1, _submitAfter - 1)
    Count.Text = tostring(_submitAfter)
    savedConfig.submitAfter = _submitAfter
    clearAceCapture()
    saveConfig()
end)
Plus.Activated:Connect(function()
    _submitAfter += 1
    Count.Text = tostring(_submitAfter)
    savedConfig.submitAfter = _submitAfter
    clearAceCapture()
    saveConfig()
end)

local ScaleCard = makeSection(62)
ScaleCard.LayoutOrder = 6
makeLabel(ScaleCard, "Title", "UI SCALE", UDim2.fromOffset(90, 18), UDim2.fromOffset(12, 8), 9, COLORS.Dim, Enum.Font.GothamBold)
makeLabel(ScaleCard, "Hint", "0.5x  →  1x", UDim2.fromOffset(90, 15), UDim2.fromOffset(12, 30), 7, COLORS.Dim, Enum.Font.GothamMedium)

local ScaleShell = Instance.new("Frame")
ScaleShell.Size = UDim2.fromOffset(118, 38)
ScaleShell.Position = UDim2.new(1, -130, 0.5, -19)
ScaleShell.BackgroundColor3 = COLORS.Control
ScaleShell.BorderSizePixel = 0
ScaleShell.Parent = ScaleCard
addCorner(ScaleShell, 10)

local ScaleMinus = makeButton(ScaleShell, "Minus", "−", UDim2.fromOffset(29, 30), UDim2.fromOffset(4, 4), 15)
local ScaleText = makeLabel(ScaleShell, "Value", "1x", UDim2.fromOffset(48, 30), UDim2.fromOffset(35, 4), 12, COLORS.White, Enum.Font.GothamBlack)
ScaleText.TextXAlignment = Enum.TextXAlignment.Center
local ScalePlus = makeButton(ScaleShell, "Plus", "+", UDim2.fromOffset(29, 30), UDim2.new(1, -33, 0, 4), 14)

local function refreshScaleText()
    local value = scaleSteps[scaleIndex]
    selectedScale = value
    ScaleText.Text = tostring(value):gsub("%.0+$", "") .. "x"
    ScaleMinus.TextColor3 = scaleIndex == #scaleSteps and COLORS.Dim or COLORS.White
    ScalePlus.TextColor3 = scaleIndex == 1 and COLORS.Dim or COLORS.White
    updateInterfaceScale()
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

local Tip = makeSection(58)
Tip.LayoutOrder = 7
makeLabel(Tip, "Title", "NOVA TIP", UDim2.fromOffset(100, 17), UDim2.fromOffset(12, 7), 8, COLORS.Accent2, Enum.Font.GothamBold)
makeLabel(Tip, "Text", "Scroll this panel on mobile to reach every control.", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, 25), 8, COLORS.Text, Enum.Font.GothamMedium)

-- Keep scrolling content sized correctly.
local function refreshSnipeCanvas()
    SnipeContent.Size = UDim2.new(1, -8, 0, contentLayout.AbsoluteContentSize.Y + 12)
end
contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(refreshSnipeCanvas)
task.defer(refreshSnipeCanvas)

-- COLLAPSE / CLOSE
local currentPage = SnipePage

local function setWindowCollapsed(collapsed)
    windowCollapsed = collapsed
    Tabs.Visible = not collapsed
    ConsolePage.Visible = not collapsed and currentPage == ConsolePage
    SnipePage.Visible = not collapsed and currentPage == SnipePage
    Window.Size = collapsed and COLLAPSED_SIZE or NORMAL_SIZE
    MinimizeButton.Text = collapsed and "+" or "−"
    updateInterfaceScale()
end

-- Keep the selected tab remembered while the window is collapsed.
local originalActivatePage = activatePage
activatePage = function(page)
    currentPage = page
    if windowCollapsed then
        ConsolePage.Visible = false
        SnipePage.Visible = false
        setTabVisual(ConsoleTab, page == ConsolePage)
        setTabVisual(SnipeTab, page == SnipePage)
        return
    end
    originalActivatePage(page)
end

local minimizeBusy = false
local function toggleMinimize()
    if minimizeBusy then return end
    minimizeBusy = true
    setWindowCollapsed(not windowCollapsed)
    task.delay(0.12, function() minimizeBusy = false end)
end
MinimizeButton.Activated:Connect(toggleMinimize)

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

activatePage(SnipePage)

-- WINDOW DRAGGING: header only, never buttons.
do
    local dragging = false
    local activeInput
    local dragStart
    local startPosition

    Header.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local function inside(control)
            return input.Position.X >= control.AbsolutePosition.X
                and input.Position.X <= control.AbsolutePosition.X + control.AbsoluteSize.X
                and input.Position.Y >= control.AbsolutePosition.Y
                and input.Position.Y <= control.AbsolutePosition.Y + control.AbsoluteSize.Y
        end
        if inside(MinimizeButton) or inside(CloseButton) then return end
        for _, child in ipairs(Header:GetChildren()) do
            if child:IsA("GuiButton") and inside(child) then return end
        end
        dragging = true
        activeInput = input
        dragStart = Vector2.new(input.Position.X, input.Position.Y)
        startPosition = Window.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
                dragging = false
                activeInput = nil
            end
        end)
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging or not activeInput then return end
        local mouseMove = activeInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement
        local touchMove = activeInput.UserInputType == Enum.UserInputType.Touch and input == activeInput
        if not mouseMove and not touchMove then return end
        local current = Vector2.new(input.Position.X, input.Position.Y)
        local delta = current - dragStart
        if delta.Magnitude < 2 then return end
        Window.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
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
