-- ============================================================
--  Turtle Mining GUI  v2.0  -- Pocket Edition
--  Runs on a pocket computer (no external monitor needed).
--  Same rednet protocol as gui.lua.
-- ============================================================

local PROTOCOL          = "miningTurtle"
local MODEM_SIDE        = "back"   -- pocket computers have modem on back
local HEARTBEAT_TIMEOUT = 30

local turtles   = {}
local selected  = nil
local tab       = "list"   -- "list" | "detail"
local running   = true

local W, H = term.getSize()

-- ── Colours (pocket screen is small; keep it simple) ─────────
local C = {
    bg        = colours.black,
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
    panel     = colours.grey,
    fuelOk    = colours.lime,
    fuelWarn  = colours.yellow,
    fuelLow   = colours.red,
}

-- ── Draw helpers ─────────────────────────────────────────────

local function tWrite(x, y, text, fg, bg)
    if x < 1 or y < 1 or y > H then return end
    local maxLen = W - x + 1
    if maxLen <= 0 then return end
    if #text > maxLen then text = text:sub(1, maxLen) end
    term.setCursorPos(x, y)
    term.setTextColour(fg or C.txt)
    term.setBackgroundColour(bg or C.bg)
    term.write(text)
end

local function tFill(x, y, w, h, fg, bg)
    if w <= 0 or h <= 0 then return end
    local line = string.rep(" ", w)
    for row = y, y + h - 1 do tWrite(x, row, line, fg, bg) end
end

-- ── Status helpers ───────────────────────────────────────────

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
    return #s > W - 2 and s:sub(1, W - 3).."~" or s
end

local function fuelColor(fuel)
    if not fuel then return C.muted end
    if fuel == "unlimited" then return C.fuelOk end
    if fuel > 500 then return C.fuelOk elseif fuel > 100 then return C.fuelWarn else return C.fuelLow end
end

local function fuelLabel(fuel)
    if not fuel then return "?" end
    if fuel == "unlimited" then return "INF" end
    if fuel >= 1000 then return math.floor(fuel/100)/10 .."k" else return tostring(fuel) end
end

