--[[
  OneHandWeaponDEX — make one-handed weapons require & scale with Dexterity (Dex build)
  ====================================================================================
  The mirror image of GothicCrossbowSTR. For each ENABLED 1H weapon:
    * Equip requirement: Strength -> Dexterity (also shown in the tooltip),
      keeping the weapon's original requirement value.
    * Damage: ADDITIVE Dexterity scaling on top of the vanilla weapon:
        m_DamageBase = originalWD + Dexterity*Scale     (Scale = DEX-per-point)
      The engine still adds the wielder's Strength on a hit, but the intended user (a
      Dexterity character who just wants a melee option without spending LP on Strength)
      has ~0 Strength, so net damage = originalWD + Dexterity*Scale. Scale is configurable
      (0 = vanilla damage / requirement-only). No cancellation -> base is always >= vanilla,
      can never show "1".
    * Scale = 0 -> requirement-only (weapon needs Dexterity, damage unchanged).

  PER-WEAPON ENABLE: every 1H weapon (sword/axe/mace) has a <NAME>_ENABLED flag in
  the INI. Only ENABLED weapons are converted. DEFAULT: one-handed SWORDS on, axes &
  maces off (swords = the Dex/light-weapon lane; axes/maces stay the Strength lane).
  Flip any flag in G1R_OneHandWeaponDEX.ini to mix it however you like.

  EVENT-DRIVEN — NO POLLING LOOP. BeginPlay + LoadMap + the HUD attribute-change hook,
  exactly like GothicCrossbowSTR. Item definitions are AngelScript class CDOs
  (/Script/Angelscript.Default__<Name>) edited at runtime each session: no .pak edits,
  no save changes. IDEMPOTENT: each weapon's vanilla damage + requirement is snapshotted
  ONCE into a _G global (survives a "Restart All Mods" re-exec), so re-applying never drifts.

  Config: G1R_OneHandWeaponDEX.ini  (Enabled, Scale, DebugLogging, per-weapon _ENABLED)
--]]

local MOD_NAME    = "[1HWeaponDEX]"
local VERSION     = "0.1.1"
local CONFIG_FILE = "G1R_OneHandWeaponDEX.ini"
local MOD_FOLDER  = "OneHandWeaponDEX"
local APPLY_DELAY_MS = 4000   -- wait after a load so the player state exists

local cfg_enabled = true
local cfg_scale   = 0.2       -- Dexterity-per-point. base = origWD + (DEX*Scale - STR), the exact
                              -- mirror of the crossbow (STR*Scale - DEX): the scaling stat is
                              -- multiplied by Scale, the replaced stat (Strength) is subtracted
                              -- RAW to cancel what the engine adds on a melee hit. 0 = requirement-
                              -- only (base untouched). Default 0.2 matches the crossbow's tuning.
local cfg_debug   = false

