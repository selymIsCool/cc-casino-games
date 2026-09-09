-- blackjack_h2h_station.lua
-- Run this on EACH player's own computer + monitor. Identical script for
-- both players -- which seat you get is assigned automatically by the
-- host (first to connect is Player 1, second is Player 2).
--
-- Your own hand is always shown in full. The opponent's hand is shown only
-- as face-down card backs (a count, not the actual cards) until showdown,
-- since this is a separate physical screen the other player can't see.
--
-- Needs: this computer's own wireless modem, and blackjack_h2h_host.lua
-- running somewhere reachable.
--
-- NOTE ON TRANSPORT: this uses RAW MODEM CHANNELS, not rednet -- see the
-- notes at the top of blackjack_h2h_host.lua for why. This station picks
-- its own random channel to listen on, and includes it as the "reply
-- channel" whenever it messages the host, so the host knows where to send
-- replies without needing rednet's ID-based addressing.

local HOST_CHANNEL = 42000 -- must match HOST_CHANNEL in blackjack_h2h_host.lua

local mon = peripheral.find("monitor")
if not mon then
    error("No monitor found. Attach a monitor to this computer.")
end
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then
    error("Attach a wireless modem to this computer.")
end
math.randomseed(os.epoch and os.epoch("utc") or os.time())
local MY_CHANNEL = math.random(42001, 64000)
modem.open(MY_CHANNEL)

local NEEDED_W, NEEDED_H = 55, 29
local function fitScale()
    local chosenW, chosenH = 0, 0
    for _, s in ipairs({ 5, 4, 3, 2.5, 2, 1.5, 1, 0.5 }) do
        local ok = pcall(function() mon.setTextScale(s) end)
        if ok then
            local w, h = mon.getSize()
            chosenW, chosenH = w, h
            if w >= NEEDED_W and h >= NEEDED_H then return w, h end
        end
    end
    return chosenW, chosenH
end

local W, H = fitScale()
local OFFSET_X = math.max(0, math.floor((W - NEEDED_W) / 2))
local OFFSET_Y = math.max(0, math.floor((H - NEEDED_H) / 2))
local function bottomY(tier) return math.max(1, H - tier) end
local function moveTo(x, y) mon.setCursorPos(x + OFFSET_X, y + OFFSET_Y) end
local function moveToAbs(x, y) mon.setCursorPos(x + OFFSET_X, y) end

local FELT = colors.green
local buttons = {}
local SUIT_GLYPH = { H = "\3", D = "\4", C = "\5", S = "\6" }

math.randomseed(os.epoch and os.epoch("utc") or os.time())

local function setColor(c) mon.setTextColor(c) end

local function drawCardFace(x, y, card)
    local glyph = SUIT_GLYPH[card.suit] or card.suit
    local red = (card.suit == "H" or card.suit == "D")
    local colour = red and colors.red or colors.black
    mon.setBackgroundColor(colors.white)
    for row = 0, 6 do
        moveTo(x, y + row)
        mon.write(string.rep(" ", 7))
    end
    setColor(colour)
    moveTo(x + 1, y + 1)
    mon.write(card.rank)
    moveTo(x + 1, y + 3)
    mon.write(glyph)
    if card.rank == "10" then
        moveTo(x, y + 5)
    else
        moveTo(x + 1, y + 5)
    end
    mon.write(card.rank)
    mon.setBackgroundColor(FELT)
    setColor(colors.black)
end

local function drawCardBack(x, y)
    mon.setBackgroundColor(colors.black)
    for row = 0, 6 do
        moveTo(x, y + row)
        setColor(colors.red)
        if row == 0 or row == 6 then
            mon.write("+-----+")
        else
            mon.write("|" .. string.rep("\4", 5) .. "|")
        end
    end
    mon.setBackgroundColor(FELT)
    setColor(colors.black)
end

local function drawHandFaces(hand, x, y)
    for i, card in ipairs(hand) do
        drawCardFace(x + (i - 1) * 8, y, card)
    end
end

local function drawHandBacks(count, x, y)
    for i = 1, count do
        drawCardBack(x + (i - 1) * 8, y)
    end
end

