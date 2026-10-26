-- Multiworld : mesh Capcom = objet AP scouté (ItemID monde).
-- Item RE9 → son mesh vanilla ; autre jeu → Empty Injector (pak).
-- NEVER_BLOCK / should_keep_vanilla : pas de rewrite.

return function(ctx)
    local try = ctx.try
    local PLACEHOLDER = ctx.AP_PLACEHOLDER_GID or "it50_00_018"
    ctx.ap_placeholder_vanilla = ctx.ap_placeholder_vanilla or {}
    local last_msg, last_key, ticks = "", "", 0
    local hooked = false

    local function as_text(v)
        if v == nil then return nil end
        if type(v) == "string" then return v end
        return try(function() return v:call("ToString()") end) or try(function() return v:ToString() end)
    end

    local function base_gid(s)
        if not s then return nil end
        return tostring(s):match("(it[%d_]+)")
    end

    local function read_gid(comp)
        local s = as_text(try(function() return comp:get_field("_ItemIDStr") end))
            or as_text(try(function() return comp:call("get_ItemID()") end))
        return base_gid(s)
    end

    local function elements(arr)
        if type(arr) == "number" then arr = sdk.to_managed_object(arr) end
        if arr == nil then return {} end
        local ok, list = pcall(function() return arr:get_elements() end)
        if ok and type(list) == "table" then return list end
        local n = tonumber(try(function() return arr:call("get_Length()") end))
            or tonumber(try(function() return arr:call("get_Count()") end)) or 0
        local out = {}
        for i = 0, n - 1 do
            local e = try(function() return arr:call("Get(System.Int32)", i) end)
                or try(function() return arr:call("get_Item(System.Int32)", i) end)
            if e then out[#out + 1] = e end
        end
        return out
    end

    local function remember_vanilla(comp, gid)
        local addr = try(function() return comp:get_address() end)
        if not addr or not gid then return end
        if not ctx.ap_placeholder_vanilla[addr] then
            ctx.ap_placeholder_vanilla[addr] = gid
        end
    end

    local function vanilla_of(comp, fallback)
        local addr = try(function() return comp:get_address() end)
        return (addr and ctx.ap_placeholder_vanilla[addr]) or fallback
    end

    local function target_gid(loc_id, vanilla)
        if not loc_id then return nil end
        if ctx.is_checked and ctx.is_checked(loc_id) then return nil end
        -- hors seed (Insanity-only etc.) : ne pas scout / rewrite
        if ctx.is_active and not ctx.is_active(loc_id) then return nil end
        if ctx.should_keep_vanilla and ctx.should_keep_vanilla(vanilla) then return nil end
        if ctx.NEVER_BLOCK_ITEMS and ctx.NEVER_BLOCK_ITEMS[vanilla] then return nil end

        local id = ctx.id_str(loc_id)
        local sc = ctx.session and ctx.session.scouts and ctx.session.scouts[id]
        if not sc then
            if ctx.request_scout then ctx.request_scout(loc_id) end
            return nil
        end

        local gid = nil
        if ctx.resolve_ap_item then
            gid = select(1, ctx.resolve_ap_item(sc.item, sc.name))
        end
        if type(gid) == "string" and gid ~= "" then
            gid = base_gid(gid) or gid
            -- KeyItem / Storage / Flag : pas le volume de ramassage du spot
            -- (clé ou module sur une pièce / bouteille → marqueur sans objet prenable)
            if ctx.NEVER_BLOCK_ITEMS and ctx.NEVER_BLOCK_ITEMS[gid] then return nil end
            local known = ctx.items_by_id and ctx.items_by_id[gid]
            local cat = known and tostring(known.category) or ""
            if cat == "KeyItem" or cat == "Storage" or cat == "Flag"
                or cat == "Map" or cat == "Procedure" then
                return nil
            end
            return gid
        end
        return PLACEHOLDER
    end

    local function known_gid(s)
        local g = base_gid(s)
        if not g then return nil end
        if ctx.items_by_id and ctx.items_by_id[g] then return g end
        local cut = g:match("^(it%d+_%d+_%d+)")
        if cut and ctx.items_by_id and ctx.items_by_id[cut] then return cut end
        return g
    end

    local function go_gid(comp)
        local go = try(function() return comp:call("get_GameObject()") end)
        local n = go and as_text(try(function() return go:call("get_Name()") end))
        return known_gid(n)
    end

    local function is_bad_mesh(gid)
        if not gid then return false end
        if ctx.NEVER_BLOCK_ITEMS and ctx.NEVER_BLOCK_ITEMS[gid] then return true end
        local known = ctx.items_by_id and ctx.items_by_id[gid]
        local cat = known and tostring(known.category) or ""
        return cat == "KeyItem" or cat == "Storage" or cat == "Flag"
            or cat == "Map" or cat == "Procedure"
    end

    -- Storage / Map / Procedure n'ont pas de volume de ramassage.
    local rebuilt = {}

    local function no_volume(gid)
        if not gid or gid == "" then return false end
        if ctx.NEVER_BLOCK_ITEMS and ctx.NEVER_BLOCK_ITEMS[gid] then return false end
        if ctx.should_keep_vanilla and ctx.should_keep_vanilla(gid) then return false end
        local known = ctx.items_by_id and ctx.items_by_id[gid]
        local cat = known and tostring(known.category) or ""
        return cat == "Storage" or cat == "Map" or cat == "Procedure"
    end

    local function rebuild_mesh(comp)
        local key = try(function() return comp:get_address() end) or comp
        if rebuilt[key] then return end
        rebuilt[key] = true
        pcall(function() comp:call("set_Enabled", false) end)
        pcall(function() comp:call("set_Enabled", true) end)
    end

    local function set_known_field(comp, name, value)
        local td = try(function() return comp:get_type_definition() end)
        local field = td and try(function() return td:get_field(name) end)
        if not field then return false end
        return pcall(function() comp:set_field(name, value) end)
    end

    local function write_gid(comp, gid)
        if not comp or not gid or not ctx.item_enum then return false end
        local enum = ctx.item_enum(gid)
        if enum == nil then return false end
        local ok = pcall(function() comp:call("set_ItemID", enum) end)
        set_known_field(comp, "_ItemIDCache", enum)
        set_known_field(comp, "_ItemIDStr", sdk.create_managed_string(gid))
        return ok and true or false
    end

    local function apply_one(comp, stats)
        if ctx.AP_VISUAL_ENABLED == false then return 0 end
        if not (ctx.has_slot_data and ctx.has_slot_data()) then return 0 end
        if not ctx.read_item or not ctx.resolve_location then
            stats.no_info = (stats.no_info or 0) + 1
            return 0
        end

        local cur = read_gid(comp)
        if not cur then
            stats.no_info = (stats.no_info or 0) + 1
            return 0
        end
        remember_vanilla(comp, cur)
        -- nom du GameObject = mesh Capcom du spot (ItemID peut déjà être une clé)
        local vanilla = go_gid(comp) or vanilla_of(comp, cur)

        local info = try(function() return ctx.read_item(comp) end)
        if not info then
            stats.no_info = (stats.no_info or 0) + 1
            return 0
        end
        info.item_id = vanilla
        local loc = select(1, ctx.resolve_location(info.keys, vanilla, info.pos))
        if not loc then
            stats.no_loc = (stats.no_loc or 0) + 1
            return 0
        end
        stats.resolved = (stats.resolved or 0) + 1

        local want = target_gid(loc.id, vanilla)
        -- Storage / Map / Procedure : pas de prompt. Mesh ramassable, une seule fois.
        local live = ctx.is_active and ctx.is_active(loc.id)
            and not (ctx.is_checked and ctx.is_checked(loc.id))
        if live and no_volume(vanilla) then
            local mesh = (want and not is_bad_mesh(want)) and want or PLACEHOLDER
            if cur ~= mesh then
                if write_gid(comp, mesh) then
                    rebuild_mesh(comp)
                    stats.rewrote = (stats.rewrote or 0) + 1
                    return 1
                end
                stats.fail = (stats.fail or 0) + 1
                return 0
            end
            rebuild_mesh(comp)
            stats.same = (stats.same or 0) + 1
            return 0
        end
        if not want then
            -- déjà rewrite vers une clé / Joint Plug : remettre le mesh du spot
            local bad = cur and vanilla and vanilla ~= cur and is_bad_mesh(cur)
            if bad and write_gid(comp, vanilla) then
                stats.rewrote = (stats.rewrote or 0) + 1
                return 1
            end
            stats.skip = (stats.skip or 0) + 1
            return 0
        end
        if want == cur then
            stats.same = (stats.same or 0) + 1
            return 0
        end

        if write_gid(comp, want) then
            stats.rewrote = (stats.rewrote or 0) + 1
            return 1
        end
        stats.fail = (stats.fail or 0) + 1
        return 0
    end

    function ctx.apply_ap_visual_models()
        if ctx.AP_VISUAL_ENABLED == false then return 0 end
        if not (ctx.session and ctx.session.scouts) then return 0 end

        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
        if not scene then return 0 end
        local cores = elements(scene:call("findComponents(System.Type)", sdk.typeof("app.ItemCore")))
        local stats = {
            cores = #cores, resolved = 0, rewrote = 0, same = 0,
            no_loc = 0, skip = 0, fail = 0, no_info = 0,
        }
        local n = 0
        for _, comp in ipairs(cores) do
            n = n + (apply_one(comp, stats) or 0)
        end

        ticks = ticks + 1
        local msg = string.format(
            "mesh=AP : cores=%d rewrite=%d skip=%d same=%d",
            stats.cores, stats.rewrote, stats.skip, stats.same)
        local key = string.format("%d/%d/%d", stats.cores, stats.rewrote, stats.skip)
        if msg ~= last_msg and (ticks <= 8 or key ~= last_key) then
            last_msg, last_key = msg, key
            ctx.info("visuel " .. msg)
        end
        return n
    end

    local function install_hooks()
        if hooked then return end
        local td = sdk.find_type_definition("app.ItemCore")
        if not td then return end
        local installed = 0
        for _, m in ipairs(try(function() return td:get_methods() end) or {}) do
            local name = try(function() return m:get_name() end)
            local low = name and string.lower(name) or ""
            if low:find("^setup") or low:find("onenable") or low == "start" or low == "awake" then
                local ok = pcall(function()
                    sdk.hook(m, function(args)
                        if ctx.AP_VISUAL_ENABLED == false then return end
                        local comp = sdk.to_managed_object(args[2])
                        if not comp then return end
                        local dummy = {
                            cores = 0, resolved = 0, rewrote = 0, same = 0,
                            no_loc = 0, skip = 0, fail = 0, no_info = 0,
                        }
                        pcall(function() apply_one(comp, dummy) end)
                    end, function(retval) return retval end)
                end)
                if ok then installed = installed + 1 end
            end
        end
        hooked = true
        ctx.info(string.format("visuel : %d hook(s) ItemCore (mesh = item AP)", installed))
    end

    install_hooks()

    ctx.on_tick("ap_visual", function()
        if not ctx.is_game_ready or not ctx.is_game_ready() then return end
        pcall(ctx.apply_ap_visual_models)
    end, { every = 0.75 })

    ctx.info("visuel : mesh Capcom = item multiworld (autre jeu → " .. PLACEHOLDER .. ")")
end
