# CC Casino Games

A series of casino games built for [ComputerCraft](https://computercraft.cc) (CC) — the Minecraft mod that adds programmable computers and turtles to the game.

## Games

### Blackjack (Solo)
Single-player blackjack against the dealer. Runs on one computer with an attached monitor. Features card graphics using CC's built-in suit glyphs, red/black casino theme on green felt, and full betting.

### Blackjack (Head-to-Head)
Two-player blackjack over wireless modem. A headless host computer coordinates the game while each player uses their own station computer + monitor. Hands are kept hidden until showdown — each station only receives its own cards.

- **`blackjack_h2h_host.lua`** — Run on the host computer (no monitor needed, just a wireless modem).
- **`blackjack_h2h_station.lua`** — Run on each player's computer (with a monitor attached).

### Roulette (Solo)
European roulette (single zero, 37 pockets) with an animated spin that decelerates to a stop. Runs on one computer with an attached monitor. Shares the same account system as blackjack, so balances carry over between games.

## Banking System

All games use a shared, gold-backed banking system. Players are identified by a 6-digit account code. Deposits and withdrawals are handled by dedicated turtles that move physical gold items in and out of storage.

| Script | Purpose |
|--------|---------|
| `deposit_turtle_seat1.lua` | Deposit turtle for seat 1 |
| `deposit_turtle_seat2.lua` | Deposit turtle for seat 2 |
| `deposit_turtle_Roulette.lua` | Deposit turtle for the roulette table |
| `withdraw_turtle_seat1.lua` | Withdraw turtle for seat 1 |
| `withdraw_turtle_seat2.lua` | Withdraw turtle for seat 2 |
| `withdraw_turtle_BlackJack (1).lua` | Withdraw turtle for blackjack table 1 |
| `withdraw_turtle_BlackJack (2).lua` | Withdraw turtle for blackjack table 2 |
| `withdraw_turtle_Roulette.lua` | Withdraw turtle for the roulette table |

## Setup

1. Place a ComputerCraft computer with a monitor attached.
2. Copy the relevant game script onto the computer.
3. Set up deposit and withdraw turtles as needed for your table layout.
4. For head-to-head blackjack, run the host script first, then each station script.

All communication uses raw modem channels (not rednet) to avoid the channel limit bug with high computer IDs.
