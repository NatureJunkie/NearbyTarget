# NearbyTargets (Vanilla 1.12)

A lightweight helper that shows nearby enemies in a simple list, with a dedicated **Top Row** that can show either:
- your **current target** (if you want it pinned), or
- the **lowest-health** enemy.

It works with nameplates, has simple filters, and supports a camera/movement “click-through” gesture by holding both mouse buttons on a row.

---

## What this addon does (in plain English)

- Shows a list of nearby enemies (from visible nameplates).
- Lets you quickly target an enemy with the **colored buttons** on each row.
- Has a separate **Top Row** that can always show your target, or the lowest HP enemy.
- Keeps the lowest-HP choice stable (it won’t flicker between same-name mobs).
- Can include your **pet’s target** even when its nameplate is not visible (as a gray “sticky” row).
- Lets you **rotate/move the camera** while the UI is under your mouse by holding **both mouse buttons** briefly. The row becomes click-through until you release.

---

## Key features

- **Top Row** is independent from the main list.
- **Two modes** for the Top Row:
  - **Target→Top**: show your current target first; if no target, show lowest hp either by % or by Raw HP.
  - **Lowest→Top** (default): show the overall lowest; if it shares the same name as your target, your target is prioritized for the Top Row.
- **Percent or Raw HP** comparison.
- **Filters** by unit type (Beast, Humanoid, etc.).
- **Sticky Target Priority**: when two enemies share the same name, the one you’re targeting is preferred for the Top Row.
- **Nameplate scanning** avoids critters and junk labels.

---

## Installation
1. Download and UnZip the file
2. Move the folder `NearbyTargets` to your `Interface\AddOns` directory.
3. Create your own Functions for the Buttons in Buttons.lua "CastSpellByName("Hunter's Mark")" to cast a spell
4. Launch the game and enable the addon in the character AddOns menu.

> This addon is written for **Vanilla 1.12** UI API.

---

## How to use

- **Open/close**: type `/nt`
- **Move the window**: drag the top bar.
- **Rotate/move camera through the list**: press and hold **both mouse buttons** on any row for a short moment. The row turns click-through so the camera/character movement receives the input. Release both buttons to restore normal clicks.

---

## Buttons on the top bar

- **Filter**: opens a small panel to enable/disable creature types.
- **Mode**: toggles the Top Row behavior:
  - **“Mode: Target→Top”**: Top Row shows your target if you have one; otherwise the lowest.
  - **“Mode: Lowest→Top”**: Top Row shows the lowest; if your target has the same name, your target is preferred.
- **Compare [%]/[HP]**: switch between percent-based or raw HP comparison.

---

## The list and the Top Row

- **Top Row** is dedicated and separate:
  - It never “steals” or removes items from the list.
  - It can show a **gray sticky** entry when your target (or pet’s target) is not visible.
- **Main list** shows visible enemies by name:
  - Uses a stable tie-breaker so the **lowest** choice is steady.
  - May include sticky pet target at the top of the list if not already visible.

---

## Colored buttons (per row)

Each row shows **seven small colored buttons** on the left. Clicking one:
1. Selects the mob by **name**, preferring to keep your current instance if already targeted.
2. Optionally runs a global function `Button1` … `Button7` if you’ve defined them (for your own macros or logic).
3. Right-clicking a button (or holding **Alt** while clicking) will try to **restore your previous target** after the button function runs.

If you don’t define any `ButtonX` functions, a small chat message explains the button has no function assigned.

---

## Filters

Click **Filter** to open a small panel. Check the types you want to see (e.g., **Humanoid**, **Undead**, etc.). **Critter** is disabled by default.

Filters are remembered between sessions.

---

## Modes (the “Mode” button)

- **Target→Top**  
  Top Row shows your **current target** when you have one. If you do not have a target, it shows the **lowest-HP** enemy.

- **Lowest→Top** (default)  
  Top Row shows the **overall lowest-HP** enemy. If your **target** has the **same name** as the lowest, the Top Row uses **your target** (sticky priority) so it doesn’t jump between same-name mobs.

---

## Sticky priority (same-name mobs)

When two enemies have the same name (e.g., two “Defias Thugs” nearby), the addon:
- Keeps the **Top Row** stable using a uid/name tie-break.
- If your **target** has the same name as the current “lowest,” the Top Row **prefers your target** so you don’t bounce between instances.

---

## Camera/movement click-through (hold both buttons)

- On any row, double click **both mouse buttons** briefly.
- That whole row becomes **temporarily click-through**, so your camera/character movement gets the input immediately.
- Releasing both mouse buttons **automatically re-enables** the row’s buttons.

This behavior is **row-scoped** and includes the Top Row.

---

## Slash commands

- `/nt`  
  Toggle the window.

- `/ntmode`  
  Toggle the Top Row mode (Target→Top vs Lowest→Top).

You’ll also see small chat messages when toggling compare mode or the Top Row mode.

---

## Troubleshooting

- **Top Row shows a gray entry**: that means it’s a **sticky** target (your target or pet’s target) that is not currently visible as a nameplate.
- **Lowest looks wrong**: make sure you’re in the compare mode you want (**%** vs **HP**). The button shows which is active.
- **Row becomes unclickable**: this is normally temporary when you hold both mouse buttons. Releasing both restores clicks. If you somehow get stuck, tap left and right mouse buttons once each over the world to reset, or type `/nt` twice to hide/show.
- **Same-name mobs bouncing**: this should be stable now. If you want to pin your target to the top regardless, switch to **Target→Top** mode.

---

## Performance notes

- The list refreshes roughly every **0.6s** by default.
- Nameplate scanning is lightweight and avoids obvious non-combat labels.

---

## Customization hooks

You can define these in your own macro file or another addon:
 
function Button1() end
function Button2() end
function Button3() end
function Button4() end
function Button5() end
function Button6() end
function Button7() end
 
They will run after the addon selects the row’s target by name.

Saved settings

Compare mode (% or HP)

Top Row mode (Target→Top or Lowest→Top)

Sticky pet toggle

Filters per creature type

These are stored in the addon's saved variables and persist across sessions.

## Compatibility

Built for Vanilla 1.12 API calls.

Works with default nameplates.

## Quick start

Install the addon.

Type /nt to show the window.

Use the Mode button to choose how the Top Row behaves.

Use the Compare button to switch between % and HP.

Click the colored buttons to target and optionally run your own ButtonX function.

Hold both mouse buttons over a row to rotate/move the camera.

Enjoy!
MADE WITH CHATGPT
