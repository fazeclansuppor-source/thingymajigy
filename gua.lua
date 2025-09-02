-- GAG HUB | v1.5.5 (+ World & Scripts tabs)
-- Adds:
--  • World tab: Vibrant Grass Overlay (toggle) and Beach (Build/Clear/Print)
--  • Scripts tab: "Load Infinite Yield" button (safe pcall + multi-fetch fallback)
-- Keeps: toast, RightCtrl minimize/restore, 0.6s fade, slider clamp, player utils, plant collector.

local Players            = game:GetService("Players")
local CoreGui            = game:GetService("CoreGui")
local TweenService       = game:GetService("TweenService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local RunService         = game:GetService("RunService")
local Workspace          = game:GetService("Workspace")
local LocalPlayer        = Players.LocalPlayer

-- ============================== PERFORMANCE OPTIMIZATION =====================
-- Pre-cache frequently used data to avoid repeated lookups
local CACHE = {
    playerName = LocalPlayer.Name,
    playerFarm = nil,
    plantsFolder = nil,
    lastFarmScan = 0,
    farmScanInterval = 5, -- seconds between farm rescans
}

-- Farm scan controller for teardown
local FARM_MON = { running = true, thread = nil }

-- Debug mode variable (defined early)
local DEBUG_MODE = false  -- default off for performance; toggle via UI if needed

-- Initialize farm cache in background
FARM_MON.thread = task.spawn(function()
    local function findPlayerFarm()
        print("DEBUG: Searching for farm belonging to:", CACHE.playerName)
        local farm = Workspace:FindFirstChild("Farm")
        if not farm then 
            print("DEBUG: No Farm container found in Workspace")
            return nil 
        end
        
        -- NEW APPROACH: Look for the player's farm more directly
        -- Check for a farm that contains the player's name and has the right structure
        local playerFarm = farm:FindFirstChild(CACHE.playerName)
        if playerFarm then
            local important = playerFarm:FindFirstChild("Important")
            if important and important:FindFirstChild("Plants_Physical") then
                print("DEBUG: Found player farm by direct name match:", playerFarm.Name)
                return playerFarm
            end
        end
        
        -- If direct name doesn't work, look for ownership
        print("DEBUG: No direct name match, checking all farms for ownership...")
        for _, child in ipairs(farm:GetChildren()) do
            if child:IsA("Model") or child:IsA("Folder") then
                -- Check if this farm has the right structure and belongs to the player
                local important = child:FindFirstChild("Important")
                if important then
                    local plantsPhysical = important:FindFirstChild("Plants_Physical")
                    local data = important:FindFirstChild("Data")
                    
                    if plantsPhysical and data then
                        local owner = data:FindFirstChild("Owner")
                        if owner and owner.Value == CACHE.playerName then
                            print("DEBUG: Found owned farm with correct structure:", child.Name)
                            return child
                        elseif owner then
                            print("DEBUG: Farm", child.Name, "belongs to:", owner.Value)
                        end
                    end
                end
            end
        end
        
        print("DEBUG: No valid player farm found")
        return nil
    end
    
    -- Wait a moment for the game to load
    task.wait(2)
    if not FARM_MON.running then return end
    
    -- Initial farm discovery
    CACHE.playerFarm = findPlayerFarm()
    if CACHE.playerFarm then
        local important = CACHE.playerFarm:FindFirstChild("Important")
        if important then
            CACHE.plantsFolder = important:FindFirstChild("Plants_Physical")
            if CACHE.plantsFolder then
                print("DEBUG: Successfully cached player farm:", CACHE.playerFarm.Name)
                print("DEBUG: Plants folder found with", #CACHE.plantsFolder:GetChildren(), "children")
            else
                print("DEBUG: No Plants_Physical folder found in", CACHE.playerFarm.Name)
            end
        end
    else
        print("DEBUG: Failed to find player farm")
    end
    
    -- Periodic refresh in background
    while FARM_MON.running do
        task.wait(CACHE.farmScanInterval)
        if not FARM_MON.running then break end
        if not CACHE.playerFarm or not CACHE.playerFarm.Parent then
            print("DEBUG: Re-scanning for player farm...")
            CACHE.playerFarm = findPlayerFarm()
            if CACHE.playerFarm then
                local important = CACHE.playerFarm:FindFirstChild("Important")
                if important then
                    CACHE.plantsFolder = important:FindFirstChild("Plants_Physical")
                end
            end
        end
    end
end)

-- ============================== HARVEST CONFIG ===============================
local HARVEST = {
    -- Broaden discovery - added more specific crop tags
    PLANT_TAGS = {"Plant","Crop","Harvestable","CollectPrompt","HarvestPrompt","Seed","Tree","Fruit","Berry","Vegetable","Flower","Carrot","Pineapple","Tomato","Potato","Corn","Wheat"},
    PLANTS_FOLDERS = {"Plants","Crops","Garden","Farm","Seeds","Trees","Fruits","Berries","Vegetables","Flowers","Plot","Plots","Plants_Physical","Carrots","Pineapples","Tomatoes","Potatoes"},

    -- Ownership signals to try (attrs + ObjectValues)
    OWNER_ATTRS={"OwnerUserId","OwnerId","PlotOwner","UserId"},
    OWNER_OBJECTVALS={"Owner","PlotOwner","Player"},

    -- "Is ready" signals
    READY_ATTRS_BOOL={"Ready","IsRipe","HarvestReady","Mature","Grown"},
    READY_ATTRS_TEXT={"Stage","State","Growth","Status"},
    -- compare lowercase; spaces removed (e.g. "fullygrown")
    READY_TEXT_SET={ripe=true,mature=true,harvest=true,ready=true,grown=true,fullygrown=true,harvestable=true},

    -- Remote names + arg shapes (unchanged)
    REMOTE_NAMES={"Harvest","Collect","Pickup","Gather","HarvestPlant","CollectPlant"},
    ARG_VARIANTS=function(plant, player)
        return {
            {plant},
            {plant, player},
            {plant, true},
            {plant, player, true},
            {player, plant},
            {plant.Name},
            {plant:GetAttribute("Id")},
            {plant:GetAttribute("ID")},
            {true, plant},
            {},
        }
    end,
    MAX_PER_TICK=3,  -- Reduced from 5 to 3 for smoother performance
    COLLECTION_DELAY=0.05,  -- Reduced from 0.1 to 0.05 for faster individual collections
}

-- === MUTATION FILTER =========================================================
local MUTATION = {
    enabled = false,      -- if ON, only collect when plant's variant matches allow-list
    set = {},             -- lowercased allow-list (e.g., {shiny=true, golden=true})
    lastText = ""
}

-- Replace your existing getPlantVariantName with this:
local function getPlantVariantName(model)
    -- 1) String attributes commonly used by games
    local v = model:GetAttribute("Variant") or model:GetAttribute("Mutation")
           or model:GetAttribute("Type")    or model:GetAttribute("Rarity")
    if type(v) == "string" and #v > 0 then
        return string.lower(v)
    end

    -- 2) StringValue children
    local sv = model:FindFirstChild("Variant") or model:FindFirstChild("Mutation")
            or model:FindFirstChild("Type")    or model:FindFirstChild("Rarity")
    if sv and sv:IsA("StringValue") and sv.Value then
        return string.lower(sv.Value)
    end

    -- 3) Boolean attribute keys (e.g., Glimmering = true)
    for k, val in pairs(model:GetAttributes()) do
        if val == true then
            return string.lower(k)
        end
    end

    -- 4) ProximityPrompt surface text
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local texts = {d.ObjectText or "", d.ActionText or "", d.Name or ""}
            local combined = table.concat(texts, " ")
            if #combined:gsub("%s","") > 0 then
                return string.lower(combined)
            end
        end
    end

    -- 5) Model name fallback
    return string.lower(model.Name or "")
end

-- Replace your existing hasWantedMutation with this:
local function hasWantedMutation(model)
    if not MUTATION.enabled then
        print("DEBUG: Mutation filter disabled, accepting", model.Name)
        return true
    end
    if not next(MUTATION.set) then
        print("DEBUG: No mutations in filter set, rejecting", model.Name)
        return false
    end

    -- Build a searchable text blob from multiple sources
    local blob = {}
    local function add(s) if typeof(s)=="string" and #s>0 then blob[#blob+1] = string.lower(s) end end

    -- A) primary sources
    add(getPlantVariantName(model))
    add(model.Name)

    -- B) prompt texts
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            add(d.ObjectText); add(d.ActionText); add(d.Name)
        end
    end

    -- C) NEW: attribute names and values (catch boolean mutation flags)
    for k, val in pairs(model:GetAttributes()) do
        if val == true then add(k) end
        if typeof(val)=="string" and #val>0 then add(k); add(val) end
    end

    -- D) NEW: FX evidence (Glimmering adds tag "Cleanup_Glimmering")
    for _, d in ipairs(model:GetDescendants()) do
        if CollectionService:HasTag(d, "Cleanup_Glimmering") then
            add("glimmering")
            break
        end
    end

    local text = table.concat(blob, " ")
    print('DEBUG: Checking mutations for', model.Name, '- text blob: "' .. text .. '"')

    if #text == 0 then
        print("DEBUG: No text found for mutation check, rejecting", model.Name)
        return false
    end

    for token,_ in pairs(MUTATION.set) do
        if string.find(text, token, 1, true) then
            print("DEBUG: Found mutation", token, "in", model.Name, "- ACCEPTING")
            return true
        end
    end

    print("DEBUG: No wanted mutations found in", model.Name, "- REJECTING")
    local mutationList = {}
    for token,_ in pairs(MUTATION.set) do table.insert(mutationList, token) end
    print("DEBUG: Looking for mutations:", table.concat(mutationList, ", "))
    return false
end

-- THEME -----------------------------------------------------------------------
local THEME = {
    BG1=Color3.fromRGB(24,26,32), BG2=Color3.fromRGB(32,35,43), BG3=Color3.fromRGB(38,41,50),
    CARD=Color3.fromRGB(30,33,40), ACCENT=Color3.fromRGB(230,72,72),
    TEXT=Color3.fromRGB(220,221,222), MUTED=Color3.fromRGB(171,178,191), BORDER=Color3.fromRGB(64,70,85),
}
local FONTS={H=Enum.Font.GothamSemibold,B=Enum.Font.Gotham,HB=Enum.Font.GothamBold}
local FADE_DUR=0.6

-- Light "glass" look: baseline opacities per theme layer
local OPACITY = {
    -- Lower values = more opaque; keep subtle glass without see-through
    BG1 = 0.02,
    BG2 = 0.04,
    BG3 = 0.06,
    CARD = 0.05,
}

local function sameColor(a,b)
    if not a or not b then return false end
    local ax,ay,az = a.R, a.G, a.B
    local bx,by,bz = b.R, b.G, b.B
    local eps = 1/255
    return math.abs(ax-bx) < eps and math.abs(ay-by) < eps and math.abs(az-bz) < eps
end

local function applyGlassLook(root)
    local function baseOpacityFor(c)
        if sameColor(c, THEME.BG1) then return OPACITY.BG1 end
        if sameColor(c, THEME.BG2) then return OPACITY.BG2 end
        if sameColor(c, THEME.BG3) then return OPACITY.BG3 end
        if sameColor(c, THEME.CARD) then return OPACITY.CARD end
        return nil
    end
    for _,d in ipairs(root:GetDescendants()) do
        if d:IsA("Frame") or d:IsA("ScrollingFrame") or d:IsA("TextBox") or d:IsA("TextButton") then
            local base = baseOpacityFor(d.BackgroundColor3)
            if base then
                d.BackgroundTransparency = base
            end
        end
    end
end

-- UTIL ------------------------------------------------------------------------
local function mk(class, props, parent) local o=Instance.new(class); for k,v in pairs(props or {}) do o[k]=v end; if parent then o.Parent=parent end; return o end
local function corner(p,r) mk("UICorner",{CornerRadius=UDim.new(0,r or 8)},p) end
local function stroke(p,t,c) mk("UIStroke",{Thickness=t or 1,Color=c or THEME.BORDER,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},p) end
local function pad(p,t,r,b,l) mk("UIPadding",{PaddingTop=UDim.new(0,t or 0),PaddingRight=UDim.new(0,r or 0),PaddingBottom=UDim.new(0,b or 0),PaddingLeft=UDim.new(0,l or 0)},p) end
local function vlist(p,px) return mk("UIListLayout",{Padding=UDim.new(0,px or 8),SortOrder=Enum.SortOrder.LayoutOrder},p) end
local function hover(btn,on,off)
    btn.MouseEnter:Connect(function() TweenService:Create(btn,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),on):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),off):Play() end)
end

-- Global registry for service-level connections (for teardown)
local GLOBAL_CONNS = {}
local function trackConn(conn)
    table.insert(GLOBAL_CONNS, conn)
    return conn
end

-- ===== Robust fade (snapshot AFTER building UI) ==============================
local OrigT = setmetatable({}, {__mode="k"})
local function snapshotTransparency(inst)
    OrigT = {}
    local function scan(node)
        local rec={}
        if node:IsA("Frame") or node:IsA("ScrollingFrame") then rec.bt=node.BackgroundTransparency end
        if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
            rec.bt=node.BackgroundTransparency; rec.tt=node.TextTransparency
        end
        if node:IsA("ImageLabel") or node:IsA("ImageButton") then
            rec.bt=node.BackgroundTransparency; rec.it=node.ImageTransparency
        end
        if node:IsA("UIStroke") then rec.st=node.Transparency end
        if next(rec) then OrigT[node]=rec end
        for _,c in ipairs(node:GetChildren()) do scan(c) end
    end
    scan(inst)
end
local function tweenTo(inst, dur, to1)
    for obj,rec in pairs(OrigT) do
        local props={}
        if rec.bt~=nil then props.BackgroundTransparency = (to1 and 1 or rec.bt) end
        if rec.tt~=nil then props.TextTransparency       = (to1 and 1 or rec.tt) end
        if rec.it~=nil then props.ImageTransparency      = (to1 and 1 or rec.it) end
        if rec.st~=nil then props.Transparency           = (to1 and 1 or rec.st) end
        if next(props) then TweenService:Create(obj, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play() end
    end
end

local function tolower(s) return typeof(s)=="string" and string.lower(s) or s end

local function textLooksHarvesty(s)
    s = tolower(s or "")
    return s:find("harvest") or s:find("collect") or s:find("gather") or s:find("pick")
end

local function nearestModel(inst)
    if not inst then return nil end
    if inst:IsA("Model") then return inst end
    return inst:FindFirstAncestorOfClass("Model")
end

-- ============================== COLLECTOR CORE ===============================
local remoteCache={}
local remoteCacheConn=nil
local function cacheReplicatedRemotes()
    remoteCache={}
    local function add(r) remoteCache[r.Name]=remoteCache[r.Name] or {}; table.insert(remoteCache[r.Name],r) end
    for _,d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            for _,nm in ipairs(HARVEST.REMOTE_NAMES) do if d.Name==nm then add(d) break end end
        end
    end
end
cacheReplicatedRemotes()
remoteCacheConn = ReplicatedStorage.DescendantAdded:Connect(function(d)
    if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
        for _,nm in ipairs(HARVEST.REMOTE_NAMES) do if d.Name==nm then remoteCache[nm]=remoteCache[nm] or {}; table.insert(remoteCache[nm], d) break end end
    end
end)

-- 🔒 STRICT ownership check
local function ownsPlant(player, plant: Instance): boolean
    if not plant or not plant.Parent then return false end

    -- A) Easiest & fastest: is the plant inside *your* farm/model?
    if CACHE.playerFarm and plant:IsDescendantOf(CACHE.playerFarm) then
        return true
    end
    if CACHE.plantsFolder and plant:IsDescendantOf(CACHE.plantsFolder) then
        return true
    end

    -- B) Common per-plant attributes (numbers or strings)
    local uid = plant:GetAttribute("OwnerUserId") or plant:GetAttribute("OwnerId") or plant:GetAttribute("UserId")
    if typeof(uid) == "number" and uid == player.UserId then return true end
    if typeof(uid) == "string" and tonumber(uid) == player.UserId then return true end

    -- C) Common ObjectValue/StringValue patterns on the model
    local sv = plant:FindFirstChild("Owner") or plant:FindFirstChild("PlotOwner") or plant:FindFirstChild("Player")
    if sv and sv:IsA("ObjectValue") and sv.Value == player then return true end
    if sv and sv:IsA("StringValue") and sv.Value == player.Name then return true end

    -- D) Game's "Important/Data" ownership (walk up once)
    local important = plant:FindFirstAncestor("Important")
    if important then
        local data = important:FindFirstChild("Data")
        if data then
            local owner = data:FindFirstChild("Owner")
            if owner then
                if owner:IsA("ObjectValue") and owner.Value == player then return true end
                if owner:IsA("StringValue") and owner.Value == player.Name then return true end
            end
            local ownerIdV = data:FindFirstChild("OwnerUserId") or data:FindFirstChild("OwnerId")
            if ownerIdV and tonumber(ownerIdV.Value) == player.UserId then return true end
        end
    end

    -- Debug rejected plants
    if DEBUG_MODE then
        print("[OWNERSHIP] REJECT:", plant:GetFullName(), "- not owned by", player.Name)
    end

    return false
end

-- (Removed erroneous duplicate getAllPlants implementation)

-- Ready: for "Grow a Garden" game, check if ProximityPrompt is enabled
local function isPlantReady(plant)
    -- For "Grow a Garden" game - check if ANY ProximityPrompt is enabled
    local foundAnyPrompt = false
    for _,pp in ipairs(plant:GetDescendants()) do
        if pp:IsA("ProximityPrompt") then
            foundAnyPrompt = true
            if pp.Enabled then
                return true
            end
        end
    end
    
    if foundAnyPrompt then
        return false
    end
    
    -- Fallback: Check boolean ready attributes
    for _,a in ipairs(HARVEST.READY_ATTRS_BOOL) do
        if plant:GetAttribute(a) == true then 
            return true 
        end
    end
    
    -- Fallback: Check text-based ready attributes
    for _,a in ipairs(HARVEST.READY_ATTRS_TEXT) do
        local v = plant:GetAttribute(a)
        if typeof(v)=="string" then
            local key = (v:gsub("%s","")):lower()
            if HARVEST.READY_TEXT_SET[key] then 
                return true 
            end
        end
    end
    
    return false
end

