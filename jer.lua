-- FairyAutoHarvester_vNext.client.lua
-- Fixes: (1) more reliable swinging (multi-path input + camera aim + short lock at target)
--        (2) robust rejoin in private servers (VIP/reserved/friend PS) w/ multiple fallbacks
-- Also: small UI polish + faster worker cadence.

---------------- Services ----------------
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local CoreGui = game:GetService('CoreGui')
local Workspace = game:GetService('Workspace')
local PPS = game:GetService('ProximityPromptService')
local TeleportService = game:GetService('TeleportService')
local UserInputService = game:GetService('UserInputService')

local LP = Players.LocalPlayer

---------------- Config ----------------
local Y_OFFSET = 3.25 -- just a few studs above the fairy
local FAIRY_OBJECTTEXT = 'fairy' -- case-insensitive
local SWING_BURST = 8 -- a few extra swings to increase reliability
local SWING_GAP = 0.08 -- slightly quicker cadence
local LOCK_SECONDS = 0.85 -- keep player pinned during swings to prevent drift/void

-- ===== Self-reexec config (local file / remote URL) =====
local SELF_FILE = "FairyAutoHarvester_vNext.client.lua" -- set if you save this script locally
local SELF_URL  = "https://raw.githubusercontent.com/fazeclansuppor-source/thingymajigy/refs/heads/main/jer.lua"  -- optional: raw URL to your loader/script (GitHub raw, etc.)

local function hasFS()
    return typeof(readfile)=="function" and typeof(isfile)=="function" and typeof(loadstring)=="function"
end

local function getQOT()
    -- supports many executors
    return (syn and syn.queue_on_teleport)
        or (queue_on_teleport)      -- KRNL / Fluxus / etc.
        or (fluxus and fluxus.queue_on_teleport)
        or (identifyexecutor and nil) -- placeholder; some execs lack QOT
end

local function queueSelfOnTeleport()
    local qot = getQOT()
    if not qot then
        warn("[FairyAutoHarvester] queue_on_teleport not available; consider autoexec.")
        return
    end

    local loader
    if SELF_URL and #SELF_URL > 0 then
        -- Remote first (recommended)
        loader = ("local ok,err=pcall(function() loadstring(game:HttpGet(%q))() end) if not ok then warn('[FAH queued] remote failed:',err) end")
                 :format(SELF_URL)
    elseif hasFS() and SELF_FILE and #SELF_FILE > 0 and isfile(SELF_FILE) then
        -- Local fallback
        loader = ("local ok,err=pcall(function() loadstring(readfile(%q))() end) if not ok then warn('[FAH queued] local failed:',err) end")
                 :format(SELF_FILE)
    else
        warn("[FairyAutoHarvester] Nothing to queue (set SELF_URL or ensure "..tostring(SELF_FILE).." exists).")
        return
    end

    qot(loader)
    print("[FairyAutoHarvester] queued loader for teleport")
end

-- Also queue when any teleport starts (covers server hops initiated by the game)
Players.LocalPlayer.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started then
        queueSelfOnTeleport()
    end
end)

---------------- Single instance ----------------
do
    local old = CoreGui:FindFirstChild('FairyAutoHarvesterUI')
    if old then
        old:Destroy()
    end
end

---------------- Helpers ----------------
local function getHRP()
    local char = LP.Character or LP.CharacterAdded:Wait()
    return char:WaitForChild('HumanoidRootPart', 5),
        char:FindFirstChildOfClass('Humanoid'),
        char
end

local function toPartOrModel(x)
    if not x then
        return nil
    end
    if x:IsA('BasePart') then
        return x
    end
    if x:IsA('Model') then
        return x.PrimaryPart or x:FindFirstChildWhichIsA('BasePart')
    end
    return x:FindFirstAncestorWhichIsA('BasePart')
end

local function zeroVel(hrp, hum)
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        if hum then
            hum:Move(Vector3.new(), true)
        end
    end)
end

local function aimCameraAt(part)
    local cam = Workspace.CurrentCamera
    if not (cam and part) then
        return
    end
    local look = (part.Position - cam.CFrame.Position).Unit
    local dist = (part.Position - cam.CFrame.Position).Magnitude
    if dist > 3 then
        cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + look)
    end
end

