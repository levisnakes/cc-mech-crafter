# CC Mech Crafter

ComputerCraft program that runs a 5x5 grid of Create mechanical crafters. When a Factory Controller gauge for one of your recipes drops below its target, it:

1. orders the ingredients through a Stock Ticker,
2. fills each crafter in the recipe's pattern,
3. pulses the crafters to start the craft,
4. waits for the crafters to finish before starting the next one.

The crafted item goes wherever your build sends it from the output crafter.

Gauge data comes from the [Factory Monitor](https://github.com/levisnakes/cc-factory-monitor) computer over rednet.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-mech-crafter/main/mech_crafter.lua startup.lua
```

## Build

- **Crafters:** a 5x5 wall of mechanical crafters with every input connected using the wrench, so they share one inventory. The arrows must lead to one output crafter.
- **Computer:** one face of a crafter touches the computer's back (`PULSE_SIDE`).
- **Input chest:** the station's packager unpacks ingredient packages into it. Packages arrive at the station address (`STATION_ADDRESS`, default `MechCrafter`) through a frogport or postbox that feeds that packager.
- **Output:** the output crafter sends its item into your network however you like (belt, funnel, packager). The gauge has to see it arrive.
- **Wired modems** on the input chest, one crafter, the Stock Ticker and the packager, all on one cable with the computer.
- The input chest must **not** have a Stock Link.
- `STORAGE` is optional: set it to an inventory on the cable to get a button that sends unordered items out of the input chest.

## Gauges

On the Factory Controller, add a gauge for each crafted item and set its target. Leave its ingredients unlinked; this computer orders them. A gauge that has ingredients linked orders on its own and would double up.

## First run

1. **Setup** tab: check every block is found, then press **Calibrate**. Put any item in the input chest; the computer places it in each crafter in turn and you click where it appeared. **Use reading order** is a shortcut if your slots already follow the grid left-to-right, top-to-bottom.
2. **Recipes** tab: **New**. Put one of each ingredient in the input chest; they appear on the left. Pick an item, click grid cells to place it, set the name and the output item, then **Save**.
3. Take the ingredients you used for the editor back out of the input chest (or press **Return them** if `STORAGE` is set).

**Craft +1** and **+8** queue crafts by hand, whatever the gauge says.

If a craft doesn't start (most often because the base was unloaded mid-craft), it pulses again, up to `RETRY_PULSES` (3) more times, `RETRY_SECONDS` (20) apart; the same goes for crafters that stay busy. After a restart with ingredients still in the crafters, it resumes by pulsing instead of starting over. Only if every retry fails does the recipe pause, with the ingredients back in the input chest and a **Resume** button on the Status tab.

## Stuck alerts

Set `DISCORD_WEBHOOK` (and `DISCORD_MENTION`, e.g. `"<@&ROLE_ID>"`) at the top of the file to get a Discord ping only when something is really stuck, with what to restart or fix. Each problem is posted once, and a follow-up without a ping says when it's fixed.

- a recipe paused after all retries (reload the base / check rotation / press Resume)
- crafters, Stock Ticker or input chest missing for 2+ minutes (restart the crafting computer, check modems)
- no gauge data from the Factory Monitor for 2+ minutes (restart the Factory Monitor computer)
- 2 ingredient orders in a row never arrived (check the station frogport/packager)
- repeated program errors (restart the crafting computer)

## config.lua

Anything in `/config.lua` on the computer overrides the settings at the top of the program, and survives reinstalls and updates. One file can be shared by every computer; each program ignores settings it doesn't use. Example:

```lua
DISCORD_WEBHOOK = "https://discord.com/api/webhooks/..."
DISCORD_MENTION = "<@&ROLE_ID>"
ALLOWED = { "YourName", "Friend" }
INPUT_CHEST = "minecraft:chest_3"
```
