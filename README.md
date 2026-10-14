# ShareSeed

Have you ever had an amazing run, sent the seed to a friend, and they got something completely
different? Different items in the treasure room, different rooms, a boss you never saw..?

That's because the seed isn't the whole story. The game checks your unlocks everywhere
If your friend doesn't have exactly the same unlocks as you, the same seed gives them a different run.

ShareSeed fixes that. It turns your run into a code that holds the seed as well as your unlocks.
Whoever plays it gets the run you got (floors, rooms, bosses, items, pills, curses), whether they
have nothing unlocked or Dead God.

For Repentance+ with [REPENTOGON](https://repentogon.com).

Download on Steam:

## Using it

Open the console. Then either click **ShareSeed** (on the top) **-> Share / play a seed** in the
menu bar, or use the console commands:

| Command                            | What it does                                                               |
| ---------------------------------- | -------------------------------------------------------------------------- |
| `shareseed`                      | Copy the current (or last) run's seed to the clipboard                     |
| `shareseed play`                 | Play the seed in your clipboard                                            |
| `shareseed play SS1.XXXXXXXX.…` | Play this seed                                                             |
| `shareseed info [code]`          | Show what's in a seed, and how many of the sharer's unlocks you don't have |
| `shareseed stop`                 | Go back to your own unlocks/save                                           |

The sharer needs the mod installed while playing the run they want to share. The code records:

- which of the 640 achievements they have (`info` only shows the total), and
  the few save-file counters that run generation reads, as they were when the run started.
- anything they unlocked mid-run
- floors that another mod rerolled as they began (TR start), and the seed each
  one ended up with.

A code Dead God profile makes a code of about 35–45 characters, a mid-game profile one of about 100–150.

## How it works, and what it does to your save

The game checks unlocks in hundreds of places: item pools, room and boss choices, how many rooms a
floor gets, floor variants, doors, starting items.
ShareSeed changes your save file to the sharer's unlocks, and puts yours back
afterwards:

Two things to consider:

- **Steam keeps unlocks.** If the sharer has unlocks you don't, the swap unlocks them, and Steam
  counts those as earned achievements. Your save gets your own back, Steam can't be undone.
  If you wish, you can potentially remove those achievements with SAM tools. But i do not recommend it.
- Codes from someone with fewer unlocks than you never touch Steam
- Sharing with fewer achievements is fine. Playing a Dead Gods save when you hit your first 100 hours.. not really :/
- **Do NOT uninstall in the middle.** Keep ShareSeed installed until a shared run is over. If you
  remove it while the save holds a shared run's unlocks, they stay. Reinstalling it and starting a
  run fixes that.

## Works in:

Repentance+ v1.9.7.12 + REPENTOGON 1.1.3 with TRStart

- **Treasure Room (TR) Start:** **COMPATIBLE✅**
  TR Start rerolled floor 1 of a seed three times on the sharer's normal run, the replay rerolled it the same way.

## Limitations

**Same route -** Like vanilla, drops depend on the order you open rooms, use rerolls and so on. Two
players see the same run when they play it the same way.

**Mods -** Mods that change generation need to be the same on both sides.

**Mod unlocks during a shared run aren't kept.** The restore puts back exactly the backup, so

anything another mod force-unlocks during a shared run is gone afterwards. Seeded runs don't award
achievements anyway.

**Version -** This version was tested on v1.9.7.12 Repentance+ with REPENTOGON.

Co-op and modded characters aren't handled.

## Dedicated to Kayhos
So he can continue the "solving your runs" series.
and help non-Dead God players.