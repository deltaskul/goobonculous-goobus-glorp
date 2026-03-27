-- ============================================================
--  Turtle Mining GUI  v1.0
--  Run on the control computer connected to a 3x2 monitor wall
--  and optionally a CCChunkloader peripheral via wired modem.
--
--  Rednet protocol: "miningTurtle"
--  Expected inbound message fields:
--    type, x, y, z, status, time, chunkX, chunkZ
--
--  Outbound commands:
--    "update"  -> updater.lua triggers wget + reboot
--    "wake"    -> updater.lua restarts the miner coroutine
--    "return"  -> quarry.lua surfaces and halts
-- ============================================================

local PROTOCOL    = "miningTurtle"
local MODEM_SIDE  = "right"          -- ender modem on the computer
local HEARTBEAT_TIMEOUT = 30         -- seconds before a turtle is marked LOST

-- ── Colour palette (falls back gracefully on b&w monitors) ──
local C = {
    bg        = colours.black,
    panel     = colours.grey,
    header    = colours.blue,
    headerTxt = colours.white,
    ok        = colours.lime,
    warn      = colours.yellow,
    err       = colours.red,
    lost      = colours.purple,
    txt       = colours.white,
    muted     = colours.lightGrey,
    sel       = colours.cyan,
    btn       = colours.lightBlue,
    btnTxt    = colours.black,
    mapBg     = colours.black,
    mapDot    = colours.lime,
    mapSel    = colours.cyan,
    mapGrid   = colours.grey,
}

-- ── State ────────────────────────────────────────────────────
local turtles    = {}   -- [id] = { x,y,z,chunkX,chunkZ,status,time,fuel,label }
local selected   = nil  -- currently selected turtle id
local tab        = "map"  -- "map" | "list"
local mon        = nil
local mW, mH     = 0, 0
local chunkloader = nil
local running    = true
local lastDraw   = 0

-- ── Chunkloader helpers ──────────────────────────────────────
local CHUNK_FILE = "chunks.txt"   -- persisted chunk registry

-- Registry: { [cx..","..cz] = true }
-- Lets us re-load all known turtle chunks on GUI startup,
-- before any heartbeat arrives (cold-start / cross-dimension fix).
local chunkRegistry = {}

local function initChunkloader()
    for _, name in ipairs(peripheral.getNames()) do
        if string.find(peripheral.getType(name) or "", "chunkloader") then
            chunkloader = peripheral.wrap(name)
            return
        end
    end
end

-- Low-level: tell the peripheral to load one chunk.
local function clLoad(cx, cz)
    if not chunkloader then return false end
    local ok = pcall(function()
        if chunkloader.loadChunk then
            chunkloader.loadChunk(cx, cz)
        elseif chunkloader.addChunk then
            chunkloader.addChunk(cx, cz)
        end
    end)
    return ok
end

-- Low-level: unload one chunk.
local function clUnload(cx, cz)
    if not chunkloader then return end
    pcall(function()
        if chunkloader.unloadChunk then
            chunkloader.unloadChunk(cx, cz)
        elseif chunkloader.removeChunk then
            chunkloader.removeChunk(cx, cz)
        end
    end)
end

-- Check whether any other active turtle still needs a given chunk,
-- so we don't unload a chunk two turtles happen to share.
local function chunkStillNeeded(cx, cz, excludeId)
    local key = cx .. "," .. cz
    local now = os.clock()
    for id, t in pairs(turtles) do
        if id ~= excludeId
                and (t.chunkX .. "," .. t.chunkZ) == key
                and now - (t.time or 0) <= HEARTBEAT_TIMEOUT then
            return true
        end
    end
    return false
end

-- Unload a chunk and remove it from the registry, unless another
-- active turtle is still in that chunk.
local function releaseChunk(cx, cz, excludeId)
    if chunkStillNeeded(cx, cz, excludeId) then return end
    local key = cx .. "," .. cz
    if chunkRegistry[key] then
        chunkRegistry[key] = nil
        saveChunkRegistry()
        clUnload(cx, cz)
    end
end

