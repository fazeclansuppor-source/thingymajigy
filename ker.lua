-- KeyLoader.client.lua — key gate → run main via loadstring (no goto)
local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- ====================== CONFIG ======================
-- If your secret is hex (looks like this one), it will be decoded to bytes.
local SHARED_SECRET   = "817340e3551ca5a4b32cd9d8188966583ebaf0e59286bbbf29c865c4348c49bf"
local MAIN_URL        = "https://raw.githubusercontent.com/fazeclansuppor-source/thingymajigy/refs/heads/main/gua.lua"
local MODULE_ASSET_ID = nil   -- number or nil (optional require() fallback)
local DEBUG           = false -- set true for verbose verifier logs
-- ====================================================

-- ---------- small utils ----------
local function hex_to_bin(hex)
    if type(hex) ~= "string" then return hex end
    if not hex:match("^[0-9a-fA-F]+$") or (#hex % 2 ~= 0) then return hex end
    return (hex:gsub("..", function(cc) return string.char(tonumber(cc,16)) end))
end

local function normalize(src)
    if src:sub(1,3) == "\239\187\191" then src = src:sub(4) end -- strip BOM
    src = src:gsub("\r\n", "\n")
    return src
end

local function split_lines(src)
    local t = {}
    for line in (src.."\n"):gmatch("([^\n]*)\n") do
        t[#t+1] = line
    end
    return t
end
local function join_lines(t) return table.concat(t, "\n") end

-- ---------- base64url ----------
local function b64url_to_bin(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = #s % 4
    if pad == 2 then s = s .. "==" elseif pad == 3 then s = s .. "=" end
    local out, b = {}, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local rev = {}; for i=1,#b do rev[b:sub(i,i)] = i-1 end
    for i=1,#s,4 do
        local c1,c2,c3,c4 = s:sub(i,i), s:sub(i+1,i+1), s:sub(i+2,i+2), s:sub(i+3,i+3)
        local n1,n2,n3,n4 = rev[c1],rev[c2],rev[c3],rev[c4]
        if not n1 or not n2 then break end
        local n = bit32.lshift(n1,18)
        n = bit32.bor(n, bit32.lshift(n2,12))
        n = bit32.bor(n, bit32.lshift(n3 or 0,6))
        n = bit32.bor(n, (n4 or 0))
        out[#out+1] = string.char(bit32.band(bit32.rshift(n,16),255))
        if c3 and c3 ~= "=" then out[#out+1] = string.char(bit32.band(bit32.rshift(n,8),255)) end
        if c4 and c4 ~= "=" then out[#out+1] = string.char(bit32.band(n,255)) end
    end
    return table.concat(out)
end

-- debug helper (bytes → base64url)
local function to_b64u(bytes)
    local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #bytes, 3 do
        local a = bytes:byte(i)     or 0
        local b = bytes:byte(i + 1) or 0
        local c = bytes:byte(i + 2) or 0
        local n  = bit32.bor(bit32.lshift(a,16), bit32.lshift(b,8), c)
        local i1 = bit32.band(bit32.rshift(n,18), 0x3F)
        local i2 = bit32.band(bit32.rshift(n,12), 0x3F)
        local i3 = bit32.band(bit32.rshift(n, 6), 0x3F)
        local i4 = bit32.band(n,                      0x3F)
        out[#out+1] = alpha:sub(i1+1, i1+1)
        out[#out+1] = alpha:sub(i2+1, i2+1)
        out[#out+1] = (i + 1 <= #bytes) and alpha:sub(i3+1, i3+1) or "="
        out[#out+1] = (i + 2 <= #bytes) and alpha:sub(i4+1, i4+1) or "="
    end
    return table.concat(out):gsub("%+","-"):gsub("/","_"):gsub("=+$","")
end

-- ---------- SHA-256 / HMAC (robust Luau version) ----------
local function u32(x) return x % 0x100000000 end
local function rrot(x,n) return bit32.bor(bit32.rshift(x,n), bit32.lshift(x, 32-n)) end

local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
}

local function sha256(msg)
    local bytes = {msg:byte(1, #msg)}
    local bitlen = #bytes * 8
    bytes[#bytes+1] = 0x80
    while (#bytes % 64) ~= 56 do bytes[#bytes+1] = 0x00 end
    for i = 7, 0, -1 do bytes[#bytes+1] = bit32.rshift(bitlen, i*8) % 256 end

    local H0,H1,H2,H3,H4,H5,H6,H7 =
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19

    for i = 1, #bytes, 64 do
        local w = {}
        for t = 1, 16 do
            local b1 = bytes[i + (t-1)*4]     or 0
            local b2 = bytes[i + (t-1)*4 + 1] or 0
            local b3 = bytes[i + (t-1)*4 + 2] or 0
            local b4 = bytes[i + (t-1)*4 + 3] or 0
            w[t] = u32(((b1*256 + b2)*256 + b3)*256 + b4)
        end
        for t = 17, 64 do
            local x = w[t-15] or 0
            local y = w[t-2]  or 0
            local s0 = bit32.bxor(rrot(x,7), rrot(x,18), bit32.rshift(x,3))
            local s1 = bit32.bxor(rrot(y,17), rrot(y,19), bit32.rshift(y,10))
            w[t] = u32((w[t-16] or 0) + s0 + (w[t-7] or 0) + s1)
        end

        local a,b,c,d,e,f,g,h = H0,H1,H2,H3,H4,H5,H6,H7
        for t = 1, 64 do
            local S1 = bit32.bxor(rrot(e,6), rrot(e,11), rrot(e,25))
            local ch = bit32.bxor(bit32.band(e,f), bit32.band(bit32.bnot(e), g))
            local T1 = u32(h + S1 + ch + (K[t] or 0) + (w[t] or 0))
            local S0 = bit32.bxor(rrot(a,2), rrot(a,13), rrot(a,22))
            local maj = bit32.bxor(bit32.band(a,b), bit32.band(a,c), bit32.band(b,c))
            local T2 = u32(S0 + maj)
            h = g; g = f; f = e
            e = u32(d + T1)
            d = c; c = b; b = a
            a = u32(T1 + T2)
        end

        H0 = u32(H0 + a); H1 = u32(H1 + b); H2 = u32(H2 + c); H3 = u32(H3 + d)
        H4 = u32(H4 + e); H5 = u32(H5 + f); H6 = u32(H6 + g); H7 = u32(H7 + h)
    end

    return string.char(
        bit32.rshift(H0,24)%256, bit32.rshift(H0,16)%256, bit32.rshift(H0,8)%256, H0%256,
        bit32.rshift(H1,24)%256, bit32.rshift(H1,16)%256, bit32.rshift(H1,8)%256, H1%256,
        bit32.rshift(H2,24)%256, bit32.rshift(H2,16)%256, bit32.rshift(H2,8)%256, H2%256,
        bit32.rshift(H3,24)%256, bit32.rshift(H3,16)%256, bit32.rshift(H3,8)%256, H3%256,
        bit32.rshift(H4,24)%256, bit32.rshift(H4,16)%256, bit32.rshift(H4,8)%256, H4%256,
        bit32.rshift(H5,24)%256, bit32.rshift(H5,16)%256, bit32.rshift(H5,8)%256, H5%256,
        bit32.rshift(H6,24)%256, bit32.rshift(H6,16)%256, bit32.rshift(H6,8)%256, H6%256,
        bit32.rshift(H7,24)%256, bit32.rshift(H7,16)%256, bit32.rshift(H7,8)%256, H7%256
    )
end

local function hmac_sha256(key, msg)
    if #key > 64 then key = sha256(key) end
    if #key < 64 then key = key .. string.rep("\0", 64 - #key) end
    local o, i = {}, {}
    for idx = 1, 64 do
        local kb = key:byte(idx) or 0
        o[idx] = string.char(bit32.bxor(kb, 0x5c))
        i[idx] = string.char(bit32.bxor(kb, 0x36))
    end
    return sha256(table.concat(o) .. sha256(table.concat(i) .. msg))
end

local function consteq(a, b)
    if #a ~= #b then return false end
    local r = 0
    for n = 1, #a do r = bit32.bxor(r, a:byte(n), b:byte(n)) end
    return r == 0
end

-- ---------- Luau auto-fixer for lines starting with '(' ----------
local function add_guard_at(lines, ln)
    local s = lines[ln]; if not s then return false end
    local lead, rest = s:match("^(%s*)(.*)$")
    if rest and rest ~= "" and rest:sub(1,1) ~= ";" and rest:sub(1,1) == "(" then
        lines[ln] = lead .. ";" .. rest
        return true
    end
    return false
end
local function remove_guard_at(lines, ln)
    local s = lines[ln]; if not s then return false end
    local lead, rest = s:match("^(%s*)(.*)$")
    if rest and rest:sub(1,1) == ";" then
        lines[ln] = lead .. rest:sub(2)
        return true
    end
    return false
end

local function autofix_parens(src, max_iters)
    max_iters = max_iters or 100
    src = normalize(src)
    local lines = split_lines(src)
    local changed = 0

    for _ = 1, max_iters do
        local blob = join_lines(lines)
        local loader = loadstring or load
        local fn, cerr = loader(blob)

        if fn then
            if DEBUG and changed > 0 then
                warn(("[KeyLoader] auto-fix: %d line adjustment(s)"):format(changed))
            end
            return join_lines(lines)
        end

        cerr = tostring(cerr or "")
        local ln = tonumber(cerr:match(":(%d+):%s*Ambiguous syntax"))
        if ln and add_guard_at(lines, ln) then
            changed = changed + 1
        else
            local ln2 = tonumber(cerr:match(":(%d+):%s*Expected%s+identifier.-got%s*';'"))
            if ln2 and remove_guard_at(lines, ln2) then
                changed = changed + 1
            else
                if DEBUG then warn("[KeyLoader] auto-fix: unhandled compile error: ", cerr) end
                return join_lines(lines)
            end
        end
    end
    if DEBUG then warn("[KeyLoader] auto-fix: hit iteration limit") end
    return join_lines(lines)
end

local RAW_LOADER = loadstring or load
local function safe_load(code, ...)
    if type(code) == "string" then
        code = autofix_parens(code)
    end
    return RAW_LOADER(code, ...)
end

-- ---------- token verify ----------
local function looks_hex(s)
    return type(s) == "string" and (#s % 2 == 0) and s:match("^[0-9a-fA-F]+$") ~= nil
end

local function uniq_push(t, v)
    for i = 1, #t do if t[i] == v then return end end
    t[#t+1] = v
end

local function verifyTokenForLocalUser(token)
    -- Expect GK.<payload_b64url>.<sig_b64url>
    local pfx, p64, s64 = token:match("^(%w+)%.([A-Za-z0-9_%-%=]+)%.([A-Za-z0-9_%-%=]+)$")
    if pfx ~= "GK" or not p64 or not s64 then
        return false, "malformed"
    end

    local given = b64url_to_bin(s64)
    if type(given) ~= "string" or #given == 0 then
        return false, "sig_decode"
    end

    -- candidate keys: ASCII and (if hex-like) its bytes
    local keys = {}
    uniq_push(keys, SHARED_SECRET)
    if looks_hex(SHARED_SECRET) then
        uniq_push(keys, hex_to_bin(SHARED_SECRET))
    end

    local rawPayload = b64url_to_bin(p64) or ""
    local noPad     = p64:gsub("=+$","")

    local msgs = {
        p64, noPad,                    -- payload (with/without padding)
        pfx .. "." .. p64,             -- "GK."..payload
        pfx .. "." .. noPad,
        pfx .. p64,                    -- "GK"..payload (no dot)
        pfx .. noPad,
        rawPayload,                    -- raw JSON bytes
        pfx .. "." .. rawPayload,      -- "GK."..raw-bytes
    }

    -- try all combinations
    local matched = false
    local matched_k, matched_m
    for ki = 1, #keys do
        local k = keys[ki]
        for mi = 1, #msgs do
            local m = msgs[mi]
            local need = hmac_sha256(k, m)
            if consteq(need, given) then
                matched = true
                matched_k, matched_m = ki, mi
                break
            end
        end
        if matched then break end
    end

    if not matched then
        if DEBUG then
            warn("[KeyLoader] verify: none matched; showing a few candidates")
            warn("  given sig :", to_b64u(given))
            for ki = 1, #keys do
                for mi = 1, math.min(4, #msgs) do
                    local need = hmac_sha256(keys[ki], msgs[mi])
                    warn(("  need k#%d m#%d: %s"):format(ki, mi, to_b64u(need)))
                end
            end
        end
        return false, "sig_mismatch"
    else
        if DEBUG then warn(("[KeyLoader] verify: matched with key#%d msg#%d"):format(matched_k, matched_m)) end
    end

    -- decode & validate payload
    local ok, payload = pcall(function() return HttpService:JSONDecode(rawPayload) end)
    if not ok or type(payload) ~= "table" then
        ok, payload = pcall(function() return HttpService:JSONDecode(b64url_to_bin(p64)) end)
        if not ok or type(payload) ~= "table" then
            return false, "payload_decode"
        end
    end

    if tostring(payload.uid) ~= tostring(LocalPlayer.UserId) then
        return false, "uid_mismatch"
    end

    local now = os.time()
    local exp = tonumber(payload.exp)
    if not exp or (exp + 120) < now then
        return false, "expired"
    end

    local is_life = (payload.typ == "lifetime") or (payload.lifetime == true)
    return true, is_life
end

-- ---------- prompt UI ----------
local function showPrompt(onOK)
    local pg = LocalPlayer:WaitForChild("PlayerGui")
    local sg = Instance.new("ScreenGui"); sg.Name="KeyPrompt"; sg.ResetOnSpawn=false; sg.IgnoreGuiInset=true; sg.Parent=pg
    local frame = Instance.new("Frame"); frame.Size=UDim2.fromOffset(460,190); frame.Position=UDim2.new(0.5,-230,0.5,-95); frame.BackgroundColor3=Color3.fromRGB(22,22,26); frame.Parent=sg
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0,10)
    local lbl = Instance.new("TextLabel"); lbl.Size=UDim2.new(1,-24,0,36); lbl.Position=UDim2.fromOffset(12,10); lbl.BackgroundTransparency=1; lbl.Font=Enum.Font.GothamBold; lbl.TextSize=20; lbl.TextColor3=Color3.new(1,1,1); lbl.Text="Enter Your Key"; lbl.Parent=frame
    local tb = Instance.new("TextBox"); tb.Size=UDim2.new(1,-24,0,60); tb.Position=UDim2.fromOffset(12,50); tb.ClearTextOnFocus=false; tb.PlaceholderText="Paste token: GK.xxx.yyy"; tb.Font=Enum.Font.Gotham; tb.TextSize=12; tb.TextWrapped=true; tb.MultiLine=true; tb.TextXAlignment=Enum.TextXAlignment.Left; tb.TextColor3=Color3.new(1,1,1); tb.BackgroundColor3=Color3.fromRGB(35,35,40); tb.Parent=frame
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0,8)
    local who = Instance.new("TextLabel"); who.Size=UDim2.new(1,-24,0,18); who.Position=UDim2.fromOffset(12,116); who.BackgroundTransparency=1; who.Font=Enum.Font.Gotham; who.TextSize=12; who.TextColor3=Color3.fromRGB(180,180,180); who.Text="Expecting UID: "..tostring(LocalPlayer.UserId); who.Parent=frame
    local msg = Instance.new("TextLabel"); msg.Size=UDim2.new(1,-24,0,18); msg.Position=UDim2.fromOffset(12,138); msg.BackgroundTransparency=1; msg.Font=Enum.Font.Gotham; msg.TextSize=14; msg.TextColor3=Color3.fromRGB(255,120,120); msg.Text=""; msg.Parent=frame
    local okBtn = Instance.new("TextButton"); okBtn.Size=UDim2.fromOffset(120,36); okBtn.Position=UDim2.new(1,-132,1,-46); okBtn.Text="Unlock"; okBtn.Font=Enum.Font.GothamBold; okBtn.TextSize=18; okBtn.TextColor3=Color3.new(1,1,1); okBtn.BackgroundColor3=Color3.fromRGB(0,120,255); okBtn.Parent=frame
    Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0,8)

    okBtn.MouseButton1Click:Connect(function()
        local tok = (tb.Text or ""):gsub("%s+",""):gsub("[`“”\"']", "")
        if #tok < 12 then msg.Text = "Please paste the full token"; return end
        msg.TextColor3 = Color3.fromRGB(255,235,120); msg.Text = "Verifying..."

        local callOK, okOrErr, info = pcall(function()
            local ok, infoOrReason = verifyTokenForLocalUser(tok)
            return ok, infoOrReason
        end)

        if not callOK then
            msg.TextColor3 = Color3.fromRGB(255,120,120)
            msg.Text = "verify error: " .. tostring(okOrErr)
            return
        end

        local ok, infoOrReason = okOrErr, info
        if ok then
            _G.IS_ADMIN = true
            _G.ADMIN_KEY_INFO = { lifetime = (infoOrReason == true) }
            msg.TextColor3 = Color3.fromRGB(120,255,120); msg.Text = "Access granted!"
            task.delay(0.1, function() sg:Destroy(); if onOK then onOK(true) end end)
        else
            msg.TextColor3 = Color3.fromRGB(255,120,120)
            msg.Text = tostring(infoOrReason or "Invalid/expired key")
        end
    end)
end

-- ---------- run main ----------
local function runMain()
    local ran = false

    if type(MAIN_URL) == "string" and #MAIN_URL > 0 then
        local okGet, src = pcall(function() return game:HttpGet(MAIN_URL, true) end)
        if not okGet then
            warn("[KeyLoader] HttpGet failed:", src)
        elseif type(src) ~= "string" or #src == 0 then
            warn("[KeyLoader] empty response")
        else
            src = autofix_parens(src)
            local loader = loadstring or load
            if not loader then
                warn("[KeyLoader] loadstring not available in this environment")
            else
                local fn, cerr = loader(src)
                if not fn then
                    warn("[KeyLoader] compile error:", cerr)
                else
                    -- ensure nested loadstring/load also auto-fix
                    local old_ls, old_load = _G.loadstring, _G.load
                    _G.loadstring, _G.load = safe_load, safe_load

                    -- some executors copy into getgenv()
                    local gv = (type(getgenv) == "function" and getgenv()) or _G
                    local old_gv_ls, old_gv_load = gv.loadstring, gv.load
                    gv.loadstring, gv.load = safe_load, safe_load

                    local okRun, rerr = pcall(fn)

                    _G.loadstring, _G.load = old_ls, old_load
                    gv.loadstring, gv.load = old_gv_ls, old_gv_load

                    if not okRun then
                        warn("[KeyLoader] runtime error:", rerr)
                    else
                        ran = true
                    end
                end
            end
        end
    end

    if not ran and MODULE_ASSET_ID then
        local okReq, res = pcall(function() return require(MODULE_ASSET_ID) end)
        if not okReq then warn("[KeyLoader] require fallback failed:", res) end
    end
end

-- Boot: prompt -> run
showPrompt(function() runMain() end)
