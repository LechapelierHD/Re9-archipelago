-- tout est gardé hors ligne : un ramassage sans connexion part à la connexion suivante

return function(ctx)
    local function empty_session()
        return {
            seed = "",
            slot = "",
            last_index = 0,
            checked = {},
            goal_sent = false,
            active = {},
            items = {},
            key_items = "",
            flag_items = "",
            enemy_drops = "",
            supply_box = "",
            supply_prices = {},
            death_link = "",
            goal = "",
            apworld_version = "",
            difficulty = "",
            scouts = {},
            in_hand = {},
            grant_pending = {},
            picked_at = {},
            hints = {},
            chapter_keys = {},
            received_counts = {},
            received_upto = 0,
            since_save = {},
            fired_pickup_flags = {},
            supply_bought = {},
            grace_credits = 0,
            grace_tracker = false,
        }
    end

    ctx.session = empty_session()

    -- coalesce : mark_checked + scouts + hints peuvent arriver en rafale
    local session_dirty, last_flush = false, 0
    local SAVE_COALESCE = 0.35

    function ctx.save_session(force)
        if force ~= true then
            session_dirty = true
            if (os.clock() - last_flush) < SAVE_COALESCE then return true end
        end
        session_dirty = false
        last_flush = os.clock()
        local ok, e = pcall(function()
            json.dump_file(ctx.FILES.session, ctx.session, 4)
        end)
        if not ok then ctx.err("sauvegarde de la session impossible : " .. tostring(e)) end
        return ok
    end

    function ctx.flush_session()
        if session_dirty then return ctx.save_session(true) end
        return true
    end

    local function copy_set(src)
        local out = {}
        if type(src) == "table" then
            for k, v in pairs(src) do
                local id = ctx.id_str(k)
                if id and v then out[id] = true end
            end
        end
        return out
    end

    function ctx.load_session()
        local data = json.load_file(ctx.FILES.session)
        if type(data) ~= "table" then
            -- créé tout de suite, sinon REFramework affiche une erreur
            ctx.save_session()
            return
        end
        local s = empty_session()
        s.seed = tostring(data.seed or "")
        s.slot = tostring(data.slot or "")
        s.last_index = math.floor(tonumber(data.last_index) or 0)
        s.goal_sent = data.goal_sent == true
        s.checked = copy_set(data.checked)
        s.supply_bought = copy_set(data.supply_bought)
        s.grace_credits = math.max(0, math.floor(tonumber(data.grace_credits) or 0))
        s.grace_tracker = data.grace_tracker == true
        s.active = copy_set(data.active)
        s.in_hand = copy_set(data.in_hand)
        -- grant_pending jamais repris : un swap interrompu laisse ReceivedItems livrer
        if type(data.picked_at) == "table" then
            for loc, p in pairs(data.picked_at) do
                local id = ctx.id_str(loc)
                if id and type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3]) then
                    s.picked_at[id] = { tonumber(p[1]), tonumber(p[2]), tonumber(p[3]) }
                end
            end
        end
        if type(data.hints) == "table" then
            for _, h in ipairs(data.hints) do
                if type(h) == "table" and type(h.text) == "string" then
                    s.hints[#s.hints + 1] = { text = h.text, found = h.found == true }
                end
            end
        end
        s.key_items = tostring(data.key_items or "")
        s.flag_items = tostring(data.flag_items or "")
        s.enemy_drops = tostring(data.enemy_drops or "")
        s.supply_box = tostring(data.supply_box or "")
        s.supply_prices = {}
        if type(data.supply_prices) == "table" then
            for code, n in pairs(data.supply_prices) do
                local id = ctx.id_str(code)
                if id and tonumber(n) then s.supply_prices[id] = math.floor(tonumber(n)) end
            end
        end
        s.death_link = tostring(data.death_link or "")
        s.goal = tostring(data.goal or "")
        s.apworld_version = tostring(data.apworld_version or "")
        s.difficulty = tostring(data.difficulty or "")
        s.deathlink_mode = data.deathlink_mode
        if type(data.chapter_keys) == "table" then
            for ch, req in pairs(data.chapter_keys) do
                if type(req) == "table" then
                    local r = {}
                    for code, n in pairs(req) do
                        local id = ctx.id_str(code)
                        if id and tonumber(n) then r[id] = math.floor(tonumber(n)) end
                    end
                    s.chapter_keys[tostring(ch)] = r
                end
            end
        end
        if type(data.received_counts) == "table" then
            for code, n in pairs(data.received_counts) do
                local id = ctx.id_str(code)
                if id and tonumber(n) then s.received_counts[id] = math.floor(tonumber(n)) end
            end
        end
        s.received_upto = math.floor(tonumber(data.received_upto) or 0)
        if type(data.fired_pickup_flags) == "table" then
            for k, v in pairs(data.fired_pickup_flags) do
                if v then s.fired_pickup_flags[tostring(k)] = true end
            end
        end
        if type(data.since_save) == "table" then
            for _, d in ipairs(data.since_save) do
                if type(d) == "table" and type(d.id) == "string" then
                    s.since_save[#s.since_save + 1] = {
                        id = d.id, hand = math.floor(tonumber(d.hand) or 0), box = math.floor(tonumber(d.box) or 0),
                    }
                end
            end
        end
        if type(data.items) == "table" then
            for code, v in pairs(data.items) do
                if type(v) == "table" and v.id then
                    s.items[tostring(code)] = { id = tostring(v.id), count = math.floor(tonumber(v.count) or 1) }
                end
            end
        end
        if type(data.scouts) == "table" then
            for loc, v in pairs(data.scouts) do
                local id = ctx.id_str(loc)
                if id and type(v) == "table" and tonumber(v.item) then
                    s.scouts[id] = {
                        item = math.floor(tonumber(v.item)), player = math.floor(tonumber(v.player) or 0),
                        flags = math.floor(tonumber(v.flags) or 0), mine = v.mine == true,
                        name = tostring(v.name or ""), owner = tostring(v.owner or ""),
                    }
                end
            end
        end
        ctx.session = s
    end

    -- autre seed ou autre slot = nouvelle partie ; seed vide = ramassages d'avant la 1re connexion, gardés
    -- retourne true si l'ancienne session a été archivée (changement de partie)
    function ctx.bind_session(seed, slot)
        seed, slot = tostring(seed or ""), tostring(slot or "")
        local s = ctx.session
        local switched = false
        if s.seed == "" then
            s.seed, s.slot = seed, slot
        elseif s.seed ~= seed or s.slot ~= slot then
            switched = true
            ctx.warn(string.format("nouvelle partie (seed %s / slot %s) : état précédent archivé", seed, slot))
            pcall(function()
                json.dump_file(ctx.DATA_DIR .. "session_" .. s.seed .. "_" .. s.slot .. ".json", s, 4)
            end)
            ctx.session = empty_session()
            ctx.session.seed, ctx.session.slot = seed, slot
        end
        ctx.save_session()
        return switched
    end

    local function id_set(list)
        local out = {}
        for _, id in ipairs(list or {}) do
            local k = ctx.id_str(id)
            if k then out[k] = true end
        end
        return out
    end

    -- retire checked/sent/scouts qui ne sont plus dans active (changement de difficulté / seed)
    local function prune_inactive_progress()
        local active = ctx.session.active or {}
        local function scrub(map)
            if type(map) ~= "table" then return 0 end
            local n = 0
            for id in pairs(map) do
                if active[id] ~= true then
                    map[id] = nil
                    n = n + 1
                end
            end
            return n
        end
        local n = scrub(ctx.session.checked) + scrub(ctx.session.sent)
        if type(ctx.session.scouts) == "table" then n = n + scrub(ctx.session.scouts) end
        if type(ctx.session.picked_at) == "table" then n = n + scrub(ctx.session.picked_at) end
        return n
    end

    -- source la plus sûre d'abord : serveur, lanceur, slot_data, calcul local, session précédente
    function ctx.apply_slot_data(sd, seed, room)
        local s = ctx.session
        room = type(room) == "table" and room or {}
        local same_room = room.seed == nil or room.seed == "" or room.seed == tostring(seed or "")
        if not same_room then
            ctx.warn("ap_connection.json décrit une autre seed (" .. tostring(room.seed) .. ") : ignoré")
            room = {}
        end

        local function pick(...)
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                if v ~= nil and tostring(v) ~= "" then return tostring(v) end
            end
            return ""
        end
        s.difficulty = pick(sd.difficulty, room.difficulty, s.difficulty)
        s.key_items = pick(sd.key_items, room.key_items, s.key_items)
        s.flag_items = pick(sd.flag_items, room.flag_items, s.flag_items)
        s.enemy_drops = pick(sd.enemy_drops, room.enemy_drops, s.enemy_drops)
        s.supply_box = pick(sd.supply_box, room.supply_box, s.supply_box)
        local price_text = pick(sd.supply_prices, room.supply_prices)
        if price_text ~= "" then
            s.supply_prices = {}
            for code, n in price_text:gmatch("(%d+):(%d+)") do
                s.supply_prices[code] = tonumber(n)
            end
        end
        s.death_link = pick(sd.death_link, room.death_link, s.death_link)
        s.goal = pick(sd.goal, s.goal)
        s.apworld_version = pick(sd.apworld_version, s.apworld_version)

        -- passée par la DLL, la liste peut arriver tronquée (déjà vu : 12 ids sur 484)
        local function trusted(list)
            if type(list) ~= "table" or #list == 0 then return false end
            for _, id in ipairs(list) do
                if not ctx.locations[ctx.id_str(id) or ""] then return false end
            end
            local expected = tonumber(sd.check_count)
            if expected == nil then
                expected = select(2, ctx.compute_active(s.difficulty, s.key_items, s.flag_items, s.enemy_drops, s.supply_box))
            end
            return expected == nil or expected == #list
        end

        local source
        ctx.active_source_args = nil
        if trusted(sd.server_locations) then
            s.active, source = id_set(sd.server_locations), "serveur"
        elseif type(room.locations) == "table" and #room.locations > 0 then
            s.active, source = id_set(room.locations), "lanceur"
        elseif trusted(sd.locations) then
            s.active, source = id_set(sd.locations), "slot_data"
        else
            local computed = ctx.compute_active(s.difficulty, s.key_items, s.flag_items, s.enemy_drops, s.supply_box)
            if computed and next(computed) ~= nil then
                s.active, source = computed, "calcul local"
                ctx.active_source_args = { s.difficulty, s.key_items, s.flag_items, s.enemy_drops, s.supply_box }
            elseif next(s.active) ~= nil then
                source = "session précédente"
            end
        end

        if ctx.VANILLA_LOCATIONS then
            for id in pairs(ctx.VANILLA_LOCATIONS) do
                s.active[id] = nil
            end
        end
        if ctx.is_story_name and ctx.locations then
            for id, loc in pairs(ctx.locations) do
                if ctx.is_story_name(loc.vanilla_item) then
                    s.active[id] = nil
                end
            end
        end
        if (s.supply_box == "false" or s.supply_box == "0") and ctx.locations then
            for id, loc in pairs(ctx.locations) do
                if (loc.name or ""):sub(1, 13) == "Supply Box - " then
                    s.active[id] = nil
                end
            end
        end

        if type(sd.items) == "table" and next(sd.items) ~= nil then
            s.items = sd.items
        end
        if type(sd.chapter_keys) == "string" then
            s.chapter_keys = {}
            for ch, list in sd.chapter_keys:gmatch("([^;=]+)=([^;]*)") do
                local req = {}
                for code, n in list:gmatch("(%d+):(%d+)") do req[code] = tonumber(n) end
                s.chapter_keys[ch] = req
            end
        end
        local pruned = prune_inactive_progress()
        if pruned > 0 then
            ctx.warn(string.format("session : %d id(s) hors seed retirés (checked/sent/scout)", pruned))
        end
        ctx.save_session()
        ctx.active_source = source
        ctx.info(string.format("slot : %d checks (source : %s), %d objets, objets clés %s, difficulté %s",
            ctx.count_table(s.active), tostring(source or "aucune"), ctx.count_table(s.items), s.key_items, s.difficulty))
        return source ~= nil
    end

    function ctx.has_slot_data()
        return next(ctx.session.active) ~= nil
    end

    function ctx.is_active(id)
        local k = ctx.id_str(id)
        return k ~= nil and ctx.session.active[k] == true
    end

    function ctx.is_checked(id)
        return ctx.session.checked[ctx.id_str(id)] == true
    end

    function ctx.mark_checked(id)
        local k = ctx.id_str(id)
        if not k or ctx.session.checked[k] then return false end
        -- jamais un check hors seed (ex. Insanity-only en Modern → KeyError serveur)
        if ctx.session.active[k] ~= true then
            ctx.warn("check ignoré (pas dans ce slot) : " .. k)
            return false
        end
        if ctx.difficulty_allows_checks and not ctx.difficulty_allows_checks() then
            ctx.warn("check bloqué : difficulté jeu ≠ seed")
            return false
        end
        ctx.session.checked[k] = true
        ctx.save_session()
        return true
    end

    -- anti-double : grant local au ramassage → ReceivedItems ne redonne pas
    function ctx.begin_local_grant(loc_id)
        local k = ctx.id_str(loc_id)
        if not k then return end
        ctx.session.grant_pending = ctx.session.grant_pending or {}
        ctx.session.grant_pending[k] = true
        ctx.save_session()
    end

    function ctx.mark_local_grant(loc_id)
        local k = ctx.id_str(loc_id)
        if not k then return end
        ctx.session.in_hand = ctx.session.in_hand or {}
        ctx.session.in_hand[k] = true
        if ctx.session.grant_pending then ctx.session.grant_pending[k] = nil end
        ctx.save_session()
    end

    function ctx.clear_local_grant_pending(loc_id)
        local k = ctx.id_str(loc_id)
        if not k or not ctx.session.grant_pending or not ctx.session.grant_pending[k] then return end
        ctx.session.grant_pending[k] = nil
        ctx.save_session()
    end

    -- done, pending
    function ctx.is_local_grant(loc_id)
        local k = ctx.id_str(loc_id)
        if not k then return false, false end
        return (ctx.session.in_hand or {})[k] == true, (ctx.session.grant_pending or {})[k] == true
    end

    -- le statut final (not found, found...) change : on compare le texte sans lui
    function ctx.add_hint(text)
        text = ctx.display_name(text)
        local body, status = text:match("^(.-)%s*%(([^()]*)%)%s*$")
        body = body or text
        local found = status ~= nil and string.lower(status) == "found"
        ctx.session.hints = ctx.session.hints or {}
        for _, h in ipairs(ctx.session.hints) do
            local old = ctx.display_name(h.text)
            local hb = old:match("^(.-)%s*%([^()]*%)%s*$") or old
            if hb == body then
                if h.text == text then return false end
                h.text, h.found = text, found
                ctx.save_session()
                return true
            end
        end
        table.insert(ctx.session.hints, 1, { text = text, found = found })
        ctx.save_session()
        return true
    end

    -- le serveur renvoie toute la liste à la connexion
    function ctx.count_received(index, code)
        local s = ctx.session
        local id = ctx.id_str(code)
        if not id or index < s.received_upto then return end
        s.received_counts[id] = (s.received_counts[id] or 0) + 1
        s.received_upto = index + 1
    end

    -- « [Hint]: X's Objet is at <emplacement> in <mon slot>'s World. (not found) »
    local location_by_name = nil
    local function pattern_escape(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
    function ctx.hinted_locations()
        local out = {}
        local slot = ctx.session.slot
        if slot == "" or not ctx.locations then return out end
        if not location_by_name then
            location_by_name = {}
            for id, loc in pairs(ctx.locations) do
                location_by_name[string.lower(loc.name)] = id
                if ctx.display_name then location_by_name[string.lower(ctx.display_name(loc.name))] = id end
            end
        end
        local suffix = " in " .. pattern_escape(slot) .. "'s World"
        for _, h in ipairs(ctx.session.hints or {}) do
            if not h.found then
                local where = h.text:match(" is at (.+)" .. suffix)
                local id = where and location_by_name[string.lower(where)]
                if id then out[id] = true end
            end
        end
        return out
    end

    -- perdus si le jeu recharge avant de sauvegarder (vide au requestSave)
    function ctx.note_delivery(game_id, hand, box)
        hand, box = math.max(0, math.floor(tonumber(hand) or 0)), math.max(0, math.floor(tonumber(box) or 0))
        if type(game_id) ~= "string" or hand + box == 0 then return end
        local list = ctx.session.since_save
        for i = 1, #list do
            local d = list[i]
            if d.id == game_id then
                d.hand = (d.hand or 0) + hand
                d.box = (d.box or 0) + box
                ctx.save_session()
                return
            end
        end
        list[#list + 1] = { id = game_id, hand = hand, box = box }
        ctx.save_session()
    end

    function ctx.clear_deliveries()
        if #ctx.session.since_save == 0 then return end
        ctx.session.since_save = {}
        ctx.save_session()
    end

    function ctx.deliveries_pending()
        local list = ctx.session.since_save
        if type(list) ~= "table" then return 0, {} end
        local rows, n = {}, 0
        for i = 1, #list do
            local d = list[i]
            local qty = (d.hand or 0) + (d.box or 0)
            if qty > 0 then
                n = n + 1
                local name = (ctx.item_display_name and ctx.item_display_name(d.id)) or d.id
                rows[#rows + 1] = {
                    id = d.id, name = name, hand = d.hand or 0, box = d.box or 0, qty = qty,
                }
            end
        end
        return n, rows
    end

    -- réinjecte depuis_save (mort / load / bouton UI). Ne vide pas la liste : un 2e reload sans save doit pouvoir rejouer
    function ctx.replay_deliveries()
        local n = select(1, ctx.deliveries_pending())
        if n == 0 then return 0, "rien à redonner" end
        if not ctx.is_game_ready or not ctx.is_game_ready() then return 0, "jeu pas prêt" end
        if ctx.is_safe_to_mutate and not ctx.is_safe_to_mutate() then return 0, "pas maintenant (load / ciné)" end

        local list = ctx.session.since_save
        local grace = ctx.current_character and ctx.current_character() == "grace"
        local user = ctx.player_inventory_user and ctx.player_inventory_user() or ctx.GRACE_HAND_USER
        local given, failed = 0, 0
        for i = 1, #list do
            local d = list[i]
            local to_box = d.box or 0
            local hand = d.hand or 0
            if hand > 0 then
                local added = 0
                if grace and ctx.inject_to_hand then
                    added = select(1, ctx.inject_to_hand(d.id, hand, user)) or 0
                end
                to_box = to_box + (hand - added)
            end
            if to_box > 0 then
                if ctx.inject_item then
                    local ok = ctx.inject_item(d.id, to_box)
                    if ok then given = given + 1 else failed = failed + 1 end
                else
                    failed = failed + 1
                end
            elseif hand > 0 then
                given = given + 1
            end
        end
        return given, failed > 0 and string.format("%d échec(s)", failed) or nil
    end

    function ctx.chapter_missing_keys(chapter)
        local req = ctx.session.chapter_keys and ctx.session.chapter_keys[chapter]
        local out = {}
        for code, need in pairs(req or {}) do
            local have = ctx.session.received_counts[code] or 0
            if have < need then
                local known = ctx.ap_items[code]
                out[#out + 1] = { name = ctx.display_name(known and known.name or code), have = have, need = need }
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end

    function ctx.checked_count()
        local n = 0
        for k in pairs(ctx.session.checked) do
            if ctx.session.active[k] then n = n + 1 end
        end
        return n
    end

    ctx.load_session()
end