local function lockAtTarget(part, seconds)
    local hrp, hum = getHRP()
    if not (hrp and part) then
        return
    end
    local targetCF = part.CFrame + Vector3.new(0, Y_OFFSET, 0)
    zeroVel(hrp, hum)
    hrp.CFrame = targetCF

    -- keep the character pinned in place very briefly while we swing
    local t0 = os.clock()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if (os.clock() - t0) > seconds then
            if conn then
                conn:Disconnect()
            end
            return
        end
        zeroVel(hrp, hum)
        hrp.CFrame = targetCF
    end)
end

local function safeTP(target)
    local hrp, hum = getHRP()
    if not hrp or not target then
        return
    end
    local p = toPartOrModel(target)
    if not p then
        return
    end
    zeroVel(hrp, hum)
    hrp.CFrame = p.CFrame + Vector3.new(0, Y_OFFSET, 0)
end

-- net finder / equipper
local function looksLikeFairyNet(tool)
    if not tool or not tool:IsA('Tool') then
        return false
    end
    if tool:GetAttribute('FairyNet') == true then
        return true
    end
    if tool:FindFirstChild('FairyNetV2Handler', true) then
        return true
    end
    local n = string.lower(tool.Name)
    return (n:find('fairy') ~= nil) and (n:find('net') ~= nil)
end

local function findNetToolAnywhere()
    local _, _, char = getHRP()
    local backpack = LP:FindFirstChildOfClass('Backpack')
        or LP:FindFirstChild('Backpack')
    local function scan(container)
        if not container then
            return nil
        end
        for _, t in ipairs(container:GetChildren()) do
            if looksLikeFairyNet(t) then
                return t
            end
        end
        return nil
    end
    return scan(char) or scan(backpack)
end

local function ensureNetEquipped(timeout)
    timeout = timeout or 3.0
    local hrp, hum, char = getHRP()
    local t0 = os.clock()
    repeat
        local tool = findNetToolAnywhere()
        if tool then
            if tool.Parent ~= char and hum then
                pcall(function()
                    hum:EquipTool(tool)
                end)
            end
            if tool.Parent ~= char then
                pcall(function()
                    tool.Parent = char
                end)
            end
            if tool.Parent == char then
                return tool
            end
        end
        RunService.Heartbeat:Wait()
    until (os.clock() - t0) > timeout
    return nil
end

-- prompts (we DO NOT trigger them)
local function isFairyPrompt(prompt)
    return tostring(prompt.ObjectText or ''):lower() == FAIRY_OBJECTTEXT
end

local function anchorFromPrompt(prompt)
    return (
        prompt
        and prompt.Parent
        and (prompt.Parent:FindFirstAncestorOfClass('Model') or prompt.Parent)
    )
end

local function findPromptUnder(inst)
    if not inst then
        return nil
    end
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA('ProximityPrompt') and isFairyPrompt(d) then
            return d
        end
    end
    return nil
end

local function temporarilyDisablePrompt(anchor, dur)
    local p = findPromptUnder(anchor)
    if not p then
        return
    end
    local old = p.Enabled
    p.Enabled = false
    task.delay(dur or 1.25, function()
        if p then
            p.Enabled = old
        end
    end)
end

-- swing only (no E) — more robust via multiple inputs + aim + lock
local function swingNetAt(anchor)
    local tool = ensureNetEquipped(2.5)
    if not tool then
        return false, 'no Fairy Net found'
    end

    local part = toPartOrModel(anchor)
    if not part then
        return false, 'no target part'
    end

    temporarilyDisablePrompt(anchor, SWING_BURST * SWING_GAP + 0.5)

    -- lock and aim to improve hit registration
    aimCameraAt(part)
    lockAtTarget(part, LOCK_SECONDS)

    local vim = game:FindService('VirtualInputManager')
    local vuser = game:FindService('VirtualUser')
    local cam = Workspace.CurrentCamera

    for _ = 1, SWING_BURST do
        -- Path A: Tool:Activate
        pcall(function()
            tool:Activate()
        end)

        -- Path B: mouse click via VIM
        if vim and cam then
            local vp = cam.ViewportSize
            local x, y = math.floor(vp.X / 2), math.floor(vp.Y / 2)
            pcall(function()
                vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
                vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
            end)
        end

        -- Path C: VirtualUser fallback (some executors prefer this)
        if vuser then
            pcall(function()
                vuser:CaptureController()
                vuser:ClickButton1(Vector2.new())
            end)
        end

        RunService.Heartbeat:Wait() -- frame-accurate pacing
        task.wait(SWING_GAP)
    end
    return true
