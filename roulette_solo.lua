-- Roulette: single player, one computer + one monitor.
-- European wheel (single zero, 37 pockets), animated spin that decelerates
-- to a stop on the winning number. Same account system (6-digit code, no
-- password) and accounts/ folder as blackjack_solo.lua, so balances carry
-- over between games.
-- Red/black casino theme on green felt, auto text-scale fit + centering,
-- nav pinned to the bottom, same visual language as the blackjack games.

-- Work around CC's background rednet listener (started by rom/startup.lua)
-- crashing on computers whose ID is above 65535: on every modem_message it
-- calls modem.isOpen(os.getComputerID()), which throws
-- "Expected number in range 0-65535" and takes the whole computer down.
-- rednet.run looks up peripheral.call at call time, so wrapping it here
-- makes out-of-range isOpen queries return false instead of throwing.
-- This must run before the wireless modem is opened below.
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

local mon = peripheral.find("monitor")
if not mon then
    error("No monitor found. Attach a monitor to this computer.")
end

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

math.randomseed(os.epoch and os.epoch("utc") or os.time())

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

local currentAccountNumber, currentIdHash = nil, nil
local balance = 0

local function persist()
    if not currentIdHash then return end
    local record = readAccount(currentIdHash) or {}
    record.balance = balance
    writeAccount(currentIdHash, record)
end

-- ===== Roulette table data =====

-- Standard European single-zero wheel, in physical pocket order.
local WHEEL_ORDER = {
    0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,
    31,9,22,18,29,7,28,12,35,3,26,
}
local RED_NUMBERS = {}
for _, n in ipairs({ 1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36 }) do
    RED_NUMBERS[n] = true
end

local function colourOf(n)
    if n == 0 then return "green" end
    if RED_NUMBERS[n] then return "red" end
    return "black"
end

local BET_TYPES = {
    { id = "red", label = "Red", payout = 1 },
    { id = "black", label = "Black", payout = 1 },
    { id = "odd", label = "Odd", payout = 1 },
    { id = "even", label = "Even", payout = 1 },
    { id = "low", label = "1-18", payout = 1 },
    { id = "high", label = "19-36", payout = 1 },
    { id = "dozen1", label = "1st 12", payout = 2 },
    { id = "dozen2", label = "2nd 12", payout = 2 },
    { id = "dozen3", label = "3rd 12", payout = 2 },
    { id = "straight", label = "Straight #", payout = 35 },
}

local function betWins(betId, straightNumber, winNumber)
    if winNumber == 0 then
        return betId == "straight" and straightNumber == 0
    end
    if betId == "red" then return colourOf(winNumber) == "red"
    elseif betId == "black" then return colourOf(winNumber) == "black"
    elseif betId == "odd" then return winNumber % 2 == 1
    elseif betId == "even" then return winNumber % 2 == 0
    elseif betId == "low" then return winNumber >= 1 and winNumber <= 18
    elseif betId == "high" then return winNumber >= 19 and winNumber <= 36
    elseif betId == "dozen1" then return winNumber >= 1 and winNumber <= 12
    elseif betId == "dozen2" then return winNumber >= 13 and winNumber <= 24
    elseif betId == "dozen3" then return winNumber >= 25 and winNumber <= 36
    elseif betId == "straight" then return winNumber == straightNumber
    end
    return false
end

-- ===== State =====

local betAmount = 100
local MIN_BET = 10
local SMALL_STEP, BIG_STEP, HUGE_STEP, MASSIVE_STEP = 50, 500, 10000, 100000
local selectedBetIndex = 1
local straightNumber = 0
local lastResult = nil -- { number, colour, won, payout }
local spinning = false
local history = {} -- most recent winning numbers, newest first
local HISTORY_MAX = 12

local function clampBet()
    if balance <= 0 then betAmount = 0; return end
    if betAmount < MIN_BET then betAmount = MIN_BET end
    if betAmount > balance then betAmount = balance end
end

