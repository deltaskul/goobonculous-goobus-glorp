-- ============================================================
--  Turtle Mining GUI  v2.0
--  For a 3x2 monitor wall on a control computer.
--
--  Rednet protocol: "miningTurtle"
--  Inbound: type, label, x, y, z, chunkX, chunkZ, status, fuel
--  Outbound: "update", "wake"
-- ============================================================

local PROTOCOL          = "miningTurtle"
local MODEM_SIDE        = "right"
local HEARTBEAT_TIMEOUT = 30
local CHUNK_FILE        = "chunks.txt"

local C = {
    bg        = colours.black,
    panel     = colours.grey,
    panelTxt  = colours.lightGrey,
    header    = colours.blue,
    headerTxt = colours.white,
    ok        = colours.lime,
    warn      = colours.yellow,
    err       = colours.red,
    lost      = colours.purple,
    txt       = colours.white,
    muted     = colours.lightGrey,
    sel       = colours.cyan,
    selTxt    = colours.black,
    btn       = colours.lightBlue,
    mapBg     = colours.black,
    mapSel    = colours.cyan,
    mapGrid   = colours.grey,
    fuelOk    = colours.lime,
    fuelWarn  = colours.yellow,
    fuelLow   = colours.red,
    clOn      = colours.lime,
    clOff     = colours.grey,
}

-- Forward declarations: prevents nil-value errors from Lua's top-down
-- scoping when mutually-dependent functions reference each other, and
-- when loadChunkRegistry calls clLoad before clLoad would otherwise
-- be defined in source order.
local saveChunkRegistry, loadChunkRegistry
local clLoad, clUnload
local chunkStillNeeded, releaseChunk, checkStaleChunks, ensureChunkLoaded

local turtles       = {}
local selected      = nil
local tab           = "map"
local mon           = nil
local mW, mH        = 0, 0
local chunkloader   = nil
local chunkRegistry = {}
local running       = true
local lastDraw      = 0

local LEFT_W  = 28
local RIGHT_X = LEFT_W + 2
local HDR_H   = 2
local FTR_H   = 1

-- ── Chunkloader ──────────────────────────────────────────────

local function initChunkloader()
    for _, name in ipairs(peripheral.getNames()) do
        if string.find(peripheral.getType(name) or "", "chunkloader") then
            chunkloader = peripheral.wrap(name)
            return
        end
    end
end

saveChunkRegistry = function()
    local f = fs.open(CHUNK_FILE, "w")
    if not f then return end
    for key in pairs(chunkRegistry) do f.writeLine(key) end
    f.close()
end

clLoad = function(cx, cz)
    if not chunkloader then return false end
    local ok = pcall(function()
        if chunkloader.loadChunk then chunkloader.loadChunk(cx, cz)
        elseif chunkloader.addChunk then chunkloader.addChunk(cx, cz) end
    end)
    return ok
end

clUnload = function(cx, cz)
    if not chunkloader then return end
    pcall(function()
        if chunkloader.unloadChunk then chunkloader.unloadChunk(cx, cz)
        elseif chunkloader.removeChunk then chunkloader.removeChunk(cx, cz) end
    end)
end

loadChunkRegistry = function()
    if not fs.exists(CHUNK_FILE) then return end
    local f = fs.open(CHUNK_FILE, "r")
    if not f then return end
    local line = f.readLine()
    while line do
        local cx, cz = line:match("^(-?%d+),(-?%d+)$")
        if cx and cz then
            cx, cz = tonumber(cx), tonumber(cz)
            chunkRegistry[cx..","..cz] = true
            clLoad(cx, cz)
        end
        line = f.readLine()
    end
    f.close()
end

chunkStillNeeded = function(cx, cz, excludeId)
    local key = cx..","..cz
    local now = os.clock()
    for id, t in pairs(turtles) do
        if id ~= excludeId and t.chunkX and t.chunkZ
                and (t.chunkX..","..t.chunkZ) == key
                and now - (t.time or 0) <= HEARTBEAT_TIMEOUT then
            return true
        end
    end
    return false
