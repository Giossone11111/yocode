local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

local getupvalues = (debug and debug.getupvalues) or getupvalues
local getconns    = getconnections or (debug and debug.getconnections)
local setupv      = (debug and debug.setupvalue) or setupvalue

local function isOurGui(instance)
    local p = instance
    for _ = 1, 10 do
        if not p then break end
        if p.Name == "GGCodeRedeemUI" then return true end
        p = p.Parent
    end
    return false
end

local function findAllTextBoxes(pg)
    local boxes = {}
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= "GGCodeRedeemUI" then
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextBox") and not isOurGui(d) then
                    boxes[#boxes+1] = d
                end
            end
        end
    end
    return boxes
end

local function isVisibleChain(inst)
    local current = inst
    while current do
        if current:IsA("GuiObject") then
            if not current.Visible then return false end
        end
        if current:IsA("ScreenGui") then
            if not current.Enabled then return false end
            return true
        end
        current = current.Parent
    end
    return true
end

local function findCodeButtons(pg)
    local btns = {}
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= "GGCodeRedeemUI" then
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

local function writeCodeToBox(box, code)
    if not box then return false end
    pcall(function()
        box.Text = code
    end)
    return box.Text == code
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
    if not LP then return false, "no LP" end
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return false, "no PlayerGui" end

    local codesGui = pg:FindFirstChild("Codes")
    if codesGui then
        if codesGui:IsA("ScreenGui") then
            codesGui.Enabled = true
        end
        local codesFrame = codesGui:FindFirstChild("Codes") or codesGui
        if codesFrame then
            if codesFrame:IsA("GuiObject") then
                codesFrame.Visible = true
            end
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
                writeCodeToBox(box, code)
                task.wait(0.05)
                if submitBtn then
                    clickButton(submitBtn)
                end
                fireBoxFocusLost(box)
                return true, "submitted via PlayerGui.Codes.Codes"
            end
        end
    end

    local function tryOpenPanel()
        local btns = findCodeButtons(pg)
        for _, btn in ipairs(btns) do
            clickButton(btn)
            task.wait(0.05)
        end
        return #btns > 0
    end

    tryOpenPanel()
    task.wait(0.3)

    local box = nil
    local deadline = tick() + 3
    while tick() < deadline do
        local allBoxes = findAllTextBoxes(pg)
        for _, d in ipairs(allBoxes) do
            if isVisibleChain(d) then
                local n   = d.Name:lower()
                local pn  = (d.Parent and d.Parent.Name or ""):lower()
                if n:find("code") or pn:find("code") or n:find("redeem") or pn:find("redeem") or n:find("input") or pn:find("input") or n:find("textbox") or n:find("enter") then
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

    writeCodeToBox(box, code)
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

    if redeemBtn then
        clickButton(redeemBtn)
    end

    fireBoxFocusLost(box)

    return true, "fallback methods used"
end

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

local notifyRemote = resolveNotifyRemote()
if not notifyRemote then
    warn("[GG Code Redeem] Notification remote not found - announcements won't be captured.")
end

if PlayerGui:FindFirstChild("GGCodeRedeemUI") then
    PlayerGui.GGCodeRedeemUI:Destroy()
end

--==================================================
-- GG CODE REDEEM UI
--==================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "GGCodeRedeemUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 330, 0, 300)
mainFrame.Position = UDim2.new(0.5, -165, 0.5, -150)
mainFrame.BackgroundColor3 = Color3.fromRGB(13, 20, 28)
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(38, 65, 78)
mainStroke.Thickness = 1
mainStroke.Parent = mainFrame

-- Header
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 48)
topBar.BackgroundColor3 = Color3.fromRGB(16, 26, 34)
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -55, 0, 20)
titleLabel.Position = UDim2.new(0, 13, 0, 7)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Text = "GG CODE REDEEM"
titleLabel.TextColor3 = Color3.fromRGB(230, 245, 247)
titleLabel.TextSize = 14
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = topBar

local subLabel = Instance.new("TextLabel")
subLabel.Size = UDim2.new(1, -55, 0, 14)
subLabel.Position = UDim2.new(0, 13, 0, 27)
subLabel.BackgroundTransparency = 1
subLabel.Font = Enum.Font.Gotham
subLabel.Text = "AUTOMATIC CODE SUBMISSION"
subLabel.TextColor3 = Color3.fromRGB(125, 155, 163)
subLabel.TextSize = 8
subLabel.TextXAlignment = Enum.TextXAlignment.Left
subLabel.Parent = topBar