-- ===== Bank: wireless comms with the deposit/withdraw turtles =====
--
-- Uses RAW MODEM CHANNELS (not rednet -- see blackjack_solo.lua for why),
-- and the SAME channel numbers, so this shares the same physical
-- deposit/withdraw turtles as the blackjack game. These three numbers, and
-- SHARED_SECRET below, must match EXACTLY across blackjack_solo.lua,
-- roulette_solo.lua, deposit_turtle.lua, and withdraw_turtle.lua.

local CHANNEL_MAIN = 41000 -- this computer listens here
local CHANNEL_DEPOSIT = 41001 -- the deposit turtle listens here
local CHANNEL_WITHDRAW = 41002 -- the withdraw turtle listens here
local GOLD_VALUE = 1000 -- $ credited per gold ingot

-- SECURITY: see blackjack_solo.lua's notes on this -- same caveats apply.
-- CHANGE THIS to your own private value, matching the turtles exactly.
local SHARED_SECRET = "CHANGE-ME-TO-YOUR-OWN-SECRET-8f2q"

local function mac(parts)
    return mix(SHARED_SECRET .. "|" .. table.concat(parts, "|") .. "|" .. SHARED_SECRET)
end

local seenNonces = {}
local seenNonceOrder = {}
local function nonceIsFresh(nonce)
    if seenNonces[nonce] then return false end
    seenNonces[nonce] = true
    table.insert(seenNonceOrder, nonce)
    if #seenNonceOrder > 300 then
        local oldest = table.remove(seenNonceOrder, 1)
        seenNonces[oldest] = nil
    end
    return true
end

local bankModem = peripheral.find("modem", function(_, m) return m.isWireless() end)
local BANK_ENABLED = bankModem ~= nil
if BANK_ENABLED then
    bankModem.open(CHANNEL_MAIN)
end

local pendingWithdraw = nil -- { requestId, ingots, timeoutTimer }
local depositFlash = nil
local nextRequestId = 1
local withdrawIngots = 0

local function loggedIn() return currentIdHash ~= nil end

-- ===== Drawing helpers =====

local function setColor(c) mon.setTextColor(c) end

local function drawTitleBanner()
    local title = "ROULETTE"
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
    mon.write("| " .. label .. " |")
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

-- A single pocket cell used both by the spin animation and the result screen.
local function drawPocketCell(x, y, number, highlighted)
    local colour = colourOf(number)
    local bg = (colour == "red") and colors.red or (colour == "black") and colors.gray or colors.lime
    mon.setBackgroundColor(bg)
    for row = 0, 2 do
        moveTo(x, y + row)
        mon.write(string.rep(" ", 5))
    end
    setColor(colors.white)
    moveTo(x + 1, y + 1)
    mon.write(string.format("%-3s", tostring(number)))
    mon.setBackgroundColor(FELT)
    setColor(colors.black)
    if highlighted then
        setColor(colors.red)
        moveTo(x + 1, y - 1)
        mon.write("\30\30\30")
        setColor(colors.black)
    end
end

-- ===== Login =====

local idEntry, idMessage = "", nil

