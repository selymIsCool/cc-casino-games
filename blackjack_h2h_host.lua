-- blackjack_h2h_host.lua
-- Headless coordinator for two-player head-to-head blackjack. No monitor
-- needed -- just a computer with a wireless modem. Manages the shared
-- deck, turn order, accounts, and settlement; each player's station
-- computer only ever receives ITS OWN hand's cards, plus a card COUNT
-- (not the cards) for the opponent, so hands stay genuinely hidden until
-- showdown.
--
-- Run one of these, then run blackjack_h2h_station.lua on each of the two
-- player computers (each with its own monitor).
--
-- NOTE ON TRANSPORT: this uses RAW MODEM CHANNELS, not rednet. rednet.open()
-- always tries to open a channel equal to this computer's own ID -- but
-- channels only go up to 65535, and on a world/server that's had many
-- computers ever crafted, IDs can climb past that, permanently breaking
-- rednet ("Expected number in range 0-65535"). Fixed/self-chosen channels
-- avoid that entirely. The host listens on a fixed channel; each station
-- picks its OWN random channel to listen on and includes it as the "reply
-- channel" on every message it sends, so the host always knows where to
-- answer without needing rednet's ID-based addressing at all.

local HOST_CHANNEL = 42000 -- must match HOST_CHANNEL in blackjack_h2h_station.lua
local MIN_BET = 10

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then
    error("Attach a wireless modem to this computer.")
end
modem.open(HOST_CHANNEL)

-- ===== Accounts (6-digit code only, shared format with blackjack_solo.lua) =====

local ACCOUNTS_DIR = "accounts"
if not fs.exists(ACCOUNTS_DIR) then fs.makeDir(ACCOUNTS_DIR) end

local function mix(input)
    local h1, h2 = 5381, 52711
    for i = 1, #input do
        local c = string.byte(input, i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 33 + (c * 7) + 1) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function hashAccountId(numStr)
    return mix("BJ-ID-SALT-9k2::" .. numStr .. "::BJ-ID-SALT-9k2")
end

local function accountPath(idHash) return fs.combine(ACCOUNTS_DIR, idHash .. ".acc") end

local function readAccount(idHash)
    local path = accountPath(idHash)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local data = f.readAll()
    f.close()
    local ok, record = pcall(textutils.unserialize, data)
    if ok and type(record) == "table" then return record end
    return nil
end

local function writeAccount(idHash, record)
    local f = fs.open(accountPath(idHash), "w")
    f.write(textutils.serialize(record))
    f.close()
end

local function loadOrCreate(idHash)
    local record = readAccount(idHash)
    if not record then
        record = { balance = 0 }
        writeAccount(idHash, record)
    end
    return record
end

local function persistBalance(idHash, balance)
    local record = readAccount(idHash) or {}
    record.balance = balance
    writeAccount(idHash, record)
end

-- ===== Deck =====

local RANKS = { "2","3","4","5","6","7","8","9","10","J","Q","K","A" }
local SUITS = { "H", "D", "C", "S" } -- transmitted as plain letters; stations render the glyphs

