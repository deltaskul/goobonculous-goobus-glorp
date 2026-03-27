-- ============================================================
--  updater.lua  v1.1
--  Run this as startup on each mining turtle.
--
--  Listens for rednet commands while the miner runs:
--    "update" -> downloads latest quarry.lua and reboots
--    "wake"   -> stops and restarts the miner (no reboot)
--
--  Assumes an ender modem on the "left" side.
-- ============================================================

local MODEM_SIDE  = "left"
local PROTOCOL    = "miningTurtle"
local PROGRAM     = "quarry"
local ARGS        = "-m"             -- always passed to quarry
local UPDATE_URL  = "https://raw.githubusercontent.com/deltaskul/goobonculous-goobus-glorp/refs/heads/main/quarry/quarry.lua"

rednet.open(MODEM_SIDE)

-- Shared flag: when true, the miner coroutine will stop cleanly
-- and the listener will restart it.
local restartMiner = false
local stopMiner    = false

-- ── Run the miner ────────────────────────────────────────────
local function runMiner()
    while true do
        restartMiner = false
        stopMiner    = false

        print("[updater] Starting miner...")
        -- Use coroutine so we can kill it on command
        -- shell.run blocks, so we wrap it in a parallel task
        -- that watches the stopMiner flag via a timer.
        local done = false

        parallel.waitForAny(
            function()
                shell.run(PROGRAM, ARGS)
                done = true
            end,
            function()
                -- Poll stop flag every 0.5s
                while not done do
                    sleep(0.5)
                    if stopMiner then return end
                end
            end
        )

        if restartMiner then
            print("[updater] Restarting miner on wake command...")
            sleep(1)
            -- loop continues, restarts shell.run
        else
            print("[updater] Miner stopped. Restarting in 3s...")
            sleep(3)
        end
    end
end

-- ── Listen for commands ──────────────────────────────────────
local function listenForCommands()
    while true do
        local id, msg, protocol = rednet.receive()

        -- Accept both protocol-tagged and raw string messages
        -- (older GUI versions broadcast raw strings)
        local isOurs = (protocol == PROTOCOL) or (protocol == nil)

        if isOurs then
            if msg == "update" then
                print("[updater] Update command received from " .. id)
                print("[updater] Downloading new quarry.lua...")

                if shell.run("wget", UPDATE_URL, PROGRAM .. ".new") then
                    shell.run("rm " .. PROGRAM)
                    shell.run("mv " .. PROGRAM .. ".new " .. PROGRAM)
                    print("[updater] Update complete! Rebooting...")
                    sleep(1)
                    os.reboot()
                else
                    print("[updater] Download failed. Keeping current version.")
                end

            elseif msg == "wake" then
                print("[updater] Wake command received from " .. id)
                -- Signal the miner coroutine to stop, then runMiner loop restarts it
                restartMiner = true
                stopMiner    = true

            elseif msg == "return" then
                -- Future: could signal quarry.lua to surface
                -- For now just restart it cleanly
                print("[updater] Return command received. Restarting miner...")
                restartMiner = false
                stopMiner    = true
            end
        end
    end
end

-- ── Entry point ──────────────────────────────────────────────
parallel.waitForAny(runMiner, listenForCommands)