statusDot = Instance.new("TextButton")
statusDot.Name = "StatusDot"
statusDot.Size = UDim2.new(0, 14, 0, 14)
statusDot.Position = UDim2.new(1, -27, 0, 17)
statusDot.BackgroundColor3 = Color3.fromRGB(34, 180, 165)
statusDot.BorderSizePixel = 0
statusDot.Text = ""
statusDot.AutoButtonColor = false
statusDot.Parent = topBar

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = statusDot

-- Tabs
local dashboardTab = Instance.new("TextButton")
dashboardTab.Size = UDim2.new(0.5, -5, 0, 29)
dashboardTab.Position = UDim2.new(0, 10, 0, 55)
dashboardTab.BackgroundColor3 = Color3.fromRGB(28, 155, 148)
dashboardTab.BorderSizePixel = 0
dashboardTab.Font = Enum.Font.GothamBold
dashboardTab.Text = "Dashboard"
dashboardTab.TextColor3 = Color3.fromRGB(235, 255, 255)
dashboardTab.TextSize = 10
dashboardTab.Parent = mainFrame

local dashCorner = Instance.new("UICorner")
dashCorner.CornerRadius = UDim.new(0, 7)
dashCorner.Parent = dashboardTab

local consoleTab = Instance.new("TextButton")
consoleTab.Size = UDim2.new(0.5, -5, 0, 29)
consoleTab.Position = UDim2.new(0.5, 0, 0, 55)
consoleTab.BackgroundColor3 = Color3.fromRGB(20, 31, 40)
consoleTab.BorderSizePixel = 0
consoleTab.Font = Enum.Font.GothamBold
consoleTab.Text = "Console"
consoleTab.TextColor3 = Color3.fromRGB(120, 150, 158)
consoleTab.TextSize = 10
consoleTab.Parent = mainFrame

local consoleCorner = Instance.new("UICorner")
consoleCorner.CornerRadius = UDim.new(0, 7)
consoleCorner.Parent = consoleTab

-- Message counter
local msgLabel = Instance.new("TextLabel")
msgLabel.Size = UDim2.new(1, -30, 0, 20)
msgLabel.Position = UDim2.new(0, 15, 0, 91)
msgLabel.BackgroundTransparency = 1
msgLabel.Font = Enum.Font.GothamBold
msgLabel.Text = "MSG: 0/3"
msgLabel.TextColor3 = Color3.fromRGB(52, 190, 178)
msgLabel.TextSize = 10
msgLabel.TextXAlignment = Enum.TextXAlignment.Left
msgLabel.Parent = mainFrame

local clearButton = Instance.new("TextButton")
clearButton.Size = UDim2.new(0, 40, 0, 20)
clearButton.Position = UDim2.new(1, -55, 0, 91)
clearButton.BackgroundColor3 = Color3.fromRGB(24, 36, 44)
clearButton.BorderSizePixel = 0
clearButton.Font = Enum.Font.GothamBold
clearButton.Text = "CLR"
clearButton.TextColor3 = Color3.fromRGB(235, 95, 105)
clearButton.TextSize = 8
clearButton.Parent = mainFrame

local clearCorner = Instance.new("UICorner")
clearCorner.CornerRadius = UDim.new(0, 6)
clearCorner.Parent = clearButton

-- Preview / captured code
previewBox = Instance.new("TextBox")
previewBox.Name = "PreviewBox"
previewBox.Size = UDim2.new(1, -30, 0, 34)
previewBox.Position = UDim2.new(0, 15, 0, 116)
previewBox.BackgroundColor3 = Color3.fromRGB(18, 31, 39)
previewBox.BorderSizePixel = 0
previewBox.PlaceholderText = "Captured code..."
previewBox.PlaceholderColor3 = Color3.fromRGB(85, 115, 123)
previewBox.Text = ""
previewBox.TextColor3 = Color3.fromRGB(225, 245, 245)
previewBox.ClearTextOnFocus = false
previewBox.Font = Enum.Font.GothamBold
previewBox.TextSize = 11
previewBox.TextXAlignment = Enum.TextXAlignment.Left
previewBox.Parent = mainFrame

local previewCorner = Instance.new("UICorner")
previewCorner.CornerRadius = UDim.new(0, 8)
previewCorner.Parent = previewBox