-- Discovery: Use cached farm data - only return plants from verified player farm
local function getAllPlants()
    local out = {}
    
    -- Ensure we have a valid cached plants folder
    if not CACHE.plantsFolder or not CACHE.plantsFolder.Parent then
        print("DEBUG: No valid plants folder cached for player:", CACHE.playerName)
        return out
    end
    
    -- Double-check we still have the right farm
    if not CACHE.playerFarm or not CACHE.playerFarm.Parent then
        print("DEBUG: Cached player farm is invalid")
        CACHE.plantsFolder = nil
        return out
    end
    
    print("DEBUG: Collecting plants from verified player farm:", CACHE.playerFarm.Name)
    
    -- Collect all plants from the player's Plants_Physical folder
    for _, child in ipairs(CACHE.plantsFolder:GetChildren()) do
        if child:IsA("Model") then
            table.insert(out, child)
            print("DEBUG: Added plant from player farm:", child.Name)
        end
    end
    
    print("DEBUG: Total plants collected from player farm:", #out)
    
    -- If we didn't find any plants, something might be wrong
    if #out == 0 then
        print("DEBUG: WARNING - No plants found in player's Plants_Physical folder")
        print("DEBUG: Plants folder children count:", #CACHE.plantsFolder:GetChildren())
        print("DEBUG: Farm name:", CACHE.playerFarm.Name)
    end
    
    return out
end
local function tryRemotesForPlant(plant,player)
    if not ownsPlant(player, plant) then return false end
    local list={}
    for _,d in ipairs(plant:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            for _,nm in ipairs(HARVEST.REMOTE_NAMES) do if d.Name==nm then table.insert(list,d) break end end
        end
    end
    for _,nm in ipairs(HARVEST.REMOTE_NAMES) do if remoteCache[nm] then for _,r in ipairs(remoteCache[nm]) do table.insert(list,r) end end end
    for _,remote in ipairs(list) do
        for _,args in ipairs(HARVEST.ARG_VARIANTS(plant,player)) do
            if remote:IsA("RemoteEvent") then if pcall(function() remote:FireServer(unpack(args)) end) then return true end
            else if pcall(function() remote:InvokeServer(unpack(args)) end) then return true end end
        end
    end
    return false
end
local function tryExploitHelpers(plant)
    if not ownsPlant(LocalPlayer, plant) then return false end
    -- Use fireproximityprompt for "Grow a Garden" game
    for _,pp in ipairs(plant:GetDescendants()) do
        if pp:IsA("ProximityPrompt") and pp.Enabled then
            print("DEBUG: Found ProximityPrompt in", plant.Name, "- firing")
            local fpp = rawget(getfenv() or _G, "fireproximityprompt") or _G.fireproximityprompt
            if typeof(fpp)=="function" and pcall(fpp, pp) then 
                print("DEBUG: Successfully fired ProximityPrompt for", plant.Name)
                return true 
            end
        end
    end
    
    -- Fallback: ClickDetectors
    for _,cd in ipairs(plant:GetDescendants()) do
        if cd:IsA("ClickDetector") then
            print("DEBUG: Found ClickDetector in", plant.Name, "- firing")
            local fcd = rawget(getfenv() or _G, "fireclickdetector") or _G.fireclickdetector
            if typeof(fcd)=="function" and pcall(fcd, cd) then
                print("DEBUG: Successfully fired ClickDetector for", plant.Name)
                return true 
            end
        end
    end
    return false
end

local collecting=false
local function CollectAllPlants(toast)
    if collecting then if toast then toast("Collect already running…") end; return {ok=false,msg="busy"} end
    collecting=true
    local total,ready,collected,processed=0,0,0,0
    
    local allPlants = getAllPlants()
    
    for _,plant in ipairs(allPlants) do
        total+=1
        if isPlantReady(plant) and hasWantedMutation(plant) then
            ready+=1
            if tryRemotesForPlant(plant,LocalPlayer) or tryExploitHelpers(plant) then 
                collected+=1
            end
            -- Add delay after each collection attempt
            task.wait(HARVEST.COLLECTION_DELAY)
        end
        
        processed+=1
        -- Yield every few plants to prevent frame drops
        if processed % HARVEST.MAX_PER_TICK == 0 then 
            task.wait(0.1) -- Longer yield for performance
        end
    end
    collecting=false
    if toast then toast(("Collected %d / %d ready (of %d total)."):format(collected,ready,total)) end
    return {ok=true,total=total,ready=ready,collected=collected}
end

-- Prefer the game's Crops.Collect remote when available (fast, accurate, batched)
local function harvestViaCropsRemote(toast)
    local ge      = ReplicatedStorage:FindFirstChild("GameEvents")
    local crops   = ge and ge:FindFirstChild("Crops")
    local collect = crops and crops:FindFirstChild("Collect")
    if not (collect and collect:IsA("RemoteEvent")) then
        return false, 0 -- remote not found; let caller fall back
    end

    local uniq, targets = {}, {}

    local function addModel(m)
        if not m or uniq[m] then return end
        -- 🔒 NEW: only send *your* plants
        if not ownsPlant(LocalPlayer, m) then return end
        -- keep your mutation filter
        if MUTATION.enabled and not hasWantedMutation(m) then return end
        -- optional: skip obvious unready plants (server still validates)
        if not isPlantReady(m) then return end
        uniq[m] = true
        table.insert(targets, m)
    end

    -- 1) Prompts tagged by the game
    for _, pp in ipairs(CollectionService:GetTagged("CollectPrompt")) do
        if pp:IsA("ProximityPrompt") then addModel(nearestModel(pp)) end
    end

    -- 2) Any prompt that *sounds* like harvesting
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local txt = d.ActionText or d.ObjectText or d.Name
            if textLooksHarvesty(txt) then addModel(nearestModel(d)) end
        end
    end

    -- 3) Backup: your generic discovery
    for _, m in ipairs(getAllPlants()) do
        if isPlantReady(m) then addModel(m) end
    end

    if #targets == 0 then
        if toast then toast("No ready crops found (owned).") end
        return true, 0
    end

    -- Batch like the game's loop
    local sent = 0
    for i = 1, #targets, HARVEST.MAX_PER_TICK do
        local slice = {}
        for j = i, math.min(i + HARVEST.MAX_PER_TICK - 1, #targets) do
            slice[#slice+1] = targets[j]
        end
        local ok = pcall(function() collect:FireServer(slice) end)
        if ok then sent += #slice else warn("[Harvest] Crops.Collect batch failed") end
        task.wait()
    end

    if toast then toast(("Harvested %d crops (yours) via Crops.Collect"):format(sent)) end
    return true, sent
end

-- ============================== AUTO-HARVEST =================================
local AUTO = {
    enabled    = false,
    method     = "Wireless",   -- "None" | "Wireless" | "CFraming"
    interval   = 5.0,          -- increased to 5.0 seconds for better performance
    fireDelay  = 0.25,         -- increased delay for stability
    tweenSpeed = 1.0,          -- seconds of tween per ~100 studs (CFraming)
    _task      = nil,
    _busy      = false,
}

-- Sync debug mode with global variable
AUTO.debugMode = DEBUG_MODE

-- ============================== AUTO-SELL =================================
local AUTO_SELL = {
    enabled = false,
    _task = nil,
    _busy = false,
    sellLocation = nil, -- Will be set to sell NPC location
    messageConnection = nil, -- Connection for listening to messages
    playerGuiConn = nil,
    playerGuiDescendantConns = {},
    starterGuiSetCoreOriginal = nil,
}

-- 🔧 forward declaration so listeners capture this local (not _G)
local performAutoSell

-- Function to detect max inventory message
local function setupInventoryMessageListener()
    if AUTO_SELL.messageConnection then return end
    
    -- Listen for StarterGui messages (common way games show notifications)
    local function checkMessage(message)
        if not AUTO_SELL.enabled then return end
        
        local lowerMsg = string.lower(tostring(message))
        -- Look for the specific "Max backpack space! Go sell" message
        if string.find(lowerMsg, "max") and string.find(lowerMsg, "backpack") and string.find(lowerMsg, "space") then
            print("DEBUG: Detected max backpack message:", message)
            print("DEBUG: AUTO_SELL._busy status:", AUTO_SELL._busy)
            
            if not AUTO_SELL._busy then
                print("DEBUG: Starting auto-sell process...")
                task.defer(function()
                    local ok, err = pcall(performAutoSell)
                    if not ok then
                        warn("[AutoSell] performAutoSell error:", err)
                        AUTO_SELL._busy = false
                    end
                end)
            else
                print("DEBUG: Auto-sell already busy, skipping...")
            end
            return
        end
        
        -- Also check for other common inventory full phrases as backup
        if string.find(lowerMsg, "inventory") and (
           string.find(lowerMsg, "full") or 
           string.find(lowerMsg, "max") or 
           string.find(lowerMsg, "limit") or
           string.find(lowerMsg, "space")
        ) then
            print("DEBUG: Detected inventory full message:", message)
            print("DEBUG: AUTO_SELL._busy status:", AUTO_SELL._busy)
            
            if not AUTO_SELL._busy then
                print("DEBUG: Starting auto-sell process...")
                task.defer(function()
                    local ok, err = pcall(performAutoSell)
                    if not ok then
                        warn("[AutoSell] performAutoSell error:", err)
                        AUTO_SELL._busy = false
                    end
                end)
            else
                print("DEBUG: Auto-sell already busy, skipping...")
            end
        end
    end
    
    -- Hook into StarterGui SetCore messages
    local starterGui = game:GetService("StarterGui")
    AUTO_SELL.messageConnection = starterGui.CoreGuiChangedSignal:Connect(function(coreGuiType)
        if coreGuiType == Enum.CoreGuiType.Chat then
            -- Check for chat messages about inventory
            local success, lastMessage = pcall(function()
                local chat = starterGui:FindFirstChild("Chat")
                if chat then
                    -- Try to get recent chat messages
                    return chat
                end
            end)
        end
    end)
    
    -- Also listen for GUI notifications that might appear
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    
    -- Monitor for new notification GUIs
    local function monitorGui(gui)
        if gui:IsA("ScreenGui") then
            -- Monitor all descendant changes in this GUI
            local function onDescendantAdded(descendant)
                if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
                    -- Wait for text to load, then check multiple times as text might change
                    task.spawn(function()
                        for i = 1, 5 do
                            task.wait(0.1)
                            if descendant.Parent and descendant.Text then
                                checkMessage(descendant.Text)
                            end
                        end
                    end)
                end
            end
            
            local c = gui.DescendantAdded:Connect(onDescendantAdded)
            table.insert(AUTO_SELL.playerGuiDescendantConns, c)
            
            -- Check existing text elements immediately
            for _, descendant in ipairs(gui:GetDescendants()) do
                if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
                    checkMessage(descendant.Text)
                end
            end
            
            -- Also monitor for property changes on existing elements
            for _, descendant in ipairs(gui:GetDescendants()) do
                if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
                    local pc = descendant:GetPropertyChangedSignal("Text"):Connect(function()
                        checkMessage(descendant.Text)
                    end)
                    table.insert(AUTO_SELL.playerGuiDescendantConns, pc)
                end
            end
        end
    end
    
    -- Monitor existing GUIs
    for _, gui in ipairs(playerGui:GetChildren()) do
        monitorGui(gui)
    end
    
    -- Monitor new GUIs
    AUTO_SELL.playerGuiConn = playerGui.ChildAdded:Connect(monitorGui)
    
    -- Also hook into StarterGui notifications (alternative notification system)
    local starterGui = game:GetService("StarterGui")
    
    -- Listen for SetCore notifications
    if not AUTO_SELL.starterGuiSetCoreOriginal then AUTO_SELL.starterGuiSetCoreOriginal = starterGui.SetCore end
    local originalSetCore = AUTO_SELL.starterGuiSetCoreOriginal
    starterGui.SetCore = function(self, setting, data)
        if setting == "ChatMakeSystemMessage" or setting == "SendNotification" then
            if type(data) == "table" and data.Text then
                checkMessage(data.Text)
            elseif type(data) == "string" then
                checkMessage(data)
            end
        end
        return originalSetCore(self, setting, data)
    end
    
    print("DEBUG: Auto-sell message listener setup complete - monitoring for 'Max backpack space! Go sell' messages")
end

-- Function to find sell NPC location
local function findSellLocation()
    local npcs = Workspace:FindFirstChild("NPCS")
    if npcs then
        local steven = npcs:FindFirstChild("Steven")
        if steven then
            local hrp = steven:FindFirstChild("HumanoidRootPart")
            if hrp then
                AUTO_SELL.sellLocation = hrp.CFrame
                return hrp.CFrame
            end
        end
    end
    return nil
end

-- Function to teleport to sell location and back
performAutoSell = function()
    print("DEBUG: performAutoSell() called")
    
    if AUTO_SELL._busy then 
        print("DEBUG: performAutoSell() - already busy, returning")
        return false 
    end
    
    print("DEBUG: Setting busy state and starting sell process")
    AUTO_SELL._busy = true
    
    local character = LocalPlayer.Character
    if not character then 
        print("DEBUG: No character found")
        AUTO_SELL._busy = false
        return false 
    end
    
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
    if not humanoidRootPart then 
        print("DEBUG: No HumanoidRootPart found")
        AUTO_SELL._busy = false
        return false 
    end
    
    -- Store original position
    local originalPosition = humanoidRootPart.CFrame
    print("DEBUG: Stored original position:", originalPosition)
    
    -- Find sell location if not cached
    if not AUTO_SELL.sellLocation then
        print("DEBUG: Sell location not cached, finding it...")
        findSellLocation()
    end
    
    if not AUTO_SELL.sellLocation then
        print("DEBUG: Could not find sell NPC location")
        AUTO_SELL._busy = false
        return false
    end
    
    print("DEBUG: Auto-selling triggered by inventory full message - teleporting to sell NPC...")
    print("DEBUG: Sell location:", AUTO_SELL.sellLocation)
    
    -- Teleport to sell location
    local sellPosition = AUTO_SELL.sellLocation * CFrame.new(0, 0, -5) -- Slightly in front
    humanoidRootPart.CFrame = sellPosition
    print("DEBUG: Teleported to sell position:", sellPosition)
    
    -- Wait a moment for teleport to register
    task.wait(0.5)
    
    -- Fire sell remote
    print("DEBUG: Attempting to fire sell remote...")
    local success = pcall(function()
        local sellRemote = ReplicatedStorage:WaitForChild("GameEvents"):WaitForChild("Sell_Inventory")
        sellRemote:FireServer()
        print("DEBUG: Sell inventory remote fired successfully")
    end)
    
    if not success then
        print("DEBUG: Failed to fire sell remote")
    end
    
    -- Wait a moment for sell to process
    task.wait(1.0)
    
    -- Teleport back to original position
    humanoidRootPart.CFrame = originalPosition
    print("DEBUG: Auto-sell complete - returned to original position")
    
    AUTO_SELL._busy = false
    print("DEBUG: Reset busy state")
    return success
end

-- Auto-sell system (message-based)
local function startAutoSell(toast)
    if AUTO_SELL.enabled then return end
    AUTO_SELL.enabled = true
    if toast then toast("Auto-sell ON (message-triggered)") end
    
    -- Cache sell location on start
    findSellLocation()
    
    -- Setup message listener
    setupInventoryMessageListener()
end

local function stopAutoSell(toast)
    AUTO_SELL.enabled = false
    if toast then toast("Auto-sell OFF") end
    
    -- Disconnect message listener
    if AUTO_SELL.messageConnection then
        AUTO_SELL.messageConnection:Disconnect()
        AUTO_SELL.messageConnection = nil
    end
    
    AUTO_SELL._busy = false
end

-- ============================== AUTO-FAIRY =================================
local AUTO_FAIRY = {
    enabled = false,
    _task = nil,
    _busy = false,
    checkInterval = 5, -- Check every 5 seconds
}

-- ============================== AUTO-SHOP =================================
local AUTO_SHOP = {
    enabled = false,
    _task = nil,
    _busy = false,
    checkInterval = 10, -- Check every 10 seconds
    availableSeeds = {},
    selectedSeeds = {}, -- Changed back to array for multiple selection
    buyAll = false,     -- When true, ignore selections and buy all available seeds
    modeSelected = false, -- UI: Auto-buy selected toggle state
    modeAll = false,      -- UI: Auto-buy all toggle state
    stockFetcher = nil,   -- RemoteFunction to query stock if found
    currentStock = {},    -- Map: seedKey -> count
    buyDelay = 0.05,      -- Much faster delay between buy attempts (seconds)
    maxSpamPerSeed = 250, -- Safety cap when we cannot read stock; must be > max real stock
    maxConcurrent = 12,   -- Fire in bursts for speed; tune if server throttles
    maxConcurrentGlobal = 32, -- Global cap across all seeds
    logBuys = false,      -- Disable per-buy file writes for speed
    _inFlightGlobal = 0   -- runtime counter of global in-flight buy calls
}

-- ============================== AUTO-GEAR =================================
local AUTO_GEAR = {
    enabled = false,
    _task = nil,
    _busy = false,
    checkInterval = 10,
    availableGear = {},
    selectedGear = {},
    buyAll = false,
    modeSelected = false,
    modeAll = false,
    stockFetcher = nil,
    currentStock = {},
    buyDelay = 0.05,
    maxSpamPerItem = 100,
    maxConcurrent = 8,
    maxConcurrentGlobal = 24,
    logBuys = false,
    _inFlightGlobal = 0
}

-- Function to get list of glimmering plants in backpack (for tracking)
local function getGlimmeringPlantNames()
    local glimmeringPlants = {}
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return glimmeringPlants end
    
    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA("Tool") then
            local itemName = string.lower(item.Name)
            local isPlant = false
            
            -- Quick plant identification
            if item:GetAttribute("PlantType") or item:GetAttribute("CropType") or item:GetAttribute("SeedType") then
                isPlant = true
            end
            
            local plantKeywords = {"tomato", "carrot", "potato", "corn", "wheat", "apple", "orange", "grape", "strawberry", "berry", "seed", "flower", "fruit", "vegetable", "crop"}
            for _, keyword in ipairs(plantKeywords) do
                if string.find(itemName, keyword) then
                    isPlant = true
                    break
                end
            end
            
            if string.match(itemName, "%[.+%]%s*%w") then
                local afterBrackets = string.match(itemName, "%[.+%]%s*(.+)")
                if afterBrackets then
                    local toolWords = {"sword", "axe", "pickaxe", "shovel", "hammer", "tool", "weapon", "gear", "equipment", "staff", "wand", "bow", "gun"}
                    local isToolName = false
                    for _, toolWord in ipairs(toolWords) do
                        if string.find(afterBrackets, toolWord) then
                            isToolName = true
                            break
                        end
                    end
                    if not isToolName then
                        isPlant = true
                    end
                end
            end
            
            -- If it's a plant, check for glimmering
            if isPlant then
                local hasGlimmering = false
                
                if item:GetAttribute("Glimmering") == true then
                    hasGlimmering = true
                elseif string.find(itemName, "glimmering") then
                    hasGlimmering = true
                else
                    local allAttrs = item:GetAttributes()
                    for attrName, attrValue in pairs(allAttrs) do
                        if type(attrValue) == "string" then
                            local lowerAttr = string.lower(attrValue)
                            if string.find(lowerAttr, "glimmering") then
                                hasGlimmering = true
                                break
                            end
                        end
                    end
                end
                
                if hasGlimmering then
                    table.insert(glimmeringPlants, item.Name)
                end
            end
        end
    end
    
    return glimmeringPlants
end
-- Function to check if player has glimmering plant in backpack
local function hasGlimmeringInBackpack()

    local glimmeringPlants = getGlimmeringPlantNames()
    
    if #glimmeringPlants > 0 then
        return true
    else
        print("� NO GLIMMERING PLANTS FOUND")
    end
    
    print("=== BACKPACK CHECK END ===")
    return false
end

-- Function to submit to fairy fountain
local function submitToFairyFountain()
    if AUTO_FAIRY._busy then 
        return false 
    end
    
    AUTO_FAIRY._busy = true
    
    local success = pcall(function()
        local fairyRemote = ReplicatedStorage:WaitForChild("GameEvents"):WaitForChild("FairyService"):WaitForChild("SubmitFairyFountainAllPlants")
        fairyRemote:FireServer()
    end)
    
    if success then
        writefile("FairyDebug.txt", "\n[" .. os.date("%X") .. "] Submitted to fairy")
    end
    
    AUTO_FAIRY._busy = false
    return success
end

-- Auto-fairy submission system
local function startAutoFairy(toast)
    if AUTO_FAIRY.enabled then 
        return 
    end
    
    AUTO_FAIRY.enabled = true
    AUTO_FAIRY.lastSubmitted = false -- Track if we just submitted
    if toast then toast("Auto-Fairy ON - will submit when glimmering plant detected in backpack") end
    
    AUTO_FAIRY._task = task.spawn(function()
        local loopCount = 0
        while AUTO_FAIRY.enabled do
            local hasGlimmering = hasGlimmeringInBackpack()
            
            if hasGlimmering then
                if not AUTO_FAIRY.lastSubmitted then
                    -- Check if we have new plants that haven't been submitted
                    local currentGlimmeringPlants = getGlimmeringPlantNames()
                    local hasNewPlants = false
                    local newPlants = {}
                    
                    for _, plantName in ipairs(currentGlimmeringPlants) do
                        local alreadySubmitted = false
                        for _, submittedPlant in ipairs(AUTO_FAIRY.submittedPlants or {}) do
                            if submittedPlant == plantName then
                                alreadySubmitted = true
                                break
                            end
                        end
                        
                        if not alreadySubmitted then
                            hasNewPlants = true
                            table.insert(newPlants, plantName)
                        end
                    end
                    
                    if hasNewPlants then
                        local submissionSuccess = submitToFairyFountain()
                        if submissionSuccess then
                            if toast then toast("Submitted to fairy fountain!") end
                            
                            -- Initialize if needed and add all current glimmering plants to submitted list
                            if not AUTO_FAIRY.submittedPlants then AUTO_FAIRY.submittedPlants = {} end
                            for _, plantName in ipairs(currentGlimmeringPlants) do
                                table.insert(AUTO_FAIRY.submittedPlants, plantName)
                            end
                        end
                    end
                else
                    print("� GLIMMERING STILL PRESENT - already submitted, waiting for backpack to clear")
                end
            else
                print("� NO GLIMMERING PLANTS - clearing submitted plant list")
                AUTO_FAIRY.submittedPlants = {} -- Reset when backpack is clear
            end
            
            -- Always wait the same amount regardless of what happened
            task.wait(AUTO_FAIRY.checkInterval)
        end
    end)
end

local function stopAutoFairy(toast)
    AUTO_FAIRY.enabled = false
    AUTO_FAIRY.submittedPlants = {} -- Reset submission tracking
    AUTO_FAIRY.lastSubmitted = false -- Reset submission state
    AUTO_FAIRY._busy = false -- Reset busy state
    
    if AUTO_FAIRY._task then
        task.cancel(AUTO_FAIRY._task)
        AUTO_FAIRY._task = nil
    end
    
    if toast then toast("Auto-Fairy OFF") end
end

-- ============================== AUTO-SHOP FUNCTIONS =================================

-- Function to buy a specific seed
local function buySeed(seedKey)
    -- Respect a global in-flight limit to avoid server throttling
    while AUTO_SHOP._inFlightGlobal >= (AUTO_SHOP.maxConcurrentGlobal or 32) and AUTO_SHOP.enabled do
        task.wait(AUTO_SHOP.buyDelay or 0.05)
    end
    AUTO_SHOP._inFlightGlobal += 1
    local ok = pcall(function()
        local ge = ReplicatedStorage:WaitForChild("GameEvents")
        ge:WaitForChild("BuySeedStock"):FireServer("Tier 1", seedKey)
    end)
    AUTO_SHOP._inFlightGlobal = math.max(0, AUTO_SHOP._inFlightGlobal - 1)
    if AUTO_SHOP.logBuys then
        local line = (ok and "Bought" or "Failed") .. " (Tier 1) " .. tostring(seedKey)
        pcall(writefile, "ShopDebug.txt", "\n[" .. os.date("%X") .. "] " .. line)
    end
    return ok
end

-- Helpers: find a RemoteFunction that returns stock
local function _findSeedStockFetcher()
    local ge = ReplicatedStorage:FindFirstChild("GameEvents")
    if not ge then return nil end
    local best
    for _, d in ipairs(ge:GetDescendants()) do
        if d:IsA("RemoteFunction") then
            local nm = string.lower(d.Name)
            if (nm:find("stock") and (nm:find("seed") or nm:find("shop"))) or nm:find("getseedstock") or nm:find("getshopstock") then
                best = d; break
            end
        end
    end
    return best
end

local function _parseStockTable(res)
    -- Normalize into { [seedKey or name] = count }
    local out = {}
    if type(res) ~= "table" then return out end
    -- array of entries
    local isArray = (#res > 0)
    if isArray then
        for _, item in ipairs(res) do
            if type(item) == "table" then
                local name = item.key or item.Key or item.name or item.Name or item.seed or item.Seed
                local count = item.stock or item.Stock or item.left or item.Left or item.amount or item.Amount or item.count or item.Count
                if typeof(name) == "string" and typeof(count) == "number" then
                    out[name] = count
                end
            end
        end
    else
        -- dictionary
        for k, v in pairs(res) do
            if typeof(k) == "string" then
                if typeof(v) == "number" then
                    out[k] = v
                elseif type(v) == "table" then
                    local count = v.stock or v.Stock or v.left or v.Left or v.amount or v.Amount or v.count or v.Count
                    if typeof(count) == "number" then out[k] = count end
                end
            end
        end
    end
    return out
end

-- ============================== AUTO-GEAR FUNCTIONS ================================

-- FireServer to buy a gear item via exact remote: GameEvents.BuyGearStock(gearName)
local function buyGear(gearKey)
    while AUTO_GEAR._inFlightGlobal >= (AUTO_GEAR.maxConcurrentGlobal or 24) and AUTO_GEAR.enabled do
        task.wait(AUTO_GEAR.buyDelay or 0.05)
    end
    AUTO_GEAR._inFlightGlobal += 1
    local ok = pcall(function()
    local ge = ReplicatedStorage:WaitForChild("GameEvents")
    ge:WaitForChild("BuyGearStock"):FireServer(gearKey)
    end)
    AUTO_GEAR._inFlightGlobal = math.max(0, AUTO_GEAR._inFlightGlobal - 1)
    if AUTO_GEAR.logBuys then
        local line = (ok and "Bought" or "Failed") .. " Gear " .. tostring(gearKey)
        pcall(writefile, "GearShopDebug.txt", "\n[" .. os.date("%X") .. "] " .. line)
    end
    return ok
end

local function _findGearStockFetcher()
    local ge = ReplicatedStorage:FindFirstChild("GameEvents")
    if not ge then return nil end
    for _, d in ipairs(ge:GetDescendants()) do
        if d:IsA("RemoteFunction") then
            local nm = string.lower(d.Name)
            if (nm:find("stock") and (nm:find("gear") or nm:find("shop"))) or nm:find("getgearstock") or nm:find("getshopstock") then
                return d
            end
        end
    end
    return nil
end

local function _parseGearStock(res)
    local out = {}
    if type(res) ~= "table" then return out end
    if #res > 0 then
        for _, it in ipairs(res) do
            if type(it) == "table" then
                local name = it.key or it.Key or it.name or it.Name or it.item or it.Item or it.GearName
                local count = it.stock or it.Stock or it.left or it.Left or it.amount or it.Amount or it.count or it.Count
                if typeof(name) == "string" and typeof(count) == "number" then out[name] = count end
            end
        end
    else
        for k, v in pairs(res) do
            if typeof(k) == "string" then
                if typeof(v) == "number" then out[k] = v
                elseif type(v) == "table" then
                    local count = v.stock or v.Stock or v.left or v.Left or v.amount or v.Amount or v.count or v.Count
                    if typeof(count) == "number" then out[k] = count end
                end
            end
        end
    end
    return out
end

-- Build gear list and price map from game data module if available
local function _loadGearData()
    AUTO_GEAR.availableGear = {}
    local success, gearData = pcall(function()
        return require(ReplicatedStorage.Data.GearData)
    end)
    if success and type(gearData) == "table" then
        for key, info in pairs(gearData) do
            if info.DisplayInShop then
                table.insert(AUTO_GEAR.availableGear, {
                    key = key,
                    name = info.GearName or key,
                    price = info.Price or info.FallbackPrice or 0,
                    layoutOrder = info.LayoutOrder or 999,
                    displayName = info.GearName or key,
                    selected = false
                })
            end
        end
        table.sort(AUTO_GEAR.availableGear, function(a,b)
            if a.layoutOrder == b.layoutOrder then return a.name < b.name else return a.layoutOrder < b.layoutOrder end
        end)
    else
        -- Fallback minimal set
        AUTO_GEAR.availableGear = {
            {key="Watering Can", name="Watering Can", price=50000, layoutOrder=10, displayName="Watering Can"},
            {key="Trowel", name="Trowel", price=100000, layoutOrder=20, displayName="Trowel"},
            {key="Basic Sprinkler", name="Basic Sprinkler", price=25000, layoutOrder=40, displayName="Basic Sprinkler"},
        }
    end
    return AUTO_GEAR.availableGear
end

-- Money-delta based loop until gear sold out (or hit cap)
local function _buyGearUntilSoldOut(gearKey, price)
    local moneyVal = _getCurrencyValueInstance and _getCurrencyValueInstance() or nil
    local getMoney = function() return (moneyVal and moneyVal.Value) or 0 end
    local start = getMoney()
    local attempts, spent, bought = 0, 0, 0
    local delay = AUTO_GEAR.buyDelay or 0.05
    local cap = AUTO_GEAR.maxSpamPerItem or 100
    local failsInRow = 0
    while AUTO_GEAR.enabled and attempts < cap do
        attempts += 1
        local before = getMoney()
        buyGear(gearKey)
        task.wait(delay)
        local after = getMoney()
        local delta = before - after
        if price and price > 0 and delta >= price * 0.9 then
            spent += delta; bought += 1; failsInRow = 0
        else
            failsInRow += 1
            if failsInRow >= 4 then break end
            task.wait(math.min(0.25 * failsInRow, 1.0))
        end
    end
    return bought
end

local function _burstBuyGear(gearKey, count)
    local inFlight = 0
    local maxC = math.max(1, AUTO_GEAR.maxConcurrent or 6)
    local delay = AUTO_GEAR.buyDelay or 0.05
    local i = 0
    while AUTO_GEAR.enabled and i < count do
        while inFlight < maxC and i < count do
            i += 1
            inFlight += 1
            task.spawn(function()
                buyGear(gearKey)
                task.wait(delay)
                inFlight -= 1
            end)
        end
        task.wait(delay)
    end
    while inFlight > 0 do task.wait(delay) end
end

local function _runForGearParallel(items, fn)
    local pending = 0
    local delay = AUTO_GEAR.buyDelay or 0.05
    for _, it in ipairs(items) do
        if not AUTO_GEAR.enabled then break end
        while AUTO_GEAR._inFlightGlobal >= (AUTO_GEAR.maxConcurrentGlobal or 24) and AUTO_GEAR.enabled do
            task.wait(delay)
        end
        pending += 1
        task.spawn(function()
            pcall(fn, it)
            pending -= 1
        end)
        task.wait(delay * 0.2)
    end
    while pending > 0 do task.wait(delay) end
end

local function _detectGearStock()
    if not AUTO_GEAR.stockFetcher then AUTO_GEAR.stockFetcher = _findGearStockFetcher() end
    local fetcher = AUTO_GEAR.stockFetcher
    if fetcher then
        local ok, res = pcall(function() return fetcher:InvokeServer() end)
        if ok and type(res) == "table" then
            local map = _parseGearStock(res)
            if next(map) ~= nil then AUTO_GEAR.currentStock = map; return true end
        end
        local ok2, res2 = pcall(function() return fetcher:InvokeServer("Shop") end)
        if ok2 and type(res2) == "table" then
            local map2 = _parseGearStock(res2); if next(map2) ~= nil then AUTO_GEAR.currentStock = map2; return true end
        end
    end
    return false
end

local function _waitForGearRefresh(targetKeys)
    local fetcher = AUTO_GEAR.stockFetcher or _findGearStockFetcher()
    if fetcher then
        while AUTO_GEAR.enabled do
            local ok, res = pcall(function() return fetcher:InvokeServer() end)
            if ok and type(res) == "table" then
                local map = _parseGearStock(res)
                if next(map) ~= nil then
                    if targetKeys and #targetKeys > 0 then
                        for _, k in ipairs(targetKeys) do
                            if k and (map[k] or map[string.gsub(k, " Gear", "")]) and (map[k] or 0) > 0 then
                                AUTO_GEAR.currentStock = map; return
                            end
                        end
                    else
                        AUTO_GEAR.currentStock = map; return
                    end
                end
            end
            task.wait(5)
        end
    else
        task.wait(30) -- simple backoff if we can't detect refresh
    end
end

local function startAutoGear(toast)
    if AUTO_GEAR.enabled then return end
    AUTO_GEAR.enabled = true
    if toast then toast("Auto-Gear ON - tracking stock and buying out selections") end
    if #AUTO_GEAR.availableGear == 0 then _loadGearData() end
    AUTO_GEAR._task = task.spawn(function()
        while AUTO_GEAR.enabled do
            if not AUTO_GEAR._busy then
                AUTO_GEAR._busy = true
                local haveStock = _detectGearStock()
                local itemsToBuy = AUTO_GEAR.buyAll and AUTO_GEAR.availableGear or AUTO_GEAR.selectedGear
                if #itemsToBuy > 0 then
                    _runForGearParallel(itemsToBuy, function(it)
                        if not AUTO_GEAR.enabled then return end
                        local key = it.key or it.name or it.displayName; if not key then return end
                        local wanted = 0
                        if haveStock and AUTO_GEAR.currentStock then
                            local variants = { key, it.displayName, it.name }
                            for _, v in ipairs(variants) do if v and AUTO_GEAR.currentStock[v] then wanted = AUTO_GEAR.currentStock[v]; break end end
                        end
                        if wanted and wanted > 0 then
                            _burstBuyGear(key, wanted)
                        else
                            if it.price and it.price > 0 then
                                _burstBuyGear(key, (AUTO_GEAR.maxConcurrent or 8) * 6)
                                _buyGearUntilSoldOut(key, it.price)
                            else
                                _burstBuyGear(key, math.min(AUTO_GEAR.maxSpamPerItem or 100, 60))
                            end
                        end
                    end)
                end
                AUTO_GEAR._busy = false
            end
            local targetKeys = {}
            local itemsToBuy = AUTO_GEAR.buyAll and AUTO_GEAR.availableGear or AUTO_GEAR.selectedGear
            for _, it in ipairs(itemsToBuy) do table.insert(targetKeys, it.key or it.name or it.displayName) end
            _waitForGearRefresh(targetKeys)
        end
    end)
end

local function stopAutoGear(toast)
    AUTO_GEAR.enabled = false; AUTO_GEAR._busy = false
    if AUTO_GEAR._task then task.cancel(AUTO_GEAR._task); AUTO_GEAR._task=nil end
    if toast then toast("Auto-Gear OFF") end
end

-- UI stock helpers (shop scanning via PlayerGui)
local function _normalizeSeedName(n)
    n = tostring(n or ""):gsub("%s+Seeds$", "")
    return (n:lower())
end

local function _findShopRoot()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local shop = pg:FindFirstChild("Seed_Shop")
    if not shop then return nil end
    local frame = shop:FindFirstChild("Frame")
    local sc = frame and frame:FindFirstChild("ScrollingFrame")
    return sc
end

local function _findItemRow(seedName)
    local sc = _findShopRoot()
    if not sc then return nil end
    local want = _normalizeSeedName(seedName)
    for _, fr in ipairs(sc:GetChildren()) do
        if fr:IsA("Frame") then
            local foundName
            for _, d in ipairs(fr:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
                    local txt = tostring(d.Text)
                    -- Try to find a label that looks like the item name
                    if (txt:find("%a")) and not txt:find("%d+/%d+") and not txt:find("%d+¢") and not txt:lower():find("stock:") then
                        local norm = _normalizeSeedName(txt)
                        if norm == want then foundName = true; break end
                    end
                end
            end
            if foundName then return fr end
        end
    end
    return nil
end

local function _readRowStock(row)
    if not row then return nil end
    local best
    for _, d in ipairs(row:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
            local t = tostring(d.Text)
            local tl = t:lower()
            -- Ignore prices / currency and plain large numbers with symbols
            if not tl:find("¢") and not tl:find("$") then
                local n = tonumber(tl:match("x%s*(%d+)") or tl:match("(%d+)%s*left") or tl:match("stock%s*:%s*(%d+)") or tl:match("^%s*(%d+)%s*$"))
                if n then best = n; break end
            end
        end
    end
    return best
end

-- Detect and cache stock map; returns true if stock acquired
function AUTO_SHOP._detectStock()
    if not AUTO_SHOP.stockFetcher then AUTO_SHOP.stockFetcher = _findSeedStockFetcher() end
    local fetcher = AUTO_SHOP.stockFetcher
    if fetcher then
        local ok, res = pcall(function() return fetcher:InvokeServer() end)
        if ok and type(res) == "table" then
            local map = _parseStockTable(res)
            if next(map) ~= nil then
                AUTO_SHOP.currentStock = map
                return true
            end
        end
        -- Try Tier 1 variant if fetcher needs args
        local ok2, res2 = pcall(function() return fetcher:InvokeServer("Tier 1") end)
        if ok2 and type(res2) == "table" then
            local map2 = _parseStockTable(res2)
            if next(map2) ~= nil then
                AUTO_SHOP.currentStock = map2
                return true
            end
        end
    end

    -- UI fallback: build a stock map from the Seed Shop list
    local sc = _findShopRoot()
    if sc then
        local uiMap = {}
        for _, fr in ipairs(sc:GetChildren()) do
            if fr:IsA("Frame") then
                local nameText
                for _, d in ipairs(fr:GetDescendants()) do
                    if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
                        local txt = tostring(d.Text)
                        if (txt:find("%a")) and not txt:find("%d+/%d+") and not txt:find("%d+¢") and not txt:lower():find("stock:") then
                            nameText = txt
                            break
                        end
                    end
                end
                local stock = _readRowStock(fr)
                if nameText and stock then
                    uiMap[nameText] = stock
                    uiMap[string.gsub(nameText, " Seeds", "")] = stock
                end
            end
        end
        if next(uiMap) ~= nil then
            AUTO_SHOP.currentStock = uiMap
            return true
        end
    end
    return false
end

local function _getCurrencyValueInstance()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if not ls then return nil end
    local candidates = {"coins","coin","money","cash","tokens","gold"}
    local best
    for _, v in ipairs(ls:GetChildren()) do
        if v:IsA("NumberValue") or v:IsA("IntValue") or v:IsA("DoubleConstrainedValue") or v:IsA("NumberSequence") then
            local name = string.lower(v.Name)
            for _, c in ipairs(candidates) do if name:find(c) then best = v; break end end
            if best then break end
        end
    end
    if not best then
        for _, v in ipairs(ls:GetChildren()) do
            if v.Value ~= nil then best = v; break end
        end
    end
    return best
end

local function _buyUntilSoldOut(seedKey, price)
    local attempts, bought = 0, 0
    local moneyVal = _getCurrencyValueInstance()
    local lastMoney = moneyVal and moneyVal.Value or nil
    local failsInRow = 0
    local delay = AUTO_SHOP.buyDelay or 0.4
    local cap = AUTO_SHOP.maxSpamPerSeed or 250

    while AUTO_SHOP.enabled and attempts < cap do
        attempts += 1
        buySeed(seedKey)
        task.wait(delay)

        if moneyVal and typeof(price) == "number" and price > 0 then
            local now = moneyVal.Value
            local spent = lastMoney and (lastMoney - now) or 0
            if spent >= price * 0.9 then -- tolerate rounding
                bought += 1
                lastMoney = now
                failsInRow = 0
                -- slight pacing to avoid throttling
                task.wait(delay)
            else
                failsInRow += 1
                -- after a few consecutive non-spends, assume sold out
                if failsInRow >= 4 then break end
                -- small backoff in case of server debounce
                task.wait(math.min(0.25 * failsInRow, 1.0))
            end
        else
            -- Unknown price: use a fixed small spam with backoff
            if attempts % 10 == 0 then task.wait(0.5) end
        end
    end
    return bought
end

-- Fire a number of buy requests quickly using small concurrent bursts
local function _burstBuy(seedKey, count)
    local inFlight = 0
    local maxC = math.max(1, AUTO_SHOP.maxConcurrent or 6)
    local delay = AUTO_SHOP.buyDelay or 0.05
    local i = 0
    while AUTO_SHOP.enabled and i < count do
        while inFlight < maxC and i < count do
            i += 1
            inFlight += 1
            task.spawn(function()
                buySeed(seedKey)
                task.wait(delay)
                inFlight -= 1
            end)
        end
        -- yield a hair to allow tasks to run
        task.wait(delay)
    end
    -- wait for last in-flight to drain
    while inFlight > 0 do task.wait(delay) end
end

-- Run a function in parallel for each seed, bounded by the global concurrency cap
local function _runForSeedsParallel(seeds, fn)
    local pending = 0
    local delay = AUTO_SHOP.buyDelay or 0.05
    for _, sd in ipairs(seeds) do
        if not AUTO_SHOP.enabled then break end
        while AUTO_SHOP._inFlightGlobal >= (AUTO_SHOP.maxConcurrentGlobal or 32) and AUTO_SHOP.enabled do
            task.wait(delay)
        end
        pending += 1
        task.spawn(function()
            pcall(fn, sd)
            pending -= 1
        end)
        task.wait(delay * 0.2)
    end
    while pending > 0 do task.wait(delay) end
end

local function _waitForRefresh(targetKeys)
    -- If we can query stock, poll until any target has stock > 0
    local fetcher = AUTO_SHOP.stockFetcher or _findSeedStockFetcher()
    if fetcher then
        while AUTO_SHOP.enabled do
            local ok, res = pcall(function() return fetcher:InvokeServer() end)
            if ok and type(res) == "table" then
                local map = _parseStockTable(res)
                if next(map) ~= nil then
                    if targetKeys and #targetKeys > 0 then
                        for _, k in ipairs(targetKeys) do
                            local key = k
                            if type(k) == "table" then key = k.key or k.name or k.displayName end
                            if key and (map[key] or map[string.gsub(key, " Seeds", "")]) and (map[key] or 0) > 0 then
                                AUTO_SHOP.currentStock = map
                                return
                            end
                        end
                    else
                        -- no specific targets; any stock is fine
                        AUTO_SHOP.currentStock = map
                        return
                    end
                end
            end
            task.wait(5)
        end
    else
        -- Fallback: watch UI for any target getting stock again
        local deadline = os.clock() + 300 -- 5 minutes max
        while AUTO_SHOP.enabled and os.clock() < deadline do
            if targetKeys and #targetKeys > 0 then
                for _, k in ipairs(targetKeys) do
                    local key = type(k) == "table" and (k.key or k.name or k.displayName) or k
                    if key then
                        local row = _findItemRow(key)
                        local st = row and _readRowStock(row)
                        if st and st > 0 then return end
                    end
                end
            end
            task.wait(5)
        end
    end
end

-- Function to start auto-shop
local function startAutoShop(toast)
    if AUTO_SHOP.enabled then 
        return 
    end
    
    AUTO_SHOP.enabled = true
    if toast then toast("Auto-Shop ON - tracking stock and buying out selections") end
    
    AUTO_SHOP._task = task.spawn(function()
        while AUTO_SHOP.enabled do
            if not AUTO_SHOP._busy then
                AUTO_SHOP._busy = true
                -- 1) Detect stock via remote if available (no UI required)
                local haveStock = AUTO_SHOP._detectStock()

                -- 2) Determine seeds to buy this cycle
                local seedsToBuy = AUTO_SHOP.buyAll and AUTO_SHOP.availableSeeds or AUTO_SHOP.selectedSeeds

                -- 3) Buy out for each target without requiring GUI (in parallel across seeds)
                if #seedsToBuy > 0 then
                    _runForSeedsParallel(seedsToBuy, function(seedData)
                        if not AUTO_SHOP.enabled then return end
                        local key = seedData.key or seedData.name or seedData.displayName
                        if not key then return end

                        local wanted = 0
                        if haveStock and AUTO_SHOP.currentStock then
                            local variants = { key, string.gsub(key, " Seeds", ""), seedData.displayName, seedData.name }
                            for _, v in ipairs(variants) do
                                if v and AUTO_SHOP.currentStock[v] then wanted = AUTO_SHOP.currentStock[v]; break end
                            end
                        end

                        if wanted and wanted > 0 then
                            _burstBuy(key, wanted)
                        else
                            -- Remote stock not available; spam until sold-out using price as meter
                            if seedData.price and seedData.price > 0 then
                                -- try a large optimistic burst first, then finish with money-checked spam
                                _burstBuy(key, AUTO_SHOP.maxConcurrent * 8)
                                _buyUntilSoldOut(key, seedData.price)
                            else
                                -- Last resort: limited blind spam
                                local cap = math.min(AUTO_SHOP.maxSpamPerSeed, 100)
                                _burstBuy(key, cap)
                            end
                        end
                    end)
                end

                AUTO_SHOP._busy = false
            end
            -- 4) Wait for shop refresh without requiring the GUI
            local targetKeys = {}
            local seedsToBuy = AUTO_SHOP.buyAll and AUTO_SHOP.availableSeeds or AUTO_SHOP.selectedSeeds
            for _, sd in ipairs(seedsToBuy) do table.insert(targetKeys, sd.key or sd.name or sd.displayName) end
            _waitForRefresh(targetKeys)
        end
    end)
end

local function stopAutoShop(toast)
    AUTO_SHOP.enabled = false
    AUTO_SHOP._busy = false
    
    if AUTO_SHOP._task then
        task.cancel(AUTO_SHOP._task)
        AUTO_SHOP._task = nil
    end
    
    if toast then toast("Auto-Shop OFF") end
end

-- Single owned, ready, (mutated-if-required) list
local function getOwnedReadyPlants()
    local out = {}
    for _, m in ipairs(getAllPlants()) do
        if ownsPlant(LocalPlayer, m) and isPlantReady(m) and hasWantedMutation(m) then
            table.insert(out, m)
        end
    end
    return out
end

-- "Wireless" = remotes / prompts without moving
local function collectWirelessOnce()
    if not AUTO.enabled then return 0 end
    
    -- try fast path first (now owned-only)
    local used, sent = harvestViaCropsRemote()
    if used and sent > 0 then return sent end

    -- fallback: local sweep over owned ready plants
    local n = 0
    for _, plant in ipairs(getOwnedReadyPlants()) do
        if not AUTO.enabled then break end -- Exit if disabled during collection
        
        if tryRemotesForPlant(plant, LocalPlayer) or tryExploitHelpers(plant) then
            n += 1
        end
        task.wait(AUTO.fireDelay)
    end
    return n
end

-- "CFraming" = tween near each plant, then fire prompt/remote
local function moveNear(plant)
    local hrp = (Players.LocalPlayer.Character or Players.LocalPlayer.CharacterAdded:Wait()):WaitForChild("HumanoidRootPart")
    local pivot = (plant.GetPivot and plant:GetPivot()) or plant.PrimaryPart and plant.PrimaryPart.CFrame or plant.CFrame or CFrame.new()
    local dest  = pivot * CFrame.new(0, 3, -3)  -- slightly in front/above

    -- distance-based tween time, scaled by tweenSpeed (≈ seconds per 100 studs)
    local dist  = (hrp.Position - dest.Position).Magnitude
    local dur   = math.clamp((dist / 100) * math.max(0.05, AUTO.tweenSpeed), 0.05, 2.5)

    local tw = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {CFrame = dest})
    tw:Play(); task.wait(dur + 0.02)