----------------------------------------------------------------------
-- The 1H weapon roster. default_on: true for swords (the Dex lane), false for
-- axes & maces (kept on Strength). Each name is overridable via <NAME>_ENABLED.
-- Sourced from reference/BetterWeapons (UE4SS object dump); excludes torches and
-- the PlayerPlayTest/QA test entries.
----------------------------------------------------------------------
local SWORDS = {
    "ItMw_1H_Sword_01", "ItMw_1H_Sword_01_Xardas_Sleeper", "ItMw_1H_Sword_02",
    "ItMw_1H_Sword_03", "ItMw_1H_Sword_04", "ItMw_1H_Sword_04_Diego_Sleeper",
    "ItMw_1H_Sword_05", "ItMw_1H_Sword_05_Darrion", "ItMw_1H_Sword_Arto",
    "ItMw_1H_Sword_Bastard_01", "ItMw_1H_Sword_Bastard_02", "ItMw_1H_Sword_Bastard_03",
    "ItMw_1H_Sword_Bastard_04", "ItMw_1H_Sword_Broad_01", "ItMw_1H_Sword_Broad_02",
    "ItMw_1H_Sword_Broad_03", "ItMw_1H_Sword_Broad_04", "ItMw_1H_Sword_Kalom",
    "ItMw_1H_Sword_Lightguard_01", "ItMw_1H_Sword_Long_01", "ItMw_1H_Sword_Long_02",
    "ItMw_1H_Sword_Long_03", "ItMw_1H_Sword_Long_04", "ItMw_1H_Sword_Long_05",
    "ItMw_1H_Sword_Old_01", "ItMw_1H_Sword_Old_02", "ItMw_1H_Sword_Paw",
    "ItMw_1H_Sword_Raven", "ItMw_1H_Sword_Scar", "ItMw_1H_Sword_Scythe_01",
    "ItMw_1H_Sword_Short_01", "ItMw_1H_Sword_Short_02", "ItMw_1H_Sword_Short_03",
    "ItMw_1H_Sword_Short_04", "ItMw_1H_Sword_Short_05", "ItMw_1H_Sword_Whistler",
    "ItMw_2H_Sword_Light_01", "ItMw_2H_Sword_Light_02", "ItMw_2H_Sword_Light_03", "ItMw_2H_Sword_Light_04", "ItMw_2H_Sword_Light_05",
    "ItMw_2H_Sword_Light_01_Stone", "ItMw_2H_Sword_Old_01", "ItMw_2H_Sword_01", "ItMw_2H_Sword_02", "ItMw_2H_Sword_03",
    "ItMw_2H_Sword_Heavy_01", "ItMw_2H_Sword_Heavy_02", "ItMw_2H_Sword_Heavy_03", "ItMw_2H_Sword_Heavy_04",
    "ItMw_2H_Sword_Thorus", "ItMw_2H_Sword_Wind", "ItMw_2H_Sword_Innos", "ItMw_2H_Sword_Uriziel_03",
}
local AXES = {
    "ItMw_1H_Axe_01", "ItMw_1H_Axe_02", "ItMw_1H_Axe_03", "ItMw_1H_Axe_Bran",
    "ItMw_1H_Axe_Cord", "ItMw_1H_Axe_Hatchet_01", "ItMw_1H_Axe_Lares",
    "ItMw_1H_Axe_Old_01", "ItMw_1H_Axe_Sickle_01", "ItMw_1H_Axe_Silas",
}
local MACES = {
    "ItMw_1H_Mace_01", "ItMw_1H_Mace_02", "ItMw_1H_Mace_03", "ItMw_1H_Mace_04",
    "ItMw_1H_Mace_Club_01", "ItMw_1H_Mace_Fortuno", "ItMw_1H_Mace_Lester",
    "ItMw_1H_Mace_Lester_Sleeper", "ItMw_1H_Mace_Light_01", "ItMw_1H_Mace_Nailmace_01",
    "ItMw_1H_Mace_Namib", "ItMw_1H_Mace_Orun", "ItMw_1H_Mace_Poker_01",
    "ItMw_1H_Mace_Sledgehammer_01", "ItMw_1H_Mace_War_01", "ItMw_1H_Mace_War_02",
    "ItMw_1H_Mace_War_03", "ItMw_1H_Mace_Warhammer_01", "ItMw_1H_Mace_Warhammer_02",
    "ItMw_1H_Mace_Warhammer_03", "ItMw_2H_Staff_02", "ItMw_2H_Staff_Scepter",
}

-- build the roster: { name, path, category, default_on }
local WEAPONS = {}
local function add_group(list, category, default_on)
    for _, n in ipairs(list) do
        WEAPONS[#WEAPONS+1] = {
            name = n, path = "/Script/Angelscript.Default__" .. n,
            category = category, default_on = default_on,
        }
    end
end
add_group(SWORDS, "Sword", true)
add_group(AXES,   "Axe",   false)
add_group(MACES,  "Mace",  false)