local previewStroke = Instance.new("UIStroke")
previewStroke.Color = Color3.fromRGB(34, 61, 70)
previewStroke.Thickness = 1
previewStroke.Parent = previewBox

local previewPad = Instance.new("UIPadding")
previewPad.PaddingLeft = UDim.new(0, 10)
previewPad.Parent = previewBox

-- Force submit
redeemButton = Instance.new("TextButton")
redeemButton.Name = "RedeemButton"
redeemButton.Size = UDim2.new(1, -30, 0, 34)
redeemButton.Position = UDim2.new(0, 15, 0, 156)
redeemButton.BackgroundColor3 = Color3.fromRGB(26, 145, 139)
redeemButton.BorderSizePixel = 0
redeemButton.Font = Enum.Font.GothamBold
redeemButton.Text = "FORCE SUBMIT"
redeemButton.TextColor3 = Color3.fromRGB(235, 255, 255)
redeemButton.TextSize = 10
redeemButton.Parent = mainFrame

local redeemCorner = Instance.new("UICorner")
redeemCorner.CornerRadius = UDim.new(0, 8)
redeemCorner.Parent = redeemButton

-- Auto submit row
local autoLabel = Instance.new("TextLabel")
autoLabel.Size = UDim2.new(0, 130, 0, 25)
autoLabel.Position = UDim2.new(0, 15, 0, 198)
autoLabel.BackgroundTransparency = 1
autoLabel.Font = Enum.Font.GothamBold
autoLabel.Text = "Auto Submit"
autoLabel.TextColor3 = Color3.fromRGB(210, 225, 229)
autoLabel.TextSize = 10
autoLabel.TextXAlignment = Enum.TextXAlignment.Left
autoLabel.Parent = mainFrame

local autoToggle = Instance.new("TextButton")
autoToggle.Size = UDim2.new(0, 45, 0, 22)
autoToggle.Position = UDim2.new(1, -60, 0, 199)
autoToggle.BackgroundColor3 = Color3.fromRGB(28, 170, 158)
autoToggle.BorderSizePixel = 0
autoToggle.Text = ""
autoToggle.Parent = mainFrame

local autoCorner = Instance.new("UICorner")
autoCorner.CornerRadius = UDim.new(1, 0)
autoCorner.Parent = autoToggle

local autoKnob = Instance.new("Frame")
autoKnob.Size = UDim2.new(0, 18, 0, 18)
autoKnob.Position = UDim2.new(1, -20, 0, 2)
autoKnob.BackgroundColor3 = Color3.fromRGB(240, 255, 255)
autoKnob.BorderSizePixel = 0
autoKnob.Parent = autoToggle

local knobCorner = Instance.new("UICorner")
knobCorner.CornerRadius = UDim.new(1, 0)
knobCorner.Parent = autoKnob

-- Submit After
local submitAfterLabel = Instance.new("TextLabel")
submitAfterLabel.Size = UDim2.new(0, 120, 0, 25)
submitAfterLabel.Position = UDim2.new(0, 15, 0, 226)
submitAfterLabel.BackgroundTransparency = 1
submitAfterLabel.Font = Enum.Font.GothamBold
submitAfterLabel.Text = "Submit After"
submitAfterLabel.TextColor3 = Color3.fromRGB(210, 225, 229)
submitAfterLabel.TextSize = 10
submitAfterLabel.TextXAlignment = Enum.TextXAlignment.Left
submitAfterLabel.Parent = mainFrame

local submitAfterBox = Instance.new("TextBox")
submitAfterBox.Size = UDim2.new(0, 42, 0, 22)
submitAfterBox.Position = UDim2.new(1, -57, 0, 227)
submitAfterBox.BackgroundColor3 = Color3.fromRGB(18, 31, 39)
submitAfterBox.BorderSizePixel = 0
submitAfterBox.Text = "3"
submitAfterBox.TextColor3 = Color3.fromRGB(225, 245, 245)
submitAfterBox.Font = Enum.Font.GothamBold
submitAfterBox.TextSize = 10
submitAfterBox.ClearTextOnFocus = false
submitAfterBox.TextXAlignment = Enum.TextXAlignment.Center
submitAfterBox.Parent = mainFrame

local afterCorner = Instance.new("UICorner")
afterCorner.CornerRadius = UDim.new(0, 6)
afterCorner.Parent = submitAfterBox

