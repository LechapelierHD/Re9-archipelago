-- Tracker de Grace. Le compte de Leon n'est pas touché.
-- it99_50_007 va dans User00. Les crédits sont session.grace_credits.

return function(ctx)
    local TRACKER = "it99_50_007"
    local paid = {}
    local reward_field = nil
    local reward_missing = false
    local as_grace = false
    local armed = false

    local function credits()
        local s = ctx.session
        if not s then return 0 end
        s.grace_credits = math.max(0, math.floor(tonumber(s.grace_credits) or 0))
        return s.grace_credits
    end

    local function holding()
        if not ctx.hand_contents then return false end
        for _, e in ipairs(ctx.hand_contents(ctx.GRACE_HAND_USER) or {}) do
            if e.id == TRACKER and (tonumber(e.count) or 0) > 0 then return true end
        end
        return false
    end

    local function base_pay()
        local d = ctx.session and tostring(ctx.session.difficulty or "") or ""
        if d == "Insanity" then return 1000 end
        return 500
    end

    local function reward_of(obj)
        if reward_missing or not obj then return nil end
        if reward_field then
            local v = nil
            pcall(function() v = tonumber(obj:get_field(reward_field)) end)
            if v and v > 0 and v < 1000000 then return math.floor(v) end
            return nil
        end
        local fields = nil
        pcall(function() fields = obj:get_type_definition():get_fields() end)
        for _, f in ipairs(fields or {}) do
            local name = nil
            pcall(function() name = f:get_name() end)
            if type(name) == "string" and (name:find("Credit", 1, true) or name:find("Reward", 1, true)) then
                local v = nil
                pcall(function() v = tonumber(obj:get_field(name)) end)
                if v and v > 0 and v < 1000000 then
                    reward_field = name
                    ctx.info("tracker Grace : champ " .. name)
                    return math.floor(v)
                end
            end
        end
        reward_missing = true
        return nil
    end

    local function pay(obj)
        if not as_grace or not armed then return end
        local addr = 0
        pcall(function() addr = obj:get_address() end)
        local now = os.clock()
        if addr ~= 0 then
            if paid[addr] and now - paid[addr] < 5 then return end
            paid[addr] = now
        end
        local amount = reward_of(obj) or base_pay()
        ctx.session.grace_credits = credits() + amount
        if ctx.save_session then ctx.save_session() end
        ctx.info(string.format("tracker Grace : +%d (total %d)", amount, ctx.session.grace_credits))
    end

    local td = sdk.find_type_definition("app.EnemyContext")
    local method = td and td:get_method("onDead")
    if method then
        sdk.hook(method, function(args)
            local obj = sdk.to_managed_object(args[2])
            if obj then pcall(pay, obj) end
        end)
        ctx.info("tracker Grace : mort accrochée")
    else
        ctx.warn("tracker Grace : EnemyContext.onDead absent")
    end

    local tracker_key = nil
    local function build_tracker_key()
        local td = sdk.find_type_definition("app.ItemID")
        local field = td and td:get_field(TRACKER)
        local value = nil
        pcall(function() value = field and field:get_data(nil) end)
        local n = type(value) == "number" and value or nil
        if n == nil and value ~= nil then pcall(function() n = sdk.to_int64(value) end) end
        if n then tracker_key = tostring(math.floor(n) & 0xFFFFFFFF) end
    end
    pcall(build_tracker_key)

    local function is_tracker_arg(v)
        if not tracker_key or v == nil then return false end
        local n = nil
        pcall(function() n = sdk.to_int64(v) end)
        if not n then return false end
        return tostring(math.floor(n) & 0xFFFFFFFF) == tracker_key
    end

    local function is_grace_hand(inv)
        if not inv then return false end
        local name, board = nil, nil
        pcall(function()
            local key = inv:get_field("_InventoryKey")
            board = tonumber(key:get_field("_BoardType"))
            local user = key:get_field("_User")
            name = user and tostring(user:get_field("_Name"))
        end)
        return board == 0 and name == (ctx.GRACE_HAND_USER or "User00")
    end

    local allowed_logged = false
    local inv_td = sdk.find_type_definition("app.Inventory")
    for _, method in ipairs(inv_td and inv_td:get_methods() or {}) do
        if method:get_name() == "canMergeOrAdd" then
            local item_arg = nil
            local self_arg = nil
            pcall(function()
                sdk.hook(method, function(args)
                    self_arg = args[2]
                    item_arg = args[3]
                end, function(retval)
                    local item, self = item_arg, self_arg
                    item_arg, self_arg = nil, nil
                    if not is_tracker_arg(item) then return retval end
                    local inv = sdk.to_managed_object(self)
                    if not is_grace_hand(inv) then return retval end
                    if not allowed_logged then
                        allowed_logged = true
                        ctx.info("tracker Grace : coffre autorisé pour it99_50_007")
                    end
                    return sdk.to_ptr(1)
                end)
            end)
        end
    end
    ctx.info("tracker Grace : prise coffre prête")

    local function hand_of(user_name)
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local elems = nil
        pcall(function()
            elems = mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end)
        for _, entry in ipairs(elems or {}) do
            local inv, name, board = nil, nil, nil
            pcall(function()
                inv = entry:get_field("value")
                local key = inv:get_field("_InventoryKey")
                board = tonumber(key:get_field("_BoardType"))
                local user = key:get_field("_User")
                name = tostring(user:get_field("_Name"))
            end)
            if inv and board == 0 and name == user_name then return inv end
        end
        return nil
    end

    -- Le coffre grise it99_50_007 : User00 n'a pas la catégorie Storage.
    -- On prête les catégories de Leon le temps du transfert, puis on les rend.
    local function give_tracker()
        local grace = hand_of(ctx.GRACE_HAND_USER or "User00")
        local leon = hand_of("User01")
        local saved = nil
        if grace and leon then
            pcall(function()
                saved = grace:get_field("_PanelItemCategories")
                local bits = leon:get_field("_PanelItemCategories")
                if bits then grace:set_field("_PanelItemCategories", bits) end
            end)
        end
        local added, err = 0, nil
        if ctx.transfer_box_to_hand then
            local ok, a, b = pcall(ctx.transfer_box_to_hand, TRACKER, 1, ctx.GRACE_HAND_USER)
            if ok then added, err = a or 0, b else err = a end
        end
        if (added or 0) <= 0 and ctx.inject_to_hand then
            local ok, a, b = pcall(ctx.inject_to_hand, TRACKER, 1, ctx.GRACE_HAND_USER)
            if ok then added, err = a or 0, b else err = a end
        end
        if grace and saved then
            pcall(function() grace:set_field("_PanelItemCategories", saved) end)
        end
        return added or 0, err
    end

    local next_give = 0
    ctx.on_tick("grace_tracker", function()
        if not ctx.session then return end
        as_grace = ctx.current_character and ctx.current_character() == "grace"
        armed = as_grace and ctx.session.grace_tracker == true and holding()
        if not as_grace then return end
        if holding() then
            if not ctx.session.grace_tracker then
                ctx.session.grace_tracker = true
                if ctx.save_session then ctx.save_session() end
                ctx.info("tracker Grace : it99_50_007 en main")
            end
            return
        end
        local now = os.clock()
        if now < next_give then return end
        next_give = now + 2
        local added, err = give_tracker()
        if added and added > 0 then
            ctx.session.grace_tracker = true
            if ctx.save_session then ctx.save_session() end
            ctx.info("tracker Grace : it99_50_007 donné")
            if ctx.push_message then
                ctx.push_message(ctx.T("Tactical Tracker de Grace"), ctx.COLORS.ok, "item")
            end
        else
            ctx.warn("tracker Grace : pas donné (" .. tostring(err) .. ")")
        end
    end, { every = 1 })
end
