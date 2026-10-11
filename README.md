# CC Mech Crafter

ComputerCraft program that runs a 5x5 grid of Create mechanical crafters. When a Factory Controller gauge for one of your recipes drops below its target, it:

1. orders the ingredients through a Stock Ticker,
2. fills each crafter in the recipe's pattern,
3. pulses the crafters to start the craft,
4. waits for the result and moves it into storage.

Gauge data comes from the [Factory Monitor](https://github.com/levisnakes/cc-factory-monitor) computer over rednet.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-mech-crafter/main/mech_crafter.lua startup.lua
```

## Build

- **Crafters:** a 5x5 wall of mechanical crafters with every input connected using the wrench, so they share one inventory. The arrows must lead to one output crafter.
- **Computer:** one face of a crafter touches the computer's back (`PULSE_SIDE`).
- **Input chest:** the station's packager unpacks ingredient packages into it. Packages arrive at the station address (`STATION_ADDRESS`, default `MechCrafter`) through a frogport or postbox that feeds that packager.
- **Output chest:** sits in front of the output crafter.
- **Storage:** an inventory that's part of your Create network (it has a Stock Link), so the gauge sees the finished items.
- **Wired modems** on the input chest, output chest, storage, one crafter, the Stock Ticker and the packager, all on one cable with the computer.
- The input and output chests must **not** have Stock Links.

## Gauges

On the Factory Controller, add a gauge for each crafted item and set its target. Leave its ingredients unlinked; this computer orders them. A gauge that has ingredients linked orders on its own and would double up.

## First run

1. **Setup** tab: check every block is found, then press **Calibrate**. Put any item in the input chest; the computer places it in each crafter in turn and you click where it appeared. **Use reading order** is a shortcut if your slots already follow the grid left-to-right, top-to-bottom.
2. **Recipes** tab: **New**. Put one of each ingredient in the input chest; they appear on the left. Pick an item, click grid cells to place it, set the name and the output item, then **Save**.
3. Go back to **Status** and press **Return them** to send the ingredients you used for the editor back to storage.

**Craft +1** and **+8** queue crafts by hand, whatever the gauge says.

If a craft fails (no rotation, wrong pattern, output not appearing), the recipe pauses, the ingredients go back into the input chest, and the Status tab shows why with a **Resume** button.