-- Sweep all known turtles; unload chunks for those that have gone LOST.
-- Called on every periodic timer tick.
local function checkStaleChunks()
    local now = os.clock()
    for id, t in pairs(turtles) do
        if t.chunkX and t.chunkZ
                and now - (t.time or 0) > HEARTBEAT_TIMEOUT then
            releaseChunk(t.chunkX, t.chunkZ, id)
        end
    end
end
local function saveChunkRegistry()
    local f = fs.open(CHUNK_FILE, "w")
    if not f then return end
    for key in pairs(chunkRegistry) do
        f.writeLine(key)
    end
    f.close()
end

-- Load registry from disk and re-issue loadChunk for every entry.
local function loadChunkRegistry()
    if not fs.exists(CHUNK_FILE) then return end
    local f = fs.open(CHUNK_FILE, "r")
    if not f then return end
    local line = f.readLine()
    while line do
        local cx, cz = line:match("^(-?%d+),(-?%d+)$")
        if cx and cz then
            cx, cz = tonumber(cx), tonumber(cz)
            chunkRegistry[cx .. "," .. cz] = true
            clLoad(cx, cz)
        end
        line = f.readLine()
    end
    f.close()
end

-- Public: register and load a chunk, persisting it.
local function ensureChunkLoaded(cx, cz)
    local key = cx .. "," .. cz
    if not chunkRegistry[key] then
        chunkRegistry[key] = true
        saveChunkRegistry()
    end
    clLoad(cx, cz)
end

-- Register a chunk manually from the terminal.
-- Usage: type  register <chunkX> <chunkZ>  in the computer shell.
-- This seeds the registry before the turtle has been heard from.
local function registerChunkManual(cx, cz)
    cx, cz = tonumber(cx), tonumber(cz)
    if not cx or not cz then
        print("Usage: register <chunkX> <chunkZ>")
        print("Example: register -12 7")
        return
    end
    ensureChunkLoaded(cx, cz)
    print(string.format("Registered chunk %d, %d — %s",
        cx, cz, chunkloader and "loaded." or "saved (no chunkloader found)."))
end

-- ── Monitor setup ────────────────────────────────────────────
local function initMonitor()
    -- Find the largest monitor
    local best, bw, bh = nil, 0, 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local m = peripheral.wrap(name)
            m.setTextScale(0.5)
            local w, h = m.getSize()
            if w * h > bw * bh then
                best, bw, bh = m, w, h
            end
        end
    end
    if not best then
        -- Fall back: look for "monitor_0" etc
        mon = peripheral.wrap("top") or peripheral.wrap("left")
    else
        mon = best
    end
    if mon then
        mon.setTextScale(0.5)
        mW, mH = mon.getSize()
    end
end

-- ── Low-level draw helpers ───────────────────────────────────
local function mWrite(x, y, text, fg, bg)
    if not mon then return end
    if x < 1 or y < 1 or y > mH then return end
    mon.setCursorPos(x, y)
    mon.setTextColour(fg or C.txt)
    mon.setBackgroundColour(bg or C.bg)
    -- Clamp text to monitor width
    local maxLen = mW - x + 1
    if maxLen <= 0 then return end
    if #text > maxLen then text = text:sub(1, maxLen) end
    mon.write(text)
end

local function mFill(x, y, w, h, char, fg, bg)
    char = char or " "
    for row = y, y + h - 1 do
        mWrite(x, row, string.rep(char, w), fg, bg)
    end
end

local function mBox(x, y, w, h, fg, bg)
    mFill(x, y, w, h, " ", fg, bg)
end

-- ── Status colour ────────────────────────────────────────────
local function statusColor(t)
    local now = os.clock()
    if now - (t.time or 0) > HEARTBEAT_TIMEOUT then return C.lost end
    local s = (t.status or ""):lower()
    if s:find("fuel") or s:find("inventory") or s:find("blocked") then
        return C.err
    elseif s:find("heartbeat") or s:find("mining") or s:find("z:") then
        return C.ok
    else
        return C.warn
    end
end

local function statusLabel(t)
    local now = os.clock()
    if now - (t.time or 0) > HEARTBEAT_TIMEOUT then return "LOST" end
    local s = t.status or "?"
    if #s > 18 then s = s:sub(1,17) .. "…" end
    return s