end

---------------- State ----------------
local Anchors = {}
local AnchorSet = setmetatable({}, { __mode = 'k' })
local AnchorCons = {}
local Queue, InQueue = {}, setmetatable({}, { __mode = 'k' })
local workerRunning = false
local autoTP, autoSwing, autoRejoin = true, true, false

---------------- GUI (clean layout) ----------------
local gui = Instance.new('ScreenGui')
gui.Name = 'FairyAutoHarvesterUI'
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.Parent = CoreGui

local card = Instance.new('Frame')
card.Name = 'Card'
card.Size = UDim2.fromOffset(360, 190)
card.Position = UDim2.new(0.5, -180, 0.22, -95)
card.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
card.Active, card.Draggable = true, true
card.Parent = gui
Instance.new('UICorner', card).CornerRadius = UDim.new(0, 12)
local stroke = Instance.new('UIStroke')
stroke.Color = Color3.fromRGB(60, 65, 85)
stroke.Thickness = 1
stroke.Parent = card
local pad = Instance.new('UIPadding')
pad.PaddingTop = UDim.new(0, 10)
pad.PaddingBottom = UDim.new(0, 10)
pad.PaddingLeft = UDim.new(0, 12)
pad.PaddingRight = UDim.new(0, 12)
pad.Parent = card

local vlist = Instance.new('UIListLayout')
vlist.Parent = card
vlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
vlist.VerticalAlignment = Enum.VerticalAlignment.Top
vlist.Padding = UDim.new(0, 8)
vlist.SortOrder = Enum.SortOrder.LayoutOrder

local header = Instance.new('Frame')
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 26)
header.Parent = card

local hpad = Instance.new('UIPadding')
hpad.PaddingLeft = UDim.new(0, 4)
hpad.PaddingRight = UDim.new(0, 4)
hpad.Parent = header

local title = Instance.new('TextLabel')
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.Text = 'Fairy Auto-Harvester'
title.TextSize = 16
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.TextXAlignment = Enum.TextXAlignment.Center
title.Size = UDim2.new(1, -28, 1, 0)
title.Parent = header

local close = Instance.new('TextButton')
close.Text = 'X'
close.Font = Enum.Font.Gotham
close.TextSize = 14
close.TextColor3 = Color3.fromRGB(230, 230, 230)
close.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
close.Size = UDim2.fromOffset(24, 24)
close.Position = UDim2.new(1, -24, 0.5, -12)
close.Parent = header
Instance.new('UICorner', close).CornerRadius = UDim.new(0, 6)
Instance.new('UIStroke', close).Color = Color3.fromRGB(60, 65, 85)
close.MouseButton1Click:Connect(function()
    if gui.Parent then
        gui:Destroy()
    end
end)

local statusLbl = Instance.new('TextLabel')
statusLbl.BackgroundTransparency = 1
statusLbl.Font = Enum.Font.Gotham
statusLbl.Text = 'Status: idle'
statusLbl.TextSize = 12
statusLbl.TextColor3 = Color3.fromRGB(170, 175, 190)
statusLbl.Size = UDim2.new(1, -8, 0, 18)
statusLbl.Parent = card

local countLbl = Instance.new('TextLabel')
countLbl.BackgroundTransparency = 1
countLbl.Font = Enum.Font.GothamBold
countLbl.Text = 'Detected fairies: 0'
countLbl.TextSize = 13
countLbl.TextColor3 = Color3.fromRGB(200, 230, 200)
countLbl.Size = UDim2.new(1, -8, 0, 18)
countLbl.Parent = card

-- Row of equal-width toggles
local row = Instance.new('Frame')
row.BackgroundTransparency = 1
row.Size = UDim2.new(1, 0, 0, 40)
row.Parent = card

local grid = Instance.new('UIGridLayout')
grid.Parent = row
grid.CellPadding = UDim2.new(0, 8, 0, 0)
grid.FillDirection = Enum.FillDirection.Horizontal
grid.FillDirectionMaxCells = 3
grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
grid.VerticalAlignment = Enum.VerticalAlignment.Center
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.CellSize = UDim2.new(1 / 3, -8, 0, 36)

