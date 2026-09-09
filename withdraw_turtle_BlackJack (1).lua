-- withdraw_turtle.lua
-- Listens for withdrawal requests from the blackjack game computer.
-- FRONT of the turtle = the public shop chest. BEHIND the turtle = a
-- private stock chest.
--
-- On each withdrawal, this turtle takes the requested amount of gold OUT
-- of the shop chest (front) and moves it INTO the stock chest (behind).
--
-- HOW THE TRANSFER WORKS: CC:Tweaked turtles can only access "front",
-- "top", or "bottom" as peripherals -- there is no "back" at all, not even
-- temporarily. That means a chest in front and a chest behind can NEVER
-- both be reachable at the same time, so this turtle can't reference the
-- shop chest by name once it has turned to face the stock chest instead.
-- The fix: move the gold through the turtle's OWN inventory as a buffer --
-- suck it out of the shop chest (front), turn 180 degrees, then drop it
-- into the stock chest (now in front). Turns back to face the shop
-- afterward. Equip/attach a WIRELESS modem to the turtle (any side).
--
-- NOTE ON TRANSPORT: this uses RAW MODEM CHANNELS, not rednet. rednet.open()
-- always tries to open a channel equal to this turtle's own computer ID --
-- but channels only go up to 65535, and on a world/server that's had many
-- computers ever crafted, turtle IDs can climb past that, permanently
-- breaking rednet on that turtle ("Expected number in range 0-65535").
-- Fixed channel numbers below avoid that entirely. These three numbers
-- must match EXACTLY in this file, blackjack_solo.lua, roulette_solo.lua and
-- deposit_turtle.lua.
--
-- SECURITY: raw modem channels have no built-in authentication, so this
-- turtle only honors withdraw requests that carry a valid signature made
-- with SHARED_SECRET below -- otherwise anyone with a wireless modem could
-- send fake requests and drain your real gold stock for free. This secret
-- must match blackjack_solo.lua, roulette_solo.lua and deposit_turtle.lua
-- EXACTLY. CHANGE it to your own private value, and keep this turtle
-- somewhere players can't break it open and read its disk.

-- Work around CC's background rednet listener (started by rom/startup.lua)
-- crashing on computers whose ID is above 65535: on every modem_message it
-- calls modem.isOpen(os.getComputerID()), which throws
-- "Expected number in range 0-65535" and takes the whole computer down.
-- rednet.run looks up peripheral.call at call time, so wrapping it here
-- makes out-of-range isOpen queries return false instead of throwing.
do
    local rawCall = peripheral.call
    peripheral.call = function(side, method, ...)
        if method == "isOpen" then
            local ch = ...
            if type(ch) == "number" and (ch < 0 or ch > 65535) then
                return false
            end
        end
        return rawCall(side, method, ...)
    end
end

local CHANNEL_MAIN = 41000 -- the game computer listens here
local CHANNEL_WITHDRAW = 41002 -- this turtle listens here
local INGOT_NAME = "minecraft:gold_ingot"
local SHARED_SECRET = "CHANGE-ME-TO-YOUR-OWN-SECRET-8f2q"

local function mix(input)
    local h1, h2 = 5381, 52711
    for i = 1, #input do
        local c = string.byte(input, i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 33 + (c * 7) + 1) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function mac(parts)
    return mix(SHARED_SECRET .. "|" .. table.concat(parts, "|") .. "|" .. SHARED_SECRET)
end

math.randomseed(os.epoch and os.epoch("utc") or os.time())

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then
    error("Attach a wireless modem to this turtle.")
end
modem.open(CHANNEL_WITHDRAW)

-- Startup sanity checks (the actual transfer doesn't need these handles,
-- but this catches a bad build immediately instead of on the first
-- withdrawal request).
if not peripheral.wrap("front") then
    error("No inventory detected in front of this turtle (public shop chest).")
end
turtle.turnLeft()
turtle.turnLeft()
local hasStock = peripheral.wrap("front") ~= nil
turtle.turnLeft()
turtle.turnLeft()
if not hasStock then
    error("No inventory detected behind this turtle (private stock chest).")
end

local function turnAround()
    turtle.turnLeft()
    turtle.turnLeft()
end

local function countTurtleGold()
    local total = 0
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name == INGOT_NAME then
            total = total + detail.count
        end
    end
    return total
end

-- Sucks up to `amount` gold ingots from whatever is currently in front of
-- the turtle, into the turtle's own inventory. Returns how many were
-- actually collected (may be less than `amount` if the chest ran short).
local function collectFromFront(amount)
    local remaining = amount
    local collected = 0
    while remaining > 0 do
        local before = countTurtleGold()
        if not turtle.suck(remaining) then break end
        local gained = countTurtleGold() - before
        if gained <= 0 then break end -- got something, but not gold -- stop rather than risk grabbing the wrong item
        collected = collected + gained
        remaining = remaining - gained
    end
    return collected
end

-- Drops every gold ingot currently held by the turtle into whatever is in
-- front of it right now.
local function dropAllGoldIntoFront()
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name == INGOT_NAME then
            turtle.select(slot)
            turtle.drop()
        end
    end
    turtle.select(1)
end

-- Takes `requested` ingots OUT of the shop chest (front) and moves them
-- INTO the private stock chest (behind), via the turtle's own inventory.
-- Returns how many were actually moved. Always ends facing the shop again.
local function fulfillWithdrawal(requested)
    local collected = collectFromFront(requested)
    turnAround()
    dropAllGoldIntoFront()
    turnAround()
    return collected
end

print("Withdraw turtle online, listening on channel " .. CHANNEL_WITHDRAW .. ". Waiting for requests...")

while true do
    local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
    if channel == CHANNEL_WITHDRAW and type(message) == "table" and message.type == "withdraw_request" then
        local expected = mac({ "withdraw_request", tostring(message.ingots), tostring(message.requestId) })
        if message.mac ~= expected then
            print("Rejected withdraw_request: bad signature (forged or wrong secret). Ignoring.")
        else
            local requested = message.ingots or 0
            local ok, moved = pcall(fulfillWithdrawal, requested)
            if not ok then
                print("Withdrawal failed: " .. tostring(moved))
                moved = 0
            elseif moved < requested then
                print("Only found " .. moved .. "/" .. requested .. " ingot(s) in the shop chest to move.")
            else
                print("Moved " .. moved .. " ingot(s) from the shop chest into stock.")
            end

            local nonce = tostring(os.epoch and os.epoch("utc") or os.time()) .. "-" .. tostring(math.random(100000, 999999))
            local reply = { type = "withdraw_result", requestId = message.requestId, moved = moved, nonce = nonce }
            reply.mac = mac({ "withdraw_result", tostring(reply.requestId), tostring(reply.moved), tostring(reply.nonce) })
            modem.transmit(CHANNEL_MAIN, CHANNEL_WITHDRAW, reply)
        end
    end
end
