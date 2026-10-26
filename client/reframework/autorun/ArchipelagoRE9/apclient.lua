-- REFramework et la DLL ont chacun leur Lua : une table remplie dans un rappel de la DLL est illisible ici.
-- Les rappels postent donc du texte dans `inbox`, décodé par process_inbox(), et on ne passe que des tables neuves à la DLL.
-- Mode bridge : ap_bridge.py (websockets officiel + permessage-deflate) parle au serveur ;
-- Lua ↔ bridge via bridge_inbox.jsonl / bridge_cmd.jsonl (même protocol inbox).

return function(ctx)
    local AP = nil
    local ap = nil
    local bridge = {
        active = false,       -- heartbeat récent
        connected = false,    -- slot Connected côté Python
        inbox_read = 0,
    }

    local st = {
        server = "",
        slot = "",
        password = "",
        status = "idle",          -- idle / connecting / connected / refused / error / disabled
        status_text = "Pas de session configurée",
        player_number = nil,
        sent = {},                -- envoyé ou déjà connu du serveur sur ce socket
        item_queue = {},
        item_fail_ticks = 0,
        refused = false,
        last_retry = 0,
        received_total = 0,
    }
    ctx.ap_state = st
    ctx.ap_bridge = bridge

    -- plus de skip : on réessaie avec backoff (load / ciné / coffre absent)
    local FAIL_WARN_TICKS = 180        -- ~3 s : 1er toast, puis rappel périodique
    -- attente bridge Python / reconnexion (était 5 s → connexion perçue comme très lente)
    local RETRY_SECONDS = 1

    local T, TF = ctx.T, ctx.TF

    -- fmt reste en français, traduit seulement à l'affichage
    local status_fmt, status_args = "Pas de session configurée", {}
    local function set_status(kind, fmt, ...)
        status_fmt, status_args = fmt, { ... }
        st.status, st.status_text = kind, TF(fmt, ...)
    end

    function ctx.ap_status_text()
        local ok, text = pcall(TF, status_fmt, table.unpack(status_args))
        return ok and text or st.status_text
    end

    do
        local opener, load_err = package.loadlib("lua-apclientpp.dll", "luaopen_apclientpp")
        if not opener then
            ctx.warn("lua-apclientpp.dll introuvable (fallback bridge Python possible) : " .. tostring(load_err))
        else
            local ok, lib = pcall(opener)
            if ok and type(lib) == "table" then
                AP = lib
            else
                ctx.warn("lua-apclientpp.dll invalide (fallback bridge) : " .. tostring(lib))
            end
        end
    end

    do
        local off = json.load_file(ctx.FILES.bridge_offset)
        if type(off) == "table" and type(off.lines_read) == "number" then
            bridge.inbox_read = math.max(0, math.floor(off.lines_read))
        end
    end

    local inbox = { n = 0, read = 0 }

    local function post(kind, payload)
        local n = inbox.n + 1
        inbox["m" .. n] = kind .. "|" .. (payload or "")
        inbox.n = n
    end

    local function clear_inbox()
        while inbox.read < inbox.n do
            inbox.read = inbox.read + 1
            inbox["m" .. inbox.read] = nil
        end
    end

    local function bridge_data_path(rel)
        return "reframework\\data\\" .. tostring(rel or ""):gsub("/", "\\")
    end

    local function bridge_save_offset()
        pcall(function()
            json.dump_file(ctx.FILES.bridge_offset, { lines_read = bridge.inbox_read }, 2)
        end)
    end

    local function bridge_refresh()
        -- Comme RE2R : DLL native d'abord — ignore le pont Python s'il tourne encore
        if AP ~= nil then
            bridge.active, bridge.connected = false, false
            return false
        end
        local s = json.load_file(ctx.FILES.bridge_status)
        if type(s) ~= "table" or not s.alive then
            bridge.active, bridge.connected = false, false
            return false
        end
        local ts = tonumber(s.ts) or 0
        bridge.active = ((os.time() + 0.0) - ts) <= 8.0
        bridge.connected = bridge.active and tostring(s.state or "") == "connected"
        return bridge.active
    end

    local function bridge_cmd(obj)
        local parts = { '{"cmd":"' .. tostring(obj.cmd or "") .. '"' }
        if obj.locations then
            local ids = {}
            for i, id in ipairs(obj.locations) do ids[i] = tostring(math.floor(tonumber(id) or 0)) end
            parts[#parts + 1] = ',"locations":[' .. table.concat(ids, ",") .. "]"
        end
        if obj.status ~= nil then parts[#parts + 1] = ',"status":' .. tostring(math.floor(tonumber(obj.status) or 0)) end
        if obj.text then
            local t = tostring(obj.text):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ")
            parts[#parts + 1] = ',"text":"' .. t .. '"'
        end
        if obj.tags then
            local tags = {}
            for i, t in ipairs(obj.tags) do tags[i] = '"' .. tostring(t) .. '"' end
            parts[#parts + 1] = ',"tags":[' .. table.concat(tags, ",") .. "]"
        end
        if obj.items_handling ~= nil then
            parts[#parts + 1] = ',"items_handling":' .. tostring(math.floor(tonumber(obj.items_handling) or 0))
        end
        if type(obj.data) == "table" then
            local d = obj.data
            local chapter = tostring(d.re9_chapter or ""):gsub('"', "")
            local extra = chapter ~= "" and (',"re9_chapter":"' .. chapter .. '"') or ""
            parts[#parts + 1] = string.format(
                ',"data":{"time":%.3f,"cause":"%s","source":"%s"%s}',
                tonumber(d.time) or 0,
                tostring(d.cause or ""):gsub('"', ""),
                tostring(d.source or ""):gsub('"', ""),
                extra)
        end
        if obj.slots then
            local slots = {}
            for i, s in ipairs(obj.slots) do slots[i] = tostring(math.floor(tonumber(s) or 0)) end
            parts[#parts + 1] = ',"slots":[' .. table.concat(slots, ",") .. "]"
        end
        if obj.create_as_hint ~= nil then
            parts[#parts + 1] = ',"create_as_hint":' .. tostring(math.floor(tonumber(obj.create_as_hint) or 0))
        end
        local line = table.concat(parts) .. "}"
        pcall(function()
            local f = io.open(bridge_data_path(ctx.FILES.bridge_cmd), "a")
            if not f then error("open bridge_cmd") end
            f:write(line .. "\n")
            f:close()
        end)
    end

    local function bridge_pull_inbox()
        local ok, content = pcall(function()
            local f = io.open(bridge_data_path(ctx.FILES.bridge_inbox), "r")
            if not f then return nil end
            local t = f:read("*a")
            f:close()
            return t
        end)
        if not ok or type(content) ~= "string" or content == "" then return end
        local n = 0
        for line in content:gmatch("[^\n]+") do
            n = n + 1
            if n > bridge.inbox_read and line ~= "" then
                local kind, payload = line:match("^(%a+)|(.*)$")
                if kind then post(kind, payload or "") end
            end
        end
        if n > bridge.inbox_read then
            bridge.inbox_read = n
            bridge_save_offset()
        end
    end

    local function is_slot_connected()
        if bridge.active and bridge.connected then return true end
        if ap == nil or AP == nil then return false end
        local ok, state = pcall(function() return ap:get_state() end)
        return ok and state == AP.State.SLOT_CONNECTED
    end
    ctx.ap_is_connected = is_slot_connected

    local function read_connection_info()
        local data = json.load_file(ctx.FILES.connection)
        if type(data) ~= "table" then
            local legacy = json.load_file("re9_ap_session.json")   -- RE9 AP Wizard
            if type(legacy) == "table" then
                data = { server_address = legacy.server, slot_name = legacy.slot_name, password = legacy.password }
            end
        end
        if type(data) ~= "table" then return false end
        st.server = tostring(data.server_address or data.server or "")
        st.slot = tostring(data.slot_name or data.slot or "")
        st.password = tostring(data.password or "")
        -- infos du lanceur, en secours si le slot_data arrive illisible
        local room = { seed = tostring(data.seed or ""), difficulty = data.difficulty, key_items = data.key_items, locations = {} }
        if type(data.locations) == "table" then
            for i, id in ipairs(data.locations) do room.locations[i] = id end
        end
        st.room = room
        return st.server ~= "" and st.slot ~= ""
    end
    read_connection_info()

    -- même hors ligne, la liste du lanceur remplace une liste absente ou abîmée
    if st.room and #st.room.locations > 0
        and (ctx.session.seed == "" or ctx.session.seed == st.room.seed) then
        ctx.apply_slot_data({}, st.room.seed, st.room)
    end

    function ctx.ap_save_connection(server, slot, password)
        local payload = { server_address = server or "", slot_name = slot or "", password = password or "" }
        local ok = pcall(function() json.dump_file(ctx.FILES.connection, payload, 4) end)
        if ok then
            st.server, st.slot, st.password = payload.server_address, payload.slot_name, payload.password
        end
        return ok
    end

    local function ap_item_name(item_id, player)
        if ap == nil then return nil end
        local game = ctx.GAME_NAME
        if player ~= nil then
            local g = ctx.try(function() return ap:get_player_game(player) end)
            if type(g) == "string" and g ~= "" then game = g end
        end
        for _, f in ipairs({
            function() return ap:get_item_name(item_id, game) end,
            function() return ap:get_item_name(item_id) end,
        }) do
            local ok, name = pcall(f)
            if ok and type(name) == "string" and name ~= "" and not name:find("^Unknown") then
                return name
            end
        end
        return nil
    end

    local function ap_player_name(slot)
        if ap == nil or slot == nil then return "?" end
        return ctx.try(function() return ap:get_player_alias(slot) end) or ("Joueur " .. tostring(slot))
    end

    function ctx.my_item_name(code)
        local known = ctx.ap_items[ctx.id_str(code) or ""]
        if not known then return nil end
        local localized = ctx.localized_names and ctx.localized_names[known.game_id]
        return localized or ctx.display_name(known.name)
    end

    local FLAG_COLORS = { { 4, "bad" }, { 1, "progress" }, { 2, "item" } }   -- piège > progression > utile

    function ctx.scout_label(loc_id)
        local sc = ctx.session.scouts[ctx.id_str(loc_id) or ""]
        if not sc then return nil end
        local name = (sc.mine and ctx.my_item_name(sc.item)) or (sc.name ~= "" and ctx.display_name(sc.name)) or ("objet " .. sc.item)
        local text = sc.mine and (name .. T(" (pour toi)")) or (name .. T(" pour ") .. (sc.owner ~= "" and sc.owner or "?"))
        local color = ctx.COLORS.info
        for _, fc in ipairs(FLAG_COLORS) do
            if (sc.flags & fc[1]) ~= 0 then color = ctx.COLORS[fc[2]] or color break end
        end
        local who = sc.mine and T("Pour toi") or TF("Pour %s", sc.owner ~= "" and sc.owner or "?")
        return text, color, sc, { name = name, who = who }
    end

    local function scout_locations(ids)
        if not ids or #ids == 0 then return end
        -- JAMAIS scout/check un id hors seed (ex. 7091000 Insanity sur seed Modern → KeyError serveur)
        local filtered = {}
        for _, raw in ipairs(ids) do
            local id = ctx.id_str(raw)
            if id and ctx.session.active[id] then
                filtered[#filtered + 1] = math.floor(tonumber(id))
            end
        end
        if #filtered == 0 then return end
        if bridge.active then
            bridge_cmd({ cmd = "LocationScouts", locations = filtered, create_as_hint = 0 })
            ctx.info(string.format("LocationScouts (bridge) : %d emplacement(s)", #filtered))
            return
        end
        if ap == nil then return end
        local ok, e = pcall(function() ap:LocationScouts(filtered, 0) end)
        if ok then
            ctx.info(string.format("LocationScouts : %d emplacement(s) demandés", #filtered))
        else
            ctx.warn("LocationScouts a échoué : " .. tostring(e))
        end
    end

    local function request_scouts()
        local ids = {}
        for id in pairs(ctx.session.active) do
            if not ctx.session.scouts[id] then ids[#ids + 1] = math.floor(tonumber(id)) end
        end
        scout_locations(ids)
    end

    -- un seul emplacement (ex. avant de strip un drop foreign)
    function ctx.request_scout(loc_id)
        local id = ctx.id_str(loc_id)
        if not id or ctx.session.scouts[id] then return false end
        if not ctx.is_active(id) then return false end
        local n = math.floor(tonumber(id))
        if not n then return false end
        scout_locations({ n })
        return true
    end

    local scouts_dirty = false
    local function on_scout(payload)
        local loc, item, player, flags = payload:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
        local id = ctx.id_str(loc)
        if not id then return end
        player = tonumber(player)
        local mine = st.player_number ~= nil and player == st.player_number
        ctx.session.scouts[id] = {
            item = math.floor(tonumber(item)), player = player, flags = math.floor(tonumber(flags)), mine = mine,
            name = ap_item_name(tonumber(item), player) or "",
            owner = mine and "" or ap_player_name(player),
        }
        scouts_dirty = true
    end

    local function drain_location_checks(force_all)
        if not is_slot_connected() then
            -- garde dirty pour renvoyer dès que le socket est de nouveau SLOT_CONNECTED
            return false
        end
        -- auto-dirty : checks locaux jamais marqués sent (évite file oubliée si dirty perdu)
        if not ctx.checks_dirty and not force_all then
            for id in pairs(ctx.session.checked) do
                if ctx.session.active[id] and not st.sent[id] then
                    ctx.checks_dirty = true
                    break
                end
            end
        end
        if not ctx.checks_dirty and not force_all then return true end
        if ctx.difficulty_allows_checks and not ctx.difficulty_allows_checks() then
            -- mismatch difficulté : ne rien envoyer (évite KeyError serveur / mauvaise logique)
            ctx.checks_dirty = true
            return false
        end
        ctx.checks_dirty = false

        local to_send = {}
        for id in pairs(ctx.session.checked) do
            -- double filtre : actif dans ce slot ET connu du catalogue client
            if ctx.session.active[id] and ctx.locations[id] and not st.sent[id] then
                to_send[#to_send + 1] = math.floor(tonumber(id))
            elseif not ctx.session.active[id] then
                -- ne jamais renvoyer un id Insanity/etc. sur une seed Modern
                st.sent[id] = nil
                ctx.session.checked[id] = nil
            end
        end
        if #to_send == 0 then return true end

        -- marquer sent seulement après un LocationChecks réussi (sinon retry au tick suivant)
        if bridge.active then
            bridge_cmd({ cmd = "LocationChecks", locations = to_send })
            for _, lid in ipairs(to_send) do st.sent[ctx.id_str(lid)] = true end
            ctx.info(string.format("LocationChecks (bridge) : %d emplacement(s)", #to_send))
            return true
        end
        local ok, e = pcall(function() ap:LocationChecks(to_send) end)
        if ok then
            for _, lid in ipairs(to_send) do st.sent[ctx.id_str(lid)] = true end
            ctx.info(string.format("LocationChecks envoyé : %d emplacement(s)", #to_send))
            return true
        end
        ctx.checks_dirty = true
        ctx.err("LocationChecks a échoué : " .. tostring(e))
        return false
    end

    -- appelé juste après un mark_checked : n'attend pas le prochain tick
    function ctx.flush_location_checks()
        ctx.checks_dirty = true
        return drain_location_checks(true)
    end

    function ctx.send_goal()
        if not is_slot_connected() then
            ctx.push_message(T("Victoire : pas connecté au serveur"), ctx.COLORS.warn)
            return false
        end
        local ok, e = true, nil
        if bridge.active then
            bridge_cmd({ cmd = "StatusUpdate", status = 30 })  -- ClientStatus.GOAL
        else
            ok, e = pcall(function() ap:StatusUpdate(AP.ClientStatus.GOAL) end)
        end
        if ok then
            ctx.session.goal_sent = true
            ctx.save_session()
            ctx.push_message(T("Objectif atteint : victoire envoyée au serveur !"), ctx.COLORS.progress, "goal")
            if ctx.celebrate then
                ctx.celebrate("VICTOIRE !", { "Resident Evil Requiem terminé", "Victoire envoyée au multiworld" })
            end
        else
            ctx.err("StatusUpdate(GOAL) a échoué : " .. tostring(e))
        end
        return ok
    end

    local function held_for_grace()
        return ctx.HOLD_ITEMS_FOR_LEON and ctx.current_character and ctx.current_character() == "leon"
    end
    ctx.ap_held_for_grace = held_for_grace

    st.was_held = false

    local item_chapters = nil
    local function chapters_of(game_id)
        if item_chapters == nil then
            item_chapters = {}
            for _, loc in pairs(ctx.locations or {}) do
                if loc.item_id and loc.item_id ~= "" and loc.chapter then
                    item_chapters[loc.item_id] = item_chapters[loc.item_id] or {}
                    item_chapters[loc.item_id][loc.chapter] = true
                end
            end
        end
        return item_chapters[game_id]
    end

    -- munitions/soins en main ; clés et progression en main seulement s'ils viennent du chapitre en cours
    local HAND_CATEGORIES = { Ammo = true, Heal = true }
    local function wanted_in_hand(game_id, flags)
        if ctx.ALWAYS_HAND_ITEMS and ctx.ALWAYS_HAND_ITEMS[game_id] then return true end
        local known = ctx.items_by_id and ctx.items_by_id[game_id]
        local category = known and known.category or ""
        if HAND_CATEGORIES[category] then return true end
        local progression = ((math.floor(tonumber(flags) or 0)) & 1) ~= 0
        if category == "KeyItem" or progression then
            local here = ctx.current_chapter or ctx.last_chapter
            local where = chapters_of(game_id)
            return here ~= nil and where ~= nil and where[here] == true
        end
        return false
    end

    -- fusible déjà au coffre : le tirer en main (sinon le panneau du couloir refuse)
    function ctx.ensure_hand_item(game_id)
        if type(game_id) ~= "string" or game_id == "" then return false end
        if not (ctx.inject_to_hand and ctx.transfer_box_to_hand) then return false end
        if not ctx.is_game_ready or not ctx.is_game_ready() then return false end
        if ctx.is_safe_to_mutate and not ctx.is_safe_to_mutate() then return false end
        if ctx.current_character and ctx.current_character() ~= "grace" then return false end
        local user = ctx.player_inventory_user and ctx.player_inventory_user() or ctx.GRACE_HAND_USER
        local moved = select(1, ctx.transfer_box_to_hand(game_id, 1, user))
        if type(moved) == "number" and moved > 0 then
            ctx.push_message(T("Déplacé du coffre vers l'inventaire : ") .. (ctx.item_display_name and ctx.item_display_name(game_id) or game_id),
                ctx.COLORS.ok, "item")
            return true
        end
        return false
    end

    local function to_grace_hand(game_id, count, name, flags)
        if not (ctx.received_to_hand and ctx.inject_to_hand and ctx.current_character() == "grace") then
            return 0
        end
        if not wanted_in_hand(game_id, flags) then return 0 end
        local user = ctx.player_inventory_user and ctx.player_inventory_user() or ctx.GRACE_HAND_USER
        local added, err = ctx.inject_to_hand(game_id, count, user)
        if added < (count or 1) then
            ctx.info(string.format("inventaire de Grace : %d/%d %s (%s), le reste va au coffre",
                added, count or 1, name, tostring(err or "plus de place")))
        end
        return added
    end

    -- livraison : queued → delivering → done (last_index n'avance qu'à done)
    local function delivery_get(idx)
        st.deliveries = st.deliveries or {}
        local d = st.deliveries[idx]
        if not d then
            d = { state = "queued", hand = nil, box = 0 }
            st.deliveries[idx] = d
        end
        return d
    end

    local function delivery_clear(idx)
        if st.deliveries then st.deliveries[idx] = nil end
        if st.hand_partial then st.hand_partial[idx] = nil end
        if st.box_partial then st.box_partial[idx] = nil end
    end

    local function drain_received_items()
        local idx = ctx.session.last_index
        local item = st.item_queue[idx]
        if item == nil then
            local next_i = nil
            for i in pairs(st.item_queue) do
                if type(i) == "number" and i >= idx and (next_i == nil or i < next_i) then next_i = i end
            end
            if next_i and next_i > idx then
                ctx.warn(string.format("file d'objets : trou à l'index %d, reprise à %d", idx, next_i))
                delivery_clear(idx)
                ctx.session.last_index = next_i
                ctx.save_session()
            end
            return
        end
        if not ctx.is_game_ready() then return end
        if ctx.is_safe_to_mutate and not ctx.is_safe_to_mutate() then return end
        if st.item_retry_after and os.clock() < st.item_retry_after then return end

        -- coffre OK en Leon (to_grace_hand ignore déjà Leon) ; was_held = HUD seulement
        if held_for_grace() then
            st.was_held = true
        elseif st.was_held then
            st.was_held = false
        end

        local d = delivery_get(idx)
        if d.state == "done" then
            st.item_queue[idx] = nil
            delivery_clear(idx)
            st.item_fail_ticks = 0
            st.item_retry_after = nil
            ctx.session.last_index = idx + 1
            st.received_total = st.received_total + 1
            ctx.save_session()
            return
        end
        d.state = "delivering"

        local ap_name = ap_item_name(item.item, st.player_number)
        local game_id, count = ctx.resolve_ap_item(item.item, ap_name)
        if game_id and ctx.game_item_name then pcall(ctx.game_item_name, game_id) end
        local name = ctx.my_item_name(item.item) or ap_name or tostring(item.item)
        local sender = (item.player ~= nil and item.player ~= st.player_number) and ap_player_name(item.player) or nil
        local from = sender and (T(" de ") .. sender) or ""
        local function card(title, where)
            return { title = title, sub = sender and (TF("De %s", sender) .. "  |  " .. where) or where }
        end

        local loc_key = ctx.id_str(item.location)
        local grant_done, grant_pending = false, false
        if item.player == st.player_number and loc_key and ctx.is_local_grant then
            grant_done, grant_pending = ctx.is_local_grant(loc_key)
        elseif item.player == st.player_number and loc_key then
            grant_done = (ctx.session.in_hand or {})[loc_key] == true
        end
        local credits = tonumber(type(name) == "string" and name:match("^(%d+) Credits$") or "")
        if credits and credits > 0 then
            if ctx.add_shared_credits then ctx.add_shared_credits(credits) end
            ctx.push_message(TF("Reçu : %d crédits%s", credits, from), ctx.COLORS.info, "item", item.flags,
                card(TF("%d crédits", credits), from ~= "" and from or T("crédits")))
            ctx.log_received(TF("%d crédits", credits), sender and from or "", false)
            d.state = "done"
        elseif grant_pending and not grant_done then
            -- swap / coffre en cours : ne pas livrer ni marquer done
            return
        elseif grant_done then
            local qty = (count or 1) > 1 and (" x" .. count) or ""
            ctx.push_message(TF("Reçu : %s%s (déjà obtenu au check)", name, qty), ctx.COLORS.info, "item", item.flags,
                card(name .. qty, T("Déjà obtenu au check")))
            ctx.log_received(name .. qty, "", ((math.floor(tonumber(item.flags) or 0)) & 1) ~= 0)
            d.state = "done"
        elseif game_id == nil then
            ctx.warn("objet AP sans correspondance dans le jeu : " .. name .. " (ignoré)")
            ctx.push_message(T("Objet inconnu reçu : ") .. name, ctx.COLORS.warn)
            d.state = "done"
        else
            count = count or 1
            local qty = count > 1 and (" x" .. count) or ""
            local flags = math.floor(tonumber(item.flags) or 0)
            local progression = (flags & 1) ~= 0
            local color = ctx.COLORS.info
            for _, fc in ipairs(FLAG_COLORS) do
                if (flags & fc[1]) ~= 0 then color = ctx.COLORS[fc[2]] or color break end
            end
            -- compat : migrer anciens partials
            if d.hand == nil and st.hand_partial and st.hand_partial[idx] ~= nil then
                d.hand = st.hand_partial[idx]
            end
            if (d.box or 0) == 0 and st.box_partial and st.box_partial[idx] then
                d.box = st.box_partial[idx]
            end
            if d.hand == nil then
                d.hand = to_grace_hand(game_id, count, name, flags)
            end
            local in_inv = d.hand or 0
            local already_box = d.box or 0
            local need = count - in_inv - already_box
            local ok, err, injected = true, nil, 0
            if need > 0 then
                ok, err, injected = ctx.inject_item(game_id, need)
                injected = math.max(0, math.floor(tonumber(injected) or 0))
                if injected > 0 then
                    already_box = already_box + injected
                    d.box = already_box
                end
            end
            local delivered = in_inv + already_box
            if delivered >= count then
                if in_inv >= count then
                    ctx.push_message(TF("Reçu : %s%s%s (inventaire de Grace)", name, qty, from), color, "item", flags,
                        card(name .. qty, T("Inventaire")))
                elseif in_inv > 0 then
                    ctx.push_message(TF("Reçu : %s%s%s (%d dans l'inventaire, le reste au coffre)", name, qty, from, in_inv), color, "item", flags,
                        card(name .. qty, TF("%d dans l'inventaire, le reste au coffre", in_inv)))
                else
                    ctx.push_message(TF("Reçu : %s%s%s (coffre)", name, qty, from), color, "item", flags,
                        card(name .. qty, T("Coffre")))
                end
                ctx.note_delivery(game_id, in_inv, already_box)
                ctx.log_received(name .. qty, from, progression)
                if ctx.apply_item_story_flag then pcall(ctx.apply_item_story_flag, game_id) end
                d.state = "done"
            else
                st.item_fail_ticks = st.item_fail_ticks + 1
                local backoff = math.min(5, 0.5 * (1 + math.floor(st.item_fail_ticks / 60)))
                st.item_retry_after = os.clock() + backoff
                if st.item_fail_ticks == 1 or (st.item_fail_ticks % FAIL_WARN_TICKS) == 0 then
                    ctx.warn(string.format("livraison reportée %s (%d/%d) : %s",
                        name, delivered, count, tostring(err or "coffre/état")))
                    if st.item_fail_ticks == 1 then
                        ctx.push_message(T("Livraison en attente : ") .. name, ctx.COLORS.warn, "item")
                    end
                end
            end
        end

        if d.state == "done" then
            st.item_queue[idx] = nil
            delivery_clear(idx)
            st.item_fail_ticks = 0
            st.item_retry_after = nil
            ctx.session.last_index = idx + 1
            st.received_total = st.received_total + 1
            ctx.save_session()
        end
    end

    function ctx.ap_pending_items()
        local n = 0
        for i in pairs(st.item_queue) do
            if i >= ctx.session.last_index then n = n + 1 end
        end
        return n
    end

    local function num_text(v)
        if type(v) == "number" then return string.format("%.0f", v) end
        return "" .. tostring(v or "")
    end

    -- lignes « S nom valeur / L location_id / I code id_jeu quantité », séparées par des tabs
    -- pairs() ne voit rien dans une table de la DLL, seuls clé connue et index marchent
    local SLOT_SCALARS = {
        "apworld_version", "goal", "difficulty", "key_items", "flag_items",
        "enemy_drops", "supply_box", "supply_prices", "death_link", "chapter_keys", "check_count",
    }
    local function slot_data_text(sd)
        if type(sd) ~= "table" then return "" end
        local parts = {}
        for _, k in ipairs(SLOT_SCALARS) do
            local v = sd[k]
            local tv = type(v)
            if tv == "string" or tv == "number" or tv == "boolean" then
                parts[#parts + 1] = "S\t" .. k .. "\t" .. (tv == "number" and num_text(v) or tostring(v))
            end
        end
        local locs = sd.locations
        if type(locs) == "table" then
            local i = 1
            while locs[i] ~= nil do
                parts[#parts + 1] = "L\t" .. num_text(locs[i])
                i = i + 1
            end
        end
        local items = sd.items
        if type(items) == "table" then
            for code in pairs(ctx.ap_items) do
                local v = items[code]
                if type(v) == "table" and v[1] ~= nil then
                    parts[#parts + 1] = "I\t" .. code .. "\t" .. tostring(v[1]) .. "\t" .. num_text(v[2] or 1)
                end
            end
        end
        return table.concat(parts, "\n")
    end

    local function install_handlers(client)
        client:set_socket_connected_handler(function() post("socket", "") end)
        client:set_socket_error_handler(function(e) post("error", "" .. tostring(e or "")) end)
        client:set_socket_disconnected_handler(function() post("disconnected", "") end)
        client:set_room_info_handler(function() post("roominfo", "") end)
        client:set_slot_connected_handler(function(slot_data)
            -- missing + checked séparés : checked doit aussi peupler session.checked
            local function dump_ids(t)
                local locs = ""
                if type(t) ~= "table" then return locs end
                pcall(function()
                    for k, v in pairs(t) do
                        local id = type(v) == "number" and v or k
                        if type(id) == "number" then locs = locs .. string.format("%d", id) .. "," end
                    end
                end)
                return locs
            end
            local ok_m, missing = pcall(function() return client.missing_locations end)
            local ok_c, checked = pcall(function() return client.checked_locations end)
            local miss = ok_m and dump_ids(missing) or ""
            local done = ok_c and dump_ids(checked) or ""
            -- actif = missing ∪ checked (comme avant)
            post("slotlocs", miss .. done)
            post("slotchecked", done)
            local ok, text = pcall(slot_data_text, slot_data)
            post("slotdata", ok and text or "")
            post("connected", ok and "" or ("" .. tostring(text)))
        end)
        client:set_slot_refused_handler(function(reasons)
            local text = ""
            if type(reasons) == "table" then
                for _, r in ipairs(reasons) do text = text .. tostring(r) .. " " end
            else
                text = "" .. tostring(reasons)
            end
            post("refused", text)
        end)
        client:set_items_received_handler(function(items)
            for _, it in ipairs(items or {}) do
                local ok, text = pcall(string.format, "%.0f,%.0f,%.0f,%.0f,%.0f",
                    it.index, it.item, it.location or 0, it.player or 0, it.flags or 0)
                if ok then post("item", text) end
            end
        end)
        pcall(function()
            client:set_location_info_handler(function(items)
                for _, it in ipairs(items or {}) do
                    local ok, text = pcall(string.format, "%.0f,%.0f,%.0f,%.0f",
                        it.location or 0, it.item or 0, it.player or 0, it.flags or 0)
                    if ok then post("scout", text) end
                end
            end)
        end)
        pcall(function()
            client:set_bounced_handler(function(b)
                local ok, text = pcall(function()
                    local tags = ""
                    local t = type(b) == "table" and b.tags or nil
                    if type(t) == "table" then
                        local i = 1
                        while t[i] ~= nil do tags = tags .. tostring(t[i]) .. "," i = i + 1 end
                    end
                    local d = type(b) == "table" and b.data or nil
                    if type(d) ~= "table" then d = {} end
                    local function clean(v) return (tostring(v or ""):gsub("[\t\n\r]", " ")) end
                    return tags .. "\t" .. string.format("%.3f", tonumber(d.time) or 0) .. "\t" .. clean(d.source) .. "\t" .. clean(d.cause)
                end)
                if ok then post("bounce", text) end
            end)
        end)
        client:set_location_checked_handler(function(ids)
            local text = ""
            for _, id in ipairs(ids or {}) do text = text .. num_text(id) .. "," end
            post("checked", text)
        end)
        client:set_print_json_handler(function(msg, extra)
            local kind = (type(msg) == "table" and msg.type) or (type(extra) == "table" and extra.type) or ""
            local receiving = (type(msg) == "table" and msg.receiving) or (type(extra) == "table" and extra.receiving) or ""
            local ok, text = pcall(function()
                local data = (type(msg) == "table" and msg.data ~= nil) and msg.data or msg
                if AP.RenderFormat and AP.RenderFormat.TEXT ~= nil then
                    return client:render_json(data, AP.RenderFormat.TEXT)
                end
                return client:render_json(data)
            end)
            if ok and type(text) == "string" and text ~= "" then
                post("print", tostring(kind) .. "\t" .. num_text(receiving) .. "\t" .. text)
            end
        end)
    end

    local socket_errors = 0
    local pending_slot_data = nil
    local pending_server_locs = nil
    local pending_server_checked = nil

    local function apply_server_checked(ids)
        if type(ids) ~= "table" then return 0 end
        local n = 0
        for _, raw in ipairs(ids) do
            local k = ctx.id_str(raw)
            if k then
                if not ctx.session.checked[k] then
                    ctx.session.checked[k] = true
                    n = n + 1
                end
                st.sent[k] = true
            end
        end
        if n > 0 then
            ctx.save_session()
            ctx.checks_dirty = true
            if ctx.refresh_markers then pcall(ctx.refresh_markers) end
        end
        return n
    end

    local function parse_slot_data(text)
        local sd = { locations = {}, items = {} }
        for line in tostring(text or ""):gmatch("[^\n]+") do
            local tag, rest = line:match("^(%u)\t(.*)$")
            if tag == "S" then
                local k, v = rest:match("^([^\t]*)\t(.*)$")
                if k and k ~= "locations" and k ~= "items" then
                    if v == "true" then sd[k] = true
                    elseif v == "false" then sd[k] = false
                    else sd[k] = tonumber(v) or v end
                end
            elseif tag == "L" then
                local id = tonumber(rest)
                if id then sd.locations[#sd.locations + 1] = id end
            elseif tag == "I" then
                local code, gid, count = rest:match("^([^\t]*)\t([^\t]*)\t(.*)$")
                if code and gid ~= "" then
                    sd.items[ctx.id_str(code) or code] = { id = gid, count = math.max(1, math.floor(tonumber(count) or 1)) }
                end
            end
        end
        return sd
    end

    local function current_tags()
        local tags = {}
        for i, t in ipairs(ctx.CLIENT_TAGS) do tags[i] = t end
        if ctx.deathlink_active and ctx.deathlink_active() then tags[#tags + 1] = "DeathLink" end
        return tags
    end

    function ctx.ap_update_tags()
        if not is_slot_connected() then return false end
        if bridge.active then
            bridge_cmd({ cmd = "ConnectUpdate", tags = current_tags(), items_handling = ctx.ITEMS_HANDLING })
            return true
        end
        local ok, e = pcall(function() ap:ConnectUpdate(ctx.ITEMS_HANDLING, current_tags()) end)
        if not ok then ctx.err("ConnectUpdate : " .. tostring(e)) end
        return ok
    end

    function ctx.ap_send_death(cause)
        if not is_slot_connected() then return false end
        local now = os.time() + 0.0
        local function data() return { time = now, cause = tostring(cause or ""), source = st.slot } end
        if bridge.active then
            bridge_cmd({ cmd = "Bounce", data = data(), tags = { "DeathLink" } })
            return true
        end
        local ok, e = pcall(function() ap:Bounce(data(), nil, nil, { "DeathLink" }) end)
        if not ok then ok, e = pcall(function() ap:Bounce(data(), {}, {}, { "DeathLink" }) end) end
        if not ok then ctx.err("Bounce DeathLink : " .. tostring(e)) end
        return ok
    end

    -- PopTracker écoute ce Bounce et active l'onglet de la carte du chapitre.
    function ctx.ap_send_zone(chapter)
        if not is_slot_connected() or not chapter or not st.player_number then return false end
        local payload = { re9_chapter = tostring(chapter), time = os.time() + 0.0, source = st.slot }
        local slots = { st.player_number }
        if bridge.active then
            bridge_cmd({ cmd = "Bounce", data = payload, slots = slots })
            return true
        end
        local ok, e = pcall(function() ap:Bounce(payload, nil, slots, nil) end)
        if not ok then ok, e = pcall(function() ap:Bounce(payload, {}, slots, {}) end) end
        if not ok then ctx.err("Bounce zone : " .. tostring(e)) end
        return ok
    end

    local function on_room_info()
        set_status("connecting", "Connexion au slot %s...", st.slot)
        if bridge.active then
            -- le bridge envoie Connect lui-même après RoomInfo
            return
        end
        local tags = current_tags()
        local version = {}
        for i, v in ipairs(ctx.CLIENT_VERSION) do version[i] = v end
        ap:ConnectSlot(st.slot, st.password, ctx.ITEMS_HANDLING, tags, version)
    end

    local function sd_flag(v)
        return v == true or v == 1 or v == "true" or v == "1"
    end

    local function short_seed(s)
        s = tostring(s or "")
        if s == "" then return "?" end
        if #s <= 28 then return s end
        return s:sub(1, 14) .. "…" .. s:sub(-8)
    end

    local function on_slot_connected(slot_data, err_text)
        if err_text ~= "" then ctx.err("slot_data illisible : " .. err_text) end
        local seed = ""
        if bridge.active then
            bridge.connected = true
            local bs = json.load_file(ctx.FILES.bridge_status)
            if type(bs) == "table" then
                st.player_number = tonumber(bs.player)
                seed = tostring(bs.seed or "")
            end
        else
            st.player_number = ctx.try(function() return ap:get_player_number() end)
            seed = tostring(ctx.try(function() return ap:get_seed() end) or "")
        end
        local prev_seed = tostring(ctx.session.seed or "")
        local prev_slot = tostring(ctx.session.slot or "")
        local expected = st.room and tostring(st.room.seed or "") or ""

        -- Room ≠ seed enregistrée par le lanceur (mauvaise adresse / port recyclé)
        ctx.seed_mismatch = nil
        if expected ~= "" and seed ~= "" and expected ~= seed then
            local msg = TF(
                "MAUVAISE SEED : le lanceur attendait %s, la room répond %s. Ce n'est pas ta partie — change l'adresse / Rejoindre.",
                short_seed(expected), short_seed(seed))
            ctx.warn(msg)
            ctx.push_message(msg, ctx.COLORS.bad, "error")
            ctx.seed_mismatch = { kind = "launcher", expected = expected, actual = seed }
        end

        local switched = ctx.bind_session(seed, st.slot)
        if switched and prev_seed ~= "" then
            local msg = TF(
                "MAUVAISE SEED : tu étais sur %s, la room est %s (slot %s). Progression archivée — reconnecte la bonne room.",
                short_seed(prev_seed), short_seed(seed),
                (st.slot ~= "" and st.slot or prev_slot))
            ctx.push_message(msg, ctx.COLORS.bad, "error")
            if not ctx.seed_mismatch then
                ctx.seed_mismatch = { kind = "session", expected = prev_seed, actual = seed }
            end
        end

        ctx.info(string.format("serveur : %d emplacements, slot_data : %d", #slot_data.server_locations, #slot_data.locations))
        if not ctx.apply_slot_data(slot_data, seed, st.room) then
            ctx.push_message(
                T("MAUVAISE SEED / checks vides : 0 check actif. Repasse par « Rejoindre » dans le lanceur (bonne room)."),
                ctx.COLORS.bad, "error")
            if not ctx.seed_mismatch then
                ctx.seed_mismatch = { kind = "empty", expected = prev_seed, actual = seed }
            end
        end

        -- Client build ↔ apworld de la seed (pas le même numéro que le patch lanceur)
        ctx.version_mismatch = nil
        do
            local got = tostring(ctx.session.apworld_version or "")
            local want = tostring(ctx.EXPECTED_APWORLD or "")
            if got ~= "" and want ~= "" and got ~= want then
                local msg = TF(
                    "Versions différentes : ce client attend l'apworld %s, la seed est en %s. Mets à jour le client ou régénère avec le bon apworld.",
                    want, got)
                ctx.warn(msg)
                ctx.push_message(msg, ctx.COLORS.warn, "warn")
                ctx.version_mismatch = { expected = want, actual = got }
            end
        end

        if ctx.session.goal_sent then
            ctx.push_message(T("Cette partie est déjà terminée (victoire envoyée). Génère une nouvelle partie pour rejouer."),
                ctx.COLORS.warn, "error")
        end
        st.sent = {}
        socket_errors = 0
        set_status("connected", "Connecté : %s (slot %s)", st.slot, tostring(st.player_number))
        if ctx.deathlink_set_yaml then ctx.deathlink_set_yaml(sd_flag(slot_data.death_link)) end
        ctx.push_message(T("Connecté à Archipelago en tant que ") .. st.slot, ctx.COLORS.ok, "system")
        drain_location_checks(true)
        request_scouts()
    end

    local function on_item(payload)
        local idx, item, loc, player, flags = payload:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
        idx = tonumber(idx)
        if idx ~= nil then
            ctx.count_received(idx, item)
            scouts_dirty = true
        end
        if idx == nil or idx < ctx.session.last_index or st.item_queue[idx] ~= nil then return end
        st.item_queue[idx] = {
            item = tonumber(item), location = tonumber(loc),
            player = tonumber(player), flags = tonumber(flags),
        }
    end

    local function on_print(payload)
        local mtype, receiving, text = payload:match("^([^\t]*)\t([^\t]*)\t(.*)$")
        if not text then return end
        text = ctx.display_name(text)
        local color = (mtype == "Hint") and ctx.COLORS.warn or ctx.COLORS.muted
        if mtype == "ItemSend" then color = ctx.COLORS.ok end
        ctx.log_console(text, color)
        if mtype == "Hint" then ctx.add_hint(text) end
        -- déjà annoncé à l'injection
        if mtype == "ItemSend" and tonumber(receiving) ~= nil and tonumber(receiving) == st.player_number then
            return
        end
        ctx.push_message(text, color)
    end

    function ctx.ap_say(text)
        if not is_slot_connected() then return false, T("pas connecté au serveur") end
        if bridge.active then
            bridge_cmd({ cmd = "Say", text = tostring(text) })
            return true
        end
        if ap == nil then return false, T("pas connecté au serveur") end
        local ok, e = pcall(function() ap:Say(tostring(text)) end)
        if not ok then return false, tostring(e) end
        return true
    end

    function ctx.ap_hint_points()
        if not is_slot_connected() then return nil end
        if bridge.active or ap == nil then return nil end
        local ok, points, cost, percent = pcall(function()
            return ap:get_hint_points(), ap:get_hint_cost_points(), ap:get_hint_cost_percent()
        end)
        if not ok or type(points) ~= "number" then return nil end
        return points, tonumber(cost), tonumber(percent)
    end

    -- handshake slot : bufferer jusqu'à connected (jamais clear_inbox entre ces messages)
    local handshake = { locs = nil, checked = nil, data = nil, ready = false }

    local function reset_handshake()
        handshake.locs, handshake.checked, handshake.data, handshake.ready = nil, nil, nil, false
        pending_slot_data, pending_server_locs, pending_server_checked = nil, nil, nil
    end

    local function apply_handshake(payload)
        local sd = handshake.data or pending_slot_data or parse_slot_data("")
        sd.server_locations = handshake.locs or pending_server_locs or {}
        local checked_ids = handshake.checked or pending_server_checked or {}
        reset_handshake()
        on_slot_connected(sd, payload)
        local n = apply_server_checked(checked_ids)
        if n > 0 then
            ctx.info(string.format("sync serveur : %d check(s) déjà faits rétabli(s)", n))
        end
    end

    local function handle_event(kind, payload)
        if kind == "socket" then
            set_status("connecting", "Socket connecté, attente du serveur...")
            st.sent = {}
            reset_handshake()
        elseif kind == "error" then
            socket_errors = socket_errors + 1
            -- la détection ws/wss produit une première erreur sans conséquence
            if socket_errors > 1 then
                set_status("error", "Erreur réseau : %s", payload)
                ctx.warn("erreur socket : " .. payload)
            end
        elseif kind == "disconnected" then
            set_status("connecting", "Déconnecté, reconnexion...")
            st.sent = {}
            reset_handshake()
        elseif kind == "roominfo" then
            on_room_info()
        elseif kind == "slotlocs" then
            local locs = {}
            for id in payload:gmatch("%-?%d+") do locs[#locs + 1] = tonumber(id) end
            handshake.locs = locs
            pending_server_locs = locs
        elseif kind == "slotchecked" then
            local checked = {}
            for id in payload:gmatch("%-?%d+") do checked[#checked + 1] = tonumber(id) end
            handshake.checked = checked
            pending_server_checked = checked
        elseif kind == "slotdata" then
            local sd = parse_slot_data(payload)
            handshake.data = sd
            pending_slot_data = sd
        elseif kind == "connected" then
            handshake.ready = true
            apply_handshake(payload)
        elseif kind == "refused" then
            reset_handshake()
            set_status("refused", "Connexion refusée : %s", payload)
            ctx.err("connexion refusée : " .. payload)
            ctx.push_message(T("Connexion refusée : ") .. payload, ctx.COLORS.bad)
            st.refused = true
        elseif kind == "item" then
            on_item(payload)
        elseif kind == "checked" then
            -- serveur confirme (collect / autre client) → marquer aussi en local
            local ids = {}
            for id in payload:gmatch("%-?%d+") do ids[#ids + 1] = tonumber(id) end
            apply_server_checked(ids)
        elseif kind == "print" then
            on_print(payload)
        elseif kind == "scout" then
            on_scout(payload)
        elseif kind == "bounce" then
            local tags, time, source, cause = payload:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if tags and (tags:find("DeathLink,", 1, true)) and ctx.on_deathlink and source ~= st.slot then
                ctx.on_deathlink(source, cause, tonumber(time))
            end
        end
    end

    local function process_inbox()
        while inbox.read < inbox.n do
            inbox.read = inbox.read + 1
            local key = "m" .. inbox.read
            local msg = inbox[key]
            inbox[key] = nil
            local kind, payload = tostring(msg or ""):match("^(%a+)|(.*)$")
            if kind then
                local ok, e = pcall(handle_event, kind, payload)
                if not ok then ctx.err("événement '" .. kind .. "' : " .. tostring(e)) end
            end
        end
    end

    local function connect()
        if not read_connection_info() then
            set_status("idle", "Pas de session : renseigne serveur et slot")
            return false
        end
        st.refused = false
        socket_errors = 0
        reset_handshake()
        clear_inbox()

        -- Comme RE2R : lua-apclientpp.dll in-game ; bridge Python seulement si DLL absente
        if AP ~= nil then
            set_status("connecting", "Connexion à %s...", st.server)
            ctx.info("connexion DLL (RE2R-style) à " .. st.server .. " en tant que '" .. st.slot .. "'")
            local ok, e = pcall(function()
                ap = AP("", ctx.GAME_NAME, st.server)
                install_handlers(ap)
            end)
            if not ok then
                ap = nil
                set_status("error", "Création du client impossible : %s", tostring(e))
                ctx.err("création du client AP : " .. tostring(e))
                return false
            end
            return true
        end

        if bridge_refresh() then
            ap = nil
            set_status("connecting", "Bridge Python → %s...", st.server)
            ctx.info("bridge Python (secours, pas de DLL) → " .. st.server .. " / '" .. st.slot .. "'")
            return true
        end

        set_status("disabled", "lua-apclientpp.dll manquante (racine du jeu)")
        return false
    end

    function ctx.ap_connect()
        ap = nil
        collectgarbage()
        st.item_queue = {}
        st.deliveries = {}
        st.hand_partial = {}
        st.box_partial = {}
        st.item_fail_ticks = 0
        st.item_retry_after = nil
        return connect()
    end

    function ctx.ap_disconnect()
        if bridge.active then bridge_cmd({ cmd = "Disconnect" }) end
        ap = nil
        collectgarbage()
        clear_inbox()
        st.refused = true   -- pas de reconnexion automatique
        set_status("idle", "Déconnecté (manuel)")
    end

    -- le serveur renvoie toute la liste à la reconnexion, on relivre à partir de l'index choisi
    function ctx.ap_redeliver_from(index)
        ctx.session.last_index = math.max(0, math.floor(tonumber(index) or 0))
        ctx.save_session()
        st.received_total = 0
        ctx.push_message(T("Objets reçus redonnés à partir du n°") .. (ctx.session.last_index + 1), ctx.COLORS.ok, "system")
        return ctx.ap_connect()
    end

    function ctx.ap_resend_all()
        st.sent = {}
        ctx.checks_dirty = true
    end

    -- Seed YAML vs difficulté réelle de la save : BLOQUE les checks si mismatch
    local DIFF_ALIASES = {
        casual = "casual", modern = "modern", classic = "classic", insanity = "insanity",
        easy = "casual", normal = "modern", hard = "classic", nightmare = "insanity",
    }
    local DIFF_BY_VALUE = {
        [0] = "casual", [1] = "modern", [2] = "classic", [3] = "insanity",
    }
    local difficulty_warned_for, difficulty_next_poll, difficulty_toast_at = nil, 0, 0

    local function normalize_diff(raw)
        if raw == nil then return nil end
        local s = string.lower(tostring(raw):gsub("^%s+", ""):gsub("%s+$", ""))
        if s == "" or s == "nil" or s == "unknown" then return nil end
        if DIFF_ALIASES[s] then return DIFF_ALIASES[s] end
        for key, canon in pairs(DIFF_ALIASES) do
            if s:find(key, 1, true) then return canon end
        end
        local n = tonumber(s)
        if n and DIFF_BY_VALUE[math.floor(n)] then return DIFF_BY_VALUE[math.floor(n)] end
        return nil
    end

    local function pretty_diff(d)
        if not d or d == "" then return "?" end
        return d:sub(1, 1):upper() .. d:sub(2)
    end

    function ctx.read_game_difficulty()
        local mgr = sdk.get_managed_singleton("app.GameDifficultyManager")
        if not mgr then return nil end
        local id = ctx.try(function() return mgr:get_field("DifficultyID") end)
            or ctx.try(function() return mgr:call("get_DifficultyID") end)
            or ctx.try(function() return mgr:call("get_CurrentDifficulty") end)
        if id == nil then return nil end
        local name = id
        if type(id) == "userdata" then
            name = ctx.try(function() return id:call("ToString()") end)
                or ctx.try(function() return id:get_field("value__") end)
        end
        return normalize_diff(name)
    end

    -- true = seed et jeu alignés (ou pas encore mesurable) → checks autorisés
    function ctx.difficulty_allows_checks()
        return ctx.difficulty_mismatch == nil
    end

    local function poll_difficulty_match()
        local expected = normalize_diff(ctx.session and ctx.session.difficulty)
        if not expected then
            ctx.game_difficulty, ctx.difficulty_mismatch = nil, nil
            return
        end
        if not (ctx.is_game_ready and ctx.is_game_ready()) then return end
        local now = os.clock()
        if now < difficulty_next_poll then return end
        difficulty_next_poll = now + 2.0

        local actual = ctx.read_game_difficulty()
        if not actual then return end
        ctx.game_difficulty = actual
        local mismatch = actual ~= expected
        ctx.difficulty_mismatch = mismatch and { expected = expected, actual = actual } or nil

        if not mismatch then
            difficulty_warned_for = nil
            return
        end

        local signature = expected .. "/" .. actual
        local msg = TF(
            "DIFFICULTÉ BLOQUÉE : seed = %s, jeu = %s. Change la difficulté (nouvelle partie) ou régénère la seed.",
            pretty_diff(expected), pretty_diff(actual))
        if signature ~= difficulty_warned_for then
            difficulty_warned_for = signature
            ctx.err(msg)
        end
        if now - difficulty_toast_at >= 12.0 then
            difficulty_toast_at = now
            ctx.push_message(msg, ctx.COLORS.bad, "error")
        end
    end

    local function tick()
        bridge_refresh()
        if bridge.active then
            bridge_pull_inbox()
            process_inbox()
            if scouts_dirty then
                scouts_dirty = false
                ctx.save_session()
            end
            drain_location_checks(false)
            drain_received_items()
            if ctx.has_slot_data and ctx.has_slot_data() then
                pcall(poll_difficulty_match)
            end
        elseif ap ~= nil then
            local ok, e = pcall(function() ap:poll() end)
            if not ok then ctx.err("poll : " .. tostring(e)) end
            process_inbox()
            if ap == nil then return end
            if scouts_dirty then
                scouts_dirty = false
                ctx.save_session()
            end
            drain_location_checks(false)
            drain_received_items()
            if ctx.has_slot_data and ctx.has_slot_data() then
                pcall(poll_difficulty_match)
            end
        end
        if ctx.resolve_names_step and ctx.is_game_ready() then pcall(ctx.resolve_names_step) end
        if ctx.flush_session then pcall(ctx.flush_session) end
        if ctx.flush_pickups then pcall(ctx.flush_pickups) end
        if bridge.active or ap ~= nil then return end
        if st.refused then return end
        local now = os.clock()
        if now - st.last_retry >= RETRY_SECONDS then
            st.last_retry = now
            connect()
        end
    end

    ctx.on_tick("ap", tick)

    connect()
end
