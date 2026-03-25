-- rednet.broadcast("update") triggers the update

local url = ""
local programName = "quarry"

rednet.open("left")

-- Function 1: Run the miner
local function runMiner()
    while true do
        print("Starting miner...")
        shell.run(programName)
        print("Miner stopped. Restarting in 3s...")
        sleep(3)
    end
end

-- Function 2: Listen for update command
local function listenForUpdate()
    while true do
        local id, msg = rednet.receive()

        if msg == "update" then
            print("Updating program...")

            if shell.run("wget", url, programName .. ".new") then
                shell.run("rm " .. programName)
                shell.run("mv " .. programName .. ".new " .. programName)
                print("Update complete!")

                os.reboot() -- restart to apply cleanly
            else
                print("Update failed.")
            end
        end
    end
end

parallel.waitForAny(runMiner, listenForUpdate)
