return function(ctx)
    ctx.items_by_id = {}
    ctx.items_by_name = {}
    ctx.ap_items = {}
    ctx.locations = {}         -- "7091000" -> { id, name, chapter, item_id, amount, x, y, z }
    ctx.chapters = {}
    ctx.location_count = 0
    ctx.ap_item_count = 0
    ctx.item_count = 0

    local loc_by_key = {}
    local loc_by_base = {}     -- clé sans @ -> { { id, x, y, z }, ... }
    local locs_by_item = {}
    local item_category = {}

    local function load_item_list()
        local data = json.load_file(ctx.FILES.item_list) or json.load_file("item_list.json")
        if type(data) ~= "table" or type(data.items) ~= "table" then
            ctx.warn("item_list.json introuvable : les noms d'objets ne seront pas résolus")
            return
        end
        for _, it in ipairs(data.items) do
            if type(it) == "table" and it.id and it.name then
                local entry = { id = it.id, name = it.name, category = it.category or "" }
                ctx.items_by_id[it.id] = entry
                local lname = string.lower(it.name)
                if ctx.items_by_name[lname] == nil then ctx.items_by_name[lname] = entry end
                ctx.item_count = ctx.item_count + 1
            end
        end
    end

    local function split_key(key)
        local base, x, y, z = key:match("^(.-)@(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
        if base then return base, tonumber(x), tonumber(y), tonumber(z) end
        return key, nil, nil, nil
    end

    local function load_ids()
        local data = json.load_file(ctx.FILES.ids)
        if type(data) ~= "table" or type(data.locations) ~= "table" then
            ctx.err("re9_ap_ids.json introuvable ou invalide (reframework\\data\\ArchipelagoRE9\\) : aucun check ne sera détecté")
            return
        end
        for _, c in ipairs(type(data.chapters) == "table" and data.chapters or {}) do
            ctx.chapters[#ctx.chapters + 1] = tostring(c)
        end

        for _, loc in ipairs(data.locations) do
            local id = ctx.id_str(loc.id)
            if id then
                local pos = type(loc.pos) == "table" and loc.pos or {}
                local diffs = nil
                if type(loc.difficulties) == "table" and #loc.difficulties > 0 then
                    diffs = {}
                    for _, d in ipairs(loc.difficulties) do diffs[string.lower(tostring(d))] = true end
                end
                local entry = {
                    id = id, name = tostring(loc.name or id), chapter = tostring(loc.chapter or ""),
                    zone = tostring(loc.zone or ""),
                    item_id = tostring(loc.vanilla_game_id or ""), amount = tonumber(loc.amount) or 1,
                    vanilla_item = tostring(loc.vanilla_item or ""), difficulties = diffs,
                    x = tonumber(pos[1]), y = tonumber(pos[2]), z = tonumber(pos[3]),
                }
                ctx.locations[id] = entry
                ctx.location_count = ctx.location_count + 1
                if entry.item_id ~= "" and entry.x then
                    locs_by_item[entry.item_id] = locs_by_item[entry.item_id] or {}
                    table.insert(locs_by_item[entry.item_id], entry)
                end
            end
        end

        for key, lid in pairs(type(data.location_by_key) == "table" and data.location_by_key or {}) do
            local id = ctx.id_str(lid)
            if id and type(key) == "string" then
                local lkey = string.lower(key)
                loc_by_key[lkey] = id
                local base, x, y, z = split_key(lkey)
                if x then
                    loc_by_base[base] = loc_by_base[base] or {}
                    table.insert(loc_by_base[base], { id = id, x = x, y = y, z = z })
                end
            end
        end

        for code, it in pairs(type(data.items) == "table" and data.items or {}) do
            if type(it) == "table" and it.game_id then
                local category = it.category
                if type(category) == "table" then category = category[1] end
                ctx.ap_items[tostring(code)] = {
                    name = tostring(it.name or code), game_id = tostring(it.game_id),
                    amount = math.max(1, math.floor(tonumber(it.amount) or 1)),
                    category = tostring(category or ""),
                }
                if it.name then item_category[tostring(it.name)] = tostring(category or "") end
                ctx.ap_item_count = ctx.ap_item_count + 1
            end
        end
    end

    -- distance² : assez pour comparer (évite sqrt sur le hot path resolve)
    local function dist2(a, x, y, z)
        if not (a.x and x) then return math.huge end
        local dx, dy, dz = a.x - x, a.y - y, a.z - z
        return dx * dx + dy * dy + dz * dz
    end

    -- des objets identiques empilés au même endroit sont des emplacements distincts
    local function pick_nearest(candidates, x, y, z, tolerance)
        local tol2 = tolerance * tolerance
        local best, best_d2, free, free_d2 = nil, tol2, nil, tol2
        for i = 1, #candidates do
            local c = candidates[i]
            local d2 = dist2(c, x, y, z)
            if d2 < best_d2 then best, best_d2 = c.id, d2 end
            if d2 < free_d2 and not ctx.is_checked(c.id) then free, free_d2 = c.id, d2 end
        end
        if free then return free, math.sqrt(free_d2) end
        return best, best and math.sqrt(best_d2) or nil
    end

    -- refusée si la base est partagée ou si la position contredit l'emplacement
    local function exact_ok(k, id, x, y, z)
        local list = loc_by_base[k]
        if list then
            for i = 1, #list do
                if list[i].id ~= id then return false end
            end
        end
        local loc = ctx.locations[id]
        local max2 = ctx.EXACT_KEY_MAX_DIST * ctx.EXACT_KEY_MAX_DIST
        if x and loc and loc.x and dist2(loc, x, y, z) > max2 then return false end
        return true
    end

    -- keys déjà en minuscules ; item_tol optionnel (pots cassés : objet un peu déplacé)
    function ctx.resolve_location(keys, item_id, pos, item_tol)
        local x, y, z = pos and pos.x, pos and pos.y, pos and pos.z
        keys = keys or {}

        for _, k in ipairs(keys) do
            local id = loc_by_key[k]
            if id and exact_ok(k, id, x, y, z) then return ctx.locations[id], "clé" end
        end

        local candidates = {}
        for _, k in ipairs(keys) do
            local list = loc_by_base[k]
            if list then
                if not x and #list == 1 then return ctx.locations[list[1].id], "clé (sans position)" end
                for _, c in ipairs(list) do candidates[#candidates + 1] = c end
            end
        end
        local id, d = pick_nearest(candidates, x, y, z, ctx.KEY_POS_TOLERANCE)
        local tol = tonumber(item_tol) or ctx.ITEM_POS_TOLERANCE
        local iid, idist = pick_nearest(locs_by_item[tostring(item_id or "")] or {}, x, y, z, tol)
        if id and (not ctx.is_checked(id) or not iid or ctx.is_checked(iid)) then
            return ctx.locations[id], string.format("clé + position (%.2f m)", d)
        end
        if iid then return ctx.locations[iid], string.format("objet + position (%.2f m)", idist) end
        return nil, nil
    end

    local STORY_NAMES = {
        ["Screwdriver"] = true,
        ["Lighter"] = true, ["Flashlight"] = true,
        ["Override Manual"] = true, ["Unknown Item (it99_05_002)"] = true,
    }

    function ctx.is_story_name(name)
        return STORY_NAMES[name] == true
    end

    -- progressif = clé, drapeau, lockpick. Mélangé = check, sauf le set histoire.
    function ctx.is_progression_name(name)
        if type(name) ~= "string" or name == "" then return false end
        local c = item_category[name]
        return c == "KeyItem" or c == "Flag" or name == "Lockpick"
    end

    function ctx.compute_active(difficulty, key_items, flag_items, enemy_drops_n, supply_box)
        local diff = string.lower(tostring(difficulty or ""))
        if diff == "" then return nil end
        local shop_off = supply_box == false or supply_box == "false" or supply_box == "0"
        local active, n = {}, 0
        for id, loc in pairs(ctx.locations) do
            local held = ctx.is_story_name(loc.vanilla_item)
            local shop_line = (loc.name or ""):sub(1, 13) == "Supply Box - "
            if loc.chapter ~= "Drop"
                and not (ctx.VANILLA_LOCATIONS and ctx.VANILLA_LOCATIONS[id])
                and (loc.difficulties == nil or loc.difficulties[diff])
                and not held
                and not (shop_off and shop_line) then
                active[id] = true
                n = n + 1
            end
        end
        local want = math.floor(tonumber(enemy_drops_n) or 0)
        if want > 0 then
            local drops = {}
            for id, loc in pairs(ctx.locations) do
                if loc.chapter == "Drop" then drops[#drops + 1] = id end
            end
            table.sort(drops, function(a, b) return tonumber(a) < tonumber(b) end)
            for i = 1, math.min(want, #drops) do
                active[drops[i]] = true
                n = n + 1
            end
        end
        return active, n
    end

    function ctx.item_display_name(item_id)
        local id = tostring(item_id or ""):match("([%w_]+)$") or ""
        local e = ctx.items_by_id[id]
        return e and e.name or id
    end

    -- slot_data, puis re9_ap_ids.json, puis le nom
    function ctx.resolve_ap_item(code, ap_name)
        local key = ctx.id_str(code)
        local mapped = key and ctx.session.items[key]
        if mapped then return mapped.id, mapped.count end
        local known = key and ctx.ap_items[key]
        if known then return known.game_id, known.amount end

        if type(ap_name) ~= "string" or ap_name == "" then return nil end
        local tagged = ap_name:match("%((it[%d_]+)%)$")
        if tagged and ctx.items_by_id[tagged] then return tagged, 1 end
        local direct = ctx.items_by_name[string.lower(ap_name)] or ctx.items_by_id[ap_name]
        if direct then return direct.id, 1 end
        return nil
    end

    load_item_list()
    load_ids()
end
