-- deposit_turtle_seat1.lua  (head-to-head table, SEAT 1)
-- This chest has a sign shop that SELLS gold ingots TO players. Whenever a
-- player buys gold (gold ingots LEAVE the chest), this turtle credits
-- whoever is currently logged into the blackjack game (over a wireless
-- modem) -- buying gold from this shop IS how you fund your account.
--
-- Build: place your sign-shop chest (configured to sell gold to players),
-- attach this turtle to one of its faces (the turtle's FRONT must face the
-- chest), and put the shop sign on a different, player-accessible face so
-- the turtle doesn't block it. Equip/attach a WIRELESS modem to the turtle
-- (any side).
--
-- NOTE ON TRANSPORT: this uses RAW MODEM CHANNELS, not rednet. rednet.open()
-- always tries to open a channel equal to this turtle's own computer ID --
-- but channels only go up to 65535, and on a world/server that's had many
-- computers ever crafted, turtle IDs can climb past that, permanently
-- breaking rednet on that turtle ("Expected number in range 0-65535").
-- Fixed channel numbers below avoid that entirely. These three numbers
-- must match EXACTLY in this file, blackjack_solo.lua, roulette_solo.lua and
-- withdraw_turtle.lua.
--
-- SECURITY: raw modem channels have no built-in authentication, so every
-- "deposit" message this turtle sends is signed with a shared secret (see
-- SHARED_SECRET below) that must match the value in blackjack_solo.lua,
-- roulette_solo.lua and withdraw_turtle.lua EXACTLY. Without it, anyone with
-- a wireless modem in range could otherwise forge free deposits. CHANGE the
-- secret to your own private value, and keep this turtle somewhere players
-- can't break it open and read its disk.

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

local CHANNEL_MAIN = 43000 -- the H2H host listens here (BANK_CHANNEL in blackjack_h2h_host.lua)
local CHANNEL_DEPOSIT = 43001 -- this turtle listens here (SEAT 1 deposit)
local INGOT_NAME = "minecraft:gold_ingot"
local CHECK_INTERVAL = 2 -- seconds between scans
local REPLY_TIMEOUT = 3 -- seconds to wait for the game computer to answer
local STATE_FILE = "deposit_turtle_state.txt"
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
modem.open(CHANNEL_DEPOSIT)

local shopChest = peripheral.wrap("front")
if not shopChest then
    error("No inventory detected in front of this turtle (shop chest).")
end

local function countGold(inv)
    local total = 0
    for _, item in pairs(inv.list()) do
        if item.name == INGOT_NAME then
            total = total + item.count
        end
    end
    return total
end

-- Remember how much gold was in the chest last time we checked, so a
-- reboot doesn't cause a spurious "sale" to be detected.
local function loadLastKnown()
    if fs.exists(STATE_FILE) then
        local f = fs.open(STATE_FILE, "r")
        local n = tonumber(f.readAll())
        f.close()
        if n then return n end
    end
    return countGold(shopChest)
end

local function saveLastKnown(n)
    local f = fs.open(STATE_FILE, "w")
    f.write(tostring(n))
    f.close()
end

-- Waits (up to `timeout` seconds) for a reply on our own channel with the
-- given message type. Returns the message, or nil on timeout.
local function waitForReply(expectedType, timeout)
    local timer = os.startTimer(timeout)
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        if event == "modem_message" and channel == CHANNEL_DEPOSIT
            and type(message) == "table" and message.type == expectedType then
            return message
        elseif event == "timer" and side == timer then
            return nil
        end
    end
end

local lastKnown = loadLastKnown()
saveLastKnown(lastKnown)

print("Deposit turtle online. Watching for gold being bought (leaving the chest)...")

while true do
    local current = countGold(shopChest)
    if current < lastKnown then
        -- Gold left the chest -- someone bought it. Credit whoever is
        -- currently logged in.
        local sold = lastKnown - current
        modem.transmit(CHANNEL_MAIN, CHANNEL_DEPOSIT, { type = "deposit_check" })
        local reply = waitForReply("deposit_check_reply", REPLY_TIMEOUT)
        if reply and reply.allowed then
            local nonce = tostring(os.epoch and os.epoch("utc") or os.time()) .. "-" .. tostring(math.random(100000, 999999))
            local msg = { type = "deposit", ingots = sold, nonce = nonce }
            msg.mac = mac({ "deposit", tostring(msg.ingots), tostring(msg.nonce) })
            modem.transmit(CHANNEL_MAIN, CHANNEL_DEPOSIT, msg)
            lastKnown = current
            saveLastKnown(lastKnown)
            print("Credited " .. sold .. " gold ingot(s) bought by the current player.")
        else
            print(sold .. " gold ingot(s) were bought, but no one is logged in -- will retry crediting on next change.")
            -- Don't move the baseline down: if we did, we'd never credit
            -- this sale once someone does log in. Leave lastKnown as-is so
            -- the next scan still sees the shortfall (unless more gold is
            -- restocked in the meantime, see below).
        end
    elseif current > lastKnown then
        -- Chest was restocked (or someone added gold back manually).
        -- Just raise the baseline -- restocking isn't a purchase.
        lastKnown = current
        saveLastKnown(lastKnown)
    end
    sleep(CHECK_INTERVAL)
end
