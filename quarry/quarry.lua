-- ============================================================
--  quarry.lua  v1.3
--  Changes from v1.2:
--    - Broadcasts fuel level and fuelMax in every heartbeat
--    - Auto-detects world origin via GPS; falls back to a
--      saved origin.txt file; finally falls back to (0,0).
--      On first run with GPS, saves coords to origin.txt so
--      subsequent restarts (when GPS may be unavailable
--      mid-mine) still have the right offset.
--    - rednet.open/close removed: updater.lua owns the modem.
-- ============================================================

os.loadAPI("inv")
os.loadAPI("t")

print("V1.3")

-- ── Config ───────────────────────────────────────────────────
local MODEM_SIDE       = "left"   -- must match updater.lua
local HEARTBEAT_INTERVAL = 5
local ORIGIN_FILE      = "origin.txt"

local lastHeartbeat = os.clock()

-- Quarry-relative position (resets to 0 each run)
local x = 0
local y = 0
local z = 0
local max      = 16
local deep     = 64
local facingfw = true

local OK            = 0
local ERROR         = 1
local LAYERCOMPLETE = 2
local OUTOFFUEL     = 3
local FULLINV       = 4
local BLOCKEDMOV    = 5
local USRINTERRUPT  = 6

local CHARCOALONLY = false
local USEMODEM     = false

-- ── Arguments ────────────────────────────────────────────────
local tArgs = {...}
for i = 1, #tArgs do
    local arg = tArgs[i]
    if string.find(arg, "-") == 1 then
        for c = 2, string.len(arg) do
            local ch = string.sub(arg, c, c)
            if     ch == 'c' then CHARCOALONLY = true
            elseif ch == 'm' then USEMODEM     = true
            else
                write("Invalid flag '"); write(ch); print("'")
            end
        end
    end
end

-- ── World-origin detection ───────────────────────────────────
-- Priority:
--   1. GPS (most accurate; saves result to origin.txt)
--   2. origin.txt saved from a previous GPS fix
--   3. (0, 0) with a warning

local ORIGIN_X, ORIGIN_Z = 0, 0

local function saveOrigin(ox, oz)
    local f = fs.open(ORIGIN_FILE, "w")
    if f then
        f.writeLine(tostring(ox))
        f.writeLine(tostring(oz))
        f.close()
    end
end

local function loadOrigin()
    if not fs.exists(ORIGIN_FILE) then return nil, nil end
    local f = fs.open(ORIGIN_FILE, "r")
    if not f then return nil, nil end
    local ox = tonumber(f.readLine())
    local oz = tonumber(f.readLine())
    f.close()
    return ox, oz
end

if USEMODEM then
    local gx, gy, gz = gps.locate(3)
    if gx then
        -- GPS offset: world position minus current quarry-relative position
        -- (which is 0,0 at startup, so ORIGIN = world position directly)
        ORIGIN_X = math.floor(gx - x)
        ORIGIN_Z = math.floor(gz - z)
        saveOrigin(ORIGIN_X, ORIGIN_Z)
        print("GPS origin: " .. ORIGIN_X .. ", " .. ORIGIN_Z)
    else
        -- Try saved origin
        local ox, oz = loadOrigin()
        if ox and oz then
            ORIGIN_X, ORIGIN_Z = ox, oz
            print("Origin from file: " .. ORIGIN_X .. ", " .. ORIGIN_Z)
        else
            print("WARNING: No GPS and no saved origin. Map position will be wrong.")
            print("Set up GPS towers, or run once with GPS to save origin.txt.")
        end
    end
else
    -- Even without modem, try to load a saved origin so it's ready
    -- if the user enables modem mid-session.
    local ox, oz = loadOrigin()
    if ox and oz then ORIGIN_X, ORIGIN_Z = ox, oz end
end

-- ── Turtle identity ──────────────────────────────────────────
local LABEL   = os.getComputerLabel() or ("Turtle " .. os.getComputerID())
local FUEL_MAX = turtle.getFuelLimit()   -- e.g. 100000 for advanced turtle

-- ── World-coordinate helpers ─────────────────────────────────
local function worldX()  return ORIGIN_X + x end
local function worldZ()  return ORIGIN_Z + z end
local function chunkX()  return math.floor(worldX() / 16) end
local function chunkZ()  return math.floor(worldZ() / 16) end

-- ── Broadcast status ─────────────────────────────────────────
function out(s)
    local s2 = s .. " @ [" .. x .. ", " .. y .. ", " .. z .. "]"
    print(s2)

    if USEMODEM then
        rednet.broadcast({
            type    = "status",
            label   = LABEL,
            x       = worldX(),
            y       = y,
            z       = z,
            chunkX  = chunkX(),
            chunkZ  = chunkZ(),
            status  = s,
            fuel    = turtle.getFuelLevel(),
            fuelMax = FUEL_MAX,
            time    = os.clock(),
        }, "miningTurtle")
        lastHeartbeat = os.clock()
    end