local function idDisplay()
    local parts = {}
    for i = 1, 6 do parts[i] = (i <= #idEntry) and idEntry:sub(i, i) or "_" end
    return table.concat(parts, " ")
end

local function renderLogin()
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()

    setColor(colors.black)
    moveTo(4, 5)
    mon.write("Enter your 6-digit account number:")
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
end

-- ===== Betting screen =====

local function renderBet()
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()

    setColor(colors.black)
    moveTo(4, 5)
    mon.write("Account: " .. currentAccountNumber .. "   Balance: $" .. balance)
    setColor(colors.red)
    moveTo(4, 6)
    mon.write("Bet: $" .. betAmount)
    setColor(colors.black)

    if #history > 0 then
        moveTo(4, 7)
        mon.write("Recent: ")
        for _, n in ipairs(history) do
            local c = colourOf(n)
            setColor(c == "red" and colors.red or c == "black" and colors.black or colors.lime)
            mon.write(tostring(n) .. " ")
        end
        setColor(colors.black)
    end

    setColor(BANK_ENABLED and colors.black or colors.red)
    moveTo(4, 12)
    if BANK_ENABLED then
        mon.write("Deposit gold ($" .. GOLD_VALUE .. "/ingot) at the deposit chest.")
    else
        mon.write("Bank offline: no wireless modem found on this computer.")
    end
    setColor(colors.black)

    if depositFlash then
        setColor(colors.red)
        moveTo(4, 13)
        mon.write(depositFlash)
        setColor(colors.black)
    end

    if balance <= 0 then
        setColor(colors.red)
        moveTo(4, 8)
        mon.write("You have no funds to bet.")
        setColor(colors.black)
        drawTierButton("Log Out", 2, 10, "logout", colors.black, 4)
        return
    end

    -- Bet type picker
    moveTo(4, 8)
    mon.write("Bet type:")
    local bt = BET_TYPES[selectedBetIndex]
    setColor(colors.red)
    moveTo(4, 9)
    mon.write(bt.label .. " (pays " .. bt.payout .. ":1)")
    setColor(colors.black)
    drawTierButton("< Type", 2, 10, "bettype_prev", colors.black, 3)
    drawTierButton("Type >", 13, 10, "bettype_next", colors.black, 3)

    if bt.id == "straight" then
        moveTo(4, 11)
        mon.write("Number: " .. straightNumber)
        drawTierButton("- Num", 25, 9, "num_dec", colors.black, 3)
        drawTierButton("+ Num", 35, 9, "num_inc", colors.red, 3)
    end

    -- Bet amount steppers
    drawTierButton("-100k", 2, 8, "dec100k", colors.black, 2)
    drawTierButton("-10k", 11, 7, "dec10k", colors.black, 2)
    drawTierButton("+10k", 19, 7, "inc10k", colors.red, 2)
    drawTierButton("+100k", 27, 8, "inc100k", colors.red, 2)

    drawTierButton("-500", 2, 8, "dec500", colors.black)
    drawTierButton("-50", 11, 7, "dec50", colors.black)
    drawTierButton("+50", 19, 7, "inc50", colors.red)
    drawTierButton("+500", 27, 8, "inc500", colors.red)
    drawTierButton("Spin! (Enter)", 37, 16, "spin", colors.red)

    drawTierButton("Log Out", 2, 10, "logout", colors.black, 4)
    if BANK_ENABLED then
        drawTierButton("Withdraw Gold", 13, 15, "withdraw", colors.black, 4)
    end
end

-- ===== Withdraw screen =====

local function renderWithdraw()
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()

    local maxIngots = math.floor(balance / GOLD_VALUE)

    setColor(colors.black)
    moveTo(4, 5)
    mon.write("Withdraw gold ingots")
    moveTo(4, 7)
    mon.write("Balance: $" .. balance)
    setColor(colors.red)
    moveTo(4, 8)
    mon.write("Withdrawing: " .. withdrawIngots .. " ingot(s) = $" .. (withdrawIngots * GOLD_VALUE))
    setColor(colors.black)
    moveTo(4, 9)
    mon.write("(Max available: " .. maxIngots .. " ingots)")

    if pendingWithdraw then
        setColor(colors.red)
        moveTo(4, 11)
        mon.write("Waiting for the withdraw turtle...")
        setColor(colors.black)
        return
    end

    drawBigKey("-1", 4, 13, "wd_dec1")
    drawBigKey("+1", 12, 13, "wd_inc1")
    drawBigKey("-5", 20, 13, "wd_dec5")
    drawBigKey("+5", 28, 13, "wd_inc5")

    drawTierButton("Cancel", 2, 10, "wd_cancel", colors.black, 2)
    drawTierButton("Confirm Withdrawal", 13, 22, "wd_confirm", colors.red, 2)
end

-- ===== Result screen =====

local function renderResult()
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()

    setColor(colors.black)
    moveTo(4, 6)
    mon.write("Winning number:")
    drawPocketCell(24, 8, lastResult.number, false)

    setColor(colors.black)
    moveTo(4, 13)
    mon.write("Colour: " .. lastResult.colour)

    setColor(lastResult.won and colors.red or colors.black)
    moveTo(4, 15)
    if lastResult.won then
        mon.write("You won $" .. lastResult.payout .. "!")
    else
        mon.write("No win this time. -$" .. lastResult.stake)
    end
    setColor(colors.black)
    moveTo(4, 16)
    mon.write("Balance: $" .. balance)

    drawTierButton("Spin Again", 2, 14, "again", colors.red)
    drawTierButton("Log Out", 17, 10, "logout", colors.black, 2)
end

-- ===== Spin animation =====
--
-- A wide strip of pockets scrolls past a fixed ball. The strip starts by
-- jumping several pockets per frame (CC can't draw faster than 20 fps, so
-- speed comes from bigger jumps, not shorter sleeps), drops to single
-- pockets, then eases out over the last stretch. The ball then hops one
-- pocket past the winner and settles back, and the winning pocket flashes.
-- Only the strip and ball are redrawn each frame -- the rest of the screen
-- is drawn once -- so there's no full-screen flicker.
-- If a speaker is attached, each pocket passing the ball clicks.

local STRIP_Y = 10
local CELL_W, CELL_GAP = 5, 1
local VISIBLE = 9 -- must be odd; the centre cell is under the ball
local STRIP_W = VISIBLE * CELL_W + (VISIBLE - 1) * CELL_GAP
local STRIP_X = math.floor((NEEDED_W - STRIP_W) / 2) + 1
local TICK = 0.05 -- CC's timer resolution; shorter sleeps round up to this anyway

local speaker = peripheral.find("speaker")
local function tickSound(pitch)
    if speaker then pcall(speaker.playSound, "block.note_block.hat", 0.4, pitch or 1.5) end
end

local function findIndex(n)
    for i, v in ipairs(WHEEL_ORDER) do
        if v == n then return i end
    end
    return 1
end

local function centreCellX()
    return STRIP_X + math.floor(VISIBLE / 2) * (CELL_W + CELL_GAP)
end

local function drawSpinStatic(stake, bt)
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()
    setColor(colors.black)
    moveTo(4, 5)
    local what = bt.label
    if bt.id == "straight" then what = "number " .. straightNumber end
    mon.write("$" .. stake .. " on " .. what)
    setColor(colors.red)
    moveTo(4, 6)
    mon.write("No more bets...")
    setColor(colors.black)
end

-- Draws the ball on the row above the strip, `cellOffset` pockets from centre.
local function drawBall(cellOffset)
    mon.setBackgroundColor(FELT)
    moveTo(STRIP_X, STRIP_Y - 1)
    mon.write(string.rep(" ", STRIP_W))
    setColor(colors.white)
    moveTo(centreCellX() + cellOffset * (CELL_W + CELL_GAP) + 2, STRIP_Y - 1)
    mon.write("\7")
    setColor(colors.black)
end

local function drawStripCells(centreIndex)
    local n = #WHEEL_ORDER
    for i = 1, VISIBLE do
        local offset = i - math.ceil(VISIBLE / 2)
        local idx = ((centreIndex - 1 + offset) % n) + 1
        drawPocketCell(STRIP_X + (i - 1) * (CELL_W + CELL_GAP), STRIP_Y, WHEEL_ORDER[idx], false)
    end
end

local function flashCentreCell(number, times)
    local x = centreCellX()
    for _ = 1, times do
        mon.setBackgroundColor(colors.white)
        for row = 0, 2 do
            moveTo(x, STRIP_Y + row)
            mon.write(string.rep(" ", CELL_W))
        end
        setColor(colors.black)
        moveTo(x + 1, STRIP_Y + 1)
        mon.write(string.format("%-3s", tostring(number)))
        mon.setBackgroundColor(FELT)
        sleep(0.2)
        drawPocketCell(x, STRIP_Y, number, false)
        sleep(0.2)
    end
end

-- Spins the wheel and returns the winning number once it has visually
-- landed. Blocks for the duration of the spin. Call drawSpinStatic() first.
local function spinWheel()
    local n = #WHEEL_ORDER
    local winningNumber = WHEEL_ORDER[math.random(1, n)]
    local targetIndex = findIndex(winningNumber)
    local startIndex = math.random(1, n)
    local laps = 3
    local SLOW_STEPS = 14 -- final single-pocket steps that ease out
    local total = laps * n + (targetIndex - startIndex) % n

    local pos = startIndex
    local function advance(k) pos = ((pos - 1 + k) % n) + 1 end

    drawBall(0)
    drawStripCells(pos)
    sleep(0.3)

    -- Fast phase: multi-pocket jumps, shrinking as it goes.
    local fastLeft = total - SLOW_STEPS
    while fastLeft > 0 do
        local step = (fastLeft > 24) and 3 or (fastLeft > 8) and 2 or 1
        advance(step)
        fastLeft = fastLeft - step
        drawStripCells(pos)
        tickSound(2)
        sleep(TICK)
    end

    -- Slow phase: one pocket per frame, delay growing quadratically.
    for i = 1, SLOW_STEPS do
        advance(1)
        drawStripCells(pos)
        local t = i / SLOW_STEPS
        tickSound(2 - t)
        sleep(TICK + 0.40 * t * t)
    end

    -- Ball bounce: hops one pocket past the winner, then settles back on it.
    sleep(0.15)
    drawBall(1)
    tickSound(1.2)
    sleep(0.2)
    drawBall(0)
    tickSound(0.8)
    sleep(0.3)

    local colour = colourOf(winningNumber)
    setColor(colour == "red" and colors.red or colour == "black" and colors.black or colors.lime)
    moveTo(4, STRIP_Y + 5)
    mon.write("Ball lands on " .. winningNumber .. " " .. string.upper(colour))
    setColor(colors.black)
    flashCentreCell(winningNumber, 3)
    sleep(0.6)

    return winningNumber
end

-- Discards any input events that queued up while the spin animation was
-- blocking (e.g. taps during the spin), so they don't fire unexpectedly
-- on whatever screen renders next.
local function flushPendingEvents()
    local marker = os.startTimer(0)
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "timer" and ev[2] == marker then break end
    end
end

-- ===== Event dispatch =====

local phase = "login" -- "login", "bet", "withdraw", "result"

local function render()
    if phase == "login" then renderLogin()
    elseif phase == "bet" then renderBet()
    elseif phase == "withdraw" then renderWithdraw()
    elseif phase == "result" then renderResult()
    end
end

local function doLogin()
    if #idEntry ~= 6 then
        idMessage = "Enter exactly 6 digits."
        return
    end
    currentAccountNumber = idEntry
    currentIdHash = hashAccountId(idEntry)
    local record = readAccount(currentIdHash)
    if not record then
        record = { balance = 0 }
        writeAccount(currentIdHash, record)
    end
    balance = record.balance or 0
    betAmount = math.min(100, balance)
    clampBet()
    idEntry, idMessage = "", nil
    phase = "bet"
end

local function handleLoginAction(action)
    if action:sub(1, 5) == "digit" then
        if #idEntry < 6 then idEntry = idEntry .. action:sub(6) end
    elseif action == "backspace" then
        idEntry = idEntry:sub(1, -2)
    elseif action == "random" then
        idEntry = tostring(math.random(100000, 999999))
    elseif action == "login" then
        doLogin()
    end
end

local function doSpin()
    if betAmount <= 0 or spinning then return end
    spinning = true
    local stake = betAmount
    local bt = BET_TYPES[selectedBetIndex]

    drawSpinStatic(stake, bt)
    local winningNumber = spinWheel()
    flushPendingEvents()
    table.insert(history, 1, winningNumber)
    if #history > HISTORY_MAX then table.remove(history) end
    local won = betWins(bt.id, straightNumber, winningNumber)

    if won then
        local payout = stake * bt.payout
        balance = balance + payout
        lastResult = { number = winningNumber, colour = colourOf(winningNumber), won = true, payout = payout, stake = stake }
    else
        balance = balance - stake
        lastResult = { number = winningNumber, colour = colourOf(winningNumber), won = false, payout = 0, stake = stake }
    end
    persist()
    clampBet()
    spinning = false
    phase = "result"
end

local function handleBetAction(action)
    if action == "logout" then
        currentAccountNumber, currentIdHash = nil, nil
        depositFlash = nil
        phase = "login"
        return
    end
    if action == "withdraw" then
        withdrawIngots = math.min(1, math.floor(balance / GOLD_VALUE))
        phase = "withdraw"
        return
    end
    if action == "bettype_prev" then
        selectedBetIndex = selectedBetIndex - 1
        if selectedBetIndex < 1 then selectedBetIndex = #BET_TYPES end
    elseif action == "bettype_next" then
        selectedBetIndex = selectedBetIndex + 1
        if selectedBetIndex > #BET_TYPES then selectedBetIndex = 1 end
    elseif action == "num_dec" then
        straightNumber = (straightNumber - 1) % 37
    elseif action == "num_inc" then
        straightNumber = (straightNumber + 1) % 37
    elseif action == "dec50" then betAmount = betAmount - SMALL_STEP
    elseif action == "inc50" then betAmount = betAmount + SMALL_STEP
    elseif action == "dec500" then betAmount = betAmount - BIG_STEP
    elseif action == "inc500" then betAmount = betAmount + BIG_STEP
    elseif action == "dec10k" then betAmount = betAmount - HUGE_STEP
    elseif action == "inc10k" then betAmount = betAmount + HUGE_STEP
    elseif action == "dec100k" then betAmount = betAmount - MASSIVE_STEP
    elseif action == "inc100k" then betAmount = betAmount + MASSIVE_STEP
    elseif action == "spin" then
        doSpin()
        render()
        return
    end
    clampBet()
end

local function handleResultAction(action)
    if action == "again" then
        phase = "bet"
    elseif action == "logout" then
        currentAccountNumber, currentIdHash = nil, nil
        phase = "login"
    end
end

local function handleWithdrawAction(action)
    local maxIngots = math.floor(balance / GOLD_VALUE)
    if action == "wd_cancel" then
        phase = "bet"
    elseif action == "wd_dec1" then
        withdrawIngots = math.max(0, withdrawIngots - 1)
    elseif action == "wd_inc1" then
        withdrawIngots = math.min(maxIngots, withdrawIngots + 1)
    elseif action == "wd_dec5" then
        withdrawIngots = math.max(0, withdrawIngots - 5)
    elseif action == "wd_inc5" then
        withdrawIngots = math.min(maxIngots, withdrawIngots + 5)
    elseif action == "wd_confirm" then
        if withdrawIngots <= 0 then return end
        if not BANK_ENABLED then return end
        local reqId = nextRequestId
        nextRequestId = nextRequestId + 1
        local msg = { type = "withdraw_request", ingots = withdrawIngots, requestId = reqId }
        msg.mac = mac({ "withdraw_request", tostring(msg.ingots), tostring(msg.requestId) })
        bankModem.transmit(CHANNEL_WITHDRAW, CHANNEL_MAIN, msg)
        pendingWithdraw = { requestId = reqId, ingots = withdrawIngots, timeoutTimer = os.startTimer(10) }
    end
end

-- ===== Bank message handling (works regardless of which screen is up) =====

local function handleBankMessage(replyChannel, message)
    if type(message) ~= "table" then return end

    if message.type == "deposit_check" then
        local allowed = loggedIn() and (phase == "bet" or phase == "withdraw" or phase == "result")
        bankModem.transmit(replyChannel, CHANNEL_MAIN, { type = "deposit_check_reply", allowed = allowed })

    elseif message.type == "deposit" then
        local expected = mac({ "deposit", tostring(message.ingots), tostring(message.nonce) })
        if message.mac ~= expected then
            print("Rejected deposit message: bad signature (forged or wrong secret).")
            return
        end
        if not nonceIsFresh(tostring(message.nonce)) then
            print("Rejected deposit message: replayed nonce.")
            return
        end
        if loggedIn() then
            local amount = (message.ingots or 0) * GOLD_VALUE
            balance = balance + amount
            persist()
            depositFlash = "Deposit received: +$" .. amount
            render()
        end

    elseif message.type == "withdraw_result" then
        if not (pendingWithdraw and message.requestId == pendingWithdraw.requestId) then return end
        local expected = mac({ "withdraw_result", tostring(message.requestId), tostring(message.moved), tostring(message.nonce) })
        if message.mac ~= expected then
            print("Rejected withdraw_result: bad signature (forged or wrong secret).")
            depositFlash = "Withdrawal response failed a security check -- balance unchanged."
            pendingWithdraw = nil
            phase = "bet"
            render()
            return
        end
        if not nonceIsFresh(tostring(message.nonce)) then
            print("Rejected withdraw_result: replayed nonce.")
            return
        end
        local moved = message.moved or 0
        balance = balance - moved * GOLD_VALUE
        persist()
        clampBet()
        if moved < pendingWithdraw.ingots then
            depositFlash = "Only " .. moved .. " of " .. pendingWithdraw.ingots ..
                " ingot(s) were in stock. Withdrew $" .. (moved * GOLD_VALUE) .. "."
        else
            depositFlash = "Withdrew " .. moved .. " ingot(s) = $" .. (moved * GOLD_VALUE)
        end
        pendingWithdraw = nil
        phase = "bet"
        render()
    end
end

local function actionFromTouch(x, y)
    for _, b in ipairs(buttons) do
        if y >= b.y1 and y <= b.y2 and x >= b.x1 and x <= b.x2 then return b.action end
    end
    return nil
end

-- ===== Main loop =====

local DIGIT_KEYS = {
    [keys.zero] = "0", [keys.one] = "1", [keys.two] = "2", [keys.three] = "3",
    [keys.four] = "4", [keys.five] = "5", [keys.six] = "6", [keys.seven] = "7",
    [keys.eight] = "8", [keys.nine] = "9",
}
if keys.numPad0 then
    for i = 0, 9 do DIGIT_KEYS[keys["numPad" .. i]] = tostring(i) end
end

render()

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    local action = nil

    if spinning then
        -- ignore input while the wheel is animating
    elseif event == "monitor_touch" then
        action = actionFromTouch(p2, p3)
    elseif event == "modem_message" then
        -- (event, side, channel, replyChannel, message, distance)
        if p2 == CHANNEL_MAIN then
            handleBankMessage(p3, p4)
        end
    elseif event == "timer" then
        if pendingWithdraw and p1 == pendingWithdraw.timeoutTimer then
            depositFlash = "No response from the withdraw turtle (timed out)."
            pendingWithdraw = nil
            phase = "bet"
            render()
        end
    elseif event == "key" then
        if phase == "login" then
            if DIGIT_KEYS[p1] then action = "digit" .. DIGIT_KEYS[p1]
            elseif p1 == keys.backspace then action = "backspace"
            elseif p1 == keys.enter then action = "login"
            end
        elseif phase == "bet" then
            if p1 == keys.enter then action = "spin" end
        elseif phase == "withdraw" then
            if p1 == keys.enter then action = "wd_confirm"
            elseif p1 == keys.backspace then action = "wd_cancel"
            end
        end
    end

    if action then
        if phase == "login" then handleLoginAction(action)
        elseif phase == "bet" then handleBetAction(action)
        elseif phase == "withdraw" then handleWithdrawAction(action)
        elseif phase == "result" then handleResultAction(action)
        end
        render()
    end
end
