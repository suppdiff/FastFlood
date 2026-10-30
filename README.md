# Fast Flood

**Fast Flood** is a lightweight, standalone graphical chat-announcement addon for **World of Warcraft 3.3.5a (build 12340, Interface 30300)**. It offers one shared announcement message, a configurable repeat interval, up to two chat destinations, and a detachable quick launcher.

> **Status: v1.0.0 — awaiting visual and live sending tests on a real 3.3.5a client.** Lua parsing and an offline mocked WoW UI/sending suite run in CI; simulated sends are not confirmation of server delivery.

## Install

1. Download the **installable** release ZIP (`FastFlood-v1.0.0.zip`) from the Releases page, or copy the `FastFlood/` directory from this repository.
2. Put the **single** `FastFlood` folder under `World of Warcraft/Interface/AddOns/`.
3. Confirm you have `Interface/AddOns/FastFlood/FastFlood.toc` (not `FastFlood/FastFlood/FastFlood.toc`).
4. Enable **Fast Flood** on the character-selection AddOns screen.
5. Type `/fastflood` in chat.

**Upgrading from v0.1.0 or v0.1.1:** Replace only the `Interface/AddOns/FastFlood` addon directory. Keep your `WTF/Account/.../SavedVariables/FastFlood.lua` file. The v1.0.0 addon converts the old single destination into the first of the new channel slots automatically.

## Commands

| Command | Result |
| --- | --- |
| `/fastflood` | Toggle the main window |
| `/fastfloodstart` | Start repeating, or stop if running |
| `/ff` | Short compatibility alias for `/fastflood` |

Older `/ff on`, `/ff off`, `/ff button`, `/ff button on`, `/ff button off`, `/ff dock`, `/ff float`, and `/ff help` are supported for existing users. The old **Send Once** control and `/ff once` command were removed from the interface in v1.0.0.

## Features

- **One message, one or two destinations:** The **+** button adds a second destination; **−** removes it. Both receive the same message. Available destinations: Say, Yell, Guild, Party, Raid, Battleground, Officer, or a joined numbered channel such as `/1` or `/2`.
- **Timing:** 10–3600 seconds **per destination**, default 30 seconds. Channel one sends immediately when Start is pressed; when enabled, channel two sends **2 seconds later**. The same stagger repeats every interval. There is no catch-up flood following a lag spike.
- **Controls:** Start/Stop buttons on the panel; `/fastfloodstart` toggles from chat. Closing the window does not stop the timer.
- **Small movable FF launcher:** Left-click toggles the panel, dragging floats it away from the minimap. Main-window checkboxes control launcher visibility and docking. There is no corner status square; running/stopped status remains in the main panel.
- **Per-character saved settings:** Message, channels, interval, window location, launcher visibility/docking, and floating launcher location are saved by WoW. Sending **never resumes automatically** after relog or `/reload`.
- **Validation:** Checks message length, joined numbered channels, group presence, duplicate destinations, and the interval before Start. If a destination disappears mid-cycle, sending stops rather than silently skipping it.

The counter displays **local send attempts**, not confirmed delivery. Realm/server chat restrictions and anti-spam policies apply. Choose a reasonable repetition interval and follow your realm's rules.

## Files

```text
FastFlood/                    <- copy this folder into Interface/AddOns
  FastFlood.toc
  FastFlood.lua
.github/workflows/lua-tests.yml
README.md
CHANGELOG.md
LICENSE
.gitignore
tests/test_fastflood.lua
scripts/package.sh
```

## Development and tests

This addon intentionally targets the original **Lua 5.1** language/API subset used in WoW 3.3.5a, rather than the current WoW API.

From the repository root, with `lua5.1` and `luac5.1` installed:

```sh
luac5.1 -p FastFlood/FastFlood.lua tests/test_fastflood.lua
lua5.1 tests/test_fastflood.lua
scripts/package.sh
```

GitHub Actions runs these commands on every push/PR. Run `bash scripts/package.sh` to build the installable archive in `dist/`. The test suite uses mocked frame, timer, channel, and SavedVariables APIs to check migration, commands, UI actions, duplicated channels, staggered sends, invalid inputs, stop conditions, and reload persistence. **You still need manual testing in-game**: frame layout at various UI scales, drag/dock behavior, real channel sends and throttling, and persistence after a full relog.

## Contributing

Changes should remain compatible with patch **3.3.5a**, including its FrameXML widget templates and Lua 5.1. Prefer focused PRs with a regression test for sending, UI, or settings changes. Please do not add chat-rate-limit bypasses or unsolicited automation without explicit user control.

## License

MIT. See [LICENSE](LICENSE).