local function sortedIds()
    local ids = {}
    for id in pairs(turtles) do ids[#ids+1] = id end
    table.sort(ids)
    return ids
end

-- ── Header ───────────────────────────────────────────────────

local function drawHeader()
    tFill(1, 1, W, 1, C.headerTxt, C.header)
    local n = 0; for _ in pairs(turtles) do n = n + 1 end
    local title = "Turtles ("..n..")"
    tWrite(1, 1, " "..title, C.headerTxt, C.header)
    -- Tab indicator right-aligned
    local tabStr = tab == "list" and "[List]Dtl" or "List[Dtl]"
    tWrite(W - #tabStr, 1, tabStr, C.headerTxt, C.header)
end

-- ── Footer ───────────────────────────────────────────────────

local function drawFooter()
    tFill(1, H, W, 1, C.muted, C.panel)
    tWrite(1, H, " [U]Upd [W]Wake [T]Tab [Q]Quit", C.muted, C.panel)
end

-- ── List view ────────────────────────────────────────────────

local function drawList()
    local row = 2
    local maxRow = H - 1
    tFill(1, row, W, maxRow - row + 1, C.txt, C.bg)

    for _, id in ipairs(sortedIds()) do
        if row > maxRow then break end
        local t   = turtles[id]
        local sel = id == selected
        local bg  = sel and C.sel or C.bg
        local fg  = sel and C.selTxt or C.txt
        local sc  = statusColor(t)

        tFill(1, row, W, 1, fg, bg)

        -- ID
        local idStr = string.format("%3d", id)
        tWrite(1, row, idStr, sel and C.selTxt or C.muted, bg)

        -- Label (up to 10 chars)
        tWrite(5, row, (t.label or ("T"..id)):sub(1, 10), fg, bg)

        -- Fuel (right-aligned, 5 chars)
        local fl  = fuelLabel(t.fuel)
        local fpad = string.rep(" ", math.max(0, 4 - #fl))..fl
        tWrite(W - 6, row, fpad, sel and C.selTxt or fuelColor(t.fuel), bg)

        -- Status dot
        tWrite(W, row, "●", sel and C.selTxt or sc, bg)

        row = row + 1
    end

    -- Empty state
    if next(turtles) == nil then
        tWrite(2, 3, "No turtles seen yet.", C.muted, C.bg)
        tWrite(2, 4, "Waiting for heartbeat...", C.muted, C.bg)
    end
end

-- ── Detail view ──────────────────────────────────────────────

local function drawDetail()
    tFill(1, 2, W, H - 2, C.txt, C.bg)

    if not selected or not turtles[selected] then
        tWrite(2, 3, "Nothing selected.", C.muted, C.bg)
        tWrite(2, 4, "Go to List tab first.", C.muted, C.bg)
        return
    end

    local t  = turtles[selected]
    local sc = statusColor(t)
    local y  = 2

    -- Mini title
    tFill(1, y, W, 1, C.headerTxt, C.header)
    tWrite(1, y, " "..(t.label or ("T"..selected)).." #"..selected, C.headerTxt, C.header)
    y = y + 1

    local function row(label, value, vc)
        tWrite(1, y, label..":", C.muted, C.bg)
        tWrite(#label + 2, y, tostring(value), vc or C.txt, C.bg)
        y = y + 1
    end

    row("Status",  statusLabel(t), sc)
    row("X",       t.x or "?")
    row("Y",       t.y or "?")
    row("Depth",   t.z and (t.z.." blk") or "?")
    row("Chunk",   (t.chunkX or "?")..","..(t.chunkZ or "?"), C.muted)

    -- Fuel with mini bar
    local fuel = t.fuel
    local fc   = fuelColor(fuel)
    row("Fuel", fuelLabel(fuel), fc)
    if fuel and fuel ~= "unlimited" then
        local barW   = W - 2
        local filled = math.floor(math.min(fuel/20000, 1) * barW)
        tWrite(1, y, string.rep("█", filled)..string.rep("░", barW-filled), fc, C.bg)
        y = y + 1
    end

    local age = math.floor(os.clock() - (t.time or os.clock()))
    row("Seen", age.."s ago", age > HEARTBEAT_TIMEOUT and C.err or C.ok)
end

-- ── Redraw ───────────────────────────────────────────────────

local function redraw()
    term.setBackgroundColour(C.bg); term.clear()
    drawHeader()
    if tab == "list" then drawList() else drawDetail() end
    drawFooter()
end

-- ── Commands ─────────────────────────────────────────────────

local function sendCommand(cmd, targetId)
    if targetId then rednet.send(targetId, cmd, PROTOCOL)
    else rednet.broadcast(cmd, PROTOCOL) end
end

-- ── Input ────────────────────────────────────────────────────

local function handleKey(key)
    if key == keys.q then
        running = false
    elseif key == keys.t then
        tab = tab == "list" and "detail" or "list"
    elseif key == keys.u then
        sendCommand("update", selected)
    elseif key == keys.w then
        sendCommand("wake", selected)
    elseif key == keys.up then
        local ids = sortedIds()
        for i, id in ipairs(ids) do
            if id == selected and i > 1 then selected = ids[i-1]; return end
        end
        -- Wrap to last
        if #ids > 0 then selected = ids[#ids] end
    elseif key == keys.down then
        local ids = sortedIds()
        for i, id in ipairs(ids) do
            if id == selected and i < #ids then selected = ids[i+1]; return end
        end
        -- Wrap to first
        if #ids > 0 then selected = ids[1] end
    end
end

-- Pocket touchscreen: tap a turtle row to select, tap again to view detail
local function handleTouch(tx, ty)
    if ty == 1 then
        -- Header touch: cycle tab
        tab = tab == "list" and "detail" or "list"
        return
    end
    if ty == H then return end  -- footer

    if tab == "list" then
        local row = ty - 1
        local ids = sortedIds()
        if ids[row] then
            if selected == ids[row] then
                -- Second tap on same row: switch to detail
                tab = "detail"
            else
                selected = ids[row]
            end
        end
    end
end

-- ── Main ─────────────────────────────────────────────────────

local function main()
    -- Pocket computers may not have a modem; degrade gracefully
    local modemOk = false
    if peripheral.isPresent(MODEM_SIDE) then
        modemOk = pcall(rednet.open, MODEM_SIDE)
    end
    if not modemOk then
        -- Try any attached modem
        for _, side in ipairs({"left","right","top","bottom","front","back"}) do
            if peripheral.isPresent(side) and
                    string.find(peripheral.getType(side) or "", "modem") then
                modemOk = pcall(rednet.open, side)
                if modemOk then break end
            end
        end
    end

    if not modemOk then
        print("No modem found on pocket computer.")
        print("Attach an ender modem and restart.")
        return
    end

    redraw(); os.startTimer(2)

    while running do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            if p3 == PROTOCOL and type(p2) == "table" and p2.type == "status" then
                local t  = turtles[p1] or {}
                t.x      = p2.x;  t.y = p2.y;  t.z = p2.z
                t.status = p2.status;  t.fuel = p2.fuel;  t.time = os.clock()
                t.label  = p2.label or t.label or ("T"..p1)
                t.chunkX = p2.chunkX or math.floor((p2.x or 0)/16)
                t.chunkZ = p2.chunkZ or math.floor((p2.z or 0)/16)
                turtles[p1] = t
                if selected == nil then selected = p1 end
                redraw()
            end
        elseif event == "key" then
            handleKey(p1); redraw()
        elseif event == "mouse_click" or event == "monitor_touch" then
            handleTouch(p2, p3); redraw()
        elseif event == "timer" then
            redraw(); os.startTimer(2)
        end
    end

    term.setBackgroundColour(colours.black); term.clear()
    term.setCursorPos(1,1); print("Pocket GUI closed.")
    rednet.close(MODEM_SIDE)
end

main()