-- Hidden/compact controls retained for existing logic
modeButton = Instance.new("TextButton")
modeButton.Name = "ModeButton"
modeButton.Size = UDim2.new(0, 1, 0, 1)
modeButton.Position = UDim2.new(0, -2, 0, -2)
modeButton.BackgroundTransparency = 1
modeButton.Text = ""
modeButton.Parent = mainFrame

delayBox = Instance.new("TextBox")
delayBox.Name = "DelayBox"
delayBox.Size = UDim2.new(0, 1, 0, 1)
delayBox.Position = UDim2.new(0, -2, 0, -2)
delayBox.BackgroundTransparency = 1
delayBox.Text = "0.5"
delayBox.Parent = mainFrame

setButton = Instance.new("TextButton")
setButton.Name = "SetButton"
setButton.Size = UDim2.new(0, 1, 0, 1)
setButton.Position = UDim2.new(0, -2, 0, -2)
setButton.BackgroundTransparency = 1
setButton.Text = ""
setButton.Parent = mainFrame

-- Console panel
local consoleFrame = Instance.new("Frame")
consoleFrame.Size = UDim2.new(1, -30, 0, 105)
consoleFrame.Position = UDim2.new(0, 15, 0, 90)
consoleFrame.BackgroundColor3 = Color3.fromRGB(9, 15, 20)
consoleFrame.BorderSizePixel = 0
consoleFrame.Visible = false
consoleFrame.Parent = mainFrame

local consoleCorner2 = Instance.new("UICorner")
consoleCorner2.CornerRadius = UDim.new(0, 8)
consoleCorner2.Parent = consoleFrame

local consoleText = Instance.new("TextLabel")
consoleText.Size = UDim2.new(1, -16, 1, -16)
consoleText.Position = UDim2.new(0, 8, 0, 8)
consoleText.BackgroundTransparency = 1
consoleText.Text = "[GG] Console ready..."
consoleText.TextColor3 = Color3.fromRGB(125, 190, 188)
consoleText.Font = Enum.Font.Code
consoleText.TextSize = 9
consoleText.TextWrapped = true
consoleText.TextXAlignment = Enum.TextXAlignment.Left
consoleText.TextYAlignment = Enum.TextYAlignment.Top
consoleText.Parent = consoleFrame

-- Clear
clearButton.MouseButton1Click:Connect(function()
    buffer = {}
    previewBox.Text = ""
    msgLabel.Text = "MSG: 0/" .. tostring(mode)
end)

-- Tabs
dashboardTab.MouseButton1Click:Connect(function()
    consoleFrame.Visible = false
    dashboardTab.BackgroundColor3 = Color3.fromRGB(28, 155, 148)
    dashboardTab.TextColor3 = Color3.fromRGB(235, 255, 255)
    consoleTab.BackgroundColor3 = Color3.fromRGB(20, 31, 40)
    consoleTab.TextColor3 = Color3.fromRGB(120, 150, 158)
end)

consoleTab.MouseButton1Click:Connect(function()
    consoleFrame.Visible = true
    dashboardTab.BackgroundColor3 = Color3.fromRGB(20, 31, 40)
    dashboardTab.TextColor3 = Color3.fromRGB(120, 150, 158)
    consoleTab.BackgroundColor3 = Color3.fromRGB(28, 155, 148)
    consoleTab.TextColor3 = Color3.fromRGB(235, 255, 255)
end)

-- Auto-submit visual toggle
local autoEnabled = true
autoToggle.MouseButton1Click:Connect(function()
    autoEnabled = not autoEnabled
    if autoEnabled then
        autoToggle.BackgroundColor3 = Color3.fromRGB(28, 170, 158)
        autoKnob.Position = UDim2.new(1, -20, 0, 2)
    else
        autoToggle.BackgroundColor3 = Color3.fromRGB(45, 58, 65)
        autoKnob.Position = UDim2.new(0, 2, 0, 2)
    end
end)

-- Dragging
local dragging, dragInput, dragStart, startPos

local function update(input)
    local delta = input.Position - dragStart
    mainFrame.Position = UDim2.new(
        startPos.X.Scale,
        startPos.X.Offset + delta.X,
        startPos.Y.Scale,
        startPos.Y.Offset + delta.Y
    )
end

mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

mainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        update(input)
    end
end)

statusDot.MouseButton1Click:Connect(function()
    screenGui:Destroy()
end)