end

local function collectCFramingOnce()
    if not AUTO.enabled then return 0 end
    
    local n = 0
    for _, plant in ipairs(getOwnedReadyPlants()) do
        if not AUTO.enabled then break end -- Exit if disabled during collection
        
        moveNear(plant)
        if not AUTO.enabled then break end -- Check again after movement
        
        if tryExploitHelpers(plant) or tryRemotesForPlant(plant, LocalPlayer) then
            n += 1
        end
        task.wait(AUTO.fireDelay)
    end
    return n
end

local function runHarvestOnce()
    if not AUTO.enabled then return 0 end -- Early exit if disabled
    
    if AUTO.method == "CFraming" then
        return collectCFramingOnce()
    elseif AUTO.method == "Wireless" then
        return collectWirelessOnce()
    else
        return 0
    end
end

local function AutoStart(toast)
    if AUTO._task then return end
    AUTO.enabled = true
    if toast then toast(("Auto-collect ON (%s)"):format(AUTO.method)) end
    AUTO._task = task.spawn(function()
        while AUTO.enabled do
            if not AUTO._busy and AUTO.enabled then -- Check enabled state before starting work
                AUTO._busy = true
                local success, result = pcall(runHarvestOnce)
                if not success then
                    warn("Harvest error:", result)
                end
                AUTO._busy = false
                -- Yield to prevent frame drops
                if AUTO.enabled then -- Only wait if still enabled
                    task.wait()
                end
            end
            
            -- Break the wait interval into smaller chunks for responsiveness
            local totalWait = math.max(1.0, AUTO.interval)
            local chunks = math.ceil(totalWait / 0.25) -- Check every 0.25 seconds
            for i = 1, chunks do
                if not AUTO.enabled then break end -- Exit immediately if disabled
                task.wait(totalWait / chunks)
            end
        end
        AUTO._task = nil -- Clean up task reference
    end)
