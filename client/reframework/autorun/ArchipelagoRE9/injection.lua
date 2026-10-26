return function(ctx)
    local try = ctx.try

    local item_id_td = sdk.find_type_definition("app.ItemID")

    local enum_names = nil
    local function build_enum_names()
        enum_names = {}
        for _, f in ipairs(try(function() return item_id_td:get_fields() end) or {}) do
            local v = try(function() return f:get_data(nil) end)
            local n = try(function() return f:get_name() end)
            if v ~= nil and n and type(v) ~= "userdata" then enum_names[v] = n end
        end
    end

    local function item_id_to_name(id_obj)
        if id_obj == nil or item_id_td == nil then return "nil" end
        if enum_names == nil then build_enum_names() end
        if type(id_obj) ~= "userdata" and enum_names[id_obj] then return enum_names[id_obj] end
        for _, f in ipairs(try(function() return item_id_td:get_fields() end) or {}) do
            local fval = try(function() return f:get_data(nil) end)
            if fval == id_obj then return try(function() return f:get_name() end) or "?" end
        end
        return "unknown"
    end

    local function get_box()
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        if not mgr then return nil end
        local elems = try(function()
            return mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end)
        if not elems then return nil end
        local entry = elems[ctx.BOX_INVENTORY_INDEX + 1]
        return entry and (
            try(function() return entry:get_field("value") end) or
            try(function() return entry:get_field("_value") end) or
            try(function() return entry:get_field("Value") end)
        )
    end

    local function get_item_id_enum(item_id)
        local field = item_id_td and try(function() return item_id_td:get_field(item_id) end)
        return field and try(function() return field:get_data(nil) end)
    end
    ctx.item_enum = get_item_id_enum

    local try_detail_method = true
    local detail_cache = {}   -- item_id -> detail | false

    local function get_item_detail(item_id)
        local hit = detail_cache[item_id]
        if hit ~= nil then return hit or nil end

        local mgr = sdk.get_managed_singleton("app.ItemManager")
        if not mgr then return nil end
        local target = get_item_id_enum(item_id)
        if not target then
            detail_cache[item_id] = false
            return nil
        end

        -- tryGetItemDetail(id) n'a pas cette signature dans RE9, on lâche au premier échec
        for _, m in ipairs(try_detail_method and try(function() return mgr:get_type_definition():get_methods() end) or {}) do
            if try(function() return m:get_name() end) == "tryGetItemDetail" then
                local ok, ret = pcall(function() return m:call(mgr, target) end)
                if ok and ret and try(function()
                    return ret:get_type_definition():get_full_name()
                end) == "app.ItemDetailData" then
                    detail_cache[item_id] = ret
                    return ret
                end
                try_detail_method = false
            end
        end

        local elems = try(function()
            return mgr:get_field("_ItemCatalog"):get_field("_Dict"):get_field("_entries"):get_elements()
        end) or {}
        for _, e in ipairs(elems) do
            local k = try(function() return e:get_field("key") end)
            if k and item_id_to_name(k) == item_id then
                local v = try(function() return e:get_field("value") end)
                local detail = try(function() return v:get_field("_Value") end) or v
                detail_cache[item_id] = detail or false
                return detail
            end
        end
        detail_cache[item_id] = false
        return nil
    end

    local function get_box_capacity(detail)
        local scd = detail and try(function() return detail:get_field("_SlotCapacityData") end)
        return (scd and (
            try(function() return scd:get_field("_BaseItemBoxCapacity") end) or
            try(function() return scd:get_field("_BaseCapacity") end)
        )) or 99
    end

    local function panel_infos(box)
        local out = {}
        local elems = try(function()
            return box:get_field("_PanelItems"):get_field("_entries"):get_elements()
        end) or {}
        for _, e in ipairs(elems) do
            local info = try(function() return e:get_field("value") end)
            if info then out[#out + 1] = info end
        end
        return out
    end

    local function panel_item_name(info)
        local state = try(function() return info:get_field("_PanelState") end)
        local id = state and try(function() return state:get_field("<ItemID>k__BackingField") end)
        return item_id_to_name(id)
    end

    local function find_panel_info(box, item_id)
        local best, best_room = nil, -1
        for _, info in ipairs(panel_infos(box)) do
            if panel_item_name(info) == item_id then
                local stock = try(function() return info:get_field("_Stock") end) or 0
                local cap   = try(function() return info:get_field("_StockCapacity") end) or 1
                if (cap - stock) > best_room then
                    best_room, best = cap - stock, info
                end
            end
        end
        return best, best_room
    end

    local function set_stock(info, stock, cap)
        pcall(function() info:set_field("_StockCapacity", cap) end)
        pcall(function() info:set_field("_Stock", stock) end)
        local state = try(function() return info:get_field("_PanelState") end)
        if state then
            pcall(function() state:set_field("<StockCapacity>k__BackingField", cap) end)
            pcall(function() state:set_field("<Stock>k__BackingField", stock) end)
        end
    end

    local add_panel_method = nil
    do
        local inv_td = sdk.find_type_definition("app.Inventory")
        for _, m in ipairs(inv_td and (try(function() return inv_td:get_methods() end) or {}) or {}) do
            if try(function() return m:get_name() end) == "addPanelImpl" then
                add_panel_method = m
                break
            end
        end
    end
    if not add_panel_method then ctx.warn("app.Inventory.addPanelImpl introuvable : injection limitée aux piles existantes") end

    local function create_slot_address()
        local td = sdk.find_type_definition("app.Inventory.SlotAddress")
        return td and (try(function() return td:create_instance(true) end)
                   or  try(function() return td:create_instance() end))
    end

    local function refresh_ui()
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local stock_event = mgr and try(function() return mgr:get_field("StockChangedEvent") end)
        if not stock_event then return end
        local args_td = sdk.find_type_definition("app.InventoryStockEventArgs")
        local event_args = args_td and (
            try(function() return args_td:create_instance(true) end) or
            try(function() return args_td:create_instance() end)
        )
        if not event_args then return end
        -- Action<InventoryStockEventArgs>.Invoke ne prend qu'un argument
        local ok = pcall(function() stock_event:call("Invoke", event_args) end)
        if not ok then
            pcall(function()
                for _, m in ipairs(try(function() return stock_event:get_type_definition():get_methods() end) or {}) do
                    if try(function() return m:get_name() end) == "Invoke" then
                        m:call(stock_event, event_args)
                        return
                    end
                end
            end)
        end
    end

    local function plain_value(v)
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then return v end
        if t == "userdata" then
            local s = try(function() return v:call("ToString()") end)
            if type(s) == "string" and #s <= 200 then return s end
        end
        return nil
    end

    local function object_fields(obj, depth)
        local out = {}
        local td = try(function() return obj:get_type_definition() end)
        while td and try(function() return td:get_full_name() end) ~= "System.Object" do
            for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
                local name = try(function() return f:get_name() end)
                if name and out[name] == nil and not try(function() return f:is_static() end) then
                    local raw = try(function() return obj:get_field(name) end)
                    local sub = depth > 0 and type(raw) == "userdata"
                        and try(function() return raw:get_type_definition():get_full_name() end)
                    if sub and sub:find("^app%.") and sub:find("Data$") then
                        out[name] = object_fields(raw, depth - 1)
                    else
                        local v = plain_value(raw)
                        if v ~= nil then out[name] = v end
                    end
                end
            end
            td = try(function() return td:get_parent_type() end)
        end
        return out
    end

    function ctx.export_item_ids()
        if not item_id_td then return false, "type app.ItemID introuvable" end
        local list, by_value = {}, {}
        for _, f in ipairs(try(function() return item_id_td:get_fields() end) or {}) do
            if try(function() return f:is_static() end) then
                local name = try(function() return f:get_name() end)
                local val = try(function() return f:get_data(nil) end)
                if name and val ~= nil then
                    local e = { id = name, value = tonumber(val) or tostring(val) }
                    local known = ctx.items_by_id[name]
                    if known then e.name, e.category = known.name, known.category end
                    list[#list + 1] = e
                    by_value[tostring(e.value)] = e
                end
            end
        end

        local in_catalog = 0
        local mgr = sdk.get_managed_singleton("app.ItemManager")
        local entries = mgr and try(function()
            return mgr:get_field("_ItemCatalog"):get_field("_Dict"):get_field("_entries"):get_elements()
        end) or {}
        for _, ent in ipairs(entries) do
            local k = try(function() return ent:get_field("key") end)
            if type(k) == "userdata" then k = try(function() return k:get_field("value__") end) end
            local e = k ~= nil and by_value[tostring(tonumber(k) or k)] or nil
            if e and not e.in_catalog then
                local v = try(function() return ent:get_field("value") end)
                local detail = v and (try(function() return v:get_field("_Value") end) or v)
                if detail then
                    e.in_catalog = true
                    e.detail_type = try(function() return detail:get_type_definition():get_full_name() end)
                    e.fields = object_fields(detail, 1)
                    in_catalog = in_catalog + 1
                end
            end
        end

        local file = ctx.DATA_DIR .. "item_export.json"
        local ok, e = pcall(function()
            json.dump_file(file, {
                exported = os.date("%Y-%m-%d %H:%M:%S"),
                enum_count = #list,
                catalog_count = in_catalog,
                items = list,
            }, 4)
        end)
        if not ok then return false, tostring(e) end
        ctx.info(string.format("export : %d ItemID, %d dans le catalogue -> reframework/data/%s", #list, in_catalog, file))
        return true, string.format("%d objets exportés (%d dans le catalogue)", #list, in_catalog)
    end

    local function deep_fields(obj, depth, seen)
        local out = {}
        local addr = try(function() return obj:get_address() end)
        if addr then
            if seen[addr] then return "(déjà vu)" end
            seen[addr] = true
        end
        local td = try(function() return obj:get_type_definition() end)
        out["@type"] = td and try(function() return td:get_full_name() end)
        while td and try(function() return td:get_full_name() end) ~= "System.Object" do
            for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
                local name = try(function() return f:get_name() end)
                if name and out[name] == nil and not try(function() return f:is_static() end) then
                    local raw = try(function() return obj:get_field(name) end)
                    local sub = type(raw) == "userdata" and try(function() return raw:get_type_definition():get_full_name() end)
                    if sub and depth > 0 and sub:find("^app%.") then
                        out[name] = deep_fields(raw, depth - 1, seen)
                    else
                        local v = plain_value(raw)
                        if v ~= nil then out[name] = v end
                    end
                end
            end
            td = try(function() return td:get_parent_type() end)
        end
        return out
    end

    local PROBE_SINGLETONS = {
        "app.PlayerManager", "app.CharacterManager", "app.PlayerContextManager", "app.GameManager",
        "app.MainGameManager", "app.ScenarioManager", "app.GameFlowManager", "app.ChapterManager",
        "app.PlayerSwitchManager", "app.CharacterSwitchManager", "app.InventoryManager", "app.ItemManager",
        "app.SaveDataManager", "app.GimmickManager", "app.EquipmentManager", "app.WeaponManager",
    }

    function ctx.export_character_probe()
        local result = { exported = os.date("%Y-%m-%d %H:%M:%S"), singletons = {}, inventories = {}, box_panels = {}, details = {} }
        for _, name in ipairs(PROBE_SINGLETONS) do
            local s = try(function() return sdk.get_managed_singleton(name) end)
            if s then result.singletons[name] = deep_fields(s, 1, {}) end
        end

        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local entries = mgr and try(function()
            return mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end) or {}
        for i, e in ipairs(entries) do
            local key = try(function() return e:get_field("key") end)
            local inv = try(function() return e:get_field("value") end)
            local panels = {}
            for _, info in ipairs(inv and panel_infos(inv) or {}) do
                panels[#panels + 1] = { item = panel_item_name(info), fields = deep_fields(info, 2, {}) }
            end
            result.inventories[#result.inventories + 1] = {
                index = i - 1, key = plain_value(key) or tostring(key),
                fields = inv and deep_fields(inv, 0, {}) or nil, panels = panels,
            }
        end

        local box = get_box()
        local done = {}
        for _, info in ipairs(box and panel_infos(box) or {}) do
            local id = panel_item_name(info)
            if not done[id] then
                done[id] = true
                local detail = get_item_detail(id)
                if detail then result.details[id] = deep_fields(detail, 2, {}) end
            end
        end

        local file = ctx.DATA_DIR .. "character_probe.json"
        local ok, e = pcall(function() json.dump_file(file, result, 4) end)
        if not ok then return false, tostring(e) end
        ctx.info("analyse des personnages -> reframework/data/" .. file)
        return true, file
    end

    -- ItemDetailData._NameMessageId -> via.gui.message.get
    ctx.localized_names = {}
    local msg_get = nil
    local function message_text(guid)
        msg_get = msg_get or try(function()
            return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
        end)
        if not msg_get then return nil end
        local s = try(function() return msg_get:call(nil, guid) end)
        if type(s) == "string" and s ~= "" and not s:find("^Rejected") then return s end
        return nil
    end

    function ctx.game_item_name(game_id)
        if not game_id then return nil end
        local cached = ctx.localized_names[game_id]
        if cached ~= nil then return cached or nil end
        local detail = get_item_detail(game_id)
        local guid = detail and try(function() return detail:get_field("_NameMessageId") end)
        local text = guid and message_text(guid)
        ctx.localized_names[game_id] = text or false
        return text
    end

    -- un nom par appel, à chaque tick
    local name_queue = nil
    function ctx.resolve_names_step()
        if name_queue == nil then
            name_queue = {}
            for _, it in pairs(ctx.ap_items) do name_queue[#name_queue + 1] = it.game_id end
        end
        local gid = name_queue[#name_queue]
        if not gid then return end
        name_queue[#name_queue] = nil
        pcall(ctx.game_item_name, gid)
    end

    -- "leon", "grace" ou nil ; nil = comportement normal, rien n'est retenu
    local kind_td = sdk.find_type_definition("app.CharacterKindID")
    local kind_names = nil
    local function kind_text(v)
        if v == nil then return nil end
        if type(v) == "userdata" then
            local s = try(function() return v:call("ToString()") end)
            if type(s) == "string" and s ~= "" then return s end
            v = try(function() return v:get_field("value__") end)
        end
        if kind_names == nil then
            kind_names = {}
            for _, f in ipairs(kind_td and (try(function() return kind_td:get_fields() end) or {}) or {}) do
                local fv = try(function() return f:get_data(nil) end)
                local n = try(function() return f:get_name() end)
                if fv ~= nil and n and type(fv) ~= "userdata" then kind_names[fv] = n end
            end
        end
        return v ~= nil and (kind_names[v] or tostring(v)) or nil
    end

    ctx.current_kind = nil
    function ctx.current_character()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local pc = mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
        if not pc then return nil end
        local text = kind_text(try(function() return pc:get_field("<KindID>k__BackingField") end))
        if not text then return nil end
        if text ~= ctx.current_kind then
            ctx.current_kind = text
            ctx.info("personnage joué : " .. text)
        end
        local low = string.lower(text)
        for who, patterns in pairs(ctx.CHARACTER_PATTERNS) do
            for _, p in ipairs(patterns) do
                if low:find(p) then return who end
            end
        end
        return nil
    end

    function ctx.player_inventory_user()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local pc = mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
        local user = pc and try(function() return pc:call("get_InventoryUserID") end)
        local name = user and (try(function() return user:get_field("_Name") end) or try(function() return user:call("ToString") end))
        if name == nil then return nil end
        name = tostring(name)
        return name:find("^User%d+$") and name or nil
    end

    -- _InventoryKey : _BoardType 0 = Hand, _User._Name "User00"...
    local HAND_BOARD = 0
    local function get_hand(user_name)
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local elems = mgr and try(function()
            return mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end) or {}
        for _, entry in ipairs(elems) do
            local inv = try(function() return entry:get_field("value") end)
            local key = inv and try(function() return inv:get_field("_InventoryKey") end)
            local board = key and try(function() return key:get_field("_BoardType") end)
            local user = key and try(function() return key:get_field("_User") end)
            local name = user and try(function() return user:get_field("_Name") end)
            if board ~= nil and tonumber(board) == HAND_BOARD and name ~= nil and tostring(name) == user_name then
                return inv
            end
        end
        return nil
    end

    local inv_td = sdk.find_type_definition("app.Inventory")
    local hand_merge = inv_td and try(function()
        return inv_td:get_method("mergeOrAdd(app.ItemID, System.Int32, System.Boolean, app.Inventory.AcquireItemOptions, app.ItemStockChangedEventType)")
    end)
    local hand_can_merge = inv_td and try(function()
        return inv_td:get_method("canMergeOrAdd(app.ItemID, System.Int32, System.Boolean)")
    end)
    local function static_value(type_name, field_name)
        local td = sdk.find_type_definition(type_name)
        local f = td and try(function() return td:get_field(field_name) end)
        return f and try(function() return f:get_data(nil) end)
    end

    local function array_len(arr)
        return arr and (try(function() return arr:get_size() end) or try(function() return #arr:get_elements() end)) or 0
    end

    local hand_count = inv_td and try(function() return inv_td:get_method("countStock(app.ItemID)") end)

    local function hand_fits(inv, id, n)
        if not hand_can_merge then return true end
        local ok, fits = pcall(function() return hand_can_merge:call(inv, id, n, false) end)
        return not ok or fits ~= false
    end

    function ctx.inject_to_hand(item_id, quantity, user_name)
        quantity = math.max(1, math.floor(tonumber(quantity) or 1))
        if not hand_merge then return 0, "mergeOrAdd introuvable" end
        local inv = get_hand(user_name)
        if not inv then return 0, "inventaire " .. tostring(user_name) .. " introuvable" end
        local id = get_item_id_enum(item_id)
        if id == nil then return 0, "objet inconnu " .. tostring(item_id) end
        local n = quantity
        if not hand_fits(inv, id, n) then
            local lo, hi = 0, quantity - 1
            while lo < hi do
                local mid = (lo + hi + 1) // 2
                if hand_fits(inv, id, mid) then lo = mid else hi = mid - 1 end
            end
            n = lo
            if n == 0 then return 0, "inventaire " .. tostring(user_name) .. " plein ou objet refusé" end
        end
        local function stock()
            return hand_count and tonumber(try(function() return hand_count:call(inv, id) end)) or nil
        end
        local before = stock()
        local options = static_value("app.Inventory.AcquireItemOptions", "Default")
        local event = static_value("app.ItemStockChangedEventType", "Default")
        local ok, result = pcall(function() return hand_merge:call(inv, id, n, false, options, event) end)
        if not ok or result == nil then return 0, "mergeOrAdd a échoué : " .. tostring(result) end
        -- si le jeu n'accepte pas tout, la variation du stock dit combien est vraiment entré
        local processed = array_len(try(function() return result:call("get_ProcessedItems") end))
        local skipped = array_len(try(function() return result:call("get_SkippedItems") end))
        local added = 0
        if processed > 0 and skipped == 0 then
            added = n
        else
            local after = stock()
            if before and after then added = math.max(0, math.min(n, after - before)) end
        end
        if added > 0 then refresh_ui() end
        if added == 0 then return 0, "refusé par le jeu" end
        return added
    end

    -- KeyItem / Flag : sans Acquired+Pickedup, le jeu a l'objet mais refuse usage / cinématiques
    -- Pattern RE4R pickup_event_flags : au check (swap) et à la réception, rejouer les flags
    local STORY_FLAG_CATEGORIES = { Flag = true, KeyItem = true }

    local pickup_event_flags = nil
    local pickup_event_items = nil
    local function ensure_pickup_event_flags()
        if pickup_event_flags ~= nil then return end
        pickup_event_flags, pickup_event_items = {}, {}
        local payload = json.load_file(ctx.FILES.pickup_flags)
        if type(payload) ~= "table" then return end
        if type(payload.locations) == "table" then
            for id, entry in pairs(payload.locations) do
                if type(entry) == "table" and type(entry.game_id) == "string" then
                    pickup_event_flags[tostring(id)] = {
                        name = entry.name,
                        game_id = entry.game_id,
                        item = entry.item,
                        retro_heal = entry.retro_heal == true,
                    }
                end
            end
        end
        if type(payload.items) == "table" then
            for gid, entry in pairs(payload.items) do
                if type(entry) == "table" then
                    pickup_event_items[tostring(gid)] = entry
                end
            end
        end
    end

    -- réception AP : Flag + KeyItem (usage / portes)
    function ctx.needs_story_flag(game_id)
        if type(game_id) ~= "string" or game_id == "" then return false end
        ensure_pickup_event_flags()
        if pickup_event_items[game_id] then return true end
        if ctx.should_keep_vanilla and ctx.should_keep_vanilla(game_id) then return true end
        if ctx.ALWAYS_HAND_ITEMS and ctx.ALWAYS_HAND_ITEMS[game_id] then return true end
        local known = ctx.items_by_id and ctx.items_by_id[game_id]
        if known and STORY_FLAG_CATEGORIES[known.category] then return true end
        for _, it in pairs(ctx.ap_items or {}) do
            if it.game_id == game_id and STORY_FLAG_CATEGORIES[tostring(it.category or "")] then return true end
        end
        return false
    end

    -- au CHECK monde : uniquement Flag / NEVER_BLOCK / liste pickup_event
    -- (pas toutes les KeyItem → sinon Acquired sur chaque spot clé)
    local function is_location_check_flag(game_id)
        if type(game_id) ~= "string" or game_id == "" then return false end
        ensure_pickup_event_flags()
        if pickup_event_items[game_id] then return true end
        if ctx.should_keep_vanilla and ctx.should_keep_vanilla(game_id) then return true end
        local known = ctx.items_by_id and ctx.items_by_id[game_id]
        if known and known.category == "Flag" then return true end
        for _, it in pairs(ctx.ap_items or {}) do
            if it.game_id == game_id and tostring(it.category or "") == "Flag" then return true end
        end
        return false
    end

    local function hashset_add(set, id)
        if set == nil or id == nil then return false end
        if pcall(function() set:call("Add", id) end) then return true end
        if pcall(function() set:call("Add(app.ItemID)", id) end) then return true end
        if pcall(function() set:call("System.Collections.Generic.HashSet`1.Add", id) end) then return true end
        return false
    end

    local function mgr_get_set(mgr, names)
        for _, name in ipairs(names) do
            local set = try(function() return mgr:get_field(name) end)
                or try(function() return mgr:call("get_" .. name:gsub("^_", "")) end)
            if set ~= nil then return set, name end
        end
        return nil, nil
    end

    local function item_id_uint_local(id)
        if id == nil then return nil end
        local v = try(function() return id:get_field("value__") end)
        if v ~= nil then return math.floor(tonumber(v) or 0) end
        local n = try(function() return sdk.to_int64(id) end)
        return n and math.floor(n & 0xFFFFFFFF) or nil
    end

    -- briquet / lampe : HasLighter doit être posé même si AcquiredIDSet a déjà réussi
    local pending_blackboard = {} -- game_id -> tries restantes
    local blackboard_done = {} -- game_id → true une fois HasLighter/HasFlashLight OK cette session

    local function scene_now()
        return try(function()
            return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
        end)
    end

    local function components_of(scene, type_name)
        if not scene then return {} end
        local ty = try(function() return sdk.typeof(type_name) end)
        if not ty then return {} end
        local arr = try(function() return scene:call("findComponents(System.Type)", ty) end)
        if not arr then return {} end
        local elems = try(function() return arr:get_elements() end)
        if type(elems) == "table" and #elems > 0 then return elems end
        local out, len = {}, tonumber(try(function() return arr:call("get_Count()") end)) or 0
        for i = 0, len - 1 do
            local e = try(function() return arr:call("get_Item(System.Int32)", i) end)
            if e then out[#out + 1] = e end
        end
        return out
    end

    local function collect_flashlight_bb()
        local scene = scene_now()
        local seen, list = {}, {}
        local function add(bb)
            if not bb then return end
            local addr = try(function() return bb:get_address() end) or bb
            if seen[addr] then return end
            seen[addr] = true
            list[#list + 1] = bb
        end
        for _, bb in ipairs(components_of(scene, "app.FlashLightBlackboardUnit")) do add(bb) end
        -- fallback : ref sur le contrôleur de main
        for _, ctrl in ipairs(components_of(scene, "app.PlayerHandMaterialController")) do
            add(try(function() return ctrl:get_field("_FlashLightBlackboardUnit_k__BackingField") end)
                or try(function() return ctrl:call("get_FlashLightBlackboardUnit") end))
        end
        for _, ctrl in ipairs(components_of(scene, "app.FlashLightController")) do
            add(try(function() return ctrl:get_field("_BlackboardUnit") end)
                or try(function() return ctrl:get_field("_FlashLightBlackboardUnit_k__BackingField") end)
                or try(function() return ctrl:call("get_FlashLightBlackboardUnit") end))
        end
        return list
    end

    local function set_bb_flag(bb, which, field)
        local ok = false
        if field and pcall(function() bb:set_field(field, true) end) then ok = true end
        if pcall(function() bb:call("set_" .. which, true) end) then ok = true end
        if pcall(function() bb:call("set_" .. which .. "(System.Boolean)", true) end) then ok = true end
        return ok
    end

    local function apply_flag_blackboard(game_id)
        ensure_pickup_event_flags()
        local meta = pickup_event_items[game_id]
        local which = meta and meta.blackboard
        if not which then return false end
        local field = which == "HasLighter" and "_HasLighter_k__BackingField"
            or which == "HasFlashLight" and "_HasFlashLight_k__BackingField"
            or nil
        local bbs = collect_flashlight_bb()
        local n = 0
        for _, bb in ipairs(bbs) do
            if set_bb_flag(bb, which, field) then n = n + 1 end
        end
        if n > 0 then
            blackboard_done[game_id] = true
            pending_blackboard[game_id] = nil
            ctx.info(string.format("blackboard %s = true (%d)", which, n))
            return true
        end
        return false
    end

    local function queue_blackboard_retry(game_id)
        ensure_pickup_event_flags()
        local meta = pickup_event_items[game_id]
        if not (meta and meta.blackboard) then return end
        if blackboard_done[game_id] then return end
        pending_blackboard[game_id] = math.max(pending_blackboard[game_id] or 0, 180)
    end

    function ctx.apply_item_story_flag(game_id)
        if not ctx.needs_story_flag(game_id) then return false end
        local id = get_item_id_enum(game_id)
        local mgr = sdk.get_managed_singleton("app.ItemManager")
        if id == nil or not mgr then return false end

        local ok_any = false
        for _, name in ipairs({ "_AcquiredIDSet", "_PickedupIDSet" }) do
            local set = try(function() return mgr:get_field(name) end)
            if hashset_add(set, id) then
                ok_any = true
                ctx.info(string.format("%s + %s", name, game_id))
            end
        end
        local u = item_id_uint_local(id)
        for _, name in ipairs({ "_AcquiredIDHashSet_Sys", "_PickedupIDHashSet_Sys" }) do
            local set = try(function() return mgr:get_field(name) end)
            if set and u ~= nil and (pcall(function() set:call("Add", u) end)
                or pcall(function() set:call("Add(System.UInt32)", u) end)) then
                ok_any = true
                ctx.info(string.format("%s (u32) + %s", name, game_id))
            end
        end

        for _, mname in ipairs({
            "notifyAcquired", "notifyItemAcquired", "onItemAcquired",
            "notifyGetItem", "onGetItem",
        }) do
            local m = try(function() return mgr:get_type_definition():get_method(mname) end)
            if m and pcall(function() m:call(mgr, id) end) then
                ok_any = true
                ctx.info("flag scénario : ItemManager." .. mname .. " (" .. game_id .. ")")
                break
            end
        end

        if apply_flag_blackboard(game_id) then
            ok_any = true
        else
            -- Acquired OK mais HasLighter pas encore (composant pas spawn) → retry
            queue_blackboard_retry(game_id)
        end

        if not ok_any then
            local m = try(function() return mgr:get_type_definition():get_method("isAcquiredItem") end)
                or try(function() return mgr:get_type_definition():get_method("isAcquired") end)
            if m then
                local ok, has = pcall(function() return m:call(mgr, id) end)
                if ok and has then ok_any = true end
            end
        end

        if ok_any then refresh_ui() end
        return ok_any
    end

    -- Au check monde : Flag / NEVER_BLOCK / pickup_event seulement (jamais KeyItem générique).
    function ctx.fire_pickup_event_flags(loc_id, reason)
        ensure_pickup_event_flags()
        local id = ctx.id_str and ctx.id_str(loc_id) or tostring(loc_id)
        local entry = pickup_event_flags[id]
        local loc = ctx.locations and ctx.locations[id]
        local vanilla_gid = (entry and entry.game_id)
            or (loc and loc.item_id)
        if type(vanilla_gid) ~= "string" or vanilla_gid == "" then return false end

        local game_id = vanilla_gid
        local sc = ctx.session.scouts and ctx.session.scouts[id]
        if sc and ctx.resolve_ap_item then
            local ap_gid = select(1, ctx.resolve_ap_item(sc.item, sc.name))
            if ap_gid and ap_gid ~= vanilla_gid then
                -- spot shuffled : garder le flag vanilla seulement si Flag/NEVER_BLOCK
                if ctx.should_keep_vanilla and ctx.should_keep_vanilla(vanilla_gid) then
                    game_id = vanilla_gid
                elseif is_location_check_flag(vanilla_gid) then
                    game_id = vanilla_gid
                else
                    ctx.info(string.format(
                        "pickup flag skip loc=%s vanilla=%s (pas un Flag de check)", id, vanilla_gid))
                    return false
                end
            end
        end

        if not is_location_check_flag(game_id) and not entry then return false end
        ctx.session.fired_pickup_flags = ctx.session.fired_pickup_flags or {}
        local key = id .. "|" .. game_id
        if ctx.session.fired_pickup_flags[key] and reason ~= "force" and reason ~= "retro_heal" then
            return true
        end
        local ok = ctx.apply_item_story_flag(game_id)
        if ok then
            ctx.session.fired_pickup_flags[key] = true
            ctx.save_session()
            ctx.info(string.format("pickup event flag loc=%s item=%s reason=%s", id, game_id, tostring(reason)))
        end
        return ok
    end

    -- rétropédalage : Flag / briquet seulement (pas toutes les KeyItem reçues)
    function ctx.apply_all_story_flags()
        ensure_pickup_event_flags()
        local n, ok_n = 0, 0
        local seen = {}
        local function one(gid)
            if not gid or seen[gid] or not is_location_check_flag(gid) then return end
            seen[gid] = true
            n = n + 1
            if ctx.apply_item_story_flag(gid) then ok_n = ok_n + 1 end
        end
        for code, count in pairs(ctx.session.received_counts or {}) do
            if tonumber(count) and tonumber(count) > 0 then
                local it = ctx.ap_items and ctx.ap_items[tostring(code)]
                if it and it.game_id then one(it.game_id) end
            end
        end
        for _, e in ipairs(ctx.box_contents() or {}) do one(e.id) end
        for loc_id, entry in pairs(pickup_event_flags) do
            if entry.retro_heal and ctx.is_checked and ctx.is_checked(loc_id) then
                n = n + 1
                if ctx.fire_pickup_event_flags(loc_id, "retro_heal") then ok_n = ok_n + 1 end
            end
        end
        return ok_n, n
    end

    local function inventory_contents(inv)
        if not inv then return {} end
        local states = try(function() return inv:call("getPanelStates") end)
        local list = states and (try(function() return states:get_elements() end) or {}) or {}
        local totals, order = {}, {}
        for _, ps in ipairs(list) do
            local id = try(function() return ps:call("get_ItemID"):call("ToString") end)
            local stock = tonumber(try(function() return ps:call("get_Stock") end)) or 0
            if type(id) == "string" and id ~= "" and stock > 0 then
                if not totals[id] then order[#order + 1] = id end
                totals[id] = (totals[id] or 0) + stock
            end
        end
        local out = {}
        for _, id in ipairs(order) do out[#out + 1] = { id = id, count = totals[id] } end
        return out
    end

    function ctx.box_contents()
        return inventory_contents(get_box())
    end

    function ctx.hand_contents(user_name)
        return inventory_contents(get_hand(user_name or ctx.GRACE_HAND_USER))
    end

    function ctx.all_hand_users()
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local elems = mgr and try(function()
            return mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end) or {}
        local users, seen = {}, {}
        for _, entry in ipairs(elems) do
            local inv = try(function() return entry:get_field("value") end)
            local key = inv and try(function() return inv:get_field("_InventoryKey") end)
            local board = key and try(function() return key:get_field("_BoardType") end)
            local user = key and try(function() return key:get_field("_User") end)
            local name = user and try(function() return user:get_field("_Name") end)
            if board ~= nil and tonumber(board) == HAND_BOARD and name and not seen[tostring(name)] then
                seen[tostring(name)] = true
                users[#users + 1] = tostring(name)
            end
        end
        table.sort(users)
        return users
    end

    -- snapshot inventaire+coffre avant un saut de scène (warp style RE4R)
    function ctx.snapshot_inventories()
        local snap = { t = os.clock(), box = ctx.box_contents(), hands = {} }
        for _, user in ipairs(ctx.all_hand_users()) do
            local list = ctx.hand_contents(user)
            if #list > 0 then snap.hands[user] = list end
        end
        return snap
    end

    local function stock_in(inv, item_id)
        if not inv or not hand_count then return 0 end
        local id = get_item_id_enum(item_id)
        if id == nil then return 0 end
        return tonumber(try(function() return hand_count:call(inv, id) end)) or 0
    end

    -- réinjecte ce qui manque après un jump (ne retire rien d'éventuels starters)
    function ctx.restore_inventories(snap)
        if type(snap) ~= "table" then return false, "snapshot invalide" end
        if not ctx.is_game_ready or not ctx.is_game_ready() then return false, "jeu pas prêt" end
        local restored = 0
        for _, e in ipairs(snap.box or {}) do
            local have = stock_in(get_box(), e.id)
            local need = math.max(0, (tonumber(e.count) or 0) - have)
            if need > 0 and ctx.inject_item(e.id, need) then restored = restored + 1 end
        end
        for user, list in pairs(snap.hands or {}) do
            local inv = get_hand(user)
            for _, e in ipairs(list or {}) do
                local have = stock_in(inv, e.id)
                local need = math.max(0, (tonumber(e.count) or 0) - have)
                if need > 0 then
                    local n = ctx.inject_to_hand(e.id, need, user)
                    if (tonumber(n) or 0) > 0 then
                        restored = restored + 1
                    elseif ctx.inject_item(e.id, need) then
                        restored = restored + 1
                    end
                end
            end
        end
        if ctx.apply_all_story_flags then pcall(ctx.apply_all_story_flags) end
        return true, restored
    end

    local box_consume = inv_td and try(function()
        return inv_td:get_method("consumeStock(app.ItemID, System.Int32, app.ItemStockChangedEventType)")
    end)

    local function hashset_remove(set, id)
        if set == nil or id == nil then return false end
        if pcall(function() set:call("Remove", id) end) then return true end
        if pcall(function() set:call("Remove(app.ItemID)", id) end) then return true end
        return false
    end

    local function item_id_uint(id)
        if id == nil then return nil end
        local v = try(function() return id:get_field("value__") end)
        if v ~= nil then return math.floor(tonumber(v) or 0) end
        local n = try(function() return sdk.to_int64(id) end)
        return n and math.floor(n & 0xFFFFFFFF) or nil
    end

    function ctx.clear_item_story_flag(game_id)
        local id = get_item_id_enum(game_id)
        local mgr = sdk.get_managed_singleton("app.ItemManager")
        if id == nil or not mgr then return false end
        local ok_any = false
        for _, name in ipairs({
            "_AcquiredIDSet", "_PickedupIDSet", "_UnpickableItemIDSet", "_ForceUsedIDSet",
        }) do
            local set = try(function() return mgr:get_field(name) end)
            if hashset_remove(set, id) then
                ok_any = true
                ctx.info("retiré de " .. name .. " : " .. tostring(game_id))
            end
        end
        local u = item_id_uint(id)
        for _, name in ipairs({ "_AcquiredIDHashSet_Sys", "_PickedupIDHashSet_Sys" }) do
            local set = try(function() return mgr:get_field(name) end)
            if set and u ~= nil then
                if pcall(function() set:call("Remove", u) end)
                    or pcall(function() set:call("Remove(System.UInt32)", u) end) then
                    ok_any = true
                    ctx.info("retiré de " .. name .. " (u32) : " .. tostring(game_id))
                end
            end
        end
        ensure_pickup_event_flags()
        local meta = pickup_event_items[game_id]
        local which = meta and meta.blackboard
        if which then
            local field = which == "HasLighter" and "_HasLighter_k__BackingField"
                or which == "HasFlashLight" and "_HasFlashLight_k__BackingField"
                or nil
            for _, bb in ipairs(collect_flashlight_bb()) do
                if field then pcall(function() bb:set_field(field, false) end) end
                pcall(function() bb:call("set_" .. which, false) end)
                ok_any = true
            end
            blackboard_done[game_id] = nil
            pending_blackboard[game_id] = nil
        end
        if ok_any then refresh_ui() end
        return ok_any
    end

    function ctx.consume_item_anywhere(item_id, quantity)
        quantity = math.max(1, math.floor(tonumber(quantity) or 1))
        if not box_consume then return 0, "consumeStock introuvable" end
        local id = get_item_id_enum(item_id)
        if id == nil then return 0, "objet inconnu " .. tostring(item_id) end
        local event = static_value("app.ItemStockChangedEventType", "Default")
        local removed = 0
        local function take_from(inv)
            if not inv or removed >= quantity then return end
            local have = hand_count and tonumber(try(function() return hand_count:call(inv, id) end)) or 0
            local n = math.min(quantity - removed, have)
            if n <= 0 then return end
            local ok = pcall(function() return box_consume:call(inv, id, n, event) end)
            if ok then removed = removed + n end
        end
        take_from(get_hand(ctx.GRACE_HAND_USER))
        local user = ctx.player_inventory_user and ctx.player_inventory_user()
        if user and user ~= ctx.GRACE_HAND_USER then take_from(get_hand(user)) end
        take_from(get_box())
        if removed > 0 then refresh_ui() end
        return removed
    end

    -- ami a donné le briquet avant le ramassage monde → pas de ciné « première acquisition »
    function ctx.repair_lighter_cutscene()
        local gid = "it99_05_000"
        local loc_id = "7091019"
        local removed = ctx.consume_item_anywhere(gid, 9)
        ctx.clear_item_story_flag(gid)
        ctx.force_story_repick = ctx.force_story_repick or {}
        ctx.force_story_repick[gid] = true
        if ctx.invalidate_pickup_cache then ctx.invalidate_pickup_cache() end
        local ok, msg = true, nil
        if ctx.repair_story_pickup then
            ok, msg = ctx.repair_story_pickup(loc_id, gid, { keep_checked = true })
        end
        ctx.info(string.format("réparation ciné briquet : retiré x%d — %s (force canPickup)", removed, tostring(msg)))
        return ok ~= false, removed, msg
    end

    -- main d'abord, puis on retire du coffre ce qui est vraiment entré
    function ctx.transfer_box_to_hand(item_id, quantity, user_name)
        local box = get_box()
        if not box then return 0, "coffre introuvable" end
        if not box_consume then return 0, "consumeStock introuvable" end
        local id = get_item_id_enum(item_id)
        if id == nil then return 0, "objet inconnu " .. tostring(item_id) end
        local in_box = hand_count and tonumber(try(function() return hand_count:call(box, id) end)) or 0
        quantity = math.min(math.max(1, math.floor(tonumber(quantity) or 1)), in_box)
        if quantity <= 0 then return 0, "plus dans le coffre" end
        local added, err = ctx.inject_to_hand(item_id, quantity, user_name)
        if added <= 0 then return 0, err end
        local event = static_value("app.ItemStockChangedEventType", "Default")
        local ok, removed = pcall(function() return box_consume:call(box, id, added, event) end)
        if not ok or removed == false then
            ctx.warn(string.format("transfert : %s x%d ajouté à l'inventaire mais pas retiré du coffre (%s)",
                item_id, added, tostring(removed)))
        end
        refresh_ui()
        return added
    end

    -- GuiManager.ItemBox:open doit tourner sur le fil du jeu, au prochain update
    local open_box_requested = false
    function ctx.request_open_item_box() open_box_requested = true end

    local function open_item_box()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local bridge = gm and try(function() return gm:get_field("<ItemBox>k__BackingField") end)
        if not bridge then return false, "coffre (GuiManager.ItemBox) introuvable" end
        if try(function() return bridge:call("get_Active") end) == true then return false, "coffre déjà ouvert" end
        local setting = try(function() return sdk.create_instance("app.GuiItemBoxOpenSetting") end)
        if not setting then return false, "GuiItemBoxOpenSetting impossible à créer" end
        setting = setting:add_ref()
        local ok, e = pcall(function() return bridge:call("open(app.GuiItemBoxOpenSetting)", setting) end)
        if not ok then return false, tostring(e) end
        return true
    end

    -- transferts et lecture du coffre faits ici, sur le fil du jeu
    ctx.box_cache = {}
    ctx.box_cache_wanted = false
    local pending_transfers = {}
    local next_box_read = 0
    function ctx.request_transfer(item_id, quantity, user_name, done)
        pending_transfers[#pending_transfers + 1] = { item_id = item_id, quantity = quantity, user = user_name, done = done }
    end

    local function process_transfers()
        for _, t in ipairs(pending_transfers) do
            local ok, moved, err = pcall(ctx.transfer_box_to_hand, t.item_id, t.quantity, t.user)
            if not ok then moved, err = 0, moved end
            if t.done then pcall(t.done, moved or 0, err) end
            next_box_read = 0
        end
        pending_transfers = {}
        if ctx.box_cache_wanted and os.clock() >= next_box_read then
            next_box_read = os.clock() + 1
            local ok, list = pcall(ctx.box_contents)
            ctx.box_cache = ok and list or {}
            ctx.box_cache_wanted = false
        end
    end

    local function process_open_box()
        pcall(process_transfers)
        if not open_box_requested then return end
        open_box_requested = false
        local ok, err = open_item_box()
        if ok then
            ctx.info("coffre ouvert à distance")
        else
            ctx.warn("ouverture du coffre impossible : " .. tostring(err))
            ctx.push_message(ctx.T("Ouverture du coffre impossible : ") .. tostring(err), ctx.COLORS.warn)
        end
    end
    -- F7
    local OPEN_BOX_KEY = 0x76
    local key_was_down = false
    re.on_frame(function()
        local down = try(function() return reframework:is_key_down(OPEN_BOX_KEY) end) == true
        if down and not key_was_down then open_box_requested = true end
        key_was_down = down
    end)
    ctx.on_tick("open_box", function() pcall(process_open_box) end)

    -- briquet reçu AP avant spawn du blackboard → reposer HasLighter dès que possible
    local bb_tick, bb_seeded = 0, false
    ctx.on_tick("story_blackboard", function()
        bb_tick = bb_tick + 1
        if bb_tick % 30 ~= 0 then return end
        if not ctx.is_game_ready or not ctx.is_game_ready() then return end
        ensure_pickup_event_flags()
        if not bb_seeded then
            bb_seeded = true
            for code, n in pairs(ctx.session.received_counts or {}) do
                if tonumber(n) and tonumber(n) > 0 then
                    local it = ctx.ap_items and ctx.ap_items[tostring(code)]
                    local gid = it and it.game_id
                    if gid then queue_blackboard_retry(gid) end
                end
            end
        end
        for gid, left in pairs(pending_blackboard) do
            if not apply_flag_blackboard(gid) then
                left = (tonumber(left) or 0) - 1
                if left <= 0 then
                    pending_blackboard[gid] = nil
                    ctx.warn("blackboard non posé après retries : " .. tostring(gid))
                else
                    pending_blackboard[gid] = left
                end
            end
        end
    end)

    -- true = coffre + ItemManager présents (partie chargée assez pour injecter)
    function ctx.is_game_ready()
        if get_box() == nil then return false end
        if sdk.get_managed_singleton("app.ItemManager") == nil then return false end
        return true
    end

    -- true = pas titre / chargement / ciné (évite gels à l'injection et sync carte)
    function ctx.is_safe_to_mutate()
        if not ctx.is_game_ready() then return false end
        local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
        if mgr == nil then return true end -- pas de flow = on tente quand même (menus rares)
        local function flag(names)
            for _, n in ipairs(names) do
                local ok, v = pcall(function() return mgr:call(n) end)
                if ok and v == true then return true end
                ok, v = pcall(function() return mgr:get_field(n) end)
                if ok and v == true then return true end
            end
            return false
        end
        if flag({ "get_IsInTitle", "get_IsNowLoading", "get_IsLoading" }) then return false end
        if flag({ "get_IsInMovie", "get_IsNowMovie", "get_IsInEvent", "get_IsEventScene" }) then return false end
        return true
    end

    function ctx.inject_item(item_id, quantity)
        quantity = math.max(1, math.floor(tonumber(quantity) or 1))
        local box = get_box()
        if not box then return false, "coffre introuvable", 0 end

        local detail = get_item_detail(item_id)
        if not detail then return false, "ItemDetailData introuvable pour " .. tostring(item_id), 0 end

        local true_cap  = get_box_capacity(detail)
        local remaining = quantity

        while remaining > 0 do
            local info, room = find_panel_info(box, item_id)
            if not info or room <= 0 then break end
            local cur = try(function() return info:get_field("_Stock") end) or 0
            local cap = try(function() return info:get_field("_StockCapacity") end) or 1
            if cap < true_cap then cap = true_cap end
            local add = math.min(remaining, cap - cur)
            if add <= 0 then break end
            set_stock(info, cur + add, cap)
            remaining = remaining - add
        end

        local guard = 0
        while remaining > 0 and add_panel_method and guard < 20 do
            guard = guard + 1
            local slot = create_slot_address()
            if not slot then break end

            local before = #(try(function() return box:call("getPanelStates"):get_elements() end) or {})
            local ok = pcall(function() add_panel_method:call(box, slot, nil, detail, nil) end)
            local after = #(try(function() return box:call("getPanelStates"):get_elements() end) or {})
            if not ok or after <= before then break end

            local new_info, min_s = nil, math.huge
            for _, info in ipairs(panel_infos(box)) do
                if panel_item_name(info) == item_id then
                    local s = try(function() return info:get_field("_Stock") end) or 0
                    if s < min_s then min_s, new_info = s, info end
                end
            end
            if not new_info then break end

            local add = math.min(remaining, true_cap)
            set_stock(new_info, add, true_cap)
            remaining = remaining - add
        end

        refresh_ui()
        local injected = quantity - remaining
        if remaining == 0 then return true, nil, injected end
        return false, string.format("seulement %d/%d injectés", injected, quantity), injected
    end
end