local function mkToggle(textOn, textOff, startOn, onChange)
    local b = Instance.new('TextButton')
    b.Text = startOn and textOn or textOff
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.TextColor3 = Color3.new(1, 1, 1)
    b.BackgroundColor3 = startOn and Color3.fromRGB(65, 160, 85)
        or Color3.fromRGB(160, 90, 60)
    b.Parent = row
    Instance.new('UICorner', b).CornerRadius = UDim.new(0, 8)
    Instance.new('UIStroke', b).Color = Color3.fromRGB(60, 65, 85)
    b.MouseButton1Click:Connect(function()
        local on = not (b.Text == textOn)
        b.Text = on and textOn or textOff
        b.BackgroundColor3 = on and Color3.fromRGB(65, 160, 85)
            or Color3.fromRGB(160, 90, 60)
        onChange(on)
    end)
    return b
end

mkToggle('Auto-TP: ON', 'Auto-TP: OFF', true, function(on)
    autoTP = on
end)
mkToggle('Auto Swing: ON', 'Auto Swing: OFF', true, function(on)
    autoSwing = on
end)
mkToggle('Auto Rejoin: ON', 'Auto Rejoin: OFF', false, function(on)
    autoRejoin = on
end)

local foot = Instance.new('TextLabel')
foot.BackgroundTransparency = 1
foot.Font = Enum.Font.Gotham
foot.Text = ('Y offset: %.2f • No prompt interaction'):format(Y_OFFSET)
foot.TextSize = 12
foot.TextColor3 = Color3.fromRGB(160, 170, 190)
foot.Size = UDim2.new(1, -8, 0, 18)
foot.Parent = card

local function setStatus(t)
    statusLbl.Text = 'Status: ' .. t
end
local function setCount(n)
    countLbl.Text = ('Detected fairies: %d'):format(n)
end

---------------- Book-keeping ----------------
local function updateCountLabel()
    local i = 1
    while i <= #Anchors do
        local a = Anchors[i]
        if not (a and a.Parent) then
            local dead = table.remove(Anchors, i)
            AnchorSet[dead] = nil
            local cons = AnchorCons[dead]
            if cons then
                for _, c in ipairs(cons) do
                    pcall(function()
                        c:Disconnect()
                    end)
                end
            end
            AnchorCons[dead] = nil
        else
            i += 1
        end
    end
    setCount(#Anchors)
end

local function enqueue(anchor)
    if not anchor or InQueue[anchor] then
        return
    end
    InQueue[anchor] = true
    table.insert(Queue, anchor)
end

local function processAnchor(anchor)
    if not (anchor and anchor.Parent) then
        return
    end
    local part = toPartOrModel(anchor)
    if autoTP then
        setStatus('TP → ' .. (anchor.Name or 'fairy'))
        safeTP(part)
        task.wait(0.10)
    end
    if autoSwing then
        setStatus('swinging net')
        local ok, err = swingNetAt(anchor)
        if not ok then
            setStatus(err or 'swing failed')
        else
            setStatus('done')
        end
    else
        setStatus('queued (auto swing OFF)')
    end
end

----------------------------------------------------------------
-- REJOIN (fixed + mirrors your Kick() → Teleport() behavior)
----------------------------------------------------------------
local _rejoinInFlight = false
local _tpRetryCount = 0

local function getReservedAccessCode()
    local jd
    pcall(function()
        jd = LP:GetJoinData()
    end)
    if not jd then
        return nil
    end
    return jd.ReservedServerAccessCode
        or jd.AccessCode
        or (jd.TeleportOptions and jd.TeleportOptions.ReservedServerAccessCode)
end

local function rejoinNow(reason)
    if _rejoinInFlight then
        return
    end
    _rejoinInFlight = true
    setStatus('rejoining…')

    local placeId = game.PlaceId
    local jobId = tostring(game.JobId or '')
    local alone = #Players:GetPlayers() <= 1
    local inPS = tostring(game.PrivateServerId or '') ~= ''
        and tostring(game.PrivateServerId) ~= '0'

    -- 1) If we have a reserved/private server access code, prefer that.
    local accessCode = getReservedAccessCode()
    if accessCode then
    queueSelfOnTeleport()
        local ok = pcall(function()
            TeleportService:TeleportToPrivateServer(placeId, accessCode, { LP })
        end)
        if ok then
            return true
        end
    end

    -- 2) If not alone & we have a JobId, hop to the same instance (fastest).
    if not alone and #jobId > 5 then
    queueSelfOnTeleport()
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, jobId, LP)
        end)
        if ok then
            return true
        end
    end

    -- 3) If in a private server, plain Teleport usually routes back to the same PS when allowed.
    if inPS then
    queueSelfOnTeleport()
        local ok = pcall(function()
            TeleportService:Teleport(placeId, LP)
        end)
        if ok then
            return true
        end
    end

    -- 4) Last-resort: your known-good pattern (Kick → Teleport)
    pcall(function()
        LP:Kick('\nRejoining...')
    end)
    task.wait()
    queueSelfOnTeleport()
    pcall(function()
        TeleportService:Teleport(placeId, LP)
    end)
    return false