local function drawTitleBanner(titleText)
    local title = titleText or "HEAD TO HEAD"
    local w = NEEDED_W - 2
    setColor(colors.black)
    moveTo(2, 1)
    mon.write("+" .. string.rep("=", w) .. "+")
    moveTo(2, 2)
    local pad = math.floor((w - (#title + 4)) / 2)
    mon.write("|" .. string.rep(" ", pad) .. "\6 ")
    setColor(colors.red)
    mon.write(title)
    setColor(colors.black)
    mon.write(" \3" .. string.rep(" ", w - pad - (#title + 4)) .. "|")
    moveTo(2, 3)
    mon.write("+" .. string.rep("=", w) .. "+")
    setColor(colors.black)
end

local function drawTierButton(label, x, w, action, bg, tier)
    local y = bottomY(tier or 1)
    moveToAbs(x, y)
    mon.setBackgroundColor(bg or colors.black)
    setColor(colors.white)
    mon.write("[" .. string.format("%-" .. (w - 2) .. "s", label) .. "]")
    mon.setBackgroundColor(FELT)
    table.insert(buttons, { x1 = x + OFFSET_X, y1 = y, x2 = x + w - 1 + OFFSET_X, y2 = y, action = action })
end

local function drawBigKey(label, x, y, action, bg)
    setColor(colors.black)
    moveTo(x, y)
    mon.write("+-----+")
    moveTo(x, y + 1)
    mon.setBackgroundColor(bg or colors.white)
    setColor(colors.black)
    mon.write("|  " .. label .. "  |")
    mon.setBackgroundColor(FELT)
    setColor(colors.black)
    moveTo(x, y + 2)
    mon.write("+-----+")
    table.insert(buttons, {
        x1 = x + OFFSET_X, y1 = y + OFFSET_Y,
        x2 = x + 6 + OFFSET_X, y2 = y + 2 + OFFSET_Y,
        action = action,
    })
end

-- ===== Connection state =====

local mySlot = nil
local idEntry, idMessage = "", nil
local myBalance = 0
local myNumber = nil
local isSetter = false
local wager = 0
local myHand, oppCount = {}, 0
local myTurn = false
local resultInfo = nil -- { yourHand, oppHand, message, yourBalance }

local phase = "connecting" -- connecting, login, waiting_login, betting, play, result

local function idDisplay()
    local parts = {}
    for i = 1, 6 do parts[i] = (i <= #idEntry) and idEntry:sub(i, i) or "_" end
    return table.concat(parts, " ")
end

local function render()
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}

    if phase == "connecting" then
        drawTitleBanner()
        setColor(colors.black)
        moveTo(4, 5)
        mon.write("Looking for the table host...")
        return
    end

    if phase == "login" then
        drawTitleBanner()
        setColor(colors.black)
        moveTo(4, 5)
        mon.write("Seat " .. mySlot .. ": enter your 6-digit account number:")
        setColor(colors.red)
        moveTo(4, 6)
        mon.write(idDisplay())
        setColor(colors.black)
        if idMessage then
            moveTo(4, 7)
            mon.write(idMessage)
        end

        local KEY_W, GAP = 7, 1
        local gridW = 3 * KEY_W + 2 * GAP
        local startX = math.floor((NEEDED_W - gridW) / 2) + 1
        local colX = { startX, startX + KEY_W + GAP, startX + 2 * (KEY_W + GAP) }
        local rowY = { 9, 13, 17, 21 }
        local digits = { "1","2","3","4","5","6","7","8","9" }
        for i, digit in ipairs(digits) do
            local row = math.floor((i - 1) / 3) + 1
            local col = ((i - 1) % 3) + 1
            drawBigKey(digit, colX[col], rowY[row], "digit" .. digit)
        end
        drawBigKey("0", colX[2], rowY[4], "digit0")
        drawTierButton("<- Backspace", 2, 14, "backspace", colors.black, 2)
        drawTierButton("Random ID", 17, 12, "random", colors.black, 2)
        drawTierButton("Log In (Enter)", 30, 17, "login", colors.red, 2)
        return
    end

    if phase == "waiting_login" then
        drawTitleBanner()
        setColor(colors.black)
        moveTo(4, 5)
        mon.write("Logged in as #" .. myNumber .. "  Balance: $" .. myBalance)
        moveTo(4, 7)
        mon.write("Waiting for the other player to log in...")
        return
    end

    if phase == "betting" then
        drawTitleBanner()
        setColor(colors.black)
        moveTo(4, 5)
        mon.write("Seat " .. mySlot .. " -- #" .. myNumber .. "   Balance: $" .. myBalance)
        setColor(colors.red)
        moveTo(4, 7)
        mon.write("Wager (each stakes this much): $" .. wager)
        setColor(colors.black)
        if isSetter then
            moveTo(4, 9)
            mon.write("You set the wager for this round.")
            drawTierButton("-100k", 2, 8, "dec100k", colors.black, 2)
            drawTierButton("-10k", 11, 7, "dec10k", colors.black, 2)
            drawTierButton("+10k", 19, 7, "inc10k", colors.red, 2)
            drawTierButton("+100k", 27, 8, "inc100k", colors.red, 2)
            drawTierButton("-500", 2, 8, "dec500", colors.black)
            drawTierButton("-50", 11, 7, "dec50", colors.black)
            drawTierButton("+50", 19, 7, "inc50", colors.red)
            drawTierButton("+500", 27, 8, "inc500", colors.red)
        else
            moveTo(4, 9)
            mon.write("Waiting on the other player to set the wager.")
        end
        drawTierButton("Ready to Deal", 37, 16, "ready", colors.red, 1)
        return
    end

    if phase == "play" then
        drawTitleBanner()
        setColor(colors.black)
        moveTo(2, 5)
        mon.write("Your hand:")
        drawHandFaces(myHand, 2, 6)

        moveTo(2, 13)
        mon.write("Opponent's hand (hidden):")
        drawHandBacks(oppCount, 2, 14)

        local function handValueLocal(hand)
            local sum, aces = 0, 0
            for _, c in ipairs(hand) do
                local v = (c.rank == "A") and 11 or (tonumber(c.rank) or 10)
                sum = sum + v
                if c.rank == "A" then aces = aces + 1 end
            end
            while sum > 21 and aces > 0 do sum = sum - 10; aces = aces - 1 end
            return sum
        end

        setColor(colors.black)
        moveTo(2, 21)
        mon.write("Your total: " .. handValueLocal(myHand))
        setColor(colors.red)
        moveTo(2, 22)
        mon.write("Wager: $" .. wager)
        setColor(colors.black)

        if myTurn then
            drawTierButton("Hit (H)", 2, 10, "hit", colors.black)
            drawTierButton("Stand (S)", 13, 12, "stand", colors.red)
            if #myHand == 2 and myBalance >= wager then
                drawTierButton("Double (D)", 26, 13, "double", colors.black)
            end
        else
            setColor(colors.red)
            moveTo(2, 24)
            mon.write("Waiting for the opponent's turn...")
            setColor(colors.black)
        end
        return
    end

    if phase == "result" then
        drawTitleBanner()
        setColor(colors.black)
        moveTo(2, 5)
        mon.write("Your hand:")
        drawHandFaces(resultInfo.yourHand, 2, 6)
        moveTo(2, 13)
        mon.write("Opponent's hand (revealed):")
        drawHandFaces(resultInfo.oppHand, 2, 14)

        setColor(colors.red)
        moveTo(2, 22)
        mon.write(resultInfo.message)
        setColor(colors.black)
        moveTo(2, 23)
        mon.write("Your balance: $" .. resultInfo.yourBalance)

        drawTierButton("Next Round", 2, 14, "ready", colors.red)
        drawTierButton("Leave Table", 17, 14, "leave", colors.black, 2)
        return
    end
end

-- ===== Action handling =====

local function sendToHost(msg)
    modem.transmit(HOST_CHANNEL, MY_CHANNEL, msg)
end

local function handleAction(action)
    if phase == "login" then
        if action:sub(1, 5) == "digit" then
            if #idEntry < 6 then idEntry = idEntry .. action:sub(6) end
        elseif action == "backspace" then
            idEntry = idEntry:sub(1, -2)
        elseif action == "random" then
            idEntry = tostring(math.random(100000, 999999))
        elseif action == "login" then
            if #idEntry ~= 6 then
                idMessage = "Enter exactly 6 digits."
            else
                sendToHost({ type = "login", accountNumber = idEntry })
            end
        end

    elseif phase == "betting" then
        if isSetter and (action:match("^dec") or action:match("^inc")) then
            local delta = 0
            if action == "dec50" then delta = -50
            elseif action == "inc50" then delta = 50
            elseif action == "dec500" then delta = -500
            elseif action == "inc500" then delta = 500
            elseif action == "dec10k" then delta = -10000
            elseif action == "inc10k" then delta = 10000
            elseif action == "dec100k" then delta = -100000
            elseif action == "inc100k" then delta = 100000
            end
            sendToHost({ type = "set_wager", amount = wager + delta })
        elseif action == "ready" then
            sendToHost({ type = "ready" })
        end

    elseif phase == "play" then
        if myTurn then
            if action == "hit" then sendToHost({ type = "hit" })
            elseif action == "stand" then sendToHost({ type = "stand" })
            elseif action == "double" then sendToHost({ type = "double" })
            end
        end

    elseif phase == "result" then
        if action == "ready" then
            sendToHost({ type = "ready" })
            phase = "betting"
        elseif action == "leave" then
            sendToHost({ type = "leave" })
            phase = "login"
            idEntry, idMessage = "", nil
        end
    end
end

local function actionFromTouch(x, y)
    for _, b in ipairs(buttons) do
        if y >= b.y1 and y <= b.y2 and x >= b.x1 and x <= b.x2 then return b.action end
    end
    return nil
end

local function handleHostMessage(message)
    local mtype = message.type
    if mtype == "join_ack" then
        mySlot = message.slot
        phase = "login"
    elseif mtype == "join_reject" then
        phase = "connecting"
        idMessage = message.reason
    elseif mtype == "login_result" then
        if message.ok then
            myNumber = idEntry
            myBalance = message.balance
            idEntry, idMessage = "", nil
            phase = "waiting_login"
        else
            idMessage = message.reason or "Login failed."
        end
    elseif mtype == "ready_for_bet" then
        wager = message.wager
        isSetter = message.isSetter
        phase = "betting"
    elseif mtype == "wager_update" then
        wager = message.wager
    elseif mtype == "deal" then
        myHand = message.hand
        oppCount = message.oppCount
        wager = message.wager
        myTurn = message.yourTurn
        phase = "play"
    elseif mtype == "hand_update" then
        myHand = message.hand
    elseif mtype == "opp_hand_count" then
        oppCount = message.count
    elseif mtype == "your_turn" then
        myTurn = true
        oppCount = message.oppCount
    elseif mtype == "waiting" then
        myTurn = false
    elseif mtype == "result" then
        resultInfo = message
        phase = "result"
    elseif mtype == "opponent_left" then
        phase = "connecting"
        idEntry, idMessage = "", "The other player left the table."
    end
end

-- ===== Connect to host =====

local function connect()
    sendToHost({ type = "join" })
end

connect()
render()
local joinRetryTimer = os.startTimer(3)

local DIGIT_KEYS = {
    [keys.zero] = "0", [keys.one] = "1", [keys.two] = "2", [keys.three] = "3",
    [keys.four] = "4", [keys.five] = "5", [keys.six] = "6", [keys.seven] = "7",
    [keys.eight] = "8", [keys.nine] = "9",
}
if keys.numPad0 then
    for i = 0, 9 do DIGIT_KEYS[keys["numPad" .. i]] = tostring(i) end
end

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()

    if event == "modem_message" then
        -- (event, side, channel, replyChannel, message, distance)
        if p2 == MY_CHANNEL and type(p4) == "table" then
            handleHostMessage(p4)
            render()
        end
    elseif event == "timer" and p1 == joinRetryTimer then
        if phase == "connecting" then
            connect() -- host might not have been up yet; try again
        end
        joinRetryTimer = os.startTimer(3)
    elseif event == "monitor_touch" then
        local action = actionFromTouch(p2, p3)
        if action then
            handleAction(action)
            render()
        end
    elseif event == "key" then
        local action = nil
        if phase == "login" then
            if DIGIT_KEYS[p1] then action = "digit" .. DIGIT_KEYS[p1]
            elseif p1 == keys.backspace then action = "backspace"
            elseif p1 == keys.enter then action = "login"
            end
        elseif phase == "play" and myTurn then
            if p1 == keys.h then action = "hit"
            elseif p1 == keys.s then action = "stand"
            elseif p1 == keys.d then action = "double"
            end
        end
        if action then
            handleAction(action)
            render()
        end
    end
end