end

releaseChunk = function(cx, cz, excludeId)
    if chunkStillNeeded(cx, cz, excludeId) then return end
    local key = cx..","..cz
    if chunkRegistry[key] then
        chunkRegistry[key] = nil
        saveChunkRegistry()
        clUnload(cx, cz)
    end
end

checkStaleChunks = function()
    local now = os.clock()
    for id, t in pairs(turtles) do
        if t.chunkX and t.chunkZ and now - (t.time or 0) > HEARTBEAT_TIMEOUT then
            releaseChunk(t.chunkX, t.chunkZ, id)
        end
    end
end

ensureChunkLoaded = function(cx, cz)
    local key = cx..","..cz
    if not chunkRegistry[key] then
        chunkRegistry[key] = true
        saveChunkRegistry()
    end
    clLoad(cx, cz)
end

local function registerChunkManual(cx, cz)
    cx, cz = tonumber(cx), tonumber(cz)
    if not cx or not cz then
        print("Usage: register <chunkX> <chunkZ>  e.g. register -12 7")
        return
    end
    ensureChunkLoaded(cx, cz)
    print(string.format("Chunk %d,%d registered. %s",
        cx, cz, chunkloader and "Loaded." or "(No chunkloader attached.)"))
end

-- ── Monitor ──────────────────────────────────────────────────

local function initMonitor()
    local best, bw, bh = nil, 0, 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local m = peripheral.wrap(name)
            m.setTextScale(0.5)
            local w, h = m.getSize()
            if w * h > bw * bh then best, bw, bh = m, w, h end
        end
    end
    mon = best or peripheral.wrap("top") or peripheral.wrap("left")
    if mon then mon.setTextScale(0.5); mW, mH = mon.getSize() end
end

local function mWrite(x, y, text, fg, bg)
    if not mon or x < 1 or y < 1 or y > mH then return end
    local maxLen = mW - x + 1
    if maxLen <= 0 then return end
    if #text > maxLen then text = text:sub(1, maxLen) end
    mon.setCursorPos(x, y)
    mon.setTextColour(fg or C.txt)
    mon.setBackgroundColour(bg or C.bg)
    mon.write(text)
end

local function mFill(x, y, w, h, fg, bg)
    if w <= 0 or h <= 0 then return end
    local line = string.rep(" ", w)
    for row = y, y + h - 1 do mWrite(x, row, line, fg, bg) end
end

local function mWriteR(x, y, w, text, fg, bg)
    mFill(x, y, w, 1, fg, bg)
    local tx = x + w - #text
    if tx < x then tx = x; text = text:sub(1, w) end
    mWrite(tx, y, text, fg, bg)
end

-- ── Helpers ──────────────────────────────────────────────────

local function statusColor(t)
    local now = os.clock()
    if now - (t.time or 0) > HEARTBEAT_TIMEOUT then return C.lost end
    local s = (t.status or ""):lower()
    if s:find("fuel") or s:find("inventory") or s:find("blocked") then return C.err
    elseif s:find("heartbeat") or s:find("mining") or s:find("z:") then return C.ok
    end
    return C.warn
end

local function statusLabel(t)
    if os.clock() - (t.time or 0) > HEARTBEAT_TIMEOUT then return "LOST" end
    local s = t.status or "?"
    return #s > 20 and s:sub(1, 19).."~" or s
end

local function fuelColor(fuel)
    if not fuel then return C.muted end
    if fuel == "unlimited" then return C.fuelOk end
    if fuel > 500 then return C.fuelOk elseif fuel > 100 then return C.fuelWarn else return C.fuelLow end
end

local function fuelLabel(fuel)
    if not fuel then return "?" end
    if fuel == "unlimited" then return "INF" end
    if fuel >= 1000 then return math.floor(fuel / 100) / 10 .."k" else return tostring(fuel) end
end

