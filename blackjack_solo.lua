-- Blackjack: single player vs the dealer, on one computer + one monitor.
-- Red/black casino theme on green felt, card graphics, accounts identified
-- by a 6-digit code (no password for now), GOLD-BACKED BANKING over
-- raw wireless modem channels with separate deposit/withdraw turtles, betting, nav
-- pinned to the bottom.
-- Uses CC's built-in font suit glyphs: \3 heart, \4 diamond, \5 club, \6 spade

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
            if w >= NEEDED_W and h >= NEEDED_H then
                return w, h
            end
        end
    end
    return chosenW, chosenH
end

local W, H = fitScale()
local OFFSET_X = math.max(0, math.floor((W - NEEDED_W) / 2))
local OFFSET_Y = math.max(0, math.floor((H - NEEDED_H) / 2))

local function bottomY(tier)
    return math.max(1, H - tier)
end

local function moveTo(x, y)
    mon.setCursorPos(x + OFFSET_X, y + OFFSET_Y)
end

local function moveToAbs(x, y)
    mon.setCursorPos(x + OFFSET_X, y)
end

local FELT = colors.green
local buttons = {}

math.randomseed(os.epoch and os.epoch("utc") or os.time())

-- ===== Bank: wireless comms with the deposit/withdraw turtles =====
--
-- Uses RAW MODEM CHANNELS, not rednet. rednet.open() always tries to open
-- a channel equal to the device's own computer ID -- but CC:Tweaked
-- channels only go up to 65535, and on a world/server that's had enough
-- computers ever crafted, IDs climb past that and rednet becomes
-- permanently unusable on that device ("Expected number in range
-- 0-65535"). Picking our own fixed channel numbers below sidesteps that
-- entirely, since they have nothing to do with any computer's ID.
--
-- These three channel numbers must match EXACTLY in this file,
-- deposit_turtle.lua, and withdraw_turtle.lua.

local CHANNEL_MAIN = 41000     -- this computer listens here
local CHANNEL_DEPOSIT = 41001  -- the deposit turtle listens here
local CHANNEL_WITHDRAW = 41002 -- the withdraw turtle listens here
local GOLD_VALUE = 1000 -- $ credited per gold ingot

-- SECURITY: raw modem channels have no built-in authentication -- any
-- wireless modem in range can transmit or listen on any channel, and the
-- reply-channel a message claims is just data, not verified by the
-- network. This shared secret must be set to the SAME value in this file,
-- deposit_turtle.lua, and withdraw_turtle.lua. Every money-affecting
-- message is signed with it (see mac() below), so a device that doesn't
-- know the secret can't forge deposits, falsify withdrawal results, or
-- drain the withdraw turtle's stock directly. CHANGE THIS to your own
-- private value before using this for anything you care about -- anyone
-- who can read these script files (e.g. by breaking into a turtle) can
-- read the secret too, so also keep
-- the turtles somewhere players can't access or pull the disk from.
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

-- Small rolling set of recently-seen nonces, so a captured message can't be
-- replayed later to double-credit a deposit or re-fake a withdraw result.
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

-- ===== Accounts (6-digit code only, no password for now) =====
--
-- The 6-digit number is the whole account ID. Only a fast hash of it is
-- used as the save file's name, so someone browsing the accounts folder
-- can't casually tell which file belongs to which account number. This is
-- NOT real security (see the earlier password-based version if that's
-- needed later) -- it just keeps filenames from being a direct giveaway.
--
-- Accounts start at $0 -- the only way to fund one is to physically
-- deposit gold ingots, so in-game money is backed by real items.

local ACCOUNTS_DIR = "accounts"
if not fs.exists(ACCOUNTS_DIR) then
    fs.makeDir(ACCOUNTS_DIR)
end

local function hashAccountId(numStr)
    return mix("BJ-ID-SALT-9k2::" .. numStr .. "::BJ-ID-SALT-9k2")
end

local function accountPath(idHash)
    return fs.combine(ACCOUNTS_DIR, idHash .. ".acc")
end

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

local currentAccountNumber = nil
local currentIdHash = nil
local balance = 0
local bet = 100
local MIN_BET = 10
local SMALL_STEP = 50
local BIG_STEP = 500
local HUGE_STEP = 10000
local MASSIVE_STEP = 100000
local wins, losses, pushes = 0, 0, 0

local function clampBet()
    if balance <= 0 then bet = 0; return end
    if bet < MIN_BET then bet = MIN_BET end
    if bet > balance then bet = balance end
end

local function persist()
    if not currentIdHash then return end
    local record = readAccount(currentIdHash) or {}
    record.balance = balance
    writeAccount(currentIdHash, record)
end

local function loggedIn()
    return currentIdHash ~= nil
end

-- ===== Deck =====

local RANKS = { "2","3","4","5","6","7","8","9","10","J","Q","K","A" }
local SUITS = { "\3", "\4", "\5", "\6" }

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

-- ===== Drawing helpers =====

local function setColor(c) mon.setTextColor(c) end

local function drawCard(x, y, card, hidden)
    if hidden then
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
        return
    end

    local red = (card.suit == "\3" or card.suit == "\4")
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
    mon.write(card.suit)
    if card.rank == "10" then
        moveTo(x, y + 5)
    else
        moveTo(x + 1, y + 5)
    end
    mon.write(card.rank)

    mon.setBackgroundColor(FELT)
    setColor(colors.black)
end

local function drawHand(hand, x, y, hideFirst)
    for i, card in ipairs(hand) do
        drawCard(x + (i - 1) * 8, y, card, hideFirst and i == 1)
    end
end

local function drawTitleBanner()
    local title = "BLACKJACK"
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
    table.insert(buttons, {
        x1 = x + OFFSET_X, y1 = y,
        x2 = x + w - 1 + OFFSET_X, y2 = y,
        action = action,
    })
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

-- ===== Login: step 1, account number =====

local idEntry = ""
local idMessage = nil

local function idDisplay()
    local parts = {}
    for i = 1, 6 do
        parts[i] = (i <= #idEntry) and idEntry:sub(i, i) or "_"
    end
    return table.concat(parts, " ")
end

local function renderId()
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
    drawTierButton("Log In (Enter)", 30, 17, "next", colors.red, 2)
end

-- ===== Betting screen =====

local function renderBet()
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()

    setColor(colors.black)
    moveTo(4, 5)
    mon.write("Account: " .. currentAccountNumber)

    setColor(colors.black)
    moveTo(4, 7)
    mon.write("Balance: $" .. balance)
    setColor(colors.red)
    moveTo(4, 8)
    mon.write("Bet:     $" .. bet)
    setColor(colors.black)

    moveTo(4, 10)
    mon.write("W:" .. wins .. "  L:" .. losses .. "  P:" .. pushes)

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
        moveTo(4, 15)
        mon.write("You have no funds. Deposit gold to play.")
        setColor(colors.black)
        drawTierButton("Log Out", 2, 10, "logout", colors.black, 3)
        return
    end

    drawTierButton("-100k", 2, 8, "dec100k", colors.black, 2)
    drawTierButton("-10k", 11, 7, "dec10k", colors.black, 2)
    drawTierButton("+10k", 19, 7, "inc10k", colors.red, 2)
    drawTierButton("+100k", 27, 8, "inc100k", colors.red, 2)

    drawTierButton("-500", 2, 8, "dec500", colors.black)
    drawTierButton("-50", 11, 7, "dec50", colors.black)
    drawTierButton("+50", 19, 7, "inc50", colors.red)
    drawTierButton("+500", 27, 8, "inc500", colors.red)
    drawTierButton("Deal (Enter)", 37, 16, "deal", colors.red)
    drawTierButton("Log Out", 2, 10, "logout", colors.black, 3)
    if BANK_ENABLED then
        drawTierButton("Withdraw Gold", 13, 15, "withdraw", colors.black, 3)
    end
end

-- ===== Withdraw screen =====

local withdrawIngots = 0

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

-- ===== Game logic =====

local function newGame()
    local deck = newDeck()
    return {
        deck = deck,
        player = { draw1(deck), draw1(deck) },
        dealer = { draw1(deck), draw1(deck) },
        revealDealer = false,
        canAct = true,
        message = nil,
        wager = bet,
    }
end

local function startingChecks(state)
    local pv = handValue(state.player)
    if pv == 21 then
        state.revealDealer = true
        state.canAct = false
        local dv = handValue(state.dealer)
        if dv == 21 then
            state.message = "Both Blackjack! Push."
            pushes = pushes + 1
        else
            local payout = math.floor(state.wager * 1.5)
            balance = balance + payout
            state.message = "Blackjack! You win $" .. payout .. "!"
            wins = wins + 1
        end
        persist()
    end
    return state
end

local function finishDealer(state)
    state.revealDealer = true
    while handValue(state.dealer) < 17 do
        table.insert(state.dealer, draw1(state.deck))
    end
    local pv, dv = handValue(state.player), handValue(state.dealer)
    if dv > 21 then
        balance = balance + state.wager
        state.message = "Dealer busts! You win $" .. state.wager .. "!"
        wins = wins + 1
    elseif dv > pv then
        balance = balance - state.wager
        state.message = "Dealer wins (" .. dv .. " vs " .. pv .. "). -$" .. state.wager
        losses = losses + 1
    elseif dv < pv then
        balance = balance + state.wager
        state.message = "You win! (" .. pv .. " vs " .. dv .. "). +$" .. state.wager
        wins = wins + 1
    else
        state.message = "Push (" .. pv .. " vs " .. dv .. "). Bet returned."
        pushes = pushes + 1
    end
    state.canAct = false
    persist()
end

local function renderPlay(state)
    mon.setBackgroundColor(FELT)
    mon.clear()
    buttons = {}
    drawTitleBanner()

    setColor(colors.black)
    moveTo(2, 5)
    mon.write("Dealer:")
    drawHand(state.dealer, 2, 6, not state.revealDealer)

    moveTo(2, 13)
    mon.write("You:")
    drawHand(state.player, 2, 14, false)

    setColor(colors.black)
    moveTo(2, 21)
    if state.revealDealer then
        mon.write("Dealer total: " .. handValue(state.dealer))
    else
        mon.write("Dealer total: ??")
    end
    moveTo(2, 22)
    mon.write("Your total:   " .. handValue(state.player))

    setColor(colors.black)
    moveTo(2, 23)
    mon.write("Balance: $" .. balance)
    setColor(colors.red)
    mon.write("   Wager: $" .. state.wager)
    setColor(colors.black)

    moveTo(2, 24)
    mon.write("W:" .. wins .. "  L:" .. losses .. "  P:" .. pushes)

    if state.message then
        setColor(colors.red)
        moveTo(2, 25)
        mon.write(state.message)
        setColor(colors.black)
    end

    if state.canAct then
        drawTierButton("Hit (H)", 2, 10, "hit", colors.black)
        drawTierButton("Stand (S)", 13, 12, "stand", colors.red)
        if #state.player == 2 and balance >= state.wager then
            drawTierButton("Double (D)", 26, 13, "double", colors.black)
        end
    end
    drawTierButton("Next Round (N)", 40, 17, "new", colors.red)
end

-- ===== Event dispatch =====

local phase = "id" -- "id", "bet", "withdraw", "play"
local game = nil

local function render()
    if phase == "id" then renderId()
    elseif phase == "bet" then renderBet()
    elseif phase == "withdraw" then renderWithdraw()
    else renderPlay(game) end
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
    wins, losses, pushes = 0, 0, 0
    bet = math.min(100, balance)
    clampBet()
    idEntry = ""
    idMessage = nil
    phase = "bet"
end

local function handleIdAction(action)
    if action:sub(1, 5) == "digit" then
        if #idEntry < 6 then idEntry = idEntry .. action:sub(6) end
    elseif action == "backspace" then
        idEntry = idEntry:sub(1, -2)
    elseif action == "random" then
        idEntry = tostring(math.random(100000, 999999))
    elseif action == "next" then
        doLogin()
    end
end

local function handleBetAction(action)
    if action == "logout" then
        persist()
        currentAccountNumber = nil
        currentIdHash = nil
        depositFlash = nil
        phase = "id"
        return
    end
    if action == "withdraw" then
        withdrawIngots = math.min(1, math.floor(balance / GOLD_VALUE))
        phase = "withdraw"
        return
    end
    if action == "dec50" then bet = bet - SMALL_STEP
    elseif action == "inc50" then bet = bet + SMALL_STEP
    elseif action == "dec500" then bet = bet - BIG_STEP
    elseif action == "inc500" then bet = bet + BIG_STEP
    elseif action == "dec10k" then bet = bet - HUGE_STEP
    elseif action == "inc10k" then bet = bet + HUGE_STEP
    elseif action == "dec100k" then bet = bet - MASSIVE_STEP
    elseif action == "inc100k" then bet = bet + MASSIVE_STEP
    elseif action == "deal" then
        clampBet()
        if bet > 0 then
            game = startingChecks(newGame())
            phase = "play"
        end
        return
    end
    clampBet()
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

local function handlePlayAction(action)
    if action == "new" then
        phase = "bet"
        return
    end
    if not game.canAct then return end

    if action == "hit" then
        table.insert(game.player, draw1(game.deck))
        local pv = handValue(game.player)
        if pv > 21 then
            game.revealDealer = true
            balance = balance - game.wager
            game.message = "Bust! You lose $" .. game.wager
            game.canAct = false
            losses = losses + 1
            persist()
        elseif pv == 21 then
            finishDealer(game)
        end
    elseif action == "stand" then
        finishDealer(game)
    elseif action == "double" then
        if #game.player == 2 and balance >= game.wager then
            game.wager = game.wager * 2
            table.insert(game.player, draw1(game.deck))
            local pv = handValue(game.player)
            if pv > 21 then
                game.revealDealer = true
                balance = balance - game.wager
                game.message = "Bust on double! You lose $" .. game.wager
                game.canAct = false
                losses = losses + 1
                persist()
            else
                finishDealer(game)
            end
        end
    end
end

local function actionFromTouch(x, y)
    for _, b in ipairs(buttons) do
        if y >= b.y1 and y <= b.y2 and x >= b.x1 and x <= b.x2 then return b.action end
    end
    return nil
end

-- ===== Bank message handling (works regardless of which screen is up) =====

local function handleBankMessage(replyChannel, message)
    if type(message) ~= "table" then return end

    if message.type == "deposit_check" then
        -- Low-stakes: doesn't need a MAC, since the deposit turtle itself
        -- authenticates the actual "deposit" message that follows.
        local allowed = loggedIn() and (phase == "bet" or phase == "play" or phase == "withdraw")
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

-- ===== Main loop =====

local DIGIT_KEYS = {
    [keys.zero] = "0", [keys.one] = "1", [keys.two] = "2", [keys.three] = "3",
    [keys.four] = "4", [keys.five] = "5", [keys.six] = "6", [keys.seven] = "7",
    [keys.eight] = "8", [keys.nine] = "9",
}
if keys.numPad0 then
    for i = 0, 9 do
        DIGIT_KEYS[keys["numPad" .. i]] = tostring(i)
    end
end

render()

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    local action = nil

    if event == "monitor_touch" then
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
        if phase == "id" then
            if DIGIT_KEYS[p1] then action = "digit" .. DIGIT_KEYS[p1]
            elseif p1 == keys.backspace then action = "backspace"
            elseif p1 == keys.enter then action = "next"
            end
        elseif phase == "bet" then
            if p1 == keys.minus then action = "dec50"
            elseif p1 == keys.equals then action = "inc50"
            elseif p1 == keys.leftBracket then action = "dec500"
            elseif p1 == keys.rightBracket then action = "inc500"
            elseif p1 == keys.enter then action = "deal"
            elseif p1 == keys.w then action = "withdraw"
            elseif p1 == keys.l then action = "logout"
            end
        elseif phase == "withdraw" then
            if p1 == keys.enter then action = "wd_confirm"
            elseif p1 == keys.backspace then action = "wd_cancel"
            end
        elseif phase == "play" then
            if p1 == keys.h then action = "hit"
            elseif p1 == keys.s then action = "stand"
            elseif p1 == keys.d then action = "double"
            elseif p1 == keys.n then action = "new"
            end
        end
    end

    if action then
        if phase == "id" then handleIdAction(action)
        elseif phase == "bet" then handleBetAction(action)
        elseif phase == "withdraw" then handleWithdrawAction(action)
        else handlePlayAction(action) end
        render()
    end
end