local scanning = false
local buffer = {}
local mode = 3
local delay = 0.5

local function updateDelay()
    local val = tonumber(delayBox.Text)
    if val and val >= 0.05 then
        delay = val
        print("[GG Code Redeem] Delay set to:", delay)
    else
        delayBox.Text = tostring(delay)
    end
end

delayBox.FocusLost:Connect(function(enter)
    if enter then updateDelay() end
end)

delayBox:GetPropertyChangedSignal("Text"):Connect(function()
    local val = tonumber(delayBox.Text)
    if val and val >= 0.05 then
        delay = val
    end
end)

setButton.MouseButton1Click:Connect(updateDelay)

local function isValidCode(msg)
    return msg:match("^[A-Za-z0-9]+$") ~= nil
end

local function updateMessageCounter()
    if msgLabel then
        msgLabel.Text = "MSG: " .. tostring(math.min(#buffer, mode)) .. "/" .. tostring(mode)
    end
end

--==================================================
-- NOTIFICATIONS
--==================================================

local function showNotification(title, message, duration)
    task.spawn(function()
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = title,
                Text = message,
                Duration = duration or 2
            })
        end)
    end)
end

local function notifyCodeFound()
    local count = math.min(#buffer, mode)
    showNotification("CODE FOUND", tostring(count) .. "/" .. tostring(mode), 2)
end

local function notifyCodeSubmit()
    showNotification("CODE SUBMIT!", "3/" .. tostring(mode), 3)
end

local function updatePreview()
    if #buffer == 0 then
        previewBox.Text = ""
        updateMessageCounter()
        return
    end
    local count = math.min(#buffer, mode)
    local combined = table.concat(buffer, "", 1, count)
    previewBox.Text = combined
    updateMessageCounter()
end

local function processBuffer()
    if not scanning then return end
    while #buffer >= mode do
        local combined = table.concat(buffer, "", 1, mode)
        buffer = {}
        updatePreview()
        typeAndSubmitCode(combined)
        notifyCodeSubmit()
        print("[GG Code Redeem] Auto-redeemed: " .. combined)
        task.wait(delay)
    end
    updatePreview()
end

local function onAnnouncement(txt)
    if not scanning or not txt or txt == "" then return end
    local msg = txt:match("^%s*(.-)%s*$")
    if msg and #msg > 0 and isValidCode(msg) then
        table.insert(buffer, msg)
        updatePreview()
        notifyCodeFound()

        if #buffer >= mode then
            task.spawn(processBuffer)
        end
        print("[GG Code Redeem] Captured: " .. msg .. " (buffer: " .. #buffer .. ")")
    end
end

local function toggleScan()
    scanning = not scanning
    if scanning then
        scanButton.Text = "SCANNING..."
        scanButton.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
        scanButton.BackgroundTransparency = 0.15
        statusDot.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
        buffer = {}
        updatePreview()
        print("[GG Code Redeem] Scanning started.")
    else
        scanButton.Text = "START SCAN"
        scanButton.BackgroundColor3 = Color3.fromRGB(80, 30, 140)
        scanButton.BackgroundTransparency = 0.2
        statusDot.BackgroundColor3 = Color3.fromRGB(120, 60, 200)
        buffer = {}
        updatePreview()
        print("[GG Code Redeem] Scanning stopped.")
    end
end

scanButton.MouseButton1Click:Connect(toggleScan)

modeButton.MouseButton1Click:Connect(function()
    mode = (mode % 4) + 1
    modeButton.Text = "MODE: " .. mode .. " GLOBAL MESSAGE" .. (mode > 1 and "S" or "")
    updatePreview()
    if scanning and #buffer >= mode then
        task.spawn(processBuffer)
    end
end)

local function manualRedeem()
    local code = previewBox.Text
    if code and code ~= "" then
        typeAndSubmitCode(code)
        print("[GG Code Redeem] Manually redeemed: " .. code)
        buffer = {}
        updatePreview()
    end
end

redeemButton.MouseButton1Click:Connect(manualRedeem)

previewBox.FocusLost:Connect(function(enter)
    if enter then manualRedeem() end
end)

if notifyRemote then
    notifyRemote.OnClientEvent:Connect(function(txt, ...)
        onAnnouncement(txt)
    end)
else
    warn("[GG Code Redeem] No notify remote - announcements not captured.")
end

print("[GG Code Redeem] Ready. Click 'START SCAN' to begin.")