end

-- ── Layout constants ─────────────────────────────────────────
--  Left panel  = turtle list  (26 cols wide)
--  Right panel = map / detail (rest of screen)
--  Header row  = 1
--  Footer row  = mH

local LEFT_W   = 26
local RIGHT_X  = LEFT_W + 2
local RIGHT_W  = 0   -- computed after monitor init
local HEADER_H = 2
local FOOTER_H = 2

-- ── Tab bar ──────────────────────────────────────────────────
local function drawTabs()
    -- Tabs sit at the top-right
    local tabs = { {id="map", label=" Map "}, {id="list", label=" Detail "} }
    local tx = RIGHT_X
    for _, t in ipairs(tabs) do
        local fg = (tab == t.id) and C.headerTxt or C.muted
        local bg = (tab == t.id) and C.header    or C.panel
        mWrite(tx, 2, t.label, fg, bg)
        tx = tx + #t.label
    end
    -- Fill rest of tab bar
    mFill(tx, 2, mW - tx + 1, 1, " ", C.muted, C.panel)
end

-- ── Header ───────────────────────────────────────────────────
local function drawHeader()
    mFill(1, 1, mW, 1, " ", C.headerTxt, C.header)
    local title = "  Turtle Mining Control  v1.0"
    mWrite(1, 1, title, C.headerTxt, C.header)
    local clock = "  " .. textutils.formatTime(os.time(), true) .. "  "
    mWrite(mW - #clock + 1, 1, clock, C.headerTxt, C.header)
    drawTabs()
end

-- ── Footer / command bar ─────────────────────────────────────
local function drawFooter()
    local y = mH
    mFill(1, y, mW, 1, " ", C.muted, C.panel)

    local btns = {
        { label = "[U] Update",  key = "u" },
        { label = "[W] Wake",    key = "w" },
        { label = "[Tab] View",  key = "tab" },
        { label = "[Q] Quit",    key = "q" },
    }
    local x = 2
    for _, b in ipairs(btns) do
        mWrite(x, y, b.label, C.btn, C.panel)
        x = x + #b.label + 2
    end

    -- Chunk loader status
    local clTxt = chunkloader and "  CL: ON" or "  CL: --"
    local clCol = chunkloader and C.ok or C.muted
    mWrite(mW - #clTxt, y, clTxt, clCol, C.panel)
end

-- ── Turtle list (left panel) ─────────────────────────────────
local function drawTurtleList()
    local x = 1
    -- Column header
    mFill(x, HEADER_H + 1, LEFT_W, 1, " ", C.muted, C.panel)
    mWrite(x + 1, HEADER_H + 1, "ID  Label           St", C.muted, C.panel)

    local row = HEADER_H + 2
    local maxRow = mH - FOOTER_H

    -- Collect sorted ids
    local ids = {}
    for id in pairs(turtles) do ids[#ids+1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        if row > maxRow then break end
        local t   = turtles[id]
        local sel = (id == selected)
        local bg  = sel and C.sel or C.bg
        local sc  = statusColor(t)

        -- Clear row
        mFill(1, row, LEFT_W, 1, " ", C.txt, bg)

        -- ID (4 chars)
        local idStr = tostring(id)
        idStr = string.rep(" ", 3 - math.min(#idStr, 3)) .. idStr:sub(1,3)
        mWrite(1, row, idStr, sel and C.btnTxt or C.muted, bg)

        -- Label (up to 11 chars)
        local lbl = (t.label or ("T"..id)):sub(1, 11)
        mWrite(5, row, lbl, sel and C.btnTxt or C.txt, bg)

        -- Status dot
        mWrite(LEFT_W - 1, row, "●", sc, bg)

        row = row + 1
    end

    -- Fill remaining rows
    while row <= maxRow do
        mFill(1, row, LEFT_W, 1, " ", C.bg, C.bg)
        row = row + 1
    end

    -- Divider
    for r = HEADER_H, mH - 1 do
        mWrite(LEFT_W + 1, r, "│", C.panel, C.bg)
    end
end

-- ── Map view (right panel) ───────────────────────────────────
local MAP_SCALE = 1   -- 1 char = 1 block (zoomed out automatically)

local function worldToMap(wx, wz, cx, cy, mapW, mapH)
    -- Convert world X,Z to map screen position centred on cx,cz
    local dx = wx - cx
    local dz = wz - cy
    local sx = math.floor(mapW / 2) + dx + RIGHT_X
    local sy = math.floor(mapH / 2) + dz + HEADER_H + 2
    return sx, sy
end

local function drawMap()
    local mapX = RIGHT_X
    local mapY = HEADER_H + 2
    local mapW = mW - RIGHT_X
    local mapH = mH - FOOTER_H - mapY

    -- Background
    mBox(mapX, mapY, mapW + 1, mapH + 1, C.mapGrid, C.mapBg)

    -- Find map centre: selected turtle, or centroid of all
    local cx, cz = 0, 0
    local count = 0
    if selected and turtles[selected] then
        cx = turtles[selected].x or 0
        cz = turtles[selected].z or 0
    else
        for _, t in pairs(turtles) do
            cx = cx + (t.x or 0)
            cz = cz + (t.z or 0)
            count = count + 1
        end
        if count > 0 then cx = math.floor(cx/count); cz = math.floor(cz/count) end
    end

    -- Grid lines every 16 blocks (chunk boundary)
    local chunkStep = 16
    -- Find first chunk line left of view
    local viewLeft  = cx - math.floor(mapW / 2)
    local firstCX   = math.floor(viewLeft / chunkStep) * chunkStep
    for gx = firstCX, viewLeft + mapW, chunkStep do
        local sx, _ = worldToMap(gx, cz, cx, cz, mapW, mapH)
        if sx >= mapX and sx <= mW then
            for r = mapY, mapY + mapH do
                mWrite(sx, r, "┊", C.mapGrid, C.mapBg)
            end
        end
    end

    -- Origin cross
    local ox, oy = worldToMap(0, 0, cx, cz, mapW, mapH)
    if ox >= mapX and ox <= mW and oy >= mapY and oy <= mapY + mapH then
        mWrite(ox, oy, "+", C.muted, C.mapBg)
    end

    -- Draw each turtle
    local ids = {}
    for id in pairs(turtles) do ids[#ids+1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local t  = turtles[id]
        local sx, sy = worldToMap(t.x or 0, t.z or 0, cx, cz, mapW, mapH)
        if sx >= mapX and sx <= mW and sy >= mapY and sy <= mapY + mapH then
            local col = (id == selected) and C.mapSel or statusColor(t)
            local glyph = (id == selected) and "◆" or "●"
            mWrite(sx, sy, glyph, col, C.mapBg)
            -- Label next to dot
            local lbl = (t.label or ("T"..id)):sub(1, 6)
            if sx + 2 + #lbl <= mW then
                mWrite(sx + 1, sy, lbl, col, C.mapBg)
            end
        end
    end

    -- Coordinates legend bottom-left of map
    mWrite(mapX, mapY + mapH, string.format(" Centre: %d, %d  Scale: 1:1 ", cx, cz), C.muted, C.mapBg)
end

-- ── Detail view (right panel) ────────────────────────────────
local function drawDetail()
    local x = RIGHT_X
    local y = HEADER_H + 2
    local w = mW - x + 1

    if not selected or not turtles[selected] then
        mFill(x, y, w, mH - y - FOOTER_H + 1, " ", C.muted, C.bg)
        mWrite(x + 2, y + 2, "No turtle selected.", C.muted, C.bg)
        mWrite(x + 2, y + 3, "Click a turtle in the list.", C.muted, C.bg)
        return
    end

    local t  = turtles[selected]
    local sc = statusColor(t)

    mFill(x, y, w, mH - y - FOOTER_H + 1, " ", C.txt, C.bg)

    -- Title bar
    local lbl = t.label or ("Turtle " .. selected)
    mFill(x, y, w, 1, " ", C.headerTxt, C.header)
    mWrite(x + 1, y, lbl .. "  (ID " .. selected .. ")", C.headerTxt, C.header)

    y = y + 2

    local function row(label, value, vc)
        mWrite(x + 1, y, label, C.muted, C.bg)
        mWrite(x + 10, y, tostring(value), vc or C.txt, C.bg)
        y = y + 1
    end

    row("Status  ", statusLabel(t), sc)
    row("X       ", t.x or "?")
    row("Y       ", t.y or "?")
    row("Z       ", t.z or "?")

    y = y + 1
    row("Chunk X ", t.chunkX or "?", C.muted)
    row("Chunk Z ", t.chunkZ or "?", C.muted)

    y = y + 1
    local age = math.floor(os.clock() - (t.time or os.clock()))
    local ageStr = age .. "s ago"
    if age > HEARTBEAT_TIMEOUT then ageStr = ageStr .. " (LOST)" end
    row("Seen    ", ageStr, age > HEARTBEAT_TIMEOUT and C.err or C.ok)

    -- Chunk loader managed?
    if chunkloader then
        y = y + 1
        row("CL Managed", "yes", C.ok)
    end

    -- Mini relative map for this turtle (shows last ~20 moves pattern not stored
    -- so we show a 5x5 grid with current pos at centre)
    y = y + 2
    mWrite(x + 1, y, "Position in chunk:", C.muted, C.bg)
    y = y + 1

    local tx = (t.x or 0) % 16
    local tz = (t.z or 0) % 16
    -- 5x5 grid
    for gz = 0, 4 do
        local line = ""
        for gx = 0, 4 do
            local bx = math.floor(tx / 16 * 5) -- map tx 0-15 → 0-4
            local bz = math.floor(tz / 16 * 5)
            if gx == bx and gz == bz then
                line = line .. "◆"
            else
                line = line .. "·"
            end
        end
        mWrite(x + 2, y, line, C.muted, C.bg)
        y = y + 1
    end
    mWrite(x + 2, y, string.format("(%d,%d) in chunk", tx, tz), C.muted, C.bg)
end

-- ── Full redraw ──────────────────────────────────────────────
local function redraw()
    if not mon then return end
    mon.setBackgroundColour(C.bg)
    mon.clear()

    drawHeader()
    drawTurtleList()
    if tab == "map" then
        drawMap()
    else
        drawDetail()
    end
    drawFooter()
    lastDraw = os.clock()
end

-- ── Handle incoming rednet message ──────────────────────────
local function handleMessage(senderId, msg)
    if type(msg) ~= "table" then return end
    if msg.type ~= "status" then return end

    local t = turtles[senderId] or {}
    t.x      = msg.x
    t.y      = msg.y      -- depth
    t.z      = msg.z
    t.status = msg.status
    t.time   = os.clock()
    t.label  = msg.label or t.label or ("T" .. senderId)

    -- Chunk coordinates from message, or compute from x/z
    local newChunkX, newChunkZ
    if msg.chunkX and msg.chunkZ then
        newChunkX = msg.chunkX
        newChunkZ = msg.chunkZ
    else
        newChunkX = math.floor((msg.x or 0) / 16)
        newChunkZ = math.floor((msg.z or 0) / 16)
    end

    -- If the turtle has moved into a different chunk, release the old one.
    if t.chunkX and t.chunkZ
            and (t.chunkX ~= newChunkX or t.chunkZ ~= newChunkZ) then
        releaseChunk(t.chunkX, t.chunkZ, senderId)
    end

    t.chunkX = newChunkX
    t.chunkZ = newChunkZ

    turtles[senderId] = t

    -- Auto-select first turtle seen
    if selected == nil then selected = senderId end

    -- Ensure chunk stays loaded
    if t.chunkX and t.chunkZ then
        ensureChunkLoaded(t.chunkX, t.chunkZ)
    end
end

-- ── Send command to selected turtle(s) ──────────────────────
local function sendCommand(cmd, targetId)
    if targetId then
        rednet.send(targetId, cmd, PROTOCOL)
    else
        rednet.broadcast(cmd, PROTOCOL)
    end
end

-- ── Monitor touch handling ───────────────────────────────────
local function handleTouch(tx, ty)
    -- Tab bar row 2, right of LEFT_W
    if ty == 2 and tx >= RIGHT_X then
        local mapTabEnd = RIGHT_X + 5   -- " Map "
        if tx <= mapTabEnd then
            tab = "map"
        else
            tab = "list"
        end
        return
    end

    -- Turtle list click (left panel, rows 4+)
    if tx <= LEFT_W and ty >= HEADER_H + 2 then
        local row = ty - (HEADER_H + 1)
        local ids = {}
        for id in pairs(turtles) do ids[#ids+1] = id end
        table.sort(ids)
        if ids[row] then
            selected = ids[row]
        end
    end
end

-- ── Keyboard input (on the computer terminal) ────────────────
local function handleKey(key)
    if key == keys.q then
        running = false
    elseif key == keys.tab then
        tab = (tab == "map") and "list" or "map"
    elseif key == keys.u then
        -- Update selected turtle, or all
        if selected then
            sendCommand("update", selected)
        else
            sendCommand("update")
        end
        -- Print feedback to computer terminal
        print("[GUI] Sent 'update' to " .. (selected and tostring(selected) or "all"))
    elseif key == keys.w then
        if selected then
            sendCommand("wake", selected)
        else
            sendCommand("wake")
        end
        print("[GUI] Sent 'wake' to " .. (selected and tostring(selected) or "all"))
    elseif key == keys.up then
        -- Select previous turtle
        local ids = {}
        for id in pairs(turtles) do ids[#ids+1] = id end
        table.sort(ids)
        for i, id in ipairs(ids) do
            if id == selected and i > 1 then selected = ids[i-1]; break end
        end
    elseif key == keys.down then
        local ids = {}
        for id in pairs(turtles) do ids[#ids+1] = id end
        table.sort(ids)
        for i, id in ipairs(ids) do
            if id == selected and i < #ids then selected = ids[i+1]; break end
        end
    end
end

-- ── Main event loop ──────────────────────────────────────────
local function main()
    initMonitor()
    initChunkloader()

    if not mon then
        error("No monitor found. Attach a monitor and try again.")
    end

    -- Open rednet
    rednet.open(MODEM_SIDE)

    -- Re-load all previously known turtle chunks immediately on startup.
    -- This is the fix for the cold-start / cross-dimension problem:
    -- chunks are loaded before any heartbeat arrives.
    loadChunkRegistry()

    print("GUI running. Monitor: " .. mW .. "x" .. mH)
    if chunkloader then
        local count = 0
        for _ in pairs(chunkRegistry) do count = count + 1 end
        print("Chunk loader active. " .. count .. " chunk(s) registered.")
        print("To pre-register a chunk: type  register <cx> <cz>  and press Enter.")
    else
        print("No chunk loader found. Chunks won't be force-loaded.")
        print("Connect a CCChunkloader via wired modem and restart.")
    end
    print("Press Q to quit, or type 'register <cx> <cz>' to seed a chunk.")

    -- Terminal input buffer for typed commands (register, etc.)
    local inputBuf = ""

    redraw()

    while running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "rednet_message" then
            local senderId, msg, protocol = p1, p2, p3
            if protocol == PROTOCOL then
                handleMessage(senderId, msg)
                redraw()
            end

        elseif event == "monitor_touch" then
            handleTouch(p2, p3)
            redraw()

        elseif event == "key" then
            if p1 == keys.enter then
                -- Process typed command from terminal
                local parts = {}
                for word in inputBuf:gmatch("%S+") do parts[#parts+1] = word end
                if parts[1] == "register" then
                    registerChunkManual(parts[2], parts[3])
                elseif parts[1] == "q" or parts[1] == "quit" then
                    running = false
                end
                inputBuf = ""
            elseif p1 == keys.backspace then
                inputBuf = inputBuf:sub(1, -2)
            else
                handleKey(p1)
            end
            redraw()

        elseif event == "char" then
            -- Build terminal input buffer for typed commands
            inputBuf = inputBuf .. p1

        elseif event == "timer" then
            checkStaleChunks()
            redraw()
        end

        if os.clock() - lastDraw >= 2 then
            os.startTimer(0)
        end
    end

    mon.clear()
    rednet.close(MODEM_SIDE)
    print("GUI closed.")
end

main()
