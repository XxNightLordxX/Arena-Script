# Crimson Arena

A configurable PvP arena for [Qbox](https://github.com/Qbox-project). Players walk up to an NPC, pick their weapons, melee and ammunition from lists you control, choose a team that does not have to be even, and optionally bet on the outcome.

By John Allday, for Crimson Roleplay.

## Install

1. Download this repository and open the archive.
2. Drag the **`Crimson-Arena`** folder into your server's `resources/`. It is named the way it should be named there, so nothing needs renaming — though the resource works under any folder name if you would rather use another.
3. Add one line to `server.cfg`, anywhere after `qbx_core`:

   ```cfg
   ensure Crimson-Arena
   ```

4. Start the server.

There is no SQL to import and nothing to install first beyond `qbx_core` and `ox_lib`, which every Qbox server already runs. `ox_target`, `ox_inventory` and `oxmysql` are used when you switch on the features that want them and are not required otherwise.

## Documentation

Everything lives inside the resource folder, so it travels with the copy on your server:

| | |
|---|---|
| **[`Crimson-Arena/README.md`](Crimson-Arena/README.md)** | Full documentation — every setting, what it does, and why it is the shape it is |
| **[`Crimson-Arena/config.lua`](Crimson-Arena/config.lua)** | Everything an operator edits except the weapon list. Every option is commented in place |
| **[`Crimson-Arena/config.weapons.lua`](Crimson-Arena/config.weapons.lua)** | The weapon catalogue, split out so the file above stays short |
| **[`Crimson-Arena/DEPLOYMENT.md`](Crimson-Arena/DEPLOYMENT.md)** | The first-run smoke-test checklist, for the part no automated test can cover |
| **[`Crimson-Arena/REFERENCE.md`](Crimson-Arena/REFERENCE.md)** | The inventory: every feature, command, export and event, and every function in every file with a line on what it is for |

## Why the resource is in a subfolder

So that the folder you drag out of the download is the folder you drop into `resources/`, correctly named, with no step in between. The repository root holds only this file, the CI workflow and the ignore list — none of which belong on a game server.

## Licence

See [`Crimson-Arena/LICENSE.md`](Crimson-Arena/LICENSE.md).
