-- Supply Box. Chaque ligne d'achat est un check. Archipelago décide l'objet.
-- Acheter envoie la location et retire l'article vanilla.

return function(ctx)
    local ROWS = {
        { id = 7091619, game_id = "it40_00_000", pack = 10, price = 500 },
        { id = 7091620, game_id = "it40_01_000", pack = 3, price = 600 },
        { id = 7091621, game_id = "it40_03_000", pack = 20, price = 800 },
        { id = 7091622, game_id = "it40_05_000", pack = 3, price = 900 },
        { id = 7091623, game_id = "it00_01_000", pack = 1, price = 1500 },
        { id = 7091624, game_id = "it10_00_002", pack = 1, price = 5500 },
        { id = 7091625, game_id = "it10_01_000", pack = 1, price = 2500 },
        { id = 7091626, game_id = "it10_01_003", pack = 1, price = 7000, names = { "990-TAC" } },
        { id = 7091627, game_id = "it10_03_001", pack = 1, price = 6000 },
        { id = 7091628, game_id = "it10_30_000", pack = 1, price = 15000 },
        { id = 7091629, game_id = "it99_01_001", pack = 1, price = 7000, names = {
            "Extension mallette", "8x13", "Case Upgrade",
        } },
    }

    local by_price, by_id = {}, {}
    for _, row in ipairs(ROWS) do
        by_id[row.game_id] = row
        if by_price[row.price] == nil then
            by_price[row.price] = row
        else
            by_price[row.price] = false
        end
    end

    local shelf_until = 0
    local pay_until = 0
    local last_stock = {}
    local pending = nil
    local asked_at = {}
    local names_logged = {}
    local buy_behavior = nil
    local captured = nil
    local rows_logged = false

    local empty_guid = nil
    local function paint(text, label)
        if empty_guid == nil then
            local td = sdk.find_type_definition("System.Guid")
            empty_guid = td and ValueType.new(td) or false
        end
        if empty_guid then pcall(function() text:call("set_MessageId", empty_guid) end) end
        pcall(function() text:call("set_Message", label) end)
    end

    local function supply_enabled()
        local v = ctx.session and ctx.session.supply_box
        if v == nil or v == "" then return true end
        return not (v == false or v == "false" or v == "0")
    end

    local function ap_price(row)
        if not row then return nil end
        local map = ctx.session and ctx.session.supply_prices
        if type(map) ~= "table" then return nil end
        local key = ctx.id_str and ctx.id_str(row.id)
        return key and tonumber(map[key]) or nil
    end

    local function row_label(row)
        if not supply_enabled() then return nil end
        local bought = ctx.session and ctx.session.supply_bought
        local key = ctx.id_str and ctx.id_str(row.id)
        if bought and key and bought[key] then return nil end
        if not ctx.is_active(row.id) or not ctx.scout_label then return nil end
        local _, _, sc, parts = ctx.scout_label(row.id)
        if not sc or not parts or not parts.name or parts.name == "" then return nil end
        if sc.mine then return parts.name end
        local who = (sc.owner and sc.owner ~= "") and sc.owner or "?"
        return parts.name .. " (" .. who .. ")"
    end

    local message_get = nil
    local function text_string(text)
        if not text then return nil end
        local msg = nil
        pcall(function() msg = text:call("get_Message") end)
        if type(msg) == "string" and msg ~= "" then return msg end
        if message_get == nil then
            local def = sdk.find_type_definition("via.gui.message")
            message_get = def and def:get_method("get(System.Guid)") or false
        end
        if not message_get then return nil end
        local id, s = nil, nil
        pcall(function() id = text:call("get_MessageId") end)
        if not id then return nil end
        pcall(function() s = message_get:call(nil, id) end)
        if type(s) == "string" and s ~= "" then return s end
        return nil
    end

    local function price_number(text)
        local s = text_string(text)
        if type(s) ~= "string" then return nil end
        return tonumber((s:gsub("%D", "")))
    end

    local function each_slot(list, fn)
        if not list then return 0 end
        local elems = nil
        pcall(function() elems = list:get_elements() end)
        if type(elems) == "table" and #elems > 0 then
            for _, item in ipairs(elems) do
                if item then fn(item) end
            end
            return #elems
        end
        local n = nil
        pcall(function() n = list:call("get_Length") end)
        if not n then pcall(function() n = list:call("get_Count") end) end
        n = tonumber(n)
        if not n or n < 1 or n > 32 then return 0 end
        local seen = 0
        for i = 0, n - 1 do
            local item = nil
            pcall(function() item = list:call("get_Item", i) end)
            if not item then pcall(function() item = list:call("get_element", i) end) end
            if item then
                seen = seen + 1
                fn(item)
            end
        end
        return seen
    end

    local function id_text(value)
        local s = nil
        if type(value) == "string" then
            s = value
        elseif value then
            pcall(function() s = value:call("ToString") end)
        end
        if type(s) ~= "string" then return nil end
        return s:match("it%d+_%d+_%d+")
    end

    local function detail_id(detail)
        if not detail then return nil end
        local iid = nil
        pcall(function() iid = detail:call("get_ItemID") end)
        if not iid then pcall(function() iid = detail:get_field("<ItemID>k__BackingField") end) end
        return id_text(iid)
    end

    local function entry_id(entry)
        local detail = nil
        pcall(function() detail = entry:call("get_ShopItemDetailData") end)
        if not detail then
            pcall(function() detail = entry:get_field("<ShopItemDetailData>k__BackingField") end)
        end
        return detail_id(detail)
    end

    local lineup_ids = nil
    local lineup_at = 0
    local function refresh_lineup()
        local now = os.clock()
        if lineup_ids and now < lineup_at then return lineup_ids end
        lineup_at = now + 1
        local mgr = sdk.get_managed_singleton("app.ShopManager")
        local field = sdk.find_type_definition("app.ShopID")
        field = field and field:get_field("Common") or nil
        local shop = field and field:get_data(nil) or nil
        if not mgr or not shop then return lineup_ids end
        local arr = nil
        pcall(function() arr = mgr:call("getShopLineup(app.ShopID, System.Boolean)", shop, false) end)
        local ids = {}
        each_slot(arr, function(detail) ids[#ids + 1] = detail_id(detail) end)
        if #ids > 0 then lineup_ids = ids end
        return lineup_ids
    end

    local function row_by_name(price, msg)
        if type(msg) ~= "string" then return nil end
        for _, candidate in ipairs(ROWS) do
            local ask = ap_price(candidate)
            if candidate.names and (not price or price == candidate.price or price == ask) then
                for _, n in ipairs(candidate.names) do
                    if msg:find(n, 1, true) then return candidate end
                end
            end
        end
        return nil
    end

    local function row_by_ap_price(price)
        local found = nil
        for _, row in ipairs(ROWS) do
            if ap_price(row) == price then
                if found then return nil end
                found = row
            end
        end
        return found
    end

    local price_logged = {}
    local function stamp_price(entry)
        local gid = entry_id(entry)
        local row = gid and by_id[gid]
        local amount = row and (ap_price(row) or row.price)
        if not amount then return end
        local charge = amount
        pcall(function() entry:call("set_Price", charge) end)
        pcall(function() entry:set_field("<Price>k__BackingField", charge) end)
        if not price_logged[row.id] then
            price_logged[row.id] = true
            ctx.info(string.format("supply : %s prix %d", gid, amount))
        end
    end

    local function paint_price(text, amount)
        if not text or not amount then return end
        local cur = text_string(text) or ""
        local prefix = cur:match("^(.-)%d+") or ""
        local label = prefix .. tostring(amount)
        if cur == label then return end
        paint(text, label)
    end

    -- Le MessageId du jeu réécrit le nom. On le vide, puis set_Message, après le refresh.
    local function dress_item(item, game_id)
        local price_text, name_text = nil, nil
        pcall(function() price_text = item:get_field("_PriceText") end)
        pcall(function() name_text = item:get_field("_NameText") end)
        local price = price_number(price_text)
        local named = row_by_name(price, name_text and text_string(name_text) or nil)
        local row = game_id and by_id[game_id] or nil
        if row and not ap_price(row) and price and row.price ~= price then row = nil end
        if not row then row = named end
        if not row and price then row = row_by_ap_price(price) or by_price[price] end
        if not row then return end
        shelf_until = os.clock() + 2
        pay_until = os.clock() + 8
        local ask = ap_price(row)
        if ask then paint_price(price_text, ask) end
        local label = row_label(row)
        if not label or not name_text then return end
        if text_string(name_text) == label then return end
        paint(name_text, label)
        if not names_logged[row.id] then
            names_logged[row.id] = true
            ctx.info("supply : " .. tostring(ask or price) .. " -> " .. label)
        end
    end

    local function dress_2720(self)
        if not self then return end
        local list = nil
        pcall(function() list = self:get_field("_GuiItems") end)
        local items = {}
        each_slot(list, function(item) items[#items + 1] = item end)
        if not rows_logged and #items > 0 then
            rows_logged = true
            local sample = nil
            if items[1] then
                pcall(function() sample = text_string(items[1]:get_field("_PriceText")) end)
            end
            ctx.info(string.format("supply : lignes x%d, data x%s, prix=%s",
                #items, captured and tostring(#captured) or "0", tostring(sample)))
        end
        local ids = captured
        if not ids or #ids ~= #items then ids = refresh_lineup() end
        local aligned = ids and #ids == #items
        for i, item in ipairs(items) do
            dress_item(item, aligned and ids[i] or nil)
        end
    end

    local function hook_buy_list()
        local td = sdk.find_type_definition("app.UI2720GuiBehavior")
        if not td then
            ctx.warn("supply : UI2720 absent")
            return
        end
        local wanted = { updateItemList = true, onUpdateScrollListItem = true }
        local hooked = 0
        for _, method in ipairs(td:get_methods()) do
            local name = method:get_name()
            local decl = ""
            pcall(function() decl = method:get_declaring_type():get_full_name() end)
            if decl == "app.UI2720GuiBehavior" and wanted[name] then
                local capture = name == "updateItemList"
                local ok, err = pcall(function()
                    sdk.hook(method, function(args)
                        buy_behavior = sdk.to_managed_object(args[2])
                        if not capture then return end
                        local arr = sdk.to_managed_object(args[3])
                        local ids = {}
                        each_slot(arr, function(entry)
                            stamp_price(entry)
                            ids[#ids + 1] = entry_id(entry)
                        end)
                        if #ids > 0 then captured = ids end
                    end, function(retval)
                        pcall(dress_2720, buy_behavior)
                        return retval
                    end)
                end)
                if ok then
                    hooked = hooked + 1
                    ctx.info("supply : ui UI2720." .. name)
                else
                    ctx.warn("supply : hook " .. name .. " ignoré : " .. tostring(err))
                end
            end
        end
        if hooked == 0 then ctx.warn("supply : liste d'achat non accrochée") end
    end
    pcall(hook_buy_list)

    local function scene_components(type_name)
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
        if not scene then return {} end
        local arr = nil
        local ok = pcall(function()
            arr = scene:call("findComponents(System.Type)", sdk.typeof(type_name))
        end)
        if not ok or not arr then return {} end
        local elems = nil
        pcall(function() elems = arr:get_elements() end)
        if type(elems) == "table" then return elems end
        return {}
    end

    local function shop_common()
        local field = sdk.find_type_definition("app.ShopID")
        field = field and field:get_field("Common") or nil
        return field and field:get_data(nil) or nil
    end

    local function vec3(pos)
        if not pos then return nil end
        local x = tonumber(pos.x)
        local y = tonumber(pos.y)
        local z = tonumber(pos.z)
        if not x then pcall(function() x = tonumber(pos:get_field("x")) end) end
        if not y then pcall(function() y = tonumber(pos:get_field("y")) end) end
        if not z then pcall(function() z = tonumber(pos:get_field("z")) end) end
        if x and y and z then return x, y, z end
        return nil
    end

    local function player_xyz()
        local x, y, z = nil, nil, nil
        pcall(function()
            local mgr = sdk.get_managed_singleton("app.CharacterManager")
            local pc = mgr and mgr:get_field("<PlayerContextFast>k__BackingField")
            local pos = pc and pc:call("get_Position")
            x, y, z = vec3(pos)
        end)
        return x, y, z
    end

    local function gimmick_xyz(comp)
        local go = nil
        pcall(function() go = comp:call("get_GameObject") end)
        local xf = go and go:call("get_Transform")
        local pos = nil
        if xf then
            pcall(function() pos = xf:call("get_Position") end)
            if not pos then pcall(function() pos = xf:call("get_UniversalPosition") end) end
        end
        return vec3(pos)
    end

    local open_logged = false
    local opened_at = 0
    local function open_shop(gimmick, as_grace)
        local shop = shop_common()
        local setting = nil
        pcall(function() setting = sdk.create_instance("app.GuiShopOpenSetting") end)
        if setting then pcall(function() setting = setting:add_ref() end) end
        if setting and shop then
            pcall(function() setting:set_field("_ShopId_k__BackingField", shop) end)
            pcall(function() setting:call("set_ShopId", shop) end)
        end
        local opened = false
        local handle = nil
        if gimmick then pcall(function() handle = gimmick:get_field("_GuiShopHandle") end) end
        if handle and setting then
            local ok = pcall(function() handle:call("open(app.GuiShopOpenSetting)", setting) end)
            opened = ok
        end
        if not opened and setting then
            local gm = sdk.get_managed_singleton("app.GuiManager")
            local bridge = gm and gm:get_field("<Shop>k__BackingField")
            if bridge then
                local ok = pcall(function() bridge:call("open(app.GuiShopOpenSetting)", setting) end)
                opened = ok
            end
        end
        if opened then
            ctx.grace_shop = as_grace == true
            opened_at = os.clock()
            ctx.info(as_grace and "supply : magasin ouvert pour Grace" or "supply : magasin ouvert")
        elseif not open_logged then
            open_logged = true
            ctx.warn("supply : ouverture du magasin pour Grace refusée")
        end
        return opened
    end

    local function nearest_shop()
        local px, py, pz = player_xyz()
        if not px then return nil end
        local best, best_d = nil, 3.0
        for _, comp in ipairs(scene_components("app.GmShopV2")) do
            local x, y, z = gimmick_xyz(comp)
            if x then
                local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
                if d <= best_d then best, best_d = comp, d end
            end
        end
        return best
    end

    local function shop_bridge_active()
        local gm = sdk.get_managed_singleton("app.GuiManager")
        local bridge = gm and gm:get_field("<Shop>k__BackingField")
        if not bridge then return false end
        local active = nil
        local ok = pcall(function() active = bridge:call("get_Active") end)
        if not ok then return nil end
        return active == true
    end

    local f_was = false
    re.on_frame(function()
        local down = false
        pcall(function() down = reframework:is_key_down(0x46) == true end)
        local edge = down and not f_was
        f_was = down
        local grace = ctx.current_character and ctx.current_character() == "grace"
        local state = shop_bridge_active()
        if state == true and grace and ctx.session and ctx.session.grace_tracker then
            ctx.grace_shop = true
        elseif state == false and os.clock() - opened_at > 1 then
            ctx.grace_shop = false
        end
        if not edge or not grace then return end
        if not supply_enabled() or not (ctx.session and ctx.session.grace_tracker) then return end
        local box = nearest_shop()
        if box then open_shop(box, true) end
    end)

    local open_supply_requested = false
    function ctx.request_open_supply()
        open_supply_requested = true
    end

    ctx.on_tick("open_supply", function()
        if not open_supply_requested then return end
        open_supply_requested = false
        local grace = ctx.current_character and ctx.current_character() == "grace"
        local opened = open_shop(nearest_shop(), grace)
        if not opened and ctx.push_message then
            ctx.push_message(ctx.T("Ouverture du Supply Box impossible."), ctx.COLORS.warn)
        end
    end, { every = 0 })

    local function behavior_from_shop()
        local mgr = sdk.get_managed_singleton("app.GuiManager")
        if not mgr then return nil end
        local bridge = mgr:get_field("<Shop>k__BackingField")
        local controller = bridge and bridge:get_field("<ViewController>k__BackingField") or nil
        local units = controller and controller:get_field("_UnitController") or nil
        local list = units and units:get_field("_UnitList") or nil
        local items = list and list:get_field("_items") or nil
        local unit = nil
        if items then
            local elems = nil
            pcall(function() elems = items:get_elements() end)
            unit = elems and elems[1] or nil
        end
        local handle = unit and unit:get_field("_UI2720GuiHandle") or nil
        if not handle then return nil end
        local behavior = nil
        pcall(function() behavior = handle:call("getBehavior") end)
        return behavior
    end

    local next_find = 0
    local found_logged = false
    ctx.on_tick("supply_names", function()
        local now = os.clock()
        if now >= next_find or not buy_behavior then
            next_find = now + 0.5
            local found = scene_components("app.UI2720GuiBehavior")
            local behavior = found[1]
            if not behavior then
                local ok, b = pcall(behavior_from_shop)
                if ok then behavior = b end
            end
            if behavior and behavior ~= buy_behavior then
                buy_behavior = behavior
                pcall(function() buy_behavior:add_ref() end)
                if not found_logged then
                    found_logged = true
                    ctx.info("supply : liste d'achat trouvée")
                end
            end
        end
    end, { every = 0.5 })

    local function dress_now()
        if not buy_behavior then return end
        local ok, err = pcall(dress_2720, buy_behavior)
        if not ok and not found_logged then
            found_logged = true
            ctx.err("supply noms : " .. tostring(err))
        end
    end

    if re.on_pre_application_entry then
        re.on_pre_application_entry("BeginRendering", dress_now)
    end
    ctx.on_tick("supply_paint", dress_now, { every = 0 })

    local function stock_of(game_id)
        local n = 0
        local function add(list)
            for _, e in ipairs(list or {}) do
                if e.id == game_id then n = n + (tonumber(e.count) or 0) end
            end
        end
        if ctx.box_contents then add(ctx.box_contents()) end
        local user = ctx.player_inventory_user and ctx.player_inventory_user()
        if ctx.hand_contents then
            if user then add(ctx.hand_contents(user)) end
            if user ~= ctx.GRACE_HAND_USER then add(ctx.hand_contents(ctx.GRACE_HAND_USER)) end
        end
        return n
    end

    local function pay_grace(row)
        if not ctx.grace_shop or not row then return end
        local price = ap_price(row) or row.price
        ctx.info(string.format("Grace paie %d sur le compte partagé", price))
    end

    local function take_vanilla(row, delta)
        if not row or not delta or delta <= 0 or not ctx.consume_item_anywhere then return 0 end
        local removed = 0
        local take = math.min(delta, row.pack)
        pcall(function() removed = ctx.consume_item_anywhere(row.game_id, take) or 0 end)
        return removed
    end

    -- L'envoi ne dépend pas du stock : un accessoire déjà possédé ne monte pas.
    local function complete_purchase(row)
        if not supply_enabled() or not row then return false end
        if not ctx.is_active(row.id) or ctx.is_checked(row.id) then return false end
        ctx.session.supply_bought = ctx.session.supply_bought or {}
        local key = ctx.id_str(row.id)
        if key then ctx.session.supply_bought[key] = true end
        pay_grace(row)
        local sent = ctx.mark_checked(row.id)
        if ctx.save_session then ctx.save_session() end
        if sent and ctx.flush_location_checks then ctx.flush_location_checks() end
        local loc = ctx.locations and key and ctx.locations[key]
        local label = loc and loc.name or tostring(row.id)
        ctx.info("supply : check envoyé " .. label)
        if sent and ctx.push_message then
            ctx.push_message(ctx.TF("Check envoyé : %s", label), ctx.COLORS.ok, "check")
        end
        return sent
    end

    local function arm(row)
        if not supply_enabled() then return end
        if not row or not ctx.is_active(row.id) or ctx.is_checked(row.id) then return end
        if pending and pending.id == row.id and os.clock() < pending.until_t then return end
        local base = last_stock[row.game_id]
        if base == nil then base = stock_of(row.game_id) end
        pending = {
            id = row.id, game_id = row.game_id, pack = row.pack,
            base = base, until_t = os.clock() + 3,
        }
    end

    local function row_from_text(s)
        if type(s) ~= "string" then return nil end
        for _, row in ipairs(ROWS) do
            if s:find(row.game_id, 1, true) then return row end
        end
        return nil
    end

    local function event_row(obj)
        if not obj then return nil end
        local price, iid = nil, nil
        pcall(function() price = obj:get_field("_BuyPrice_k__BackingField") end)
        if price == nil then pcall(function() price = obj:get_field("_BuyPrice") end) end
        pcall(function() iid = obj:get_field("_BuyItemID_k__BackingField"):call("ToString") end)
        if type(iid) ~= "string" then
            pcall(function() iid = obj:call("ToString") end)
        end
        local by_id_row = row_from_text(iid)
        if by_id_row then return by_id_row end
        price = tonumber(price)
        local asked = price and row_by_ap_price(price)
        if asked then return asked end
        local row = price and by_price[price] or nil
        if row and (type(iid) ~= "string" or not iid:find("it%d") or iid:find(row.game_id, 1, true)) then
            return row
        end
        return nil
    end

    local function arg_item_text(v)
        if v == nil then return nil end
        local obj, s = nil, nil
        pcall(function() obj = sdk.to_managed_object(v) end)
        if obj then
            pcall(function() s = obj:call("ToString") end)
            if type(s) == "string" and s:find("it%d", 1) then return s end
        end
        if sdk.to_valuetype then
            local vt = nil
            pcall(function() vt = sdk.to_valuetype(v, "app.ItemID") end)
            if vt then
                pcall(function() s = vt:call("ToString") end)
                if type(s) == "string" and s:find("it%d", 1) then return s end
            end
        end
        return nil
    end

    local function args_row(args)
        for i = 2, 6 do
            local obj = nil
            pcall(function() obj = sdk.to_managed_object(args[i]) end)
            local row = event_row(obj)
            if row then return row end
            row = row_from_text(arg_item_text(args[i]))
            if row then return row end
        end
        return nil
    end

    local queued = nil
    local function hook_method(method, how)
        local name = method:get_name()
        local ok, err = pcall(function()
            sdk.hook(method, function(args)
                local row = nil
                pcall(function() row = args_row(args) end)
                if row then queued = row end
            end, function(retval)
                return retval
            end)
        end)
        if ok then
            ctx.info("supply : achat accroché (" .. how .. ") " .. tostring(name))
            return 1
        end
        ctx.warn("supply : hook " .. tostring(name) .. " ignoré : " .. tostring(err))
        return 0
    end

    local function install_buy_hook()
        local hooked = 0
        for _, type_name in ipairs({ "app.ShopManager", "app.GuiShopController" }) do
            local td = sdk.find_type_definition(type_name)
            local methods = td and td:get_methods() or {}
            for _, method in ipairs(methods) do
                local name = method:get_name()
                local hit, shop_stock = false, false
                    if type_name == "app.ShopManager" and (name == "consumeStock" or name == "consumeStockImpl") then
                        shop_stock = true
                    end
                    local params = nil
                    pcall(function() params = method:get_param_types() end)
                    if params then
                        for _, p in ipairs(params) do
                            local full = nil
                            pcall(function() full = p:get_full_name() end)
                            if full and full:find("ShopBuyEventArgs", 1, true) and not full:find("Action", 1, true) then
                                hit = true
                                break
                            end
                        end
                    end
                    if hit or shop_stock then
                        hooked = hooked + hook_method(method, hit and "event" or "stock")
                    end
                end
            end
        if hooked == 0 then
            ctx.warn("supply : aucun achat accroché, les noms s'affichent mais l'achat n'envoie pas le check")
        end
    end

    local ok_hook, err_hook = pcall(install_buy_hook)
    if not ok_hook then ctx.warn("supply : hook d'achat non installé : " .. tostring(err_hook)) end

    -- Leon paie dans app.Inventory._Moneys. Un objet pour un autre joueur ne monte pas le stock.
    local balances = {}
    local function inventory_key(inv, index)
        local key = nil
        pcall(function()
            local k = inv:get_field("_InventoryKey")
            local board = k and k:get_field("_BoardType")
            local user = k and k:get_field("_User")
            local name = user and user:get_field("_Name")
            key = tostring(board) .. ":" .. tostring(name)
        end)
        return key or ("i" .. tostring(index))
    end

    local function money_drops()
        local drops = {}
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local elems = nil
        pcall(function()
            elems = mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end)
        for index, entry in ipairs(elems or {}) do
            local inv = nil
            pcall(function() inv = entry:get_field("value") end)
            if inv then
                local now = nil
                pcall(function() now = tonumber(inv:get_field("_Moneys")) end)
                if not now then pcall(function() now = tonumber(inv:call("get_Moneys")) end) end
                if now then
                    local key = inventory_key(inv, index)
                    local prev = balances[key]
                    if prev and now < prev then drops[#drops + 1] = prev - now end
                    balances[key] = now
                end
            end
        end
        return drops
    end

    -- Un seul solde : _Moneys de Leon et session.grace_credits.
    -- Un chapitre recharge l'argent vanilla et baisse _Moneys sans achat.
    local shared_last = nil
    local credit_scene = nil
    local credit_quiet_until = 0
    local credit_notice = 0
    local function leon_wallets()
        local found = {}
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local elems = nil
        pcall(function()
            elems = mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end)
        for index, entry in ipairs(elems or {}) do
            local inv = nil
            pcall(function() inv = entry:get_field("value") end)
            if inv then
                local name, board, money = nil, nil, nil
                pcall(function()
                    local key = inv:get_field("_InventoryKey")
                    board = key and tonumber(key:get_field("_BoardType"))
                    local user = key and key:get_field("_User")
                    name = user and tostring(user:get_field("_Name"))
                    money = tonumber(inv:get_field("_Moneys"))
                end)
                if name == "User01" and money then
                    found[#found + 1] = { inv = inv, index = index, board = board, money = money }
                end
            end
        end
        return found
    end

    local function share_credits(allowed_spend)
        local s = ctx.session
        if not s then return end
        local wallets = leon_wallets()
        if #wallets == 0 then return end
        local leon = 0
        for _, wallet in ipairs(wallets) do
            if wallet.money > leon then leon = wallet.money end
        end
        local grace = math.max(0, math.floor(tonumber(s.grace_credits) or 0))
        local shared
        local kept = false
        if shared_last == nil then
            shared = math.max(leon, grace)
        else
            local leon_delta = leon - shared_last
            local grace_delta = grace - shared_last
            if leon_delta < 0 then
                local keep = math.min(math.floor(tonumber(allowed_spend) or 0), -leon_delta)
                if keep < -leon_delta then kept = true end
                leon_delta = -keep
            end
            shared = shared_last + leon_delta + grace_delta
            if shared < 0 then shared = 0 end
        end
        shared = math.floor(shared)
        if kept and os.clock() - credit_notice > 2 then
            credit_notice = os.clock()
            ctx.info(string.format("crédits gardés au chargement : %d", shared))
        end
        if grace ~= shared then
            s.grace_credits = shared
            if ctx.save_session then ctx.save_session() end
        end
        local stuck = false
        for _, wallet in ipairs(wallets) do
            local hit = (leon > 0 and wallet.money == leon) or (leon == 0 and wallet.board == 0)
            local shown = wallet.money
            if hit and wallet.money ~= shared then
                pcall(function() wallet.inv:set_field("_Moneys", shared) end)
                local read = nil
                pcall(function() read = tonumber(wallet.inv:get_field("_Moneys")) end)
                if read == shared then
                    shown = shared
                else
                    stuck = true
                    if read then shown = read end
                end
            end
            if hit then
                balances[inventory_key(wallet.inv, wallet.index)] = shown
            end
        end
        if stuck and shared <= leon then
            shared = leon
            s.grace_credits = leon
            for _, wallet in ipairs(wallets) do
                local hit = (leon > 0 and wallet.money == leon) or (leon == 0 and wallet.board == 0)
                if hit then balances[inventory_key(wallet.inv, wallet.index)] = leon end
            end
        end
        shared_last = shared
    end

    function ctx.add_shared_credits(amount)
        amount = math.floor(tonumber(amount) or 0)
        if amount <= 0 or not ctx.session then return end
        ctx.session.grace_credits = math.floor(tonumber(ctx.session.grace_credits) or 0) + amount
        if ctx.save_session then ctx.save_session() end
        ctx.info(string.format("crédits +%d (portefeuille partagé)", amount))
    end

    local function rows_priced(delta)
        local vanilla, asked = {}, {}
        for _, row in ipairs(ROWS) do
            if supply_enabled() and ctx.is_active(row.id) and not ctx.is_checked(row.id) then
                if row.price == delta then vanilla[#vanilla + 1] = row end
                local ask = ap_price(row)
                if ask and ask == delta and ask ~= row.price then asked[#asked + 1] = row end
            end
        end
        if #vanilla > 0 then return vanilla end
        return asked
    end

    local function description_row()
        if not buy_behavior then return nil end
        local view, name = nil, nil
        pcall(function() view = buy_behavior:get_field("_ItemDescriptionView") end)
        pcall(function() name = view and view:get_field("_ItemNameText") end)
        local s = text_string(name)
        if type(s) ~= "string" and name then
            pcall(function() s = name:call("get_Text") end)
            if type(s) ~= "string" then pcall(function() s = name:call("ToString") end) end
        end
        if type(s) ~= "string" then return nil end
        for _, row in ipairs(ROWS) do
            local label = row_label(row)
            if label and (s == label or s:find(label, 1, true)) then return row end
        end
        return nil
    end

    local function selected_index(list)
        if not list then return nil end
        local td = nil
        pcall(function() td = list:get_type_definition() end)
        if not td then return nil end
        for _, method in ipairs(td:get_methods() or {}) do
            local name = method:get_name()
            if name == "get_SelectedIndex" or name == "get_FocusIndex"
                or name == "get_CursorIndex" or name == "get_CurrentIndex" then
                local value = nil
                pcall(function() value = tonumber(method:call(list)) end)
                if value and value >= 0 then return value end
            end
        end
        return nil
    end

    local function highlighted_row()
        local picked = description_row()
        if picked then return picked end
        if not buy_behavior then return nil end
        local list, index = nil, nil
        pcall(function() list = buy_behavior:get_field("_ItemList") end)
        index = selected_index(list)
        if not index then
            local helper = nil
            pcall(function() helper = buy_behavior:get_field("_ScrollListHelper") end)
            pcall(function() list = helper and helper:get_field("_ScrollList") end)
            index = selected_index(list)
        end
        local gid = index and captured and captured[index + 1]
        return gid and by_id[gid] or nil
    end

    local hook_row, hook_at = nil, 0
    local enum_row = {}
    local function remember_buy_arg(v)
        local n = nil
        pcall(function() n = sdk.to_int64(v) end)
        if not n then return end
        local key = tostring(math.floor(n) & 0xFFFFFFFF)
        local row = enum_row[key]
        if not row then return end
        hook_row = row
        hook_at = os.clock()
    end

    local function hook_buy_id()
        local td = sdk.find_type_definition("app.ItemID")
        for _, row in ipairs(ROWS) do
            local field, value = nil, nil
            pcall(function() field = td and td:get_field(row.game_id) end)
            pcall(function() value = field and field:get_data(nil) end)
            local n = type(value) == "number" and value or nil
            if n == nil and value ~= nil then pcall(function() n = sdk.to_int64(value) end) end
            if n then enum_row[tostring(math.floor(n) & 0xFFFFFFFF)] = row end
        end
        local shop = sdk.find_type_definition("app.ShopManager")
        local hooked = 0
        for _, method in ipairs(shop and shop:get_methods() or {}) do
            if method:get_name() == "buy" then
                local ok = pcall(function()
                    sdk.hook(method, function(args)
                        for i = 3, 6 do remember_buy_arg(args[i]) end
                    end, function(retval)
                        return retval
                    end)
                end)
                if ok then hooked = hooked + 1 end
            end
        end
        ctx.info(string.format("supply : id achat x%d, buy x%d", (function()
            local n = 0
            for _ in pairs(enum_row) do n = n + 1 end
            return n
        end)(), hooked))
    end
    pcall(hook_buy_id)

    local payment = nil

    local function stock_gain(hits, base)
        local found = nil
        for _, hit in ipairs(hits) do
            local before = base and base[hit.game_id] or last_stock[hit.game_id]
            if before ~= nil and stock_of(hit.game_id) > before then
                if found then return nil end
                found = hit
            end
        end
        return found
    end

    local function hooked_hit(hits)
        if not hook_row or os.clock() - hook_at > 2 then return nil end
        for _, hit in ipairs(hits) do
            if hit.id == hook_row.id then return hit end
        end
        return nil
    end

    local function send_paid(row, delta)
        payment = nil
        arm(row)
        if complete_purchase(row) then
            ctx.info(string.format("supply : crédits -%d, check envoyé", delta))
        end
    end

    local function resolve_hits(hits)
        return hooked_hit(hits) or highlighted_row() or stock_gain(hits, payment and payment.base)
    end

    local function pay_from_credits()
        if payment then
            local row = nil
            local picked = resolve_hits(payment.hits)
            if picked then
                for _, hit in ipairs(payment.hits) do
                    if hit.id == picked.id then row = hit end
                end
            end
            if row then
                send_paid(row, payment.delta)
            elseif os.clock() > payment.until_t then
                ctx.info(string.format("supply : crédits -%d, aucune ligne", payment.delta))
                payment = nil
            end
        end
        local drops = money_drops()
        local scene = ctx.current_scene and ctx.current_scene() or ""
        if scene ~= "" then
            if credit_scene and credit_scene ~= scene then
                credit_quiet_until = os.clock() + 3
            end
            credit_scene = scene
        end
        local quiet = os.clock() < credit_quiet_until
        local hooked = hook_row and (os.clock() - hook_at) < 2
        local allowed = 0
        if not quiet then
            for _, delta in ipairs(drops) do
                if hooked or #rows_priced(delta) > 0 then
                    allowed = allowed + delta
                end
            end
        end
        share_credits(allowed)
        if quiet or os.clock() > pay_until then return end
        for _, delta in ipairs(drops) do
            local hits = rows_priced(delta)
            local row = #hits == 1 and hits[1] or nil
            if not row and #hits > 1 then
                local base = {}
                for _, hit in ipairs(hits) do
                    base[hit.game_id] = last_stock[hit.game_id]
                    if base[hit.game_id] == nil then base[hit.game_id] = stock_of(hit.game_id) end
                end
                payment = { delta = delta, hits = hits, base = base, until_t = os.clock() + 1.5 }
                local picked = resolve_hits(hits)
                for _, hit in ipairs(hits) do
                    if picked and hit.id == picked.id then row = hit end
                end
            end
            if row then
                send_paid(row, delta)
            elseif #hits == 0 and hooked then
                ctx.info(string.format("supply : crédits -%d, aucune ligne", delta))
            end
        end
    end

    local function ask_missing()
        if os.clock() > shelf_until or not ctx.request_scout then return end
        local now = os.clock()
        for _, row in ipairs(ROWS) do
            if supply_enabled() and ctx.is_active(row.id) and not ctx.is_checked(row.id) and not row_label(row) then
                local k = ctx.id_str(row.id)
                if k and (not asked_at[k] or now - asked_at[k] > 2) then
                    asked_at[k] = now
                    ctx.request_scout(row.id)
                end
            end
        end
    end

    ctx.on_tick("supply_pay", function()
        if queued and not ctx.is_checked(queued.id) then
            local row = queued
            queued = nil
            arm(row)
            complete_purchase(row)
        end
        pay_from_credits()
    end, { every = 0 })

    ctx.on_tick("supply", function()
        local fresh = os.clock() <= shelf_until
        local job = pending
        if job then
            if os.clock() > job.until_t then
                pending = nil
            else
                local delta = stock_of(job.game_id) - job.base
                if delta > 0 then
                    pending = nil
                    local removed = take_vanilla(job, delta)
                    if not ctx.is_checked(job.id) then complete_purchase(job) end
                    local key = ctx.id_str(job.id)
                    local loc = ctx.locations and ctx.locations[key]
                    ctx.info(string.format("supply : %s acheté, retiré x%d",
                        loc and loc.name or tostring(job.id), removed))
                end
            end
        end
        if fresh then
            for _, row in ipairs(ROWS) do
                if payment and payment.base[row.game_id] ~= nil then
                elseif not pending or pending.game_id ~= row.game_id then
                    last_stock[row.game_id] = stock_of(row.game_id)
                end
            end
            ask_missing()
        end
    end, { every = 0.25 })

    local function price_of(row)
        return ap_price(row) or row.price
    end

    local function already_bought(row)
        local key = ctx.id_str and ctx.id_str(row.id)
        local set = ctx.session and ctx.session.supply_bought
        if set and key and set[key] then return true end
        return ctx.is_checked and ctx.is_checked(row.id)
    end

    local function grace_buy(row)
        local s = ctx.session
        if not s or not row then return end
        if ctx.current_character and ctx.current_character() ~= "grace" then return end
        if not s.grace_tracker then return end
        if not supply_enabled() or not ctx.is_active(row.id) or already_bought(row) then return end
        local price = price_of(row)
        local have = math.max(0, math.floor(tonumber(s.grace_credits) or 0))
        if have < price then
            if ctx.push_message then
                ctx.push_message(ctx.TF("Pas assez de crédits (%d / %d).", have, price), ctx.COLORS.warn)
            end
            return
        end
        local label = row_label(row)
        local sent = ctx.mark_checked and ctx.mark_checked(row.id)
        if not sent then return end
        s.grace_credits = have - price
        s.supply_bought = s.supply_bought or {}
        local key = ctx.id_str(row.id)
        if key then s.supply_bought[key] = true end
        if ctx.save_session then ctx.save_session() end
        if ctx.flush_location_checks then ctx.flush_location_checks() end
        ctx.info(string.format("Grace achète %s pour %d (reste %d)",
            label or tostring(row.id), price, s.grace_credits))
        if ctx.push_message then
            ctx.push_message(ctx.TF("Acheté : %s  -%d", label or tostring(row.id), price), ctx.COLORS.ok, "check")
        end
    end

    function ctx.draw_grace_supply()
        local s = ctx.session
        if not s then return end
        imgui.text(ctx.TF("Crédits de Grace : %d", math.floor(tonumber(s.grace_credits) or 0)))
        if ctx.current_character and ctx.current_character() ~= "grace" then
            imgui.text(ctx.T("Passe sur Grace pour acheter."))
            return
        end
        if not s.grace_tracker then
            imgui.text(ctx.T("Le Tactical Tracker n'est pas en main."))
            return
        end
        if not supply_enabled() then
            imgui.text(ctx.T("Supply Box désactivé dans le YAML."))
            return
        end
        local any = false
        for _, row in ipairs(ROWS) do
            if ctx.is_active(row.id) and not already_bought(row) then
                any = true
                if not row_label(row) and ctx.request_scout then ctx.request_scout(row.id) end
                local label = row_label(row) or "..."
                local price = price_of(row)
                imgui.text(string.format("%s    %d", label, price))
                imgui.same_line()
                if imgui.button(ctx.T("Acheter") .. "##grace_buy_" .. tostring(row.id)) then
                    grace_buy(row)
                end
            end
        end
        if not any then imgui.text(ctx.T("Aucune ligne à acheter.")) end
    end
end
