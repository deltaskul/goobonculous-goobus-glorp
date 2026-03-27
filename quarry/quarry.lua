-- ============================================================
--  quarry.lua  v1.2
--  Changes from v1.1:
--    - Heartbeat now includes chunkX, chunkZ, and label
--    - Label is read from the turtle's own name (set with
--      the label command in CC or via peripheral.call)
--    - World-origin tracking: turtles broadcast their
--      absolute X/Z so the GUI can map them together.
--      NOTE: You must note the turtle's starting world
--      coords and hard-code them below (ORIGIN_X, ORIGIN_Z)
--      or use GPS if available.
-- ============================================================

os.loadAPI("inv")
os.loadAPI("t")

print("V1.2")

-- ── World-origin offset ──────────────────────────────────────
-- Set these to the turtle's starting position in world coordinates.
-- If you have GPS, the turtle can find these automatically (see below).
-- If not, stand at the turtle, press F3 in Minecraft, and read X and Z.
local ORIGIN_X = 0   -- <-- CHANGE THIS per turtle
local ORIGIN_Z = 0   -- <-- CHANGE THIS per turtle

-- ── Config ───────────────────────────────────────────────────
local MODEM_SIDE = "left"    -- must match updater.lua; modem already open when run via updater
local HEARTBEAT_INTERVAL = 5
local lastHeartbeat = os.clock()

local x = 0
local y = 0
local z = 0
local max  = 16
local deep = 64
local facingfw = true

local OK           = 0
local ERROR        = 1
local LAYERCOMPLETE = 2
local OUTOFFUEL    = 3
local FULLINV      = 4
local BLOCKEDMOV   = 5
local USRINTERRUPT = 6

local CHARCOALONLY = false
local USEMODEM     = false

-- ── Arguments ────────────────────────────────────────────────
local tArgs = {...}
for i = 1, #tArgs do
    local arg = tArgs[i]
    if string.find(arg, "-") == 1 then
        for c = 2, string.len(arg) do
            local ch = string.sub(arg, c, c)
            if ch == 'c' then
                CHARCOALONLY = true
            elseif ch == 'm' then
                USEMODEM = true
            else
                write("Invalid flag '"); write(ch); print("'")
            end
        end
    end
end

-- ── GPS origin (optional) ────────────────────────────────────
-- If GPS is available, auto-detect starting world position.
if USEMODEM then
    local gx, gy, gz = gps.locate(3)
    if gx then
        ORIGIN_X = gx - x
        ORIGIN_Z = gz - z
        print("GPS origin: " .. ORIGIN_X .. ", " .. ORIGIN_Z)
    else
        print("GPS unavailable, using hardcoded ORIGIN_X/Z")
    end
end

-- ── Turtle label ─────────────────────────────────────────────
local LABEL = os.getComputerLabel() or ("Turtle " .. os.getComputerID())

-- ── World coordinates ────────────────────────────────────────
local function worldX() return ORIGIN_X + x end
local function worldZ() return ORIGIN_Z + z end
local function chunkX() return math.floor(worldX() / 16) end
local function chunkZ() return math.floor(worldZ() / 16) end

-- ── Output / broadcast ──────────────────────────────────────
function out(s)
    local s2 = s .. " @ [" .. x .. ", " .. y .. ", " .. z .. "]"
    print(s2)

    if USEMODEM then
        rednet.broadcast({
            type    = "status",
            label   = LABEL,
            x       = worldX(),
            y       = y,
            z       = z,       -- depth (negative = underground)
            chunkX  = chunkX(),
            chunkZ  = chunkZ(),
            status  = s,
            time    = os.clock(),
        }, "miningTurtle")
        lastHeartbeat = os.clock()
    end
end

-- ── Drop inventory in chest ──────────────────────────────────
function dropInChest()
    turtle.turnLeft()

    local success, data = turtle.inspect()

    if success then
        if data.name == "minecraft:chest" then
            out("Dropping items in chest")

            for i = 1, 16 do
                turtle.select(i)
                data = turtle.getItemDetail()

                if data ~= nil and
                        data.name ~= "minecraft:charcoal" and
                        (data.name == "minecraft:coal" and CHARCOALONLY == false) == false and
                        (data.damage == nil or data.name .. data.damage ~= "minecraft:coal1") then
                    turtle.drop()
                end
            end
        end
    end

    turtle.turnRight()
end

-- ── Movement ─────────────────────────────────────────────────
function goDown()
    while true do
        if turtle.getFuelLevel() <= fuelNeededToGoBack() then
            if not refuel() then return OUTOFFUEL end
        end

        if not turtle.down() then
            turtle.up()
            z = z + 1
            return
        end
        z = z - 1
    end
end

function fuelNeededToGoBack()
    return -z + x + y + 2
end

function refuel()
    for i = 1, 16 do
        turtle.select(i)
        item = turtle.getItemDetail()
        if item and
                (item.name == "minecraft:charcoal" or (item.name == "minecraft:coal" and
                (CHARCOALONLY == false or item.damage == 1))) and
                turtle.refuel(1) then
            return true
        end
    end
    return false
end

-- ── Horizontal movement ──────────────────────────────────────
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
        local dugFw = t.dig()
        if dugFw == false then
            out("Hit bedrock, can't keep going")
            return BLOCKEDMOV
        end
        t.digUp()
        t.digDown()

        if t.fw() == false then return BLOCKEDMOV end
        y = y + 1

    elseif not facingfw and y > 0 then
        t.dig()
        t.digUp()
        t.digDown()

        if t.fw() == false then return BLOCKEDMOV end
        y = y - 1

    else
        if x + 1 >= max then
            t.digUp()
            t.digDown()
            return LAYERCOMPLETE
        end

        if facingfw then turtle.turnRight() else turtle.turnLeft() end

        t.dig()
        t.digUp()
        t.digDown()

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

            -- Heartbeat
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

    x = 0
    y = 0
    facingfw = true
end

function goUp()
    while z < 0 do
        t.up()
        z = z + 1
    end
    goToOrigin()
end

-- ── Main loop ────────────────────────────────────────────────
function mainloop()
    while true do
        local errorcode = digLayer()

        if errorcode ~= OK then
            goUp()
            return errorcode
        end

        goToOrigin()

        for i = 1, 3 do
            t.digDown()
            local success = t.down()

            if not success then
                goUp()
                return BLOCKEDMOV
            end

            z = z - 1
            out("Z: " .. z)
        end
    end
end

-- ── Entry point ──────────────────────────────────────────────
-- Note: rednet is already open via updater.lua.
-- If running quarry standalone (not via updater), pass -m and
-- uncomment the two lines below.
-- if USEMODEM then rednet.open(MODEM_SIDE) end

out("\n\n\n-- WELCOME TO THE MINING TURTLE --\n\n")

while true do
    goDown()

    local errorcode = mainloop()
    dropInChest()

    if errorcode ~= FULLINV then
        break
    end
end

-- if USEMODEM then rednet.close(MODEM_SIDE) end