local function newDeck()
    local deck = {}
    for _, s in ipairs(SUITS) do
        for _, r in ipairs(RANKS) do
            table.insert(deck, { rank = r, suit = s })
        end
    end
    for i = #deck, 2, -1 do
        local j = math.random(i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end

local function draw1(deck) return table.remove(deck) end

local function cardValue(card)
    if card.rank == "A" then return 11 end
    if card.rank == "J" or card.rank == "Q" or card.rank == "K" then return 10 end
    return tonumber(card.rank)
end

local function handValue(hand)
    local sum, aces = 0, 0
    for _, c in ipairs(hand) do
        sum = sum + cardValue(c)
        if c.rank == "A" then aces = aces + 1 end
    end
    while sum > 21 and aces > 0 do
        sum = sum - 10
        aces = aces - 1
    end
    return sum
end

-- ===== Table state =====

math.randomseed(os.epoch and os.epoch("utc") or os.time())

local players = {
    [1] = { channel = nil, number = nil, hash = nil, balance = 0, ready = false, hand = {}, done = false },
    [2] = { channel = nil, number = nil, hash = nil, balance = 0, ready = false, hand = {}, done = false },
}
local wager = 100
local deck = nil
local turn = 1
local dealt = false

local function slotOf(channel)
    if players[1].channel == channel then return 1 end
    if players[2].channel == channel then return 2 end
    return nil
end

local function send(slot, msg)
    if players[slot].channel then
        modem.transmit(players[slot].channel, HOST_CHANNEL, msg)
    end
end

local function clampWager()
    local cap = math.min(players[1].balance, players[2].balance)
    if wager < MIN_BET then wager = MIN_BET end
    if wager > cap then wager = cap end
    if cap <= 0 then wager = 0 end
end

local function resetForNewJoin(slot)
    players[slot] = { channel = nil, number = nil, hash = nil, balance = 0, ready = false, hand = {}, done = false }
end

local function bothLoggedIn()
    return players[1].hash ~= nil and players[2].hash ~= nil
end

local function dealRound()
    deck = newDeck()
    players[1].hand = { draw1(deck), draw1(deck) }
    players[2].hand = { draw1(deck), draw1(deck) }
    players[1].done, players[2].done = false, false
    players[1].ready, players[2].ready = false, false
    turn = 1
    dealt = true
    send(1, { type = "deal", hand = players[1].hand, oppCount = #players[2].hand, wager = wager, yourTurn = true })
    send(2, { type = "deal", hand = players[2].hand, oppCount = #players[1].hand, wager = wager, yourTurn = false })
end

local function settle()
    local v1, v2 = handValue(players[1].hand), handValue(players[2].hand)
    local b1, b2 = v1 > 21, v2 > 21
    local msg1, msg2

    if b1 and b2 then
        msg1 = "Both bust (" .. v1 .. " / " .. v2 .. ")! Push -- bet returned."
        msg2 = msg1
    elseif b1 then
        players[1].balance = players[1].balance - wager
        players[2].balance = players[2].balance + wager
        msg1 = "You bust (" .. v1 .. "). Opponent wins $" .. wager .. "."
        msg2 = "Opponent busts (" .. v1 .. ")! You win $" .. wager .. "."
    elseif b2 then
        players[2].balance = players[2].balance - wager
        players[1].balance = players[1].balance + wager
        msg1 = "Opponent busts (" .. v2 .. ")! You win $" .. wager .. "."
        msg2 = "You bust (" .. v2 .. "). Opponent wins $" .. wager .. "."
    elseif v1 > v2 then
        players[2].balance = players[2].balance - wager
        players[1].balance = players[1].balance + wager
        msg1 = "You win! (" .. v1 .. " vs " .. v2 .. ") +$" .. wager
        msg2 = "You lose. (" .. v2 .. " vs " .. v1 .. ") -$" .. wager
    elseif v2 > v1 then
        players[1].balance = players[1].balance - wager
        players[2].balance = players[2].balance + wager
        msg1 = "You lose. (" .. v1 .. " vs " .. v2 .. ") -$" .. wager
        msg2 = "You win! (" .. v2 .. " vs " .. v1 .. ") +$" .. wager
    else
        msg1 = "Push! Both had " .. v1 .. ". Bet returned."
        msg2 = msg1
    end

    persistBalance(players[1].hash, players[1].balance)
    persistBalance(players[2].hash, players[2].balance)

    send(1, { type = "result", yourHand = players[1].hand, oppHand = players[2].hand, message = msg1, yourBalance = players[1].balance })
    send(2, { type = "result", yourHand = players[2].hand, oppHand = players[1].hand, message = msg2, yourBalance = players[2].balance })
    dealt = false
end

local function advanceTurn(actingSlot)
    local otherSlot = (actingSlot == 1) and 2 or 1
    players[actingSlot].done = true
    if players[otherSlot].done then
        settle()
    else
        turn = otherSlot
        send(otherSlot, { type = "your_turn", oppCount = #players[actingSlot].hand })
        send(actingSlot, { type = "waiting" })
    end
end

print("Head-to-head host online, listening on channel " .. HOST_CHANNEL .. ". Waiting for players...")

while true do
    local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
    if channel == HOST_CHANNEL and type(message) == "table" then
        local senderChannel = replyChannel
        local mtype = message.type

        if mtype == "join" then
            if players[1].channel == senderChannel or players[2].channel == senderChannel then
                modem.transmit(senderChannel, HOST_CHANNEL, { type = "join_ack", slot = slotOf(senderChannel) })
            elseif not players[1].channel then
                players[1].channel = senderChannel
                modem.transmit(senderChannel, HOST_CHANNEL, { type = "join_ack", slot = 1 })
                print("Player 1 station connected.")
            elseif not players[2].channel then
                players[2].channel = senderChannel
                modem.transmit(senderChannel, HOST_CHANNEL, { type = "join_ack", slot = 2 })
                print("Player 2 station connected.")
            else
                modem.transmit(senderChannel, HOST_CHANNEL, { type = "join_reject", reason = "Table is full." })
            end

        elseif mtype == "login" then
            local slot = slotOf(senderChannel)
            if slot then
                local hash = hashAccountId(message.accountNumber)
                local otherSlot = (slot == 1) and 2 or 1
                if players[otherSlot].hash == hash then
                    modem.transmit(senderChannel, HOST_CHANNEL, { type = "login_result", ok = false, reason = "That account is already seated at this table." })
                else
                    local record = loadOrCreate(hash)
                    players[slot].number = message.accountNumber
                    players[slot].hash = hash
                    players[slot].balance = record.balance or 0
                    modem.transmit(senderChannel, HOST_CHANNEL, { type = "login_result", ok = true, balance = players[slot].balance })
                    if bothLoggedIn() then
                        clampWager()
                        send(1, { type = "ready_for_bet", slot = 1, wager = wager, isSetter = true })
                        send(2, { type = "ready_for_bet", slot = 2, wager = wager, isSetter = false })
                        print("Both players logged in. Betting phase.")
                    end
                end
            end

        elseif mtype == "set_wager" then
            local slot = slotOf(senderChannel)
            if slot == 1 and bothLoggedIn() and not dealt then
                wager = message.amount or wager
                clampWager()
                send(1, { type = "wager_update", wager = wager })
                send(2, { type = "wager_update", wager = wager })
            end

        elseif mtype == "ready" then
            local slot = slotOf(senderChannel)
            if slot and bothLoggedIn() then
                players[slot].ready = true
                if players[1].ready and players[2].ready and wager > 0 then
                    dealRound()
                    print("Dealt a new round. Wager: $" .. wager)
                end
            end

        elseif mtype == "hit" then
            local slot = slotOf(senderChannel)
            if slot and dealt and turn == slot and not players[slot].done then
                table.insert(players[slot].hand, draw1(deck))
                local v = handValue(players[slot].hand)
                if v >= 21 then
                    send(slot, { type = "hand_update", hand = players[slot].hand })
                    advanceTurn(slot)
                else
                    send(slot, { type = "hand_update", hand = players[slot].hand })
                    local otherSlot = (slot == 1) and 2 or 1
                    send(otherSlot, { type = "opp_hand_count", count = #players[slot].hand })
                end
            end

        elseif mtype == "stand" then
            local slot = slotOf(senderChannel)
            if slot and dealt and turn == slot and not players[slot].done then
                advanceTurn(slot)
            end

        elseif mtype == "double" then
            local slot = slotOf(senderChannel)
            if slot and dealt and turn == slot and not players[slot].done and #players[slot].hand == 2 and players[slot].balance >= wager then
                table.insert(players[slot].hand, draw1(deck))
                send(slot, { type = "hand_update", hand = players[slot].hand })
                advanceTurn(slot)
            end

        elseif mtype == "leave" then
            local slot = slotOf(senderChannel)
            if slot then
                resetForNewJoin(slot)
                local otherSlot = (slot == 1) and 2 or 1
                send(otherSlot, { type = "opponent_left" })
                dealt = false
                print("Player " .. slot .. " left the table.")
            end
        end
    end
end
