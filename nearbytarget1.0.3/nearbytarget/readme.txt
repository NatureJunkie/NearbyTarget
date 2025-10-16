# Changelog

All notable changes to **NearbyTargets (Vanilla 1.12, Lua 5.0-safe)** are documented here.

## [v0.10.0] — Dual-scope filters, multi-`[t:]` targeter, chat directives

**NearbyTargets** now supports independent list filtering and a silent multi-`[t:]` targeter running in parallel, plus inline chat directives and sturdier input handling.

### ✨ Highlights
- **Dual-scope parsing**: plain words filter the **list**, while each `[t:...]` block has its **own** filters.
- **Silent multi-`[t:]` targeter**: background tick, locks to a match, resumes after death.
- **Chat directives**: `[say] [party] [raid] [rw] [whisper] [whisper:Name:Name2]` + Message box + Enter to send.
- **Compare toggle drives row text**: `%` shows percent; `HP` shows `hp / max`.
- **Configurable clickthrough**: `holdBothDelay` controls how long to hold both mouse buttons.

### ✅ Added
- `[t:token1,token2|token3]` scopes with their own `[below:N] [above:N] [lvl:<|>|=N]`.
- Independent, **silent** targeter (no chat spam):  
  `TARGET_INTERVAL = 0.30s`, locks until target dies/changes, then continues.
- Chat flow: put directives in **Filters**, message in **Message**, press **Send**/**Enter**.  
  `[whisper]` with no names whispers **all visible players** in the list.
- Robust input: Filters box parses continuously; **Enter** parses + defocuses (1.12-safe).
- New settings:
  ```lua
  NearbyTargetsSettings = {
    comparePercent = true,
    pinTargetFirst = false,
    holdBothDelay  = 0.10,
  }
### 🔁 Changed
- **Top-row mode logic clarified** (labels unchanged):
  - `pinTargetFirst = true` → Top shows **Target** (fallback **Lowest**).
  - `false` → Top shows **Lowest**; if its **name matches** your current target, the **sticky target** is shown.
- **Lowest tie-break** is now **name-based** when values are equal (removed UID mapping).
- **Compare toggle** now also controls **row text** (`%` vs `hp / max`), not just comparison math.
- **Geometry constants** extracted (row/button sizes & spacing) while preserving the **existing look**.
- **Header labels**: `"Compare [%]"` / `"Compare [HP]"` for clarity.
 
### 🧰 Fixed
- **Enter in Filters**: now parses scopes and **clears focus** correctly on Vanilla 1.12.
- **Clickthrough re-arm**: rows consistently re-enable mouse after releasing **both** buttons.
- **Targeter lock**: releases on death/mismatch, then **resumes scanning**.
 
### 🧪 Usage quickstart
- **Show/Hide**: `/nt /ntparty /ntraid` 
- **Top-row toggle**: `/ntmode`  
- **Filters examples**:
  - `gnoll [below:35]` → list gnolls under 35% (in `%` mode).
  - `harpy [t:witch|siren][lvl:<30][below:60]`  
    - **List**: “harpy”, `lvl<30`, `hp<60%`.  
    - **Targeter**: seeks “witch” **or** “siren” with its own constraints.
- **Chat**:
  - Add `[party]` / `[raid]` / `[rw]` / `[say]` / `[whisper]` / `[whisper:Name:Name2]` in **Filters**.  
  - Put your line in **Message** → press **Send** or **Enter**.

### 🔎 Known limits (Vanilla rules)
- Same-name mobs **cannot** be uniquely targeted via API; locks are by **name**, not instance.
- Levels may be missing on some nameplates; level filters **pass** when data is unavailable.