-- DEX requirement source: a natively-Dexterity weapon to copy the m_RequiredStats
-- map shape from (bows are Dexterity and untouched by GothicCrossbowSTR).
local DEX_SOURCES = {
    "/Script/Angelscript.Default__ItRw_Bow_Long_01",
    "/Script/Angelscript.Default__ItRw_Bow_Small_01",
    "/Script/Angelscript.Default__ItRw_Bow_Long_02",
}

----------------------------------------------------------------------
local function log(m) print(string.format("%s %s\n", MOD_NAME, tostring(m))) end
local function dbg(m) if cfg_debug then log(m) end end
local function usable(o) if not o then return false end local ok,v=pcall(function() return o:IsValid() end) return ok and v end
local function full(o) if not o then return "<nil>" end local ok,v=pcall(function() return o:GetFullName() end) return ok and tostring(v) or "<?>" end
local function pget(v) if v==nil then return nil end local ok,u=pcall(function() return v:get() end) if ok and u~=nil then return u end return v end
local function pset(p,val) local ok=pcall(function() p:set(val) end) if ok then return true end return pcall(function() p:Set(val) end) end
local function trim(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local function upper(v) return string.upper(trim(v)) end

----------------------------------------------------------------------
-- config
----------------------------------------------------------------------
local weapon_on = {}   -- name -> bool (resolved enable state)

local function script_dir()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or not info or not info.source then return nil end
    local s = tostring(info.source); if s:sub(1,1) == "@" then s = s:sub(2) end
    return s:match("^(.*[\\/])[^\\/]*$")
end
local function read_file(p) local f=io.open(p,"r"); if not f then return nil end local c=f:read("*a"); f:close(); return c end
local function cfg_bool(v,d) local n=upper(v); if n=="" then return d end if n=="1" or n=="TRUE" or n=="YES" or n=="ON" then return true end if n=="0" or n=="FALSE" or n=="NO" or n=="OFF" then return false end return d end
local function cfg_num(v,d) local n=tonumber(trim(v)); if n==nil then return d end return n end

local function load_config()
    local dir = script_dir(); local cands = {}
    if dir then cands[#cands+1]=dir.."..\\"..CONFIG_FILE; cands[#cands+1]=dir..CONFIG_FILE end
    cands[#cands+1] = "Mods\\"..MOD_FOLDER.."\\"..CONFIG_FILE
    cands[#cands+1] = CONFIG_FILE
    local kv = nil
    for _, path in ipairs(cands) do
        local content = read_file(path)
        if content then
            kv = {}
            for line in string.gmatch(content, "[^\r\n]+") do
                local s = trim(line)
                if s ~= "" and s:sub(1,1)~=";" and s:sub(1,1)~="#" and s:sub(1,1)~="[" then
                    local k,v = s:match("^([%w_%.%-]+)%s*=%s*(.-)%s*$")
                    if k then v = v:gsub("%s*[;#].*$", ""); kv[upper(k)]=trim(v) end   -- strip inline ; / # comments
                end
            end
            break
        end
    end
    if kv then
        cfg_enabled = cfg_bool(kv.ENABLED, true)
        cfg_scale   = cfg_num(kv.SCALE, 0.2)
        cfg_debug   = cfg_bool(kv.DEBUGLOGGING, false)
    else
        log("config not found; using defaults (swords on, axes/maces off)")
    end
    -- per-weapon enable: <NAME>_ENABLED, default per category
    local on_count = 0
    for _, w in ipairs(WEAPONS) do
        local key = upper(w.name) .. "_ENABLED"
        local val = kv and kv[key] or nil
        weapon_on[w.name] = cfg_bool(val, w.default_on)
        if weapon_on[w.name] then on_count = on_count + 1 end
    end
    log(string.format("config: Enabled=%s Scale=%s Debug=%s | %d/%d weapons enabled",
        tostring(cfg_enabled), tostring(cfg_scale), tostring(cfg_debug), on_count, #WEAPONS))
end

----------------------------------------------------------------------
-- cached lookups
----------------------------------------------------------------------
local item_cache = {}
local function get_item(path)
    local o = item_cache[path]
    if usable(o) then return o end
    o = StaticFindObject(path); if usable(o) then item_cache[path]=o; return o end
    return nil
end
local set_cache = {}
local function find_player_set(shortName)
    local c = set_cache[shortName]
    if usable(c) then return c end
    local ok, objs = pcall(FindAllOf, shortName)
    if ok and objs then for _,o in ipairs(objs) do local fn=full(o)
        if usable(o) and fn:find("PlayerState",1,true) and not fn:find("Default__",1,true) then set_cache[shortName]=o; return o end end end
    return nil
end
local function attr_current(set, field)
    if not usable(set) then return nil end
    local val; pcall(function() local r=set[field]; if type(r)=="number" then val=r else val=r.CurrentValue end end)
    return val
end

----------------------------------------------------------------------
-- vanilla snapshots (idempotent — kept in _G so they survive a script re-exec)
----------------------------------------------------------------------
local origWD  = _G.__OHSWD_origWD  or {}   -- path -> vanilla weapon m_DamageBase
local origReq = _G.__OHSWD_origReq or {}   -- path -> vanilla requirement value
_G.__OHSWD_origWD, _G.__OHSWD_origReq = origWD, origReq

----------------------------------------------------------------------
-- (A) requirement: Strength -> Dexterity
----------------------------------------------------------------------
local function req_owner(cdo) local owner; pcall(function() cdo["m_RequiredStats"]:ForEach(function(k,v) local key=pget(k); pcall(function() owner=key.AttributeOwner and key.AttributeOwner:GetFullName() end) end) end) return owner end
local function req_value(cdo) local val; pcall(function() cdo["m_RequiredStats"]:ForEach(function(k,v) val=pget(v) end) end) return val end
local function is_dex(owner) return owner and string.lower(tostring(owner)):find("dexterity",1,true) ~= nil end

local req_done = false
local function apply_requirement()
    if req_done then return end
    -- locate a Dexterity requirement map to copy onto our weapons
    local src
    for _, path in ipairs(DEX_SOURCES) do local o=StaticFindObject(path); if usable(o) and is_dex(req_owner(o)) then src=o break end end
    if not src then return false end
    local ok, srcMap = pcall(function() return src["m_RequiredStats"] end)
    if not ok or srcMap==nil then return false end
    local n = 0
    for _, w in ipairs(WEAPONS) do
        if weapon_on[w.name] then
            local cdo = get_item(w.path)
            if cdo then
                -- snapshot the vanilla requirement value ONCE (persisted in _G)
                if origReq[w.path]==nil then local v=req_value(cdo); origReq[w.path]=(type(v)=="number") and v or 10 end
                local origVal = origReq[w.path]
                pcall(function() cdo["m_RequiredStats"] = srcMap end)
                pcall(function() cdo["m_RequiredStats"]:ForEach(function(k,v) pset(v, origVal) end) end)
                n = n + 1
            end
        end
    end
    req_done = true
    log("requirement set to Dexterity on " .. n .. " enabled weapon(s)")
    return true
end

----------------------------------------------------------------------
-- (B) damage compensation: scale with Dexterity instead of Strength
----------------------------------------------------------------------
local function apply_damage(str, dex)
    for _, w in ipairs(WEAPONS) do
        if weapon_on[w.name] then
            local cdo = get_item(w.path)
            if cdo then
                local ok, m = pcall(function() return cdo["m_DamageBase"] end)
                if ok and m then
                    if origWD[w.path]==nil then local first; pcall(function() m:ForEach(function(k,v) if first==nil then first=pget(v) end end) end) if type(first)=="number" then origWD[w.path]=first end end
                    local wd = origWD[w.path]
                    if type(wd)=="number" then
                        -- Convert only when Dexterity (the new scaling stat) is at least the
                        -- Strength it replaces — i.e. the player actually leans Dexterity. If their
                        -- Strength is higher, leave the sword VANILLA: never convert onto the weaker
                        -- stat, so no nerf and no "1" base for an off-build (Strength) player.
                        -- Additive: add Dexterity scaling on top of the vanilla weapon.
                        --   base = origWD + DEX*Scale   (Scale = how much each DEX point adds)
                        -- The engine still adds the wielder's STR, but the target build (a DEX
                        -- character wanting a melee option) has ~0 STR, so net = origWD + DEX*Scale.
                        -- No cancellation, no gate -> the base can never drop below vanilla.
                        local target = wd + dex*cfg_scale
                        pcall(function() m:ForEach(function(k,v) pset(v, target) end) end)
                    end
                end
            end
        end
    end
end

local function read_damage(path)
    local cdo = get_item(path); if not cdo then return nil end
    local v; pcall(function() cdo["m_DamageBase"]:ForEach(function(k,val) if v==nil then v=pget(val) end end) end)
    return v
end

----------------------------------------------------------------------
-- the single apply pass (called on events, not in a loop)
----------------------------------------------------------------------
local function first_enabled_path()
    for _, w in ipairs(WEAPONS) do if weapon_on[w.name] and get_item(w.path) then return w.path end end
    return nil
end

local function apply_all(reason)
    if not cfg_enabled then return end
    apply_requirement()
    -- Scale<=0: requirement-only mode. Leave m_DamageBase untouched so damage keeps
    -- scaling with Strength (vanilla). Player gets Dexterity ACCESS, vanilla damage.
    if cfg_scale <= 0 then
        log(string.format("APPLY[%s]: requirement=Dexterity; DEX damage scaling OFF (Scale=0) -> vanilla Strength damage kept", tostring(reason)))
        return
    end
    local str_set = find_player_set("AttributeSet_Strength")
    local dex_set = find_player_set("AttributeSet_Dexterity")
    local str = attr_current(str_set, "Strength")
    local dex = attr_current(dex_set, "Dexterity")
    if type(str)=="number" and type(dex)=="number" then
        apply_damage(str, dex)
        local sample = first_enabled_path()
        log(string.format("APPLY[%s]: STR=%.0f DEX=%.0f -> sample m_DamageBase=%s",
            tostring(reason), str, dex, tostring(sample and read_damage(sample) or "n/a")))
    else
        log(string.format("APPLY[%s] skipped: attributes not ready (STR=%s DEX=%s)",
            tostring(reason), tostring(str), tostring(dex)))
    end
end

-- one-shot deferred apply after an event (coalesced; NOT a repeating loop)
local pending = false
local pending_reason = nil
local function schedule_apply(reason, delay_ms)
    if pending then return end
    pending = true
    pending_reason = reason
    pcall(ExecuteWithDelay, delay_ms or APPLY_DELAY_MS, function()
        local r = pending_reason
        pending = false
        pcall(function() pcall(ExecuteInGameThread, function() apply_all(r) end) end)
    end)
end

----------------------------------------------------------------------
load_config()
if cfg_enabled then
    local started = false
    RegisterBeginPlayPostHook(function()
        if started then return end
        started = true
        schedule_apply("first BeginPlay")
    end)
    pcall(RegisterLoadMapPostHook, function()
        req_done = false
        schedule_apply("LoadMap")
    end)
    -- attribute changed (learn a point / permanent potion) surfaces via the HUD wrapper
    local attr_hook = "/Script/G1R.HUDNotification_GameplayAttributeWrapper:SetAttribute"
    local ok = pcall(RegisterHook, attr_hook, function() pcall(schedule_apply, "attr-change", 600) end)
    log("attr-change hook " .. (ok and "OK" or "FAIL") .. " (" .. attr_hook .. ")")

    log("v" .. VERSION .. " loaded (BeginPlay + LoadMap + attr-change). Scale=" .. cfg_scale)
else
    log("disabled via config.")
end