end

-- ── Inventory ────────────────────────────────────────────────
function dropInChest()
    turtle.turnLeft()
    local success, data = turtle.inspect()
    if success and data.name == "minecraft:chest" then
        out("Dropping items in chest")
        for i = 1, 16 do
            turtle.select(i)
            data = turtle.getItemDetail()
            if data ~= nil
                    and data.name ~= "minecraft:charcoal"
                    and not (data.name == "minecraft:coal" and CHARCOALONLY == false)
                    and not (data.damage ~= nil and data.name .. data.damage == "minecraft:coal1") then
                turtle.drop()
            end
        end
    end
    turtle.turnRight()
end

-- ── Fuel ─────────────────────────────────────────────────────
function fuelNeededToGoBack()
    return -z + x + y + 2
end

function refuel()
    for i = 1, 16 do
        turtle.select(i)
        local item = turtle.getItemDetail()
        if item and
                (item.name == "minecraft:charcoal" or
                 (item.name == "minecraft:coal" and (CHARCOALONLY == false or item.damage == 1)))
                and turtle.refuel(1) then
            return true
        end
    end
    return false
end

-- ── Movement ─────────────────────────────────────────────────
function goDown()
    while true do
        if turtle.getFuelLevel() <= fuelNeededToGoBack() then
            if not refuel() then return OUTOFFUEL end
        end
        if not turtle.down() then
            turtle.up(); z = z + 1; return
        end
        z = z - 1
    end
end

function moveH()
    if inv.isInventoryFull() then
        out("Dropping trash")
        inv.dropThrash()
        if inv.isInventoryFull() then
            out("Stacking items")
            inv.stackItems()
        end
        if inv.isInventoryFull() then
            out("Full inventory!")
            return FULLINV
        end
    end

    if turtle.getFuelLevel() <= fuelNeededToGoBack() then
        if not refuel() then
            out("Out of fuel!")
            return OUTOFFUEL
        end
    end

    if facingfw and y < max - 1 then
        if t.dig() == false then
            out("Hit bedrock, can't keep going")
            return BLOCKEDMOV
        end
        t.digUp(); t.digDown()
        if t.fw() == false then return BLOCKEDMOV end
        y = y + 1

    elseif not facingfw and y > 0 then
        t.dig(); t.digUp(); t.digDown()
        if t.fw() == false then return BLOCKEDMOV end
        y = y - 1

    else
        if x + 1 >= max then
            t.digUp(); t.digDown()
            return LAYERCOMPLETE
        end
        if facingfw then turtle.turnRight() else turtle.turnLeft() end
        t.dig(); t.digUp(); t.digDown()
        if t.fw() == false then return BLOCKEDMOV end
        x = x + 1
        if facingfw then turtle.turnRight() else turtle.turnLeft() end
        facingfw = not facingfw
    end

    return OK
end

-- ── Layer ────────────────────────────────────────────────────
function digLayer()
    local errorcode = OK
    while errorcode == OK do
        if USEMODEM then
            local msg = rednet.receive(1)
            if msg ~= nil and string.find(msg, "return") ~= nil then
                return USRINTERRUPT
            end
            if os.clock() - lastHeartbeat >= HEARTBEAT_INTERVAL then
                out("Heartbeat: still mining")
            end
        end
        errorcode = moveH()
    end
    if errorcode == LAYERCOMPLETE then return OK end
    return errorcode
end

-- ── Navigation ───────────────────────────────────────────────
function goToOrigin()
    if facingfw then
        turtle.turnLeft()
        t.fw(x)
        turtle.turnLeft()
        t.fw(y)
        turtle.turnRight()
        turtle.turnRight()
    else
        turtle.turnRight()
        t.fw(x)
        turtle.turnLeft()
        t.fw(y)
        turtle.turnRight()
        turtle.turnRight()
    end
    x = 0; y = 0; facingfw = true
end

function goUp()
    while z < 0 do t.up(); z = z + 1 end
    goToOrigin()
end

-- ── Main loop ────────────────────────────────────────────────
function mainloop()
    while true do
        local errorcode = digLayer()
        if errorcode ~= OK then
            goUp(); return errorcode
        end
        goToOrigin()
        for i = 1, 3 do
            t.digDown()
            if not t.down() then
                goUp(); return BLOCKEDMOV
            end
            z = z - 1
            out("Z: " .. z)
        end
    end
end

-- ── Entry point ──────────────────────────────────────────────
-- rednet is already open by updater.lua.
-- Uncomment below only if running quarry standalone:
-- if USEMODEM then rednet.open(MODEM_SIDE) end

out("\n\n\n-- WELCOME TO THE MINING TURTLE --\n\n")

while true do
    goDown()
    local errorcode = mainloop()
    dropInChest()
    if errorcode ~= FULLINV then break end
end

-- if USEMODEM then rednet.close(MODEM_SIDE) end
