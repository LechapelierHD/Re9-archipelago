local ctx = {}
local MODULE_DIR = "reframework\\autorun\\ArchipelagoRE9\\"

-- optional : installe a part par le lanceur, absent = pas d'erreur
local function load_module(name, optional)
    local ok, err = pcall(function()
        dofile(MODULE_DIR .. name .. ".lua")(ctx)
    end)
    if not ok and optional and tostring(err):find("cannot open", 1, true) then
        return false
    end
    if not ok then
        log.error("[RE9 AP] module '" .. name .. "' n'a pas pu etre charge : " .. tostring(err))
        print("[RE9 AP] ERREUR module " .. name .. " : " .. tostring(err))
    end
    return ok
end

load_module("config")
load_module("lang")
load_module("state")
load_module("scenes")
load_module("data")
load_module("scene_jump")
load_module("tick")
-- ordre d'enregistrement on_tick = ordre d'execution
load_module("injection")
load_module("detector")
load_module("apclient")
load_module("supply")
load_module("goal")
load_module("grace_tracker")
load_module("deathlink")
load_module("respawn")
load_module("chapterskip", true)
load_module("chapter_gate")
load_module("markers")
load_module("ap_visual")
load_module("theme")
load_module("ui")
load_module("ui_debug")

if ctx.info then
    ctx.info(string.format("charge : %d emplacements, %d objets AP", ctx.location_count or 0, ctx.ap_item_count or 0))
end