end

local function AutoStop(toast)
    AUTO.enabled = false -- Set this first to stop the loop
    if toast then toast("Auto-collect OFF") end
    if AUTO._task then
        AUTO._task = nil -- Clear task reference
    end
    AUTO._busy = false -- Reset busy state
end

-- Public setters (call from your GUI)
_G.HarvestControl = {
    SetEnabled = function(on, toast) if on then AutoStart(toast) else AutoStop(toast) end end,
    SetMethod  = function(m) AUTO.method  = (m == "CFraming" and "CFraming") or (m == "Wireless" and "Wireless") or "None" end,
    SetInterval= function(s) AUTO.interval = tonumber(s) or AUTO.interval end,
    SetFireDelay=function(s) AUTO.fireDelay = tonumber(s) or AUTO.fireDelay end,
    SetTweenSpeed=function(s) AUTO.tweenSpeed = tonumber(s) or AUTO.tweenSpeed end,
    SetDebugMode=function(on) 
        DEBUG_MODE = on and true or false
        AUTO.debugMode = DEBUG_MODE
    end,
    RunOnce    = function() return runHarvestOnce() end,
}

-- ============================== PLAYER FEATURES ==============================
local SPEED={MIN=8,MAX=200,Chosen=16,Enabled=false,Default=16}
local InfiniteJump={Enabled=false}
local NoClip={Enabled=false,Conn=nil}
local Fly={Enabled=false,Speed=80,BV=nil,BG=nil,Conn=nil}
local Teleport={Enabled=false,Modifier=Enum.KeyCode.LeftControl}
-- Global connection handles for teardown
local JumpConn=nil
local TeleportConn=nil
local CharAddedConn=nil

local function getHumanoid()
    local ch=Players.LocalPlayer.Character or Players.LocalPlayer.CharacterAdded:Wait()
    local hum=ch:FindFirstChildOfClass("Humanoid"); if hum then return hum end
    local c; c=ch.ChildAdded:Connect(function(n) if n:IsA("Humanoid") then hum=n; c:Disconnect() end end)
    repeat task.wait() until hum; return hum
end
local function getHRP() local ch=Players.LocalPlayer.Character; return ch and ch:FindFirstChild("HumanoidRootPart") end

-- Apply WITHOUT mutating SPEED.Chosen
local function applySpeedValue(v)
    local hum=(Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")) or getHumanoid()
    if hum then hum.WalkSpeed=v end
end

local function setCustomSpeed(on)
    SPEED.Enabled = on and true or false
    if SPEED.Enabled then
        applySpeedValue(SPEED.Chosen)
    else
        applySpeedValue(SPEED.Default)
    end
end

JumpConn = UserInputService.JumpRequest:Connect(function()
    if InfiniteJump.Enabled then
        local hum=Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping); hum.Jump=true end
    end
end)

local function setNoClip(on)
    if on then
        if NoClip.Conn then NoClip.Conn:Disconnect() end
        NoClip.Conn = RunService.Stepped:Connect(function()
            local ch=Players.LocalPlayer.Character; if not ch then return end
            for _,p in ipairs(ch:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide=false end end
        end)
    else
        if NoClip.Conn then NoClip.Conn:Disconnect(); NoClip.Conn=nil end
    end
    NoClip.Enabled=on
end

local function stopFly()
    Fly.Enabled=false
    if Fly.Conn then Fly.Conn:Disconnect(); Fly.Conn=nil end
    local hrp=getHRP(); if hrp then if Fly.BV then Fly.BV:Destroy() Fly.BV=nil end; if Fly.BG then Fly.BG:Destroy() Fly.BG=nil end end
    local hum=Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid"); if hum then hum.PlatformStand=false end
end
local function startFly()
    local hrp=getHRP(); local hum=getHumanoid(); if not hrp or not hum then return end
    stopFly(); Fly.Enabled=true; hum.PlatformStand=true
    local bv=Instance.new("BodyVelocity"); bv.MaxForce=Vector3.new(1e9,1e9,1e9); bv.Velocity=Vector3.zero; bv.Parent=hrp; Fly.BV=bv
    local bg=Instance.new("BodyGyro"); bg.MaxTorque=Vector3.new(1e9,1e9,1e9); bg.P=9e4; bg.CFrame=workspace.CurrentCamera.CFrame; bg.Parent=hrp; Fly.BG=bg
    Fly.Conn = RunService.RenderStepped:Connect(function()
        if not Fly.Enabled then return end
        local cam=workspace.CurrentCamera; if not cam then return end
        bg.CFrame=cam.CFrame
        local dir=Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir+=cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir-=cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir+=cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir-=cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.E) then dir+=Vector3.new(0,1,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then dir-=Vector3.new(0,1,0) end
        if dir.Magnitude>0 then dir=dir.Unit*Fly.Speed end
        bv.Velocity=dir
    end)
end
local function setFly(on) if on then startFly() else stopFly() end end

-- Teleport (toggle-gated, LeftCtrl+Click; ignores UI)
local mouse=Players.LocalPlayer:GetMouse()
local function pointInside(frame)
    local m=UserInputService:GetMouseLocation(); local p=frame.AbsolutePosition; local s=frame.AbsoluteSize
    return m.X>=p.X and m.X<=p.X+s.X and m.Y>=p.Y and m.Y<=p.Y+s.Y
end
TeleportConn = mouse.Button1Down:Connect(function()
    if not Teleport.Enabled or not UserInputService:IsKeyDown(Teleport.Modifier) then return end
    local gui=CoreGui:FindFirstChild("SpeedStyleUI"); if gui and gui.Enabled then
        local win=gui:FindFirstChild("MainWindow", true); if win and pointInside(win) then return end
    end
    local ch=Players.LocalPlayer.Character; local pos=mouse.Hit and mouse.Hit.p
    if ch and pos then ch:PivotTo(CFrame.new(pos + Vector3.new(0,3,0))) end
end)

-- ============================== WORLD: GRASS OVERLAY =========================
local GO = {
    Enabled=false,
    TAG="GrassOverlay_Client",
    COLOR=Color3.fromRGB(72,220,96),
    THICK=0.12,
    MIN_TILE=6,
    GREEN_H_MIN=0.23, GREEN_H_MAX=0.42,
    overlays=setmetatable({}, {__mode="k"}),
    conns=setmetatable({}, {__mode="k"}),
    scanConn=nil, refreshConn=nil
}
local function isCharacterDescendant(inst)
    local m = inst:FindFirstAncestorOfClass("Model")
    return m and m:FindFirstChildOfClass("Humanoid") ~= nil
end
local function isOverlayPart(inst)
    return inst:IsA("BasePart") and (inst.Name==GO.TAG or CollectionService:HasTag(inst, GO.TAG) or inst:GetAttribute("__IsOverlay")==true)
end
local function looksLikeGrass(part)
    if not part:IsA("BasePart") then return false end
    if isCharacterDescendant(part) or part:IsA("Terrain") or isOverlayPart(part) then return false end
    if part.CFrame.UpVector.Y < 0.9 then return false end
    if math.min(part.Size.X, part.Size.Z) < GO.MIN_TILE then return false end
    local name = string.lower(part.Name)
    local byName = string.find(name, "grass") or string.find(name, "lawn") or string.find(name, "turf")
    local byMat  = (part.Material==Enum.Material.Grass) or (part.Material==Enum.Material.Ground)
    local h,s,v = Color3.toHSV(part.Color)
    local greenish = (h>GO.GREEN_H_MIN and h<GO.GREEN_H_MAX and s>0.2 and v>0.2)
    return byName or byMat or greenish
end
local function ensureOverlay(base)
    if not base or not base:IsA("BasePart") or not base.Parent then return end
    if isOverlayPart(base) then return end
    if GO.overlays[base] and GO.overlays[base].Parent then return end
    if not looksLikeGrass(base) then return end
    local ov = Instance.new("Part")
    ov.Name = GO.TAG
    ov:SetAttribute("__IsOverlay", true)
    CollectionService:AddTag(ov, GO.TAG)
    ov.Anchored=true; ov.CanCollide=false; ov.CanQuery=false; ov.CanTouch=false
    ov.Material=Enum.Material.Grass; ov.Color=GO.COLOR; ov.Transparency=0
    ov.CastShadow=false; ov.Locked=true; ov.TopSurface=Enum.SurfaceType.Smooth; ov.BottomSurface=Enum.SurfaceType.Smooth
    local function apply()
        if not base.Parent then return end
        local offset = CFrame.new(0, base.Size.Y/2 + GO.THICK/2 + 0.01, 0)
        ov.CFrame = base.CFrame * offset
        ov.Size = Vector3.new(base.Size.X+0.02, GO.THICK, base.Size.Z+0.02)
    end
    apply()
    ov.Parent = base
    GO.overlays[base] = ov
    if not GO.conns[base] then
        local function sync()
            if ov.Parent==nil or base.Parent==nil then return end
            apply()
        end
        local c1 = base:GetPropertyChangedSignal("CFrame"):Connect(sync)
        local c2 = base:GetPropertyChangedSignal("Size"):Connect(sync)
        local c3 = base:GetPropertyChangedSignal("Parent"):Connect(function()
            if not base.Parent and ov then ov:Destroy() end
        end)
        GO.conns[base] = {c1,c2,c3}
    end
end
local function GO_Start()
    if GO.Enabled then return end
    GO.Enabled=true
    for _,d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("BasePart") and not isOverlayPart(d) then ensureOverlay(d) end
    end
    GO.scanConn = Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") and not isOverlayPart(d) then task.defer(function() ensureOverlay(d) end) end
    end)
    local acc=0
    GO.refreshConn = RunService.Heartbeat:Connect(function(dt)
        acc += dt
        if acc>2 then
            acc=0
            for _,d in ipairs(Workspace:GetDescendants()) do
                if d:IsA("BasePart") and not isOverlayPart(d) then ensureOverlay(d) end
            end
        end
    end)
end
local function GO_Stop()
    if not GO.Enabled then return end
    GO.Enabled=false
    if GO.scanConn then GO.scanConn:Disconnect(); GO.scanConn=nil end
    if GO.refreshConn then GO.refreshConn:Disconnect(); GO.refreshConn=nil end
    for base,ov in pairs(GO.overlays) do pcall(function() ov:Destroy() end); GO.overlays[base]=nil end
    for base,b in pairs(GO.conns) do for _,c in ipairs(b) do pcall(function() c:Disconnect() end) end; GO.conns[base]=nil end
end

-- ============================== WORLD: BEACH =================================
local BEACH = {
    USE_SAVED=true,
    SAVED_CF = CFrame.new(164.126, -16.000, -17.034) * CFrame.Angles(0, math.rad(-90.000), 0),
    HEIGHT_ADJUST = 117.0,
    SAND_SEA_SIDE = false,   -- false -> -Z, true -> +Z
    SAND_EXTRA_Z  = 0.0,
    WATER_UP      = 2.0,
    WATER_LEFT    = 6.0,     -- left = -X
    WATER_EXTRA_Z = 0.0,
    CFG = {
        SandSize   = Vector3.new(220, 2, 130),
        SlopeSize  = Vector3.new(220,12, 38),
        WaterSize  = Vector3.new(260, 6, 240),
        SandColor  = Color3.fromRGB(242,216,158),
        WaterColor = Color3.fromRGB(60,190,255),
        WaterTransparency = 0.45,
        CollideSand = true, CollideSlope=true,
        WaveAmp=1.0, WaveSpeed=0.9, RippleAmp=0.7, RippleSpeed=0.35
    },
    SEAM = { sandIntoSlope=1.5, waterHeight=0.6 },
    folder=nil, parts={sand=nil,slope=nil,water=nil}, baseWaterCF=nil, waveConn=nil, anchorCF=nil
}
local function beachLogCF(cf, tag)
    local p = cf.Position
    local _,ry = cf:ToEulerAnglesYXZ()
    local yaw = math.deg(ry)
    warn(string.format("[Beach] %s at (%.3f, %.3f, %.3f), yaw=%.2f°", tag or "Anchor", p.X,p.Y,p.Z, yaw))
    print(string.format(
        "[Beach] Copy-paste:\nlocal HARDCODED_BEACH_CF = CFrame.new(%.3f, %.3f, %.3f) * CFrame.Angles(0, math.rad(%.3f), 0)",
        p.X, p.Y, p.Z, yaw
    ))