end

-- (Optional) Retry if Roblox throws a transient TeleportInitFailed
TeleportService.TeleportInitFailed:Connect(function(...)
    if not _rejoinInFlight then
        return
    end
    if _tpRetryCount >= 2 then
        return
    end
    _tpRetryCount += 1
    task.delay(0.75, function()
        rejoinNow('Retry')
    end)
end)

-- Expose manual entry point (console): _G.FairyAutoHarvester_RejoinNow()
_G.FairyAutoHarvester_RejoinNow = function()
    rejoinNow('Manual rejoin')
end

-- (Optional) Hotkey: Alt+R to rejoin now (delete if you don’t want it)
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then
        return
    end
    if
        input.KeyCode == Enum.KeyCode.R
        and UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
    then
        rejoinNow('Alt+R')
    end
end)

----------------------------------------------------------------
-- Worker
----------------------------------------------------------------
local function runWorker()
    if workerRunning then
        return
    end
    workerRunning = true
    setStatus('worker running')
    while #Queue > 0 do
        local a = table.remove(Queue, 1)
        InQueue[a] = nil
        pcall(processAnchor, a)
        task.wait(0.18)
    end
    workerRunning = false
    setStatus('idle')

    -- Auto rejoin when queue stays empty briefly
    if autoRejoin then
        local t0 = os.clock()
        while (os.clock() - t0) < 0.75 do
            if #Queue > 0 then
                return
            end
            RunService.Heartbeat:Wait()
        end
        -- mirror your snippet's logic:
        -- if alone => Kick + Teleport(place)
        -- else      => TeleportToPlaceInstance(place, jobId)
        rejoinNow('Auto rejoin')
    end
end

local function kickWorker()
    if not workerRunning and #Queue > 0 then
        task.defer(function()
            RunService.Heartbeat:Wait() -- allow bursts to coalesce
            if not workerRunning and #Queue > 0 then
                runWorker()
            end
        end)
    end
end

local function trackAnchor(anchor)
    if not anchor or AnchorSet[anchor] then
        return
    end
    AnchorSet[anchor] = true
    table.insert(Anchors, anchor)
    AnchorCons[anchor] = AnchorCons[anchor] or {}
    table.insert(
        AnchorCons[anchor],
        anchor.AncestryChanged:Connect(function(_, parent)
            if parent == nil then
                updateCountLabel()
            end
        end)
    )
    updateCountLabel()
    enqueue(anchor)
    kickWorker()
end

---------------- Detection (existing + new) ----------------
local function attachPromptWatchers(prompt)
    local function check()
        if prompt.Enabled and isFairyPrompt(prompt) then
            local a = anchorFromPrompt(prompt)
            if a then
                trackAnchor(a)
            end
        end
    end
    check()
    prompt:GetPropertyChangedSignal('Enabled'):Connect(check)
    prompt:GetPropertyChangedSignal('ObjectText'):Connect(check)
end

-- initial pass (prompts only)
for _, inst in ipairs(Workspace:GetDescendants()) do
    if inst:IsA('ProximityPrompt') then
        attachPromptWatchers(inst)
    end
end
kickWorker() -- start immediately if initial scan queued anything

-- live hooks
Workspace.DescendantAdded:Connect(function(obj)
    if obj:IsA('ProximityPrompt') then
        attachPromptWatchers(obj)
    end
end)

PPS.PromptShown:Connect(function(prompt)
    if isFairyPrompt(prompt) then
        local a = anchorFromPrompt(prompt)
        if a then
            trackAnchor(a)
        end
    end
end)

print(
    '[FairyAutoHarvester] vNext: stronger swing + PS rejoin fallbacks loaded.'
)
