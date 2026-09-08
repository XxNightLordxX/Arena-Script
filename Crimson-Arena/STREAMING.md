# `stream/` — shipping your own props with the arena

**You almost certainly do not need this.** Read the first section before
putting anything in here.

## The arena already survives a missing prop

Every prop the arena spawns names a **chain** of models, not one model. The
client tries them in order and uses the first one your build actually has:

```lua
models = {
    'stt_prop_stunt_bblock_huge_01',   -- Cunning Stunts
    'bkr_prop_biker_bblock_huge_01',   -- Bikers
    'imp_prop_impexp_bblock_huge_01',  -- Import/Export
    'ar_prop_ar_bblock_huge_01',       -- Arena War
    'prop_container_01a',              -- base game
}
```

The last entry is **base game**. It is not in a DLC, it is not behind an
update, and a stock GTA V install has it — so for a chain to run out
completely, someone has to have deliberately stripped assets out of the
server's game files. Every model named in `config.lua` was checked
against the game's own object list by a test that is not in this release —
one invented name shipped once, which is why that test was written. **Nothing
checks the names now**, so if you add a prop, check it in game yourself.

## How to tell, on your own server, in ten seconds

Start the resource and look at **F8** on any client. If a chain has run out,
you get this and the arena refuses to start rather than dropping anyone into
open air:

```
[crimson_arena] PROPS MISSING ON THIS BUILD -- an arena below cannot be built and will refuse to start:
    skydome floor -- none of: stt_prop_stunt_bblock_huge_01, ...
```

Nothing printed means every chain found a model. With `Config.Debug = true`
you get the full report either way, including *which* model each chain
landed on.

## If a chain really has run out

Two options, in order of how much work they are:

**1. Name props you do have.** Edit the `models` list in `config.lua` — any
solid prop with a flat top works as a floor, and any solid prop works as
cover. The client measures whatever you name with `GetModelDimensions` and
lays the floor out on the real footprint, so you do not have to work out
tile spacing or heights. Prefer a prop that is *large*: the floor is tiled,
so a small prop means hundreds of pieces (see `maxTiles`).

**2. Stream the props yourself.** **There is no `stream/` folder in this
resource, deliberately** — FiveM registers *every* file in one as a streaming
asset, so a stray `.md` or `.txt` in there prints an error in every player's
console on every connect. Make the folder yourself when you have a real model
to put in it:

```
stream/
  my_platform.ydr        the model
  my_platform.ytd        its textures, if separate
  my_platform.ytyp       the type definition, if the model needs one
```

`.ydr` and `.ytd` files stream automatically — FiveM picks up anything in a
`stream/` folder and no manifest line is needed. A `.ytyp` does need one, in
`fxmanifest.lua`:

```lua
data_file 'DLC_ITYP_REQUEST' 'stream/my_platform.ytyp'
```

Then name your model in `config.lua` like any other.

**This resource ships no game assets and will not.** The prop models it names
are Rockstar's, they belong to the copy of GTA V your server already has, and
redistributing them inside a resource is both a licensing problem and a
pointless one — your server has them. If you want to stream a *custom*
platform, make the folder as above and FiveM will pick it up.