local function sortedIds()
    local ids = {}
    for id in pairs(turtles) do ids[#ids+1] = id end
    table.sort(ids)
    return ids
end

local function chunkCount()
    local n = 0; for _ in pairs(chunkRegistry) do n = n + 1 end; return n
end

-- ── Header / Footer ──────────────────────────────────────────

local tabOrder = { "map", "detail", "chunks" }
local tabLabels = { map=" Map ", detail=" Detail ", chunks=" Chunks " }

local function drawHeader()
    mFill(1, 1, mW, 1, C.headerTxt, C.header)
    mWrite(2, 1, "Turtle Mining Control  v2.0", C.headerTxt, C.header)
    local n = 0; for _ in pairs(turtles) do n = n + 1 end
    local cs = n..(n == 1 and " turtle" or " turtles")
    mWriteR(mW - #cs, 1, #cs + 1, cs, C.headerTxt, C.header)
    local tx = RIGHT_X
    for _, id in ipairs(tabOrder) do
        local lbl = tabLabels[id]
        local act = tab == id
        mWrite(tx, 2, lbl, act and C.headerTxt or C.muted, act and C.header or C.panel)
        tx = tx + #lbl
    end
    mFill(tx, 2, mW - tx + 1, 1, C.muted, C.panel)
end

local function drawFooter()
    local y = mH
    mFill(1, y, mW, 1, C.btn, C.panel)
    local items = { "[U]Update","[W]Wake","[Tab]View","[arrows]Sel","[Q]Quit" }
    local x = 2
    for _, s in ipairs(items) do
        mWrite(x, y, s, C.btn, C.panel); x = x + #s + 2
    end
    local clStr = chunkloader and (" CL:"..chunkCount()) or " CL:--"
    mWriteR(mW - #clStr, y, #clStr + 1, clStr,
        chunkloader and C.clOn or C.clOff, C.panel)
end

-- ── Turtle list ──────────────────────────────────────────────

local function drawTurtleList()
    mFill(1, HDR_H + 1, LEFT_W, 1, C.panelTxt, C.panel)
    mWrite(2, HDR_H + 1, "ID  Label          Fuel  S", C.panelTxt, C.panel)
    local row = HDR_H + 2
    local maxRow = mH - FTR_H
    for _, id in ipairs(sortedIds()) do
        if row > maxRow then break end
        local t   = turtles[id]
        local sel = id == selected
        local bg  = sel and C.sel or C.bg
        local fg  = sel and C.selTxt or C.txt
        local sc  = statusColor(t)
        mFill(1, row, LEFT_W, 1, fg, bg)
        local idStr = tostring(id)
        idStr = string.rep(" ", math.max(0, 3 - #idStr))..idStr:sub(1,3)
        mWrite(1, row, idStr, sel and C.selTxt or C.muted, bg)
        mWrite(5, row, (t.label or ("T"..id)):sub(1,13), fg, bg)
        mWriteR(19, row, 5, fuelLabel(t.fuel), sel and C.selTxt or fuelColor(t.fuel), bg)
        mWrite(LEFT_W - 1, row, "●", sel and C.selTxt or sc, bg)
        row = row + 1
    end
    while row <= maxRow do mFill(1, row, LEFT_W, 1, C.bg, C.bg); row = row + 1 end
    for r = HDR_H, mH - 1 do mWrite(LEFT_W + 1, r, "│", C.panel, C.bg) end
end

-- ── Map ──────────────────────────────────────────────────────

local function worldToMap(wx, wz, cx, cz, mapW, mapH)
    return math.floor(mapW/2) + (wx-cx) + RIGHT_X,
           math.floor(mapH/2) + (wz-cz) + HDR_H + 2
end

local function drawMap()
    local mapX = RIGHT_X
    local mapY = HDR_H + 2
    local mapW = mW - RIGHT_X
    local mapH = mH - FTR_H - mapY - 1
    mFill(mapX, mapY, mapW + 1, mapH + 2, C.mapGrid, C.mapBg)

    local cx, cz, count = 0, 0, 0
    if selected and turtles[selected] then
        cx = turtles[selected].x or 0; cz = turtles[selected].z or 0
    else
        for _, t in pairs(turtles) do cx=cx+(t.x or 0); cz=cz+(t.z or 0); count=count+1 end
        if count > 0 then cx=math.floor(cx/count); cz=math.floor(cz/count) end
    end

    for key in pairs(chunkRegistry) do
        local kcx, kcz = key:match("^(-?%d+),(-?%d+)$")
        if kcx then
            kcx, kcz = tonumber(kcx), tonumber(kcz)
            local sx = worldToMap(kcx*16,      cz, cx, cz, mapW, mapH)
            local ex = worldToMap(kcx*16 + 15, cz, cx, cz, mapW, mapH)
            for col = math.max(sx, mapX), math.min(ex, mW) do
                for r = mapY, mapY + mapH do mWrite(col, r, "░", colours.teal, C.mapBg) end
            end
        end
    end

    local viewLeft = cx - math.floor(mapW/2)
    local firstCX  = math.floor(viewLeft/16)*16
    for gx = firstCX, viewLeft + mapW, 16 do
        local sx = worldToMap(gx, cz, cx, cz, mapW, mapH)
        if sx >= mapX and sx <= mW then
            for r = mapY, mapY + mapH do mWrite(sx, r, "┊", C.mapGrid, C.mapBg) end
        end
    end

    local ox, oy = worldToMap(0, 0, cx, cz, mapW, mapH)
    if ox >= mapX and ox <= mW and oy >= mapY and oy <= mapY+mapH then
        mWrite(ox, oy, "+", C.muted, C.mapBg)
    end

    for _, id in ipairs(sortedIds()) do
        local t = turtles[id]
        local sx, sy = worldToMap(t.x or 0, t.z or 0, cx, cz, mapW, mapH)
        if sx >= mapX and sx <= mW and sy >= mapY and sy <= mapY+mapH then
            local col = id == selected and C.mapSel or statusColor(t)
            mWrite(sx, sy, id == selected and "◆" or "●", col, C.mapBg)
            if sx+1 <= mW-1 then mWrite(sx+1, sy, (t.label or ("T"..id)):sub(1,6), col, C.mapBg) end
        end
    end

    mFill(mapX, mapY+mapH+1, mapW+1, 1, C.muted, C.mapBg)
    mWrite(mapX+1, mapY+mapH+1,
        string.format("ctr %d,%d  ░=loaded chunk  ┊=chunk edge", cx, cz), C.muted, C.mapBg)
end

-- ── Detail ───────────────────────────────────────────────────

local function drawDetail()
    local x = RIGHT_X; local y = HDR_H + 2; local w = mW - x + 1
    mFill(x, y, w, mH - y - FTR_H + 1, C.txt, C.bg)
    if not selected or not turtles[selected] then
        mWrite(x+2, y+1, "No turtle selected.", C.muted, C.bg)
        mWrite(x+2, y+2, "Use arrow keys or click the list.", C.muted, C.bg)
        return
    end
    local t = turtles[selected]; local sc = statusColor(t)
    mFill(x, y, w, 1, C.headerTxt, C.header)
    mWrite(x+1, y, (t.label or ("Turtle "..selected)).."  (ID "..selected..")", C.headerTxt, C.header)
    y = y + 2
    local LW = 12
    local function row(label, value, vc)
        mWrite(x+1, y, label, C.muted, C.bg)
        mWrite(x+1+LW, y, tostring(value), vc or C.txt, C.bg)
        y = y + 1
    end
    row("Status",     statusLabel(t), sc);   y = y + 1
    row("World X",    t.x or "?")
    row("World Y",    t.y or "?")
    row("Depth",      t.z and (t.z.." blk") or "?"); y = y + 1
    local ckKey    = t.chunkX and t.chunkZ and (t.chunkX..","..t.chunkZ)
    local ckLoaded = ckKey and chunkRegistry[ckKey]
    row("Chunk",      (t.chunkX or "?")..", "..(t.chunkZ or "?"), C.muted)
    row("CL managed", ckLoaded and "yes" or (chunkloader and "no" or "no CL"),
        ckLoaded and C.ok or C.warn); y = y + 1
    local fuel = t.fuel; local fc = fuelColor(fuel)
    row("Fuel",       fuelLabel(fuel)..(fuel and fuel~="unlimited" and ("  /"..fuel) or ""), fc)
    if fuel and fuel ~= "unlimited" then
        local barW   = math.min(w - 4, 24)
        local filled = math.floor(math.min(fuel/20000, 1) * barW)
        mWrite(x+1, y, string.rep("█", filled)..string.rep("░", barW-filled), fc, C.bg)
        y = y + 2
    else
        y = y + 1
    end
    local age = math.floor(os.clock() - (t.time or os.clock()))
    row("Last seen",  age.."s ago", age > HEARTBEAT_TIMEOUT and C.err or C.ok)
end

-- ── Chunks ───────────────────────────────────────────────────

local function drawChunks()
    local x = RIGHT_X; local y = HDR_H + 2; local w = mW - x + 1
    mFill(x, y, w, mH - y - FTR_H + 1, C.txt, C.bg)
    mFill(x, y, w, 1, C.headerTxt, C.header)
    mWrite(x+1, y, "Loaded chunks  ("..chunkCount().." registered)", C.headerTxt, C.header)
    y = y + 2
    mWrite(x+1, y, "ChunkX    ChunkZ    Turtle        Active", C.muted, C.bg); y = y + 1

    local chunkOwner = {}
    local now = os.clock()
    for id, t in pairs(turtles) do
        if t.chunkX and t.chunkZ then
            chunkOwner[t.chunkX..","..t.chunkZ] = {
                label  = t.label or ("T"..id),
                active = now - (t.time or 0) <= HEARTBEAT_TIMEOUT,
            }
        end
    end

    local keys = {}
    for k in pairs(chunkRegistry) do keys[#keys+1] = k end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if y >= mH - FTR_H then break end
        local kcx, kcz = key:match("^(-?%d+),(-?%d+)$")
        local owner    = chunkOwner[key]
        local lbl      = owner and owner.label or "—"
        local active   = owner and owner.active
        mWrite(x+1, y, string.format("%-10s%-10s%-14s%s",
            kcx, kcz, lbl, active and "yes" or "idle"),
            active and C.ok or C.warn, C.bg)
        y = y + 1
    end
    if chunkCount() == 0 then
        mWrite(x+2, y,   "No chunks registered.", C.muted, C.bg); y = y + 1
        mWrite(x+2, y,   "Auto-registered on first heartbeat,", C.muted, C.bg); y = y + 1
        mWrite(x+2, y,   "or type: register <cx> <cz>", C.muted, C.bg)
    end
end

-- ── Redraw ───────────────────────────────────────────────────

local function redraw()
    if not mon then return end
    mon.setBackgroundColour(C.bg); mon.clear()
    drawHeader(); drawTurtleList()
    if     tab == "map"    then drawMap()
    elseif tab == "detail" then drawDetail()
    elseif tab == "chunks" then drawChunks()
    end
    drawFooter()
    lastDraw = os.clock()
end

-- ── Messages ─────────────────────────────────────────────────

local function handleMessage(senderId, msg)
    if type(msg) ~= "table" or msg.type ~= "status" then return end
    local t  = turtles[senderId] or {}
    t.x      = msg.x;  t.y = msg.y;  t.z = msg.z
    t.status = msg.status;  t.fuel = msg.fuel;  t.time = os.clock()
    t.label  = msg.label or t.label or ("T"..senderId)
    local newCX = msg.chunkX or math.floor((msg.x or 0)/16)
    local newCZ = msg.chunkZ or math.floor((msg.z or 0)/16)
    if t.chunkX and t.chunkZ and (t.chunkX ~= newCX or t.chunkZ ~= newCZ) then
        releaseChunk(t.chunkX, t.chunkZ, senderId)
    end
    t.chunkX = newCX;  t.chunkZ = newCZ
    turtles[senderId] = t
    if selected == nil then selected = senderId end
    ensureChunkLoaded(t.chunkX, t.chunkZ)
end

local function sendCommand(cmd, targetId)
    if targetId then rednet.send(targetId, cmd, PROTOCOL)
    else rednet.broadcast(cmd, PROTOCOL) end
end

local function doWake(targetId)
    if targetId and turtles[targetId] then
        local t = turtles[targetId]
        if t.chunkX and t.chunkZ then
            ensureChunkLoaded(t.chunkX, t.chunkZ)
            print(string.format("[GUI] Re-loaded chunk %d,%d before wake", t.chunkX, t.chunkZ))
        end
    else
        for _, t in pairs(turtles) do
            if t.chunkX and t.chunkZ then ensureChunkLoaded(t.chunkX, t.chunkZ) end
        end
    end
    sendCommand("wake", targetId)
    print("[GUI] Wake sent to "..(targetId and tostring(targetId) or "all"))
end

-- ── Input ────────────────────────────────────────────────────

local function handleTouch(tx, ty)
    if ty == 2 and tx >= RIGHT_X then
        local pos = RIGHT_X
        for _, id in ipairs(tabOrder) do
            local lbl = tabLabels[id]
            if tx < pos + #lbl then tab = id; return end
            pos = pos + #lbl
        end
        return
    end
    if tx <= LEFT_W and ty >= HDR_H + 2 then
        local ids = sortedIds()
        local idx  = ty - (HDR_H + 1)
        if ids[idx] then selected = ids[idx] end
    end
end

local function handleKey(key)
    if     key == keys.q   then running = false
    elseif key == keys.tab then
        for i, v in ipairs(tabOrder) do
            if v == tab then tab = tabOrder[(i % #tabOrder)+1]; return end
        end
        tab = tabOrder[1]
    elseif key == keys.u then
        sendCommand("update", selected)
        print("[GUI] Update sent to "..(selected and tostring(selected) or "all"))
    elseif key == keys.w then
        doWake(selected)
    elseif key == keys.up then
        local ids = sortedIds()
        for i, id in ipairs(ids) do
            if id == selected and i > 1 then selected = ids[i-1]; return end
        end
    elseif key == keys.down then
        local ids = sortedIds()
        for i, id in ipairs(ids) do
            if id == selected and i < #ids then selected = ids[i+1]; return end
        end
    end
end

-- ── Main ─────────────────────────────────────────────────────

local function main()
    initMonitor(); initChunkloader()
    if not mon then error("No monitor found. Attach a 3x2 monitor wall and restart.") end
    rednet.open(MODEM_SIDE)
    loadChunkRegistry()
    print("GUI v2.0  monitor "..mW.."x"..mH)
    if chunkloader then print("Chunk loader active. "..chunkCount().." chunk(s) pre-loaded.")
    else print("No chunk loader found.") end
    print("Type 'register <cx> <cz>' to manually seed a chunk.")

    local inputBuf = ""
    redraw(); os.startTimer(2)

    while running do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            if p3 == PROTOCOL then handleMessage(p1, p2); redraw() end
        elseif event == "monitor_touch" then
            handleTouch(p2, p3); redraw()
        elseif event == "key" then
            if p1 == keys.enter then
                local parts = {}
                for w in inputBuf:gmatch("%S+") do parts[#parts+1] = w end
                inputBuf = ""
                if     parts[1] == "register" then registerChunkManual(parts[2], parts[3])
                elseif parts[1] == "q" or parts[1] == "quit" then running = false end
            elseif p1 == keys.backspace then
                inputBuf = inputBuf:sub(1, -2)
            else
                handleKey(p1)
            end
            redraw()
        elseif event == "char" then
            inputBuf = inputBuf .. p1
        elseif event == "timer" then
            checkStaleChunks(); redraw(); os.startTimer(2)
        end
    end

    mon.clear(); rednet.close(MODEM_SIDE); print("GUI closed.")
end

main()