end
local function beachGroundYaw(cf)
    local origin = cf.Position + Vector3.new(0,1000,0)
    local hit = Workspace:Raycast(origin, Vector3.new(0,-3000,0), RaycastParams.new())
    local pos = hit and Vector3.new(cf.X, hit.Position.Y, cf.Z) or cf.Position
    local _,ry = cf:ToEulerAnglesYXZ()
    return CFrame.new(pos) * CFrame.Angles(0, ry, 0)
end
local function beachComputeAnchor()
    local cf = BEACH.USE_SAVED and BEACH.SAVED_CF
        or (LocalPlayer.Character and LocalPlayer.Character:WaitForChild("HumanoidRootPart").CFrame or CFrame.new())
    return beachGroundYaw(cf) * CFrame.new(0, BEACH.HEIGHT_ADJUST, 0)
end
local function beachCleanup()
    if BEACH.waveConn then BEACH.waveConn:Disconnect(); BEACH.waveConn=nil end
    if BEACH.folder then BEACH.folder:Destroy(); BEACH.folder=nil end
    BEACH.parts={sand=nil,slope=nil,water=nil}; BEACH.baseWaterCF=nil; BEACH.anchorCF=nil
end
local function mkPart(name, size, cf, color, material, transp, parent, collide)
    local p = Instance.new("Part")
    p.Name, p.Size, p.CFrame = name, size, cf
    p.Anchored=true; p.CanCollide=collide or false; p.CanQuery=collide or false; p.CanTouch=false
    p.CastShadow=false; p.Material=material; p.Color=color; p.Transparency=transp or 0
    p.TopSurface=Enum.SurfaceType.Smooth; p.BottomSurface=Enum.SurfaceType.Smooth
    p.Parent=parent
    return p
end
local function beachBuild()
    beachCleanup()
    local CFG, SEAM = BEACH.CFG, BEACH.SEAM
    local anchor = beachComputeAnchor(); BEACH.anchorCF = anchor; beachLogCF(anchor, "Anchor")
    local folder = Instance.new("Folder"); folder.Name="ClientBeach_LOCAL"; folder.Parent=Workspace; BEACH.folder=folder

    -- slope
    local slopeCF = anchor * CFrame.new(0, CFG.SlopeSize.Y*0.5, 0)
    local slope = Instance.new("WedgePart")
    slope.Name="Beach_Slope"; slope.Anchored=true; slope.CanCollide=CFG.CollideSlope; slope.CanQuery=CFG.CollideSlope; slope.CanTouch=false
    slope.CastShadow=false; slope.Color=CFG.SandColor; slope.Material=Enum.Material.Sand; slope.Size=CFG.SlopeSize
    slope.CFrame=slopeCF; slope.Parent=folder
    BEACH.parts.slope = slope

    local halfSlopeZ = CFG.SlopeSize.Z*0.5
    -- sand
    local sandZ do
        local halfSandZ = CFG.SandSize.Z*0.5
        local baseZ = halfSlopeZ + halfSandZ - SEAM.sandIntoSlope
        local sign = BEACH.SAND_SEA_SIDE and 1 or -1
        sandZ = sign*baseZ + BEACH.SAND_EXTRA_Z
        local sandCF = anchor * CFrame.new(0, CFG.SandSize.Y*0.5, sandZ)
        BEACH.parts.sand = mkPart("Beach_Sand", CFG.SandSize, sandCF, CFG.SandColor, Enum.Material.Sand, 0, folder, CFG.CollideSand)
    end

    -- water (follow sand Z; up & left a bit)
    local xLeft = -BEACH.WATER_LEFT
    local yUp   = SEAM.waterHeight + BEACH.WATER_UP
    local zFwd  = sandZ + BEACH.WATER_EXTRA_Z
    local waterCF = anchor * CFrame.new(xLeft, yUp, zFwd)
    BEACH.parts.water = mkPart("Beach_Water", CFG.WaterSize, waterCF, CFG.WaterColor, Enum.Material.Glass, CFG.WaterTransparency, folder, false)
    BEACH.parts.water.Reflectance = 0.03
    BEACH.baseWaterCF = BEACH.parts.water.CFrame

    -- waves
    local t=0
    BEACH.waveConn = RunService.RenderStepped:Connect(function(dt)
        if not BEACH.parts.water or not BEACH.parts.water.Parent then return end
        t += dt
        local bob  = math.sin(t * math.pi * 2 * CFG.WaveSpeed) * CFG.WaveAmp
        local tilt = math.sin(t * math.pi * 2 * CFG.RippleSpeed) * math.rad(CFG.RippleAmp)
        BEACH.parts.water.CFrame = BEACH.baseWaterCF * CFrame.new(0, bob, 0) * CFrame.Angles(tilt, 0, 0)
    end)
end

-- ============================== SCRIPTS: Infinite Yield ======================
local function execInfiniteYield(toast)
    local url = "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"

    local function try_game_httpget()
        return pcall(function() return game:HttpGet(url) end)
    end
    local function try_httpget_func()
        local httpget = rawget(getfenv() or _G, "httpget") or _G.httpget
        if not httpget then return false, nil end
        return pcall(function() return httpget(url) end)
    end
    local function try_syn_request()
        if not (syn and syn.request) then return false, nil end
        return pcall(function()
            local r = syn.request({Url=url, Method="GET"})
            return r and r.Body or ""
        end)
    end

    local ok, src = try_game_httpget()
    if not ok or not src or #src==0 then ok, src = try_httpget_func() end
    if not ok or not src or #src==0 then ok, src = try_syn_request() end

    if not ok or not src or #src==0 then
        if toast then toast("Infinite Yield: failed to download") end
        warn("[IY] Download failed.")
        return
    end

    local fn, ferr = loadstring(src)
    if not fn then
        if toast then toast("Infinite Yield: loadstring error") end
        warn("[IY] loadstring error: ".. tostring(ferr))
        return
    end
    local okrun, err2 = pcall(fn)
    if okrun then
        if toast then toast("Infinite Yield loaded") end
    else
        if toast then toast("Infinite Yield: runtime error") end
        warn("[IY] runtime error: ".. tostring(err2))
    end
end

-- LOADING ---------------------------------------------------------------------
local function createLoadingScreen(onComplete)
    local gui=mk("ScreenGui",{Name="PlaceholderUI_Loading",IgnoreGuiInset=true,ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Global},CoreGui)
    local bg =mk("Frame",{Size=UDim2.fromScale(1,1),BackgroundColor3=THEME.BG1,BackgroundTransparency=1},gui)
    local grid=mk("ImageLabel",{Image="rbxassetid://285329487",ScaleType=Enum.ScaleType.Tile,TileSize=UDim2.new(0,50,0,50),Size=UDim2.fromScale(2,2),Position=UDim2.fromScale(-0.5,-0.5),ImageTransparency=0.9,BackgroundTransparency=1},bg)
    TweenService:Create(grid,TweenInfo.new(24,Enum.EasingStyle.Linear,Enum.EasingDirection.Out,-1),{Position=UDim2.fromScale(0.5,0.5)}):Play()
    local title=mk("TextLabel",{Size=UDim2.new(1,0,0,44),Position=UDim2.new(0.5,0,0.35,0),AnchorPoint=Vector2.new(0.5,0.5),BackgroundTransparency=1,Font=FONTS.HB,Text="GAG Hub",TextColor3=THEME.TEXT,TextSize=40,TextTransparency=1},bg)
    local barBG=mk("Frame",{Size=UDim2.new(0.3,0,0,8),Position=UDim2.new(0.5,0,0.5,0),AnchorPoint=Vector2.new(0.5,0.5),BackgroundColor3=THEME.BG3,BackgroundTransparency=1},bg) corner(barBG,100)
    local bar =mk("Frame",{Size=UDim2.new(0,0,1,0),BackgroundColor3=THEME.ACCENT},barBG) corner(bar,100)
    local status=mk("TextLabel",{Size=UDim2.new(1,0,0,24),Position=UDim2.new(0.5,0,0.5,24),AnchorPoint=Vector2.new(0.5,0.5),BackgroundTransparency=1,Font=FONTS.B,TextColor3=THEME.MUTED,TextSize=16,TextTransparency=1},bg)
    coroutine.wrap(function()
        TweenService:Create(bg,TweenInfo.new(.55,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency=0}):Play()
        TweenService:Create(title,TweenInfo.new(.55,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{TextTransparency=0}):Play()
        task.wait(.45); TweenService:Create(barBG,TweenInfo.new(.32,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency=0}):Play()
        TweenService:Create(status,TweenInfo.new(.32,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{TextTransparency=0}):Play()
        local steps={{"Initializing...",.5},{"Loading assets...",.55},{"Building layout...",.65},{"Finalizing...",.5}}
        for i,s in ipairs(steps) do status.Text=s[1]; TweenService:Create(bar,TweenInfo.new(.32,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Size=UDim2.new(i/#steps,0,1,0)}):Play(); task.wait(s[2]) end
        task.wait(.25); TweenService:Create(bg,TweenInfo.new(.55,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency=1}):Play()
        task.wait(.35); gui:Destroy(); onComplete()
    end)()
end

-- COMPONENTS ------------------------------------------------------------------
local function makeToaster(rootGui)
    local overlay = mk("Frame", {Name="ToastOverlay", BackgroundTransparency=1, Size=UDim2.fromScale(1,1), ZIndex=1000}, rootGui)
    overlay.ClipsDescendants = false
    local stack = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(0, 420, 1, 0), Position=UDim2.new(0.5, -210, 0, 10), AnchorPoint=Vector2.new(0,0), ZIndex=1001}, overlay)
    local lay = Instance.new("UIListLayout", stack)
    lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
    lay.VerticalAlignment   = Enum.VerticalAlignment.Top
    lay.Padding             = UDim.new(0, 6)

    local function toast(text)
        local f = mk("Frame", {Size=UDim2.new(1, 0, 0, 40), BackgroundColor3=THEME.BG2, ZIndex=1002}, stack)
        corner(f, 8); stroke(f,1,THEME.BORDER); pad(f,8,12,8,12)
        local t = mk("TextLabel", {BackgroundTransparency=1, Font=FONTS.H, Text=text, TextSize=14, TextColor3=THEME.TEXT, TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,1,0), ZIndex=1003}, f)
        f.BackgroundTransparency = 1; t.TextTransparency = 1
        TweenService:Create(f, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency=0}):Play()
        TweenService:Create(t, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency=0}):Play()
        task.delay(2.0, function()
            TweenService:Create(f, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency=1}):Play()
            TweenService:Create(t, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency=1}):Play()
            task.wait(0.4); f:Destroy()
        end)
    end
    return toast
end

local function makeToggle(parent,text,subtext,default,onChanged,toast)
    local row=mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,50)},parent)
    corner(row,8); stroke(row,1,THEME.BORDER); pad(row,8,12,8,12)
    local left=mk("Frame",{BackgroundTransparency=1,Size=UDim2.new(1,-80,1,0)},row)
    local t=mk("TextLabel",{BackgroundTransparency=1,Font=FONTS.H,Text=text,TextSize=15,TextColor3=THEME.TEXT,TextXAlignment=Enum.TextXAlignment.Left},left)
    t.Size=UDim2.new(1,0,0,18)
    if subtext and #subtext>0 then
        mk("TextLabel",{BackgroundTransparency=1,Font=FONTS.B,Text=subtext,TextSize=12,TextColor3=THEME.MUTED,TextXAlignment=Enum.TextXAlignment.Left,Position=UDim2.new(0,0,0,20),Size=UDim2.new(1,0,0,18)},left)
    end
    local sw=mk("TextButton",{AutoButtonColor=false,AnchorPoint=Vector2.new(1,0.5),Position=UDim2.new(1,0,0.5,0),Size=UDim2.new(0,52,0,24),BackgroundColor3=THEME.BG2,Text=""},row)
    corner(sw,12); stroke(sw,1,THEME.BORDER)
    local knob=mk("Frame",{Size=UDim2.new(0,18,0,18),Position=UDim2.new(0,3,0,3),BackgroundColor3=THEME.MUTED},sw); corner(knob,9)
    local state= default and true or false
    local function render()
        if state then
            TweenService:Create(sw,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundColor3=THEME.ACCENT}):Play()
            TweenService:Create(knob,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Position=UDim2.new(1,-21,0,3),BackgroundColor3=Color3.new(1,1,1)}):Play()
        else
            TweenService:Create(sw,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundColor3=THEME.BG2}):Play()
            TweenService:Create(knob,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Position=UDim2.new(0,3,0,3),BackgroundColor3=THEME.MUTED}):Play()
        end
    end
    sw.MouseButton1Click:Connect(function() state=not state; render(); if onChanged then task.spawn(onChanged,state) end; if toast then toast(text..": "..(state and "ON" or "OFF")) end end)
    render(); hover(row,{BackgroundColor3=THEME.BG2},{BackgroundColor3=THEME.CARD})
    return {Set=function(v) state=v; render() end, Get=function() return state end, Instance=row}
end

local function groupBox(parent, title)
    local box = mk("Frame", {BackgroundColor3=THEME.BG2, Size=UDim2.new(1,0,0,10)}, parent)
    corner(box,10); stroke(box,1,THEME.BORDER); pad(box,10,10,10,10)
    mk("TextLabel", {BackgroundTransparency=1, Font=FONTS.HB, Text=title, TextSize=16, TextColor3=THEME.TEXT, Size=UDim2.new(1,0,0,18)}, box)
    mk("Frame", {BackgroundColor3=THEME.BORDER, Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,0,24)}, box)
    local inner = mk("Frame", {BackgroundTransparency=1, Position=UDim2.new(0,0,0,30), Size=UDim2.new(1,0,0,0)}, box)
    local lay = vlist(inner, 8)
    lay:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        inner.Size = UDim2.new(1,0,0, lay.AbsoluteContentSize.Y)
        box.Size = UDim2.new(1,0,0, 30 + lay.AbsoluteContentSize.Y + 10)
    end)
    return inner
end

-- Slider row (clamped knob; textbox centered)
local function sliderRow(parent, label, minV, maxV, startV, onChange, lockDrag, unlockDrag)
    local row = mk("Frame", {BackgroundColor3=THEME.CARD, Size=UDim2.new(1,0,0,56)}, parent)
    corner(row,8); stroke(row,1,THEME.BORDER); pad(row,8,10,8,10)
    mk("TextLabel", {BackgroundTransparency=1, Font=FONTS.H, Text=label, TextSize=15, TextColor3=THEME.TEXT, TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,18)}, row)

    local track = mk("Frame", {BackgroundColor3=THEME.BG2, Size=UDim2.new(1,-120,0,6), Position=UDim2.new(0,10,0,36)}, row)
    corner(track,3)
    local knob  = mk("Frame", {Parent=track, BackgroundColor3=THEME.ACCENT, Size=UDim2.new(0,14,0,14), AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.new(0.5,0,0.5,0)}, track)
    corner(knob,7)

    local box   = mk("TextBox", {
        Text=tostring(startV), Font=FONTS.H, TextSize=14, TextColor3=THEME.TEXT,
        BackgroundColor3=THEME.BG2, Size=UDim2.new(0,84,0,26),
        AnchorPoint=Vector2.new(1,0.5), Position=UDim2.new(1,-10,0.5,0), ClearTextOnFocus=false
    }, row)
    corner(box,8); stroke(box,1,THEME.BORDER)

    local dragging=false
    local current = startV
    local KNOB_R = 7
    local function padFrac() return KNOB_R / math.max(1, track.AbsoluteSize.X) end
    local function v2a(v) local pf=padFrac(); return pf + ((v-minV)/(maxV-minV))*(1-2*pf) end
    local function a2v(a) local pf=padFrac(); local t=(a-pf)/math.max(1e-6,(1-2*pf)); return math.floor(minV + t*(maxV-minV) + .5) end
    local function setVisual(v)
        current = math.clamp(v, minV, maxV)
        box.Text = tostring(current)
        local a = math.clamp(v2a(current), padFrac(), 1-padFrac())
        knob.Position = UDim2.new(a, 0, 0.5, 0)
    end
    local function setFromMouse(x)
        local raw = (x - track.AbsolutePosition.X)/math.max(1, track.AbsoluteSize.X)
        local a = math.clamp(raw, padFrac(), 1-padFrac())
        local v = a2v(a)
        setVisual(v)
        return v
    end

    track:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() setVisual(current) end)
    task.defer(function() setVisual(startV) end)

    knob.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true; if lockDrag then lockDrag() end end end)
    knob.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false; if unlockDrag then unlockDrag() end end end)
    track.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true; if lockDrag then lockDrag() end; onChange(setFromMouse(i.Position.X)) end end)
    UserInputService.InputChanged:Connect(function(i) if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then onChange(setFromMouse(i.Position.X)) end end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false; if unlockDrag then unlockDrag() end end end)
    box.FocusLost:Connect(function() local n=tonumber(box.Text); if not n then box.Text=tostring(current) return end; n=math.clamp(math.floor(n+0.5),minV,maxV); setVisual(n); onChange(n) end)

    return {SetVisual=setVisual}
end

-- APP -------------------------------------------------------------------------
local function buildApp()
    if CoreGui:FindFirstChild("SpeedStyleUI") then CoreGui.SpeedStyleUI:Destroy() end
    local app=mk("ScreenGui",{Name="SpeedStyleUI",IgnoreGuiInset=true,ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Global},CoreGui)

    local win=mk("Frame",{Name="MainWindow",Size=UDim2.new(0,720,0,420),Position=UDim2.new(0.5,-360,0.5,-210),BackgroundColor3=THEME.BG1,Active=true,Draggable=true},app)
    corner(win,14); stroke(win,1,THEME.BORDER)
    -- Subtle gradient for depth
    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255,255,255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(200,200,210)),
    })
    grad.Rotation = 90
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.95),
        NumberSequenceKeypoint.new(1, 0.95),
    })
    grad.Parent = win

    local top=mk("Frame",{BackgroundColor3=THEME.BG2,Size=UDim2.new(1,0,0,36)},win); corner(top,10); stroke(top,1,THEME.BORDER); top.ClipsDescendants = true
    -- Title shifted to avoid overlapping the menu icon (28px wide + padding)
    mk("TextLabel",{BackgroundTransparency=1,Font=FONTS.HB,Text="GAG HUB | v1.5.5",TextColor3=THEME.TEXT,TextSize=14,TextXAlignment=Enum.TextXAlignment.Left,Position=UDim2.new(0,44,0,0),Size=UDim2.new(1,-160,1,0)},top)
    local menuBtn=mk("ImageButton",{AutoButtonColor=false,BackgroundColor3=THEME.BG3,Size=UDim2.new(0,28,0,24),Position=UDim2.new(0,8,0.5,0),AnchorPoint=Vector2.new(0,0.5),ImageTransparency=1},top)
    do
        local function bar(y)
            local f = Instance.new("Frame")
            f.BackgroundColor3 = THEME.TEXT
            f.BorderSizePixel = 0
            f.Size = UDim2.new(0, 16, 0, 2)
            f.Position = UDim2.new(0, 6, 0, y)
            f.Parent = menuBtn
        end
        bar(5); bar(10); bar(15)
    end
    local btnMin=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=THEME.BG3,Size=UDim2.new(0,28,0,24),Position=UDim2.new(1,-68,0.5,0),AnchorPoint=Vector2.new(0,0.5),Text="—",TextColor3=THEME.TEXT,Font=FONTS.H,TextSize=18},top)
    local btnClose=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=THEME.BG3,Size=UDim2.new(0,28,0,24),Position=UDim2.new(1,-34,0.5,0),AnchorPoint=Vector2.new(0,0.5),Text="X",TextColor3=THEME.TEXT,Font=FONTS.H,TextSize=14},top)
    corner(btnMin,6); corner(btnClose,6); stroke(btnMin,1,THEME.BORDER); stroke(btnClose,1,THEME.BORDER)
    hover(btnMin,{BackgroundColor3=THEME.BG2},{BackgroundColor3=THEME.BG3})
    hover(btnClose,{BackgroundColor3=Color3.fromRGB(120,40,40)},{BackgroundColor3=THEME.BG3})

    local sideExpandedW,sideCompactW=176,64
    local sidebarCompact=false
    local sidebarVisible=true
    local side=mk("Frame",{BackgroundColor3=THEME.BG2,Position=UDim2.new(0,0,0,36),Size=UDim2.new(0,sideExpandedW,1,-36)},win); stroke(side,1,THEME.BORDER); pad(side,10,10,10,10); vlist(side,6)
    side.ClipsDescendants = true
    local host=mk("Frame",{BackgroundColor3=THEME.BG1,Position=UDim2.new(0,sideExpandedW,0,36),Size=UDim2.new(1,-sideExpandedW,1,-36)},win); stroke(host,1,THEME.BORDER); pad(host,12,12,12,12); corner(host,12)
    host.ClipsDescendants = true

    local toast = makeToaster(app)

    local sideButtons={}
    local function applySide() for _,b in ipairs(sideButtons) do b.TextXAlignment=sidebarCompact and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left end end
    local function setSidebarCompact(on)
        sidebarCompact=on and true or false
        if not sidebarVisible then return end
        local target=sidebarCompact and sideCompactW or sideExpandedW
        TweenService:Create(side,TweenInfo.new(.35,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Size=UDim2.new(0,target,1,-36)}):Play()
        TweenService:Create(host,TweenInfo.new(.35,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Position=UDim2.new(0,target,0,36),Size=UDim2.new(1,-target,1,-36)}):Play()
        applySide()
    end

    local function setSidebarVisible(on)
        sidebarVisible = on and true or false
        local targetW = sidebarVisible and (sidebarCompact and sideCompactW or sideExpandedW) or 0
        TweenService:Create(side, TweenInfo.new(.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0, targetW, 1, -36)}):Play()
        TweenService:Create(host, TweenInfo.new(.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = UDim2.new(0, targetW, 0, 36), Size = UDim2.new(1, -targetW, 1, -36)}):Play()
        applySide()
    end

    local pages={}
    local function makePage(title)
        local page=mk("Frame",{BackgroundTransparency=1,Visible=false,Size=UDim2.new(1,0,1,0)},host)
        mk("TextLabel",{BackgroundTransparency=1,Font=FONTS.HB,Text=title,TextSize=20,TextColor3=THEME.TEXT,Size=UDim2.new(1,0,0,22)},page)
        mk("Frame",{BackgroundColor3=THEME.BORDER,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0,26)},page)
    local scroll=mk("ScrollingFrame",{BackgroundTransparency=1,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-38),CanvasSize=UDim2.new(0,0,0,0),ScrollBarThickness=6},page)
    scroll.ClipsDescendants = true
        local lay=vlist(scroll,10)
        lay:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() scroll.CanvasSize=UDim2.new(0,0,0,lay.AbsoluteContentSize.Y+8) end)
        pages[title]={Root=page,Body=scroll}; return pages[title]
    end
    local function showPage(name) for k,v in pairs(pages) do v.Root.Visible=(k==name) end end
    local function addSide(label,pageName)
        local b=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=THEME.BG3,Size=UDim2.new(1,0,0,32),Font=FONTS.H,Text=label,TextColor3=THEME.TEXT,TextSize=14,TextTruncate=Enum.TextTruncate.AtEnd},side)
        corner(b,8); stroke(b,1,THEME.BORDER); hover(b,{BackgroundColor3=THEME.BG2},{BackgroundColor3=THEME.BG3})
        b.MouseButton1Click:Connect(function()
            for _,c in ipairs(side:GetChildren()) do if c:IsA("TextButton") then TweenService:Create(c,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundColor3=THEME.BG3}):Play() end end
            TweenService:Create(b,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundColor3=THEME.BG2}):Play()
            showPage(pageName)
        end)
        table.insert(sideButtons,b); return b
    end

    -- Menu toggles sidebar visibility
    hover(menuBtn,{BackgroundColor3=THEME.BG2},{BackgroundColor3=THEME.BG3})
    menuBtn.MouseButton1Click:Connect(function()
        setSidebarVisible(not sidebarVisible)
    end)

    -- Helper function to create collapsible sections (available to all pages)
    local function makeCollapsibleSection(parent, title, initiallyExpanded)
        local sectionFrame = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,0)},parent) -- Height will be auto-calculated
        corner(sectionFrame,8); stroke(sectionFrame,1,THEME.BORDER)
        
        -- Header with expand/collapse button
    local header = mk("Frame",{BackgroundColor3=THEME.BG2,Size=UDim2.new(1,0,0,36)},sectionFrame)
        corner(header,8); stroke(header,1,THEME.BORDER)
        
        local expandBtn = mk("TextButton",{
            Text = initiallyExpanded and "▼" or "►",
            Font = FONTS.H, TextSize = 14, TextColor3 = THEME.TEXT,
            BackgroundTransparency = 1,
            Size = UDim2.new(0,20,1,0),
            Position = UDim2.new(0,8,0,0)
        }, header)
        
        local titleLabel = mk("TextLabel",{
            Text = title,
            Font = FONTS.HB, TextSize = 16, TextColor3 = THEME.TEXT,
            BackgroundTransparency = 1,
            Size = UDim2.new(1,-36,1,0),
            Position = UDim2.new(0,28,0,0),
            TextXAlignment = Enum.TextXAlignment.Left
        }, header)
        
        -- Content area
    local content = mk("Frame",{
            BackgroundTransparency = 1,
            Position = UDim2.new(0,0,0,36),
            Size = UDim2.new(1,0,1,-36),
            Visible = initiallyExpanded
        }, sectionFrame)
    sectionFrame.ClipsDescendants = true
    content.ClipsDescendants = true
        pad(content,8,8,8,8); vlist(content,6)
        
        local isExpanded = initiallyExpanded
        local contentLayout = content:FindFirstChildOfClass("UIListLayout")
        
        -- Function to update section height based on content
        local function updateHeight()
            if isExpanded and contentLayout then
                local contentHeight = contentLayout.AbsoluteContentSize.Y + 16 -- padding
                sectionFrame.Size = UDim2.new(1,0,0,36 + contentHeight)
            else
                sectionFrame.Size = UDim2.new(1,0,0,36)
            end
        end
        
        -- Connect to content size changes
        if contentLayout then
            contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateHeight)
        end
        
        -- Expand/collapse functionality
        expandBtn.MouseButton1Click:Connect(function()
            isExpanded = not isExpanded
            expandBtn.Text = isExpanded and "▼" or "►"
            content.Visible = isExpanded
            
            -- Animate the expansion/collapse
            updateHeight()
        end)
        
        -- Initial height setup
        updateHeight()
        
        return content
    end

    -- Pages -------------------------------------------------------------------
    do
        local P = makePage("Main")
        
        -- AUTO COLLECTION SECTION
    local autoCollectSection = makeCollapsibleSection(P.Body, "Auto Collection", false)

        -- Auto-Collect toggle using existing AUTO system
        makeToggle(
            autoCollectSection,
            "Auto-Collect Plants",
            "Automatically collect all ready plants continuously",
            AUTO.enabled,
            function(on)
                if on then
                    AutoStart(toast)
                else
                    AutoStop(toast)
                end
            end,
            toast
        )

        -- Mutation Filter UI (text list + toggle)
        local rowMF = mk("Frame", {BackgroundColor3=THEME.CARD, Size=UDim2.new(1,0,0,46)}, autoCollectSection)
        corner(rowMF,8); stroke(rowMF,1,THEME.BORDER); pad(rowMF,6,6,6,6)

        local tb = mk("TextBox", {
            Text = MUTATION.lastText or "",
            PlaceholderText = "Mutations to collect (e.g. Glimmering, Rainbow, Golden, etc)",
            Font = FONTS.H, TextSize = 14, TextColor3 = THEME.TEXT,
            BackgroundColor3 = THEME.BG2, Size = UDim2.new(1,0,1,0),
            ClearTextOnFocus = false
        }, rowMF)
        corner(tb,8); stroke(tb,1,THEME.BORDER)

        tb.FocusLost:Connect(function()
            setMutationFilterFromText(tb.Text)
            -- Update the text box to store the current filter
            MUTATION.lastText = tb.Text
            if MUTATION.enabled and next(MUTATION.set) then
                toast("Mutation filter set: "..tb.Text)
            else
                toast("Mutation filter cleared")
            end
        end)

        local mutationToggle = makeToggle(
            autoCollectSection,
            "Require Mutation Match",
            "Only harvest plants whose Variant/Mutation matches the list above",
            MUTATION.enabled,
            function(on)
                MUTATION.enabled = on and true or false
                if on and tb.Text and #tb.Text > 0 then 
                    setMutationFilterFromText(tb.Text) 
                elseif not on then
                    -- When turning off, keep the text but disable filtering
                    MUTATION.enabled = false
                    print("DEBUG: Mutation filtering disabled but text preserved")
                end
                toast("Require Mutation: "..(MUTATION.enabled and "ON" or "OFF"))
            end,
            toast
        )

        -- Manual test button for farm detection
        local rowTest = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},autoCollectSection)
        corner(rowTest,8); stroke(rowTest,1,THEME.BORDER); pad(rowTest,6,6,6,6)
        local btnTest = mk("TextButton",{
            Text="Test Farm Detection",
            Font=FONTS.H, TextSize=16, TextColor3=THEME.TEXT,
            BackgroundColor3=THEME.BG2, Size=UDim2.new(1,0,1,0), AutoButtonColor=false
        }, rowTest)
        corner(btnTest,8); stroke(btnTest,1,THEME.BORDER); hover(btnTest,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        btnTest.MouseButton1Click:Connect(function()
            print("=== MANUAL FARM TEST ===")
            print("Player name:", CACHE.playerName)
            print("Cached farm:", CACHE.playerFarm and CACHE.playerFarm.Name or "NONE")
            print("Cached plants folder:", CACHE.plantsFolder and "EXISTS" or "NONE")
            
            local plants = getAllPlants()
            print("Plants found:", #plants)
            
            if #plants > 0 then
                print("First few plants:")
                for i = 1, math.min(5, #plants) do
                    print("  -", plants[i].Name)
                end
                toast("Found " .. #plants .. " plants in your farm")
            else
                toast("No plants found - check console for details")
            end
        end)

        -- AUTO SELL SECTION
    local autoSellSection = makeCollapsibleSection(P.Body, "Auto Sell", false)

        -- Auto-Sell toggle
        makeToggle(
            autoSellSection,
            "Auto-Sell Inventory",
            "Automatically sell when game shows 'inventory full' message",
            AUTO_SELL.enabled,
            function(on)
                if on then
                    startAutoSell(toast)
                else
                    stopAutoSell(toast)
                end
            end,
            toast
        )

        -- Manual sell test button
        local rowSell = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},autoSellSection)
        corner(rowSell,8); stroke(rowSell,1,THEME.BORDER); pad(rowSell,6,6,6,6)
        local btnSell = mk("TextButton",{
            Text="Test Sell Now",
            Font=FONTS.H, TextSize=16, TextColor3=THEME.TEXT,
            BackgroundColor3=THEME.BG2, Size=UDim2.new(1,0,1,0), AutoButtonColor=false
        }, rowSell)
        corner(btnSell,8); stroke(btnSell,1,THEME.BORDER); hover(btnSell,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        btnSell.MouseButton1Click:Connect(function()
            print("=== MANUAL SELL TEST ===")
            
            if performAutoSell() then
                toast("Inventory sold successfully!")
            else
                toast("Sell failed - check console for details")
            end
        end)
    end

    -- Removed legacy GAG Hub page; moved UI Options into Misc page

    do
        local P=makePage("Player")
        local GM = groupBox(P.Body, "Movement")
        makeToggle(GM,"Enable Custom WalkSpeed","Apply your chosen speed",false,function(on) setCustomSpeed(on) end,toast)

        local dragging=false; local prevDrag=true
        local function lockDrag() if not dragging then dragging=true; prevDrag=win.Draggable; win.Draggable=false end end
        local function unlockDrag() if dragging then dragging=false; win.Draggable=(prevDrag==nil) and true or prevDrag end end

        sliderRow(GM, "WalkSpeed", SPEED.MIN, SPEED.MAX, SPEED.Chosen, function(v)
            SPEED.Chosen=v
            if SPEED.Enabled then applySpeedValue(v) end
        end, lockDrag, unlockDrag)

        makeToggle(GM,"Fly","WASD + E/Q for up/down",false,function(on) setFly(on) end,toast)
        sliderRow(GM, "Fly Speed", 20, 300, Fly.Speed, function(v) Fly.Speed=v end, lockDrag, unlockDrag)

        local GA = groupBox(P.Body, "Abilities / Utility")
        makeToggle(GA,"Infinite Jump","Allow jumping mid-air",false,function(on) InfiniteJump.Enabled=on end,toast)
        makeToggle(GA,"NoClip","Disable collisions on your character",false,function(on) setNoClip(on) end,toast)
        makeToggle(GA,"Ctrl + Click Teleport","Hold LeftCtrl and click to teleport",false,function(on) Teleport.Enabled=on end,toast)
    end

    -- MISC PAGE (formerly World) ---------------------------------------------
    do
        local P=makePage("Misc")

        -- UI Options (moved from GAG Hub) as a collapsible section
        local U = makeCollapsibleSection(P.Body, "UI Options", false)
        makeToggle(U, "Compact Sidebar", "Shrink sidebar width", false, function(on)
            setSidebarCompact(on)
        end, toast)

        -- Visuals section (collapsible)
        local V = makeCollapsibleSection(P.Body, "Visuals", false)
        makeToggle(V, "Vibrant Grass Overlay", "Client-only overlay (no duplicates)", false, function(on)
            if on then GO_Start() else GO_Stop() end
        end, toast)

    -- Beach controls (moved under Visuals)
    local row1 = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},V)
        corner(row1,8); stroke(row1,1,THEME.BORDER); pad(row1,6,6,6,6)
        local bb = mk("TextButton",{Text="Build Beach",Font=FONTS.H,TextSize=16,TextColor3=THEME.TEXT,BackgroundColor3=THEME.BG2,Size=UDim2.new(.5,-4,1,0),AutoButtonColor=false},row1)
        local cb = mk("TextButton",{Text="Clear Beach",Font=FONTS.H,TextSize=16,TextColor3=THEME.TEXT,BackgroundColor3=THEME.BG2,Size=UDim2.new(.5,-4,1,0),Position=UDim2.new(.5,8,0,0),AutoButtonColor=false},row1)
        corner(bb,8); stroke(bb,1,THEME.BORDER); hover(bb,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        corner(cb,8); stroke(cb,1,THEME.BORDER); hover(cb,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        bb.MouseButton1Click:Connect(function() beachBuild(); toast("Beach built (client)") end)
        cb.MouseButton1Click:Connect(function() beachCleanup(); toast("Beach cleared") end)

    local row2 = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},V)
        corner(row2,8); stroke(row2,1,THEME.BORDER); pad(row2,6,6,6,6)
        local pb = mk("TextButton",{Text="Print Anchor CFrame",Font=FONTS.H,TextSize=16,TextColor3=THEME.TEXT,BackgroundColor3=THEME.BG2,Size=UDim2.new(1,0,1,0),AutoButtonColor=false},row2)
        corner(pb,8); stroke(pb,1,THEME.BORDER); hover(pb,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        pb.MouseButton1Click:Connect(function()
            if BEACH.anchorCF then beachLogCF(BEACH.anchorCF, "Current Anchor") else toast("Build beach first to set anchor") end
        end)
    end

    -- (Removed stray duplicated 'Load Fairy Watcher' block previously misplaced here)

    -- SCRIPTS PAGE -------------------------------------------------------------
    do
        local P=makePage("Scripts")
        local S = groupBox(P.Body, "Quick Executors")

        -- Row: Load Infinite Yield
        local row = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},S)
        corner(row,8); stroke(row,1,THEME.BORDER); pad(row,6,6,6,6)
        local iy = mk("TextButton",{Text="Load Infinite Yield",Font=FONTS.H,TextSize=16,TextColor3=THEME.TEXT,BackgroundColor3=THEME.BG2,Size=UDim2.new(1,0,1,0),AutoButtonColor=false},row)
        corner(iy,8); stroke(iy,1,THEME.BORDER); hover(iy,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        iy.MouseButton1Click:Connect(function()
            toast("Loading Infinite Yield…")
            execInfiniteYield(toast)
        end)

        -- Row: Load Fairy Watcher (external)
        local rowFairy = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},S)
        corner(rowFairy,8); stroke(rowFairy,1,THEME.BORDER); pad(rowFairy,6,6,6,6)
        local btnFairy = mk("TextButton",{
            Text="Load Fairy Watcher",
            Font=FONTS.H, TextSize=16, TextColor3=THEME.TEXT,
            BackgroundColor3=THEME.BG2, Size=UDim2.new(1,0,1,0), AutoButtonColor=false
        }, rowFairy)
        corner(btnFairy,8); stroke(btnFairy,1,THEME.BORDER); hover(btnFairy,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        btnFairy.MouseButton1Click:Connect(function()
            toast("Loading Fairy Watcher…")
            local ok, err = pcall(function()
                loadstring(game:HttpGet("https://raw.githubusercontent.com/CheesyPoofs346/fairy/refs/heads/main/Protected_7114364430847823.lua"))()
            end)
            if not ok then
                warn("[Fairy Watcher] ".. tostring(err))
                toast("Fairy Watcher: error (see Output)")
            end
        end)
    end

    -- EVENTS PAGE -------------------------------------------------------------
    do
    local P = makePage("Events")
    local autoFairySection = makeCollapsibleSection(P.Body, "Fairy Fountain Auto Submit", false)

        -- Auto-Fairy toggle
        makeToggle(
            autoFairySection,
            "Auto Submit to Fairy",
            "Automatically submit to fairy fountain when glimmering plant is detected in backpack",
            AUTO_FAIRY.enabled,
            function(on)
                if on then
                    startAutoFairy(toast)
                else
                    stopAutoFairy(toast)
                end
            end,
            toast
        )

        -- Manual test button for fairy submission
        local rowFairyTest = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},autoFairySection)
        corner(rowFairyTest,8); stroke(rowFairyTest,1,THEME.BORDER); pad(rowFairyTest,6,6,6,6)
        local btnFairyTest = mk("TextButton",{
            Text="Test Fairy Submit Now",
            Font=FONTS.H, TextSize=16, TextColor3=THEME.TEXT,
            BackgroundColor3=THEME.BG2, Size=UDim2.new(1,0,1,0), AutoButtonColor=false
        }, rowFairyTest)
        corner(btnFairyTest,8); stroke(btnFairyTest,1,THEME.BORDER); hover(btnFairyTest,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        btnFairyTest.MouseButton1Click:Connect(function()
            print("=== MANUAL FAIRY TEST ===")
            
            if submitToFairyFountain() then
                toast("Fairy submission successful!")
            else
                toast("Fairy submission failed - check console for details")
            end
        end)

        -- Check backpack status button
        local rowBackpackCheck = mk("Frame",{BackgroundColor3=THEME.CARD,Size=UDim2.new(1,0,0,46)},autoFairySection)
        corner(rowBackpackCheck,8); stroke(rowBackpackCheck,1,THEME.BORDER); pad(rowBackpackCheck,6,6,6,6)
        local btnBackpackCheck = mk("TextButton",{
            Text="Check for Glimmering in Backpack",
            Font=FONTS.H, TextSize=16, TextColor3=THEME.TEXT,
            BackgroundColor3=THEME.BG2, Size=UDim2.new(1,0,1,0), AutoButtonColor=false
        }, rowBackpackCheck)
        corner(btnBackpackCheck,8); stroke(btnBackpackCheck,1,THEME.BORDER); hover(btnBackpackCheck,{BackgroundColor3=THEME.BG3},{BackgroundColor3=THEME.BG2})
        btnBackpackCheck.MouseButton1Click:Connect(function()
            print("=== BACKPACK GLIMMERING CHECK ===")
            
            if hasGlimmeringInBackpack() then
                toast("Glimmering plant found in backpack!")
                print("DEBUG: Glimmering plant detected")
            else
                toast("No glimmering plants in backpack")
            end
        end)
    end

    -- SHOPS PAGE -------------------------------------------------------------
    do
    local P = makePage("Shops")
    local seedShopSection = makeCollapsibleSection(P.Body, "Seed Shop Auto Buy", false)
    local gearShopSection = makeCollapsibleSection(P.Body, "Gear Shop Auto Buy", false)

        -- Function to scan for available seeds in the shop
        local function getAvailableSeeds()
            AUTO_SHOP.availableSeeds = {}
            
            print("DEBUG: Starting seed shop scan using SeedData module...")
            
            -- Read directly from the game's SeedData module (same data the shop uses)
            local success, seedData = pcall(function()
                return require(ReplicatedStorage.Data.SeedData)
            end)
            
            if success and seedData then
                print("DEBUG: Successfully loaded SeedData module")
                
                -- Loop through all seeds in the data (same way the shop does)
                for seedKey, seedInfo in pairs(seedData) do
                    -- Only include seeds that are displayed in shop (same check as game)
                    if seedInfo.DisplayInShop then
                        print("DEBUG: Found shop seed:", seedKey, "->", seedInfo.SeedName)
                        
                        table.insert(AUTO_SHOP.availableSeeds, {
                            key = seedKey,
                            name = seedInfo.SeedName,
                            price = seedInfo.Price,
                            layoutOrder = seedInfo.LayoutOrder or 999,
                            displayName = seedInfo.SeedName, -- Remove extra "Seeds" since SeedName already includes it
                            selected = false
                        })
                    end
                end
                
                -- Sort seeds by their LayoutOrder (same order as in the actual shop)
                table.sort(AUTO_SHOP.availableSeeds, function(a, b)
                    if a.layoutOrder == b.layoutOrder then
                        return a.name < b.name
                    else
                        return a.layoutOrder < b.layoutOrder
                    end
                end)
                
                print("DEBUG: Loaded", #AUTO_SHOP.availableSeeds, "seeds from SeedData module")
            else
                print("DEBUG: Failed to load SeedData module, falling back to simple detection...")
                
                -- Fallback: Use common seed names if module loading fails
                local commonSeeds = {"Carrot Seeds", "Tomato Seeds", "Potato Seeds", "Corn Seeds", "Wheat Seeds", "Apple Seeds", "Orange Seeds", "Pineapple Seeds"}
                for i, seedName in ipairs(commonSeeds) do
                    table.insert(AUTO_SHOP.availableSeeds, {
                        key = string.gsub(seedName, " Seeds", ""), -- Remove "Seeds" for the key
                        name = seedName,
                        price = 0,
                        layoutOrder = i,
                        displayName = seedName,
                        selected = false
                    })
                    print("DEBUG: Added fallback seed:", seedName)
                end
            end
            
            print("DEBUG: Seed shop scan complete. Found", #AUTO_SHOP.availableSeeds, "seed options")
            return AUTO_SHOP.availableSeeds
        end

        -- Function to test if a specific seed is available by monitoring game responses
        local function validateSeedAvailability()
            print("DEBUG: Validating seed availability...")
            
            -- This function could be enhanced to:
            -- 1. Monitor for error messages when attempting purchases
            -- 2. Check if the shop GUI contains specific seed names
            -- 3. Analyze the SeedShopController module if accessible
            
            -- For now, keep all detected seeds as potentially available
            -- Users can test with individual "Buy" buttons to see what works
        end

        -- Initialize available seeds
        getAvailableSeeds()

    -- Header label
    local headerLabel = Instance.new("TextLabel")
    headerLabel.Parent = seedShopSection
    headerLabel.BackgroundTransparency = 1
    headerLabel.Size = UDim2.new(1, -20, 0, 24)
    headerLabel.Position = UDim2.new(0, 10, 0, 50)
    headerLabel.Text = "Select Seeds"
    headerLabel.TextColor3 = THEME.TEXT
    headerLabel.TextXAlignment = Enum.TextXAlignment.Left
    headerLabel.Font = Enum.Font.GothamBold
    headerLabel.TextSize = 14

        -- Predeclare toggles for cross-control
        local autoBuyTgl
        local autoBuyAllTgl

        -- Auto Buy Selected Seeds toggle (match global toggle style)
        autoBuyTgl = makeToggle(
            seedShopSection,
            "Auto Buy Selected Seeds",
            "Continuously buys the seeds you select below",
            AUTO_SHOP.enabled,
            function(on)
                AUTO_SHOP.modeSelected = on and true or false
                if on then
                    -- If switching to selected mode while buy-all is on, turn buy-all off
                    if AUTO_SHOP.buyAll then
                        AUTO_SHOP.buyAll = false
                        AUTO_SHOP.modeAll = false
                        if autoBuyAllTgl and autoBuyAllTgl.Set then autoBuyAllTgl.Set(false) end
                        if toast then toast("Auto Buy All Seeds turned OFF (using Selected mode)") end
                    end
                    if #AUTO_SHOP.selectedSeeds > 0 then
                        if not AUTO_SHOP.enabled then startAutoShop(toast) end
                    else
                        if toast then toast("Please select at least one seed first!") end
                        AUTO_SHOP.modeSelected = false
                        autoBuyTgl.Set(false)
                        -- If nothing else is active, stop loop
                        if AUTO_SHOP.enabled and not AUTO_SHOP.modeAll then stopAutoShop(toast) end
                    end
                else
                    -- Turning off selected mode
                    if AUTO_SHOP.enabled and not AUTO_SHOP.modeAll then
                        stopAutoShop(toast)
                    end
                end
            end,
            toast
        )
        -- Place it where the old row was
    autoBuyTgl.Instance.Position = UDim2.new(0, 10, 0, 82)
        autoBuyTgl.Instance.Size = UDim2.new(1, -20, 0, 46)

    -- Auto Buy All Seeds toggle (mutually exclusive with selected)
    autoBuyAllTgl = makeToggle(
            seedShopSection,
            "Auto Buy All Seeds",
            "Continuously buys every seed that appears in the shop",
            AUTO_SHOP.buyAll,
            function(on)
                AUTO_SHOP.buyAll = on and true or false
                AUTO_SHOP.modeAll = AUTO_SHOP.buyAll
                
                -- If turning on "all" while selected is on, turn off selected
        if AUTO_SHOP.buyAll and (AUTO_SHOP.modeSelected) then
                    if toast then toast("Auto Buy Selected turned OFF (using All Seeds mode)") end
                    AUTO_SHOP.modeSelected = false
                    autoBuyTgl.Set(false)
                    -- Keep AUTO_SHOP.enabled true; startAutoShop already running
                end
                
                -- If enabling while auto-shop is on, nothing else to do; loop picks it up
                -- If enabling and auto-shop is off, require user to toggle Auto Buy Selected separately to start, or we can auto-start here:
                if on and not AUTO_SHOP.enabled then
                    -- Start loop with buyAll mode
                    if #AUTO_SHOP.availableSeeds == 0 then getAvailableSeeds() end
                    startAutoShop(toast)
        elseif (not on) and AUTO_SHOP.enabled and (not AUTO_SHOP.modeSelected) then
                    -- If both modes are off, stop auto-shop
                    stopAutoShop(toast)
                end
            end,
            toast
        )
        autoBuyAllTgl.Instance.Position = UDim2.new(0, 10, 0, 132)
        autoBuyAllTgl.Instance.Size = UDim2.new(1, -20, 0, 46)

    -- (Tier row removed; auto-detection no longer needed)

        -- Seed Selection Dropdown
        local dropdownContainer = Instance.new("Frame")
        dropdownContainer.Parent = seedShopSection
        dropdownContainer.BackgroundTransparency = 1
        dropdownContainer.Size = UDim2.new(1, -20, 0, 40)
    dropdownContainer.Position = UDim2.new(0, 10, 0, 184)

        -- Main dropdown button
        local dropdownButton = Instance.new("TextButton")
        dropdownButton.Parent = dropdownContainer
        dropdownButton.BackgroundColor3 = THEME.BG2
        dropdownButton.BorderSizePixel = 0
        dropdownButton.Size = UDim2.new(1, 0, 1, 0)
        dropdownButton.Text = "Select Seeds ▼"
        dropdownButton.TextColor3 = THEME.TEXT
        dropdownButton.TextXAlignment = Enum.TextXAlignment.Left
        dropdownButton.Font = Enum.Font.Gotham
        dropdownButton.TextSize = 13
        corner(dropdownButton, 8)
        stroke(dropdownButton, 1, THEME.BORDER)
        pad(dropdownButton, 0, 0, 0, 15)

        -- Dropdown list (initially hidden)
    local seedListFrame = Instance.new("ScrollingFrame")
        seedListFrame.Parent = seedShopSection
        seedListFrame.BackgroundColor3 = THEME.BG1
        seedListFrame.BorderSizePixel = 0
        seedListFrame.Size = UDim2.new(1, -20, 0, 200)
    seedListFrame.Position = UDim2.new(0, 10, 0, 229)
        seedListFrame.Visible = false
        seedListFrame.CanvasSize = UDim2.new(0, 0, 0, #AUTO_SHOP.availableSeeds * 35 + 10)
        seedListFrame.ScrollBarThickness = 8
    seedListFrame.ClipsDescendants = true
        corner(seedListFrame, 8)
        stroke(seedListFrame, 1, THEME.BORDER)

        local seedListLayout = Instance.new("UIListLayout")
        seedListLayout.Parent = seedListFrame
        seedListLayout.Padding = UDim.new(0, 3)
        seedListLayout.SortOrder = Enum.SortOrder.LayoutOrder

        -- Function to update dropdown display text
        local function updateDropdownText()
            local selectedCount = #AUTO_SHOP.selectedSeeds
            if selectedCount == 0 then
                dropdownButton.Text = "Select Seeds ▼"
            elseif selectedCount == 1 then
                dropdownButton.Text = AUTO_SHOP.selectedSeeds[1].displayName .. " ▼"
            else
                local names = {}
                for i = 1, math.min(selectedCount, 3) do
                    table.insert(names, AUTO_SHOP.selectedSeeds[i].displayName)
                end
                if selectedCount > 3 then
                    dropdownButton.Text = table.concat(names, ", ") .. " +" .. (selectedCount - 3) .. " more ▼"
                else
                    dropdownButton.Text = table.concat(names, ", ") .. " ▼"
                end
            end
        end

        -- Function to create seed selection list (with an 'All' row at the top)
        local function createSeedList()
            -- Clear existing items
            for _, child in ipairs(seedListFrame:GetChildren()) do
                if child:IsA("Frame") then
                    child:Destroy()
                end
            end

            -- All row: quick-select everything
            do
                local allRow = Instance.new("Frame")
                allRow.Parent = seedListFrame
                allRow.BackgroundColor3 = THEME.BG2
                allRow.BorderSizePixel = 0
                allRow.Size = UDim2.new(1, -16, 0, 32)
                allRow.LayoutOrder = 0
                corner(allRow, 6)

                local allBtn = Instance.new("TextButton")
                allBtn.Parent = allRow
                allBtn.BackgroundTransparency = 1
                allBtn.Size = UDim2.new(1, 0, 1, 0)
                allBtn.Text = "All"
                allBtn.TextColor3 = THEME.TEXT
                allBtn.Font = Enum.Font.Gotham
                allBtn.TextSize = 13
                
                allBtn.MouseButton1Click:Connect(function()
                    -- Check if all are currently selected
                    local allSelected = true
                    for _, sd in ipairs(AUTO_SHOP.availableSeeds) do
                        if not sd.selected then allSelected = false break end
                    end

                    AUTO_SHOP.selectedSeeds = {}
                    if allSelected then
                        -- Unselect all
                        for _, sd in ipairs(AUTO_SHOP.availableSeeds) do sd.selected = false end
                        -- selectedSeeds remains empty
                        if toast then toast("Cleared all selections") end
                    else
                        -- Select all
                        for _, sd in ipairs(AUTO_SHOP.availableSeeds) do sd.selected = true; table.insert(AUTO_SHOP.selectedSeeds, sd) end
                        if toast then toast("Selected all " .. #AUTO_SHOP.availableSeeds .. " seeds!") end
                    end

                    createSeedList()
                    updateDropdownText()
                end)

                allRow.MouseEnter:Connect(function() allRow.BackgroundColor3 = THEME.BG3 end)
                allRow.MouseLeave:Connect(function() allRow.BackgroundColor3 = THEME.BG2 end)
            end

            for i, seedData in ipairs(AUTO_SHOP.availableSeeds) do
                local seedRow = Instance.new("Frame")
                seedRow.Parent = seedListFrame
                seedRow.BackgroundColor3 = THEME.BG2
                seedRow.BorderSizePixel = 0
                seedRow.Size = UDim2.new(1, -16, 0, 32)
                seedRow.LayoutOrder = i + 1
                corner(seedRow, 6)

                -- Checkbox
                local checkbox = Instance.new("TextButton")
                checkbox.Parent = seedRow
                checkbox.BackgroundColor3 = seedData.selected and Color3.fromRGB(0, 150, 0) or THEME.BG3
                checkbox.Size = UDim2.new(0, 24, 0, 24)
                checkbox.Position = UDim2.new(0, 8, 0.5, -12)
                checkbox.Text = ""
                checkbox.BorderSizePixel = 0
                corner(checkbox, 4)
                stroke(checkbox, 1, THEME.BORDER)

                local checkmark = Instance.new("TextLabel")
                checkmark.Parent = checkbox
                checkmark.BackgroundTransparency = 1
                checkmark.Size = UDim2.new(1, 0, 1, 0)
                checkmark.Text = "✓"
                checkmark.TextColor3 = Color3.fromRGB(255, 255, 255)
                checkmark.TextScaled = true
                checkmark.Font = Enum.Font.GothamBold
                checkmark.Visible = seedData.selected or false

                -- Seed name and price
                local seedLabel = Instance.new("TextLabel")
                seedLabel.Parent = seedRow
                seedLabel.BackgroundTransparency = 1
                seedLabel.Size = UDim2.new(1, -40, 1, 0)
                seedLabel.Position = UDim2.new(0, 40, 0, 0)
                seedLabel.Text = seedData.displayName .. (seedData.price > 0 and (" - " .. seedData.price .. "¢") or "")
                seedLabel.TextColor3 = THEME.TEXT
                seedLabel.TextXAlignment = Enum.TextXAlignment.Left
                seedLabel.Font = Enum.Font.Gotham
                seedLabel.TextSize = 13

                -- Click functionality for entire row
                local function toggleSelection()
                    seedData.selected = not (seedData.selected or false)
                    checkbox.BackgroundColor3 = seedData.selected and Color3.fromRGB(0, 150, 0) or THEME.BG3
                    checkmark.Visible = seedData.selected
                    
                    -- Update selected seeds list
                    AUTO_SHOP.selectedSeeds = {}
                    for _, seed in ipairs(AUTO_SHOP.availableSeeds) do
                        if seed.selected then
                            table.insert(AUTO_SHOP.selectedSeeds, seed)
                        end
                    end
                    
                    -- Update dropdown text
                    updateDropdownText()
                end

                checkbox.MouseButton1Click:Connect(toggleSelection)
                seedRow.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 then
                        toggleSelection()
                    end
                end)

                -- Hover effect for the row
                seedRow.MouseEnter:Connect(function()
                    if not seedData.selected then
                        seedRow.BackgroundColor3 = THEME.BG3
                    end
                end)
                seedRow.MouseLeave:Connect(function()
                    if not seedData.selected then
                        seedRow.BackgroundColor3 = THEME.BG2
                    end
                end)
            end

            -- Update canvas size and dropdown text
            seedListFrame.CanvasSize = UDim2.new(0, 0, 0, (#AUTO_SHOP.availableSeeds + 1) * 35 + 10)
            updateDropdownText()
        end

        -- Toggle dropdown visibility
        dropdownButton.MouseButton1Click:Connect(function()
            seedListFrame.Visible = not seedListFrame.Visible
            local isOpen = seedListFrame.Visible
            dropdownButton.Text = dropdownButton.Text:gsub("▼", isOpen and "▲" or "▼")
            dropdownButton.Text = dropdownButton.Text:gsub("▲", isOpen and "▲" or "▼")
        end)

    -- Close dropdown when clicking outside
        local UserInputService = game:GetService("UserInputService")
        UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                if seedListFrame.Visible then
                    local mousePos = UserInputService:GetMouseLocation()
                    local dropdownPos = dropdownButton.AbsolutePosition
                    local dropdownSize = dropdownButton.AbsoluteSize
                    local listPos = seedListFrame.AbsolutePosition
                    local listSize = seedListFrame.AbsoluteSize
                    
                    -- Check if click is outside both the dropdown button and the list
                    local outsideDropdown = mousePos.X < dropdownPos.X or mousePos.X > dropdownPos.X + dropdownSize.X or
                                          mousePos.Y < dropdownPos.Y or mousePos.Y > dropdownPos.Y + dropdownSize.Y
                    local outsideList = mousePos.X < listPos.X or mousePos.X > listPos.X + listSize.X or
                                       mousePos.Y < listPos.Y or mousePos.Y > listPos.Y + listSize.Y
                    
                    if outsideDropdown and outsideList then
                        seedListFrame.Visible = false
                        updateDropdownText()
                    end
                end
            end
        end)

    -- Removed extra action toggles; handled via dropdown 'All' button and auto modes

    -- Auto toggle handled by makeToggle above

    -- Initialize seed list
        createSeedList()

    -- =================== Gear Shop =====================
    local function getAvailableGear()
        _loadGearData()
        return AUTO_GEAR.availableGear
    end

    getAvailableGear()

    local gearHeader = Instance.new("TextLabel")
    gearHeader.Parent = gearShopSection
    gearHeader.BackgroundTransparency = 1
    gearHeader.Size = UDim2.new(1, -20, 0, 24)
    gearHeader.Position = UDim2.new(0, 10, 0, 50)
    gearHeader.Text = "Select Gear"
    gearHeader.TextColor3 = THEME.TEXT
    gearHeader.TextXAlignment = Enum.TextXAlignment.Left
    gearHeader.Font = Enum.Font.GothamBold
    gearHeader.TextSize = 14

    local gearAutoSelectedTgl, gearAutoAllTgl
    gearAutoSelectedTgl = makeToggle(
        gearShopSection,
        "Auto Buy Selected Gear",
        "Continuously buys the gear you select below",
        AUTO_GEAR.enabled,
        function(on)
            AUTO_GEAR.modeSelected = on and true or false
            if on then
                if AUTO_GEAR.buyAll then
                    AUTO_GEAR.buyAll = false; AUTO_GEAR.modeAll = false
                    if gearAutoAllTgl and gearAutoAllTgl.Set then gearAutoAllTgl.Set(false) end
                end
                if #AUTO_GEAR.selectedGear > 0 then
                    if not AUTO_GEAR.enabled then startAutoGear(toast) end
                else
                    toast("Please select at least one gear first!")
                    AUTO_GEAR.modeSelected = false
                    gearAutoSelectedTgl.Set(false)
                    if AUTO_GEAR.enabled and not AUTO_GEAR.modeAll then stopAutoGear(toast) end
                end
            else
                if AUTO_GEAR.enabled and not AUTO_GEAR.modeAll then stopAutoGear(toast) end
            end
        end,
        toast
    )
    gearAutoSelectedTgl.Instance.Position = UDim2.new(0, 10, 0, 82)
    gearAutoSelectedTgl.Instance.Size = UDim2.new(1, -20, 0, 46)

    gearAutoAllTgl = makeToggle(
        gearShopSection,
        "Auto Buy All Gear",
        "Continuously buys every gear item that appears in the shop",
        AUTO_GEAR.buyAll,
        function(on)
            AUTO_GEAR.buyAll = on and true or false
            AUTO_GEAR.modeAll = AUTO_GEAR.buyAll
            if AUTO_GEAR.buyAll and AUTO_GEAR.modeSelected then
                toast("Auto Buy Selected (Gear) turned OFF (using All mode)")
                AUTO_GEAR.modeSelected = false
                gearAutoSelectedTgl.Set(false)
            end
            if on and not AUTO_GEAR.enabled then
                if #AUTO_GEAR.availableGear == 0 then getAvailableGear() end
                startAutoGear(toast)
            elseif (not on) and AUTO_GEAR.enabled and (not AUTO_GEAR.modeSelected) then
                stopAutoGear(toast)
            end
        end,
        toast
    )
    gearAutoAllTgl.Instance.Position = UDim2.new(0, 10, 0, 132)
    gearAutoAllTgl.Instance.Size = UDim2.new(1, -20, 0, 46)

    local gearDropdownContainer = Instance.new("Frame")
    gearDropdownContainer.Parent = gearShopSection
    gearDropdownContainer.BackgroundTransparency = 1
    gearDropdownContainer.Size = UDim2.new(1, -20, 0, 40)
    gearDropdownContainer.Position = UDim2.new(0, 10, 0, 184)

    local gearDropdownButton = Instance.new("TextButton")
    gearDropdownButton.Parent = gearDropdownContainer
    gearDropdownButton.BackgroundColor3 = THEME.BG2
    gearDropdownButton.BorderSizePixel = 0
    gearDropdownButton.Size = UDim2.new(1, 0, 1, 0)
    gearDropdownButton.Text = "Select Gear ▼"
    gearDropdownButton.TextColor3 = THEME.TEXT
    gearDropdownButton.TextXAlignment = Enum.TextXAlignment.Left
    gearDropdownButton.Font = Enum.Font.Gotham
    gearDropdownButton.TextSize = 13
    corner(gearDropdownButton, 8)
    stroke(gearDropdownButton, 1, THEME.BORDER)
    pad(gearDropdownButton, 0, 0, 0, 15)

    local gearListFrame = Instance.new("ScrollingFrame")
    gearListFrame.Parent = gearShopSection
    gearListFrame.BackgroundColor3 = THEME.BG1
    gearListFrame.BorderSizePixel = 0
    gearListFrame.Size = UDim2.new(1, -20, 0, 200)
    gearListFrame.Position = UDim2.new(0, 10, 0, 229)
    gearListFrame.Visible = false
    gearListFrame.CanvasSize = UDim2.new(0, 0, 0, #AUTO_GEAR.availableGear * 35 + 10)
    gearListFrame.ScrollBarThickness = 8
    gearListFrame.ClipsDescendants = true
    corner(gearListFrame, 8); stroke(gearListFrame, 1, THEME.BORDER)
    local gearListLayout = Instance.new("UIListLayout"); gearListLayout.Parent = gearListFrame; gearListLayout.Padding = UDim.new(0, 3); gearListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local function updateGearDropdownText()
        local n = #AUTO_GEAR.selectedGear
        if n == 0 then gearDropdownButton.Text = "Select Gear ▼"
        elseif n == 1 then gearDropdownButton.Text = (AUTO_GEAR.selectedGear[1].displayName or AUTO_GEAR.selectedGear[1].name) .. " ▼"
        else
            local names = {}
            for i=1, math.min(n,3) do table.insert(names, AUTO_GEAR.selectedGear[i].displayName or AUTO_GEAR.selectedGear[i].name) end
            gearDropdownButton.Text = table.concat(names, ", ") .. (n>3 and (" +"..(n-3).." more ▼") or " ▼")
        end
    end

    local function createGearList()
        for _, ch in ipairs(gearListFrame:GetChildren()) do if ch:IsA("Frame") then ch:Destroy() end end

        -- All row
        do
            local allRow = Instance.new("Frame"); allRow.Parent = gearListFrame; allRow.BackgroundColor3 = THEME.BG2; allRow.BorderSizePixel = 0; allRow.Size = UDim2.new(1, -16, 0, 32); allRow.LayoutOrder = 0; corner(allRow, 6)
            local btn = Instance.new("TextButton"); btn.Parent = allRow; btn.BackgroundTransparency = 1; btn.Size = UDim2.new(1,0,1,0); btn.Text = "All"; btn.TextColor3 = THEME.TEXT; btn.Font = Enum.Font.Gotham; btn.TextSize = 13
            btn.MouseButton1Click:Connect(function()
                local allSelected = true; for _, it in ipairs(AUTO_GEAR.availableGear) do if not it.selected then allSelected=false break end end
                AUTO_GEAR.selectedGear = {}
                if allSelected then
                    for _, it in ipairs(AUTO_GEAR.availableGear) do it.selected=false end
                    toast("Cleared all gear selections")
                else
                    for _, it in ipairs(AUTO_GEAR.availableGear) do it.selected=true; table.insert(AUTO_GEAR.selectedGear, it) end
                    toast("Selected all "..#AUTO_GEAR.availableGear.." gear items!")
                end
                createGearList(); updateGearDropdownText()
            end)
            allRow.MouseEnter:Connect(function() allRow.BackgroundColor3 = THEME.BG3 end)
            allRow.MouseLeave:Connect(function() allRow.BackgroundColor3 = THEME.BG2 end)
        end

        for i, it in ipairs(AUTO_GEAR.availableGear) do
            local row = Instance.new("Frame"); row.Parent = gearListFrame; row.BackgroundColor3 = THEME.BG2; row.BorderSizePixel = 0; row.Size = UDim2.new(1, -16, 0, 32); row.LayoutOrder = i + 1; corner(row, 6)
            local checkbox = Instance.new("TextButton"); checkbox.Parent=row; checkbox.BackgroundColor3 = it.selected and Color3.fromRGB(0,150,0) or THEME.BG3; checkbox.Size = UDim2.new(0,24,0,24); checkbox.Position = UDim2.new(0,8,0.5,-12); checkbox.Text=""; checkbox.BorderSizePixel=0; corner(checkbox,4); stroke(checkbox,1,THEME.BORDER)
            local checkmark = Instance.new("TextLabel"); checkmark.Parent=checkbox; checkmark.BackgroundTransparency=1; checkmark.Size=UDim2.new(1,0,1,0); checkmark.Text="✓"; checkmark.TextColor3=Color3.new(1,1,1); checkmark.TextScaled=true; checkmark.Font=Enum.Font.GothamBold; checkmark.Visible = it.selected or false
            local label = Instance.new("TextLabel"); label.Parent=row; label.BackgroundTransparency=1; label.Size=UDim2.new(1,-40,1,0); label.Position=UDim2.new(0,40,0,0); label.Text=(it.displayName or it.name) .. ((it.price and it.price>0) and (" - "..it.price.."¢") or ""); label.TextColor3=THEME.TEXT; label.TextXAlignment=Enum.TextXAlignment.Left; label.Font=Enum.Font.Gotham; label.TextSize=13
            local function toggle()
                it.selected = not (it.selected or false); checkbox.BackgroundColor3 = it.selected and Color3.fromRGB(0,150,0) or THEME.BG3; checkmark.Visible = it.selected
                AUTO_GEAR.selectedGear = {}; for _, g in ipairs(AUTO_GEAR.availableGear) do if g.selected then table.insert(AUTO_GEAR.selectedGear, g) end end
                updateGearDropdownText()
            end
            checkbox.MouseButton1Click:Connect(toggle)
            row.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then toggle() end end)
            row.MouseEnter:Connect(function() if not it.selected then row.BackgroundColor3 = THEME.BG3 end end)
            row.MouseLeave:Connect(function() if not it.selected then row.BackgroundColor3 = THEME.BG2 end end)
        end
        gearListFrame.CanvasSize = UDim2.new(0,0,0,(#AUTO_GEAR.availableGear+1)*35+10)
        updateGearDropdownText()
    end

    gearDropdownButton.MouseButton1Click:Connect(function()
        gearListFrame.Visible = not gearListFrame.Visible
        local isOpen = gearListFrame.Visible
        gearDropdownButton.Text = gearDropdownButton.Text:gsub("▼", isOpen and "▲" or "▼")
        gearDropdownButton.Text = gearDropdownButton.Text:gsub("▲", isOpen and "▲" or "▼")
    end)

    UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if gearListFrame.Visible then
                local mousePos = UserInputService:GetMouseLocation()
                local btnPos, btnSize = gearDropdownButton.AbsolutePosition, gearDropdownButton.AbsoluteSize
                local listPos, listSize = gearListFrame.AbsolutePosition, gearListFrame.AbsoluteSize
                local outsideBtn = mousePos.X < btnPos.X or mousePos.X > btnPos.X + btnSize.X or mousePos.Y < btnPos.Y or mousePos.Y > btnPos.Y + btnSize.Y
                local outsideList = mousePos.X < listPos.X or mousePos.X > listPos.X + listSize.X or mousePos.Y < listPos.Y or mousePos.Y > listPos.Y + listSize.Y
                if outsideBtn and outsideList then gearListFrame.Visible = false; updateGearDropdownText() end
            end
        end
    end)

    createGearList()
    end

    addSide("Main","Main")
    addSide("Events","Events")
    addSide("Shops","Shops")
    addSide("Player","Player")
    addSide("Misc","Misc")
    addSide("Scripts","Scripts")
    applySide()
    showPage("Player")

    -- Apply glass look after UI is built, then snapshot for fades
    applyGlassLook(app)
    snapshotTransparency(win)

    local minimized=false
    local function fadeOutAll(done) tweenTo(win, FADE_DUR, true); task.delay(FADE_DUR, function() if done then done() end end) end
    local function fadeInAll() tweenTo(win, FADE_DUR, false) end
    
    -- Minimize hint overlay (separate ScreenGui so it shows while app is disabled)
    local function showMinimizeHint()
        -- Clean up any prior hint(s)
        for _, child in ipairs(CoreGui:GetChildren()) do
            if child.Name == "SpeedStyleUI_Hint" then pcall(function() child:Destroy() end) end
        end
        local hintGui = mk("ScreenGui", {Name="SpeedStyleUI_Hint", IgnoreGuiInset=true, ResetOnSpawn=false, ZIndexBehavior=Enum.ZIndexBehavior.Global}, CoreGui)
        hintGui.DisplayOrder = 9999
        -- Match toast area (top-center, ~420px wide)
        local box = mk("Frame", {Size=UDim2.new(0, 420, 0, 40), Position=UDim2.new(0.5, 0, 0, 10), AnchorPoint=Vector2.new(0.5,0), BackgroundColor3=THEME.BG2, BackgroundTransparency=0}, hintGui)
        corner(box, 8); stroke(box, 1, THEME.BORDER); pad(box, 8, 12, 8, 12)
        local lbl = mk("TextLabel", {BackgroundTransparency=1, Font=FONTS.H, Text="Press Right Ctrl to reopen", TextSize=14, TextColor3=THEME.TEXT, TextXAlignment=Enum.TextXAlignment.Center, Size=UDim2.new(1,0,1,0)}, box)
        -- subtle pop-in
        box.BackgroundTransparency = 1; lbl.TextTransparency = 1
        TweenService:Create(box, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency=0}):Play()
        TweenService:Create(lbl, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency=0}):Play()
        -- Re-apply top position on the next frame in case anything adjusted layout
        task.defer(function()
            if box and box.Parent then
                box.AnchorPoint = Vector2.new(0.5, 0)
                box.Position = UDim2.new(0.5, 0, 0, 10)
            end
        end)
        -- auto-dismiss after ~2.5s
        task.delay(2.5, function()
            if not hintGui or not hintGui.Parent then return end
            local t1 = TweenService:Create(box, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency=1})
            local t2 = TweenService:Create(lbl, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency=1})
            t1:Play(); t2:Play()
            task.wait(0.27)
            if hintGui and hintGui.Parent then hintGui:Destroy() end
        end)
    end
    local function hideMinimizeHint()
        local hint = CoreGui:FindFirstChild("SpeedStyleUI_Hint")
        if hint then hint:Destroy() end
    end

    -- Close confirmation dialog
    local function shutdownAndClose()
        -- Stop all automation systems before closing
        print("DEBUG: Shutting down all systems...")
        if AUTO.enabled then AutoStop() print("DEBUG: Auto-collect stopped") end
        -- Auto-sell: restore SetCore and disconnect listeners
        if AUTO_SELL.enabled then stopAutoSell() end
        if AUTO_SELL.messageConnection then AUTO_SELL.messageConnection:Disconnect(); AUTO_SELL.messageConnection=nil end
        if AUTO_SELL.playerGuiConn then AUTO_SELL.playerGuiConn:Disconnect(); AUTO_SELL.playerGuiConn=nil end
        if AUTO_SELL.playerGuiDescendantConns then for _,c in ipairs(AUTO_SELL.playerGuiDescendantConns) do pcall(function() c:Disconnect() end) end; AUTO_SELL.playerGuiDescendantConns = {} end
        do
            local starterGui = game:GetService("StarterGui")
            if AUTO_SELL.starterGuiSetCoreOriginal then
                starterGui.SetCore = AUTO_SELL.starterGuiSetCoreOriginal
                AUTO_SELL.starterGuiSetCoreOriginal = nil
            end
        end
        if AUTO_FAIRY.enabled then stopAutoFairy() print("DEBUG: Auto-fairy stopped") end
        -- Auto-shop
        if AUTO_SHOP.enabled then stopAutoShop() print("DEBUG: Auto-shop stopped") end
        -- World visuals
        if GO.Enabled then GO_Stop() print("DEBUG: Grass overlay stopped") end
        beachCleanup()
        -- Movement/utility
        setNoClip(false)
        stopFly()
        setCustomSpeed(false)
        Teleport.Enabled=false
        InfiniteJump.Enabled=false
        -- Disconnect globals
        if NoClip.Conn then pcall(function() NoClip.Conn:Disconnect() end); NoClip.Conn=nil end
        if Fly.Conn then pcall(function() Fly.Conn:Disconnect() end); Fly.Conn=nil end
        if JumpConn then pcall(function() JumpConn:Disconnect() end); JumpConn=nil end
        if TeleportConn then pcall(function() TeleportConn:Disconnect() end); TeleportConn=nil end
        if CharAddedConn then pcall(function() CharAddedConn:Disconnect() end); CharAddedConn=nil end
    if remoteCacheConn then pcall(function() remoteCacheConn:Disconnect() end); remoteCacheConn=nil end
    if GLOBAL_CONNS then for _,c in ipairs(GLOBAL_CONNS) do pcall(function() c:Disconnect() end) end; GLOBAL_CONNS = {} end
        -- Hide any hint overlays
        local hint = CoreGui:FindFirstChild("SpeedStyleUI_Hint"); if hint then pcall(function() hint:Destroy() end) end
    -- Stop farm scanner
    FARM_MON.running = false
    if FARM_MON.thread then pcall(function() task.cancel(FARM_MON.thread) end); FARM_MON.thread=nil end
        print("DEBUG: All systems stopped, destroying GUI...")
        fadeOutAll(function()
            hideMinimizeHint()
            app:Destroy()
        end)
    end
    local function showCloseConfirm()
        -- Prevent stacking
        if app:FindFirstChild("ConfirmOverlay") then return end
        local overlay = mk("Frame", {Name="ConfirmOverlay", BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=0.45, Size=UDim2.fromScale(1,1), ZIndex=1000}, app)
        local dlg = mk("Frame", {Size=UDim2.new(0, 360, 0, 140), Position=UDim2.new(0.5,0,0.5,0), AnchorPoint=Vector2.new(0.5,0.5), BackgroundColor3=THEME.CARD, ZIndex=1001}, overlay)
        corner(dlg, 10); stroke(dlg, 1, THEME.BORDER); pad(dlg, 12, 12, 12, 12)
        mk("TextLabel", {BackgroundTransparency=1, Font=FONTS.HB, Text="Close GAG Hub?", TextSize=18, TextColor3=THEME.TEXT, TextXAlignment=Enum.TextXAlignment.Left, Size=UDim2.new(1,0,0,24), ZIndex=1002}, dlg)
        mk("TextLabel", {BackgroundTransparency=1, Font=FONTS.B, Text="Are you sure you want to close? All features will stop.", TextWrapped=true, TextSize=14, TextColor3=THEME.MUTED, TextXAlignment=Enum.TextXAlignment.Left, Position=UDim2.new(0,0,0,28), Size=UDim2.new(1,0,0,44), ZIndex=1002}, dlg)
        local btnRow = mk("Frame", {BackgroundTransparency=1, Size=UDim2.new(1,0,0,40), Position=UDim2.new(0,0,1,-44), ZIndex=1002}, dlg)
        local btnCancel = mk("TextButton", {AutoButtonColor=false, BackgroundColor3=THEME.BG3, Size=UDim2.new(0.5,-6,1,0), Text="Cancel", TextColor3=THEME.TEXT, Font=FONTS.H, TextSize=14, ZIndex=1003}, btnRow)
        local btnYes    = mk("TextButton", {AutoButtonColor=false, BackgroundColor3=THEME.ACCENT, Size=UDim2.new(0.5,-6,1,0), Position=UDim2.new(0.5,12,0,0), Text="Yes, close", TextColor3=Color3.new(1,1,1), Font=FONTS.H, TextSize=14, ZIndex=1003}, btnRow)
        corner(btnCancel,8); stroke(btnCancel,1,THEME.BORDER); hover(btnCancel,{BackgroundColor3=THEME.BG2},{BackgroundColor3=THEME.BG3})
        corner(btnYes,8); stroke(btnYes,1,THEME.BORDER); hover(btnYes,{BackgroundColor3=Color3.fromRGB(240,90,90)},{BackgroundColor3=THEME.ACCENT})
        btnCancel.MouseButton1Click:Connect(function() overlay:Destroy() end)
        btnYes.MouseButton1Click:Connect(function()
            overlay:Destroy()
            shutdownAndClose()
        end)
    end

    btnMin.MouseButton1Click:Connect(function()
        minimized=true
        showMinimizeHint()
        fadeOutAll(function() app.Enabled=false end)
    end)
    btnClose.MouseButton1Click:Connect(function()
        showCloseConfirm()
    end)
    local rightCtrlConn
    rightCtrlConn = UserInputService.InputBegan:Connect(function(input,gpe)
        if gpe or UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode==Enum.KeyCode.RightControl then
            if minimized then 
                app.Enabled=true; fadeInAll(); minimized=false; hideMinimizeHint()
            else 
                minimized=true; showMinimizeHint(); fadeOutAll(function() app.Enabled=false end) 
            end
        end
    end)
    table.insert(GLOBAL_CONNS, rightCtrlConn)

    CharAddedConn = Players.LocalPlayer.CharacterAdded:Connect(function()
        task.wait(.1)
        applySpeedValue(SPEED.Enabled and SPEED.Chosen or SPEED.Default)
        if NoClip.Enabled then setNoClip(true) end
        if Fly.Enabled then startFly() end
        if GO.Enabled then GO_Start() end
    end)
end

-- INIT ------------------------------------------------------------------------

createLoadingScreen(buildApp)
