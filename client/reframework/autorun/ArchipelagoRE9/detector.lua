return function(ctx)
    local try = ctx.try

    ctx.suppress_vanilla = true
    ctx.swap_own_items = true
    ctx.last_pickup = nil
    ctx.recent_pickups = json.load_file(ctx.FILES.last_pickups)
    if type(ctx.recent_pickups) ~= "table" then
        ctx.recent_pickups = {}
        pcall(function() json.dump_file(ctx.FILES.last_pickups, ctx.recent_pickups, 4) end)
    end

    local function as_text(v)
        if v == nil then return nil end
        if type(v) == "string" then return v end
        local s = try(function() return v:call("ToString()") end)
        if type(s) == "string" then return s end
        return nil
    end

    local function read_guid(comp, field)
        local s = as_text(try(function() return comp:get_field(field) end))
        if s and s ~= "" and s ~= ctx.ZERO_GUID then return s end
        return nil
    end

    local function read_context_id(comp)
        local cid = try(function() return comp:get_field("_ContextID") end)
        if not cid then return nil end
        local s = as_text(try(function() return cid:get_field("_RawID") end))
        if s and s ~= "" and s ~= ctx.ZERO_GUID then return s end
        return nil
    end

    local function read_position(go)
        local xform = try(function() return go:call("get_Transform()") end)
        if not xform then return nil end
        local pos = try(function() return xform:call("get_UniversalPosition()") end)
                 or try(function() return xform:call("get_Position()") end)
        if not pos then return nil end
        local x = tonumber(try(function() return pos.x end) or try(function() return pos:get_field("x") end))
        local y = tonumber(try(function() return pos.y end) or try(function() return pos:get_field("y") end))
        local z = tonumber(try(function() return pos.z end) or try(function() return pos:get_field("z") end))
        if x and y and z and not (x == 0 and y == 0 and z == 0) then return { x = x, y = y, z = z } end
        return nil
    end

    local function read_item(comp)
        local item_id = as_text(try(function() return comp:get_field("_ItemIDStr") end))
            or as_text(try(function() return comp:call("get_ItemID()") end)) or "unknown"
        item_id = item_id:match("(it[%d_]+)") or item_id
        -- clés fp:: / NEVER_BLOCK sur le gid Capcom d'origine (avant rewrite mesh AP)
        local addr = try(function() return comp:get_address() end)
        local vanilla = addr and ctx.ap_placeholder_vanilla and ctx.ap_placeholder_vanilla[addr]
        local key_id = vanilla or item_id

        local amount = try(function() return comp:get_field("_ItemAmount") end) or 1
        local go_name, folder_path, pos = nil, nil, nil
        local go = try(function() return comp:call("get_GameObject()") end)
        if go then
            go_name     = as_text(try(function() return go:call("get_Name()") end))
            folder_path = as_text(try(function() return go:call("get_Folder()"):call("get_Path()") end))
            pos = read_position(go)
        end

        local keys = {}
        local function add(k) if k then keys[#keys + 1] = string.lower(k) end end
        add(read_guid(comp, "_StaticInstanceID"))
        local cid = read_context_id(comp)
        if cid then add("ctx::" .. cid) end
        if folder_path then
            if go_name then add("fp::" .. folder_path .. "/" .. go_name) end
            if go_name ~= key_id then add("fp::" .. folder_path .. "/" .. key_id) end
            -- clé avec XYZ (comme re9_ap_ids) : Joint Plug #1/#2/#3 à 20 cm
            if pos and key_id then
                add(string.format("fp::%s/%s@%.1f,%.1f,%.1f", folder_path, key_id, pos.x, pos.y, pos.z))
                if go_name and go_name ~= key_id then
                    add(string.format("fp::%s/%s@%.1f,%.1f,%.1f", folder_path, go_name, pos.x, pos.y, pos.z))
                end
            end
        end

        return {
            keys = keys,
            item_id = key_id,
            item_name = ctx.item_display_name(key_id),
            amount = amount,
            folder_path = folder_path or "unknown",
            pos = pos,
        }
    end
    ctx.read_item = read_item

    local function is_ignored(info)
        local path = info.folder_path
        for i = 1, #ctx.IGNORED_FOLDER_PREFIXES do
            local prefix = ctx.IGNORED_FOLDER_PREFIXES[i]
            if path:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    local pickups_dirty = false
    local function flush_pickups()
        if not pickups_dirty then return end
        pickups_dirty = false
        pcall(function() json.dump_file(ctx.FILES.last_pickups, ctx.recent_pickups, 4) end)
    end
    ctx.flush_pickups = flush_pickups

    local function remember_pickup(info, loc, how, status)
        local rec = {
            keys = info.keys,
            item_id = info.item_id,
            item_name = info.item_name,
            amount = info.amount,
            folder_path = info.folder_path,
            pos = info.pos and string.format("%.2f, %.2f, %.2f", info.pos.x, info.pos.y, info.pos.z) or nil,
            location = loc and loc.name or nil,
            location_id = loc and loc.id or nil,
            match = how,
            status = status,
        }
        ctx.last_pickup = rec
        table.insert(ctx.recent_pickups, 1, rec)
        if #ctx.recent_pickups > 50 then ctx.recent_pickups[51] = nil end
        pickups_dirty = true
    end

    local warned_no_slot = false

    -- nil si objet d'un autre joueur, sans équivalent ou de catégorie à risque : il passe alors par le coffre
    local function own_swap(loc_id)
        if not ctx.swap_own_items then return nil end
        local sc = ctx.session.scouts[ctx.id_str(loc_id)]
        if not (sc and sc.mine) then return nil end
        local known = ctx.ap_items[ctx.id_str(sc.item)]
        if not (known and ctx.SWAP_CATEGORIES[known.category]) then return nil end
        local gid, count = ctx.resolve_ap_item(sc.item, sc.name)
        local enum = gid and ctx.item_enum and ctx.item_enum(gid)
        if enum == nil then return nil end
        return { gid = gid, count = count or 1, enum = enum, name = sc.name, loc_id = ctx.id_str(loc_id) }
    end

    -- on ne bloque que le même objet qu'au premier ramassage (sauvegarde rechargée), pas un voisin rattaché par erreur
    local SAME_OBJECT_DIST = 1.0
    local function picked_before(loc_id, pos)
        if not pos then return true end
        local p = ctx.session.picked_at and ctx.session.picked_at[ctx.id_str(loc_id)]
        if not p then return false end
        local dx, dy, dz = p[1] - pos.x, p[2] - pos.y, p[3] - pos.z
        return dx * dx + dy * dy + dz * dz <= SAME_OBJECT_DIST * SAME_OBJECT_DIST
    end
    ctx.picked_before = picked_before

    local function remember_position(loc_id, pos)
        if not pos then return end
        ctx.session.picked_at = ctx.session.picked_at or {}
        ctx.session.picked_at[ctx.id_str(loc_id)] = {
            math.floor(pos.x * 100 + 0.5) / 100, math.floor(pos.y * 100 + 0.5) / 100, math.floor(pos.z * 100 + 0.5) / 100,
        }
        -- coalesce avec mark_checked (même tick → un seul dump)
        ctx.save_session()
    end

    local function announce_check(loc)
        ctx.checks_dirty = true
        if ctx.refresh_markers then ctx.refresh_markers() end
        -- envoi immédiat : le toast ne veut pas dire « déjà parti » si on attend le tick
        if ctx.flush_location_checks then ctx.flush_location_checks() end
        -- RE4R pickup event flags : Flag / story → Acquired+Pickedup même si l'item a été swappé
        if ctx.fire_pickup_event_flags then
            pcall(ctx.fire_pickup_event_flags, loc.id, "check")
        end
        local label, color, sc, parts = nil, nil, nil, nil
        if ctx.scout_label then label, color, sc, parts = ctx.scout_label(loc.id) end
        if label then
            ctx.push_message(ctx.T("Trouvé : ") .. label .. "  (" .. loc.name .. ")", color, "check", sc and sc.flags,
                parts and { title = parts.name, sub = parts.who .. "  |  " .. loc.name })
        else
            ctx.push_message(ctx.T("Check : ") .. loc.name, ctx.COLORS.ok, "check", nil, { title = loc.name })
        end
    end

    -- cache canPickupTo (déclaré tôt : repair / invalidate y touchent)
    local check_cache, check_cache_size = {}, 0

    -- briquet / fusible déjà « check » AP : remettre l'objet monde pour reposer le flag scénario
    -- (l'objet AP reçu d'un ami ne pose pas le flag — il faut re-ramasser le vanilla)
    -- opts.keep_checked = true : ne pas renvoyer le check (ami a déjà donné l'item, on veut juste la ciné)
    function ctx.repair_story_pickup(loc_id, item_id, opts)
        local id = ctx.id_str(loc_id)
        if not id then return false, "id invalide" end
        opts = opts or {}
        if not opts.keep_checked then
            if ctx.session.checked then ctx.session.checked[id] = nil end
            if ctx.session.picked_at then ctx.session.picked_at[id] = nil end
            ctx.save_session()
        end

        local loc = ctx.locations[id]
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
        if not scene then return true, "session nettoyée (scène absente)" end
        local arr = scene:call("findComponents(System.Type)", sdk.typeof("app.ItemCore"))
        local n = 0
        local elems = {}
        do
            local ok, list = pcall(function() return arr:get_elements() end)
            if ok and type(list) == "table" then
                elems = list
            else
                local len = tonumber(try(function() return arr:call("get_Count()") end)) or 0
                for i = 0, len - 1 do
                    local e = try(function() return arr:call("get_Item(System.Int32)", i) end)
                    if e then elems[#elems + 1] = e end
                end
            end
        end
        for _, comp in ipairs(elems) do
            local info = read_item(comp)
            if info and info.item_id == item_id then
                -- sinon le jeu refuse le ramassage si Acquired / Vanish déjà posés (item AP d'un ami)
                pcall(function() comp:set_field("_VanishHasAcquired", false) end)
                pcall(function() comp:set_field("_VanishHasFamilyAcquired", false) end)
                pcall(function() comp:set_field("_IsPickupWaiting", false) end)
                pcall(function() comp:set_field("_BindTriggerSleeping", false) end)
                local go = try(function() return comp:call("get_GameObject()") end)
                if go then
                    pcall(function() go:call("set_DrawSelf", true) end)
                    pcall(function() go:call("set_UpdateSelf", true) end)
                    pcall(function() go:call("set_Draw", true) end)
                    pcall(function() go:call("set_Update", true) end)
                    n = n + 1
                end
            end
        end
        if ctx.refresh_markers then ctx.refresh_markers() end
        if n > 0 then
            return true, string.format("%d objet(s) réaffiché(s) — re-ramasse le %s", n, item_id)
        end
        return true, "session nettoyée — si l'objet n'est plus dans la pièce, recharge une save avant ce ramassage"
    end

    function ctx.invalidate_pickup_cache()
        check_cache, check_cache_size = {}, 0
    end

    -- casiers / gimmicks : l'objet peut disparaître sans passer par ItemCore.pickup
    function ctx.force_check(loc, reason, pos)
        if not loc or not ctx.has_slot_data() then return false end
        if not ctx.is_active(loc.id) or not ctx.mark_checked(loc.id) then return false end
        if pos then remember_position(loc.id, pos) end
        announce_check(loc)
        remember_pickup({
            keys = {}, item_id = loc.item_id or "?", item_name = loc.vanilla_item or loc.name,
            amount = loc.amount or 1, folder_path = reason or "forcé", pos = pos,
        }, loc, reason or "forcé", "check")
        ctx.info("check forcé : " .. loc.name .. " (" .. tostring(reason) .. ")")
        return true
    end

    -- drops ennemis + pots cassés :
    -- 1) emplacement monde (clés / objet+pos) si match
    -- 2) sinon pool Enemy Drop #N dans l'ordre (comme Options.enemy_drops apworld)
    local DROP_FOLDERS = { "AppResident/Instance/Item", "AppResident/Instance/DropResource" }
    local enemy_drops          -- liste ordonnée des Drop actifs
    local enemy_drops_sig = "" -- invalide le cache si le set active change
    local warned_drops_empty = false
    local POT_TOL = 3.5        -- pot cassé : l'objet a un peu bougé

    local function is_drop_folder(path)
        for _, prefix in ipairs(DROP_FOLDERS) do
            if path:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    local function enemy_drops_signature()
        local parts = {}
        for id in pairs(ctx.session.active or {}) do
            local loc = ctx.locations[id]
            if loc and loc.chapter == "Drop" then parts[#parts + 1] = id end
        end
        table.sort(parts)
        return table.concat(parts, ",")
    end

    local function ensure_enemy_drops()
        local sig = enemy_drops_signature()
        if enemy_drops and sig == enemy_drops_sig then return end
        enemy_drops, enemy_drops_sig = {}, sig
        for id in pairs(ctx.session.active or {}) do
            local loc = ctx.locations[id]
            if loc and loc.chapter == "Drop" then
                enemy_drops[#enemy_drops + 1] = loc
            end
        end
        table.sort(enemy_drops, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    end

    -- prochain Enemy Drop #N libre (ordre ID = ordre seed)
    local function take_next_enemy_drop()
        ensure_enemy_drops()
        for _, loc in ipairs(enemy_drops) do
            if not ctx.is_checked(loc.id) and ctx.mark_checked(loc.id) then
                return loc
            end
        end
        return nil
    end

    -- emplacement monde près du drop (pas le pool Drop) — ne pas voler un Enemy Drop #N
    local function match_world_drop(info)
        local loc, how = ctx.resolve_location(info.keys or {}, info.item_id, info.pos, POT_TOL)
        if not loc then return nil, nil end
        if loc.chapter == "Drop" then return nil, nil end
        return loc, how
    end

    -- Strip seulement si scout connu : foreign → retirer ; à toi → swap éventuel.
    -- Sans scout : demander LocationScouts et laisser le vanilla (évite de strip « pour toi » à tort).
    local function suppress_after_scout(info, loc, vanilla_hint)
        if not ctx.suppress_vanilla or not loc then return nil end
        local id = ctx.id_str(loc.id)
        local sc = id and ctx.session.scouts and ctx.session.scouts[id]
        if not sc then
            if id and ctx.is_active(id) and ctx.request_scout then ctx.request_scout(id) end
            ctx.info(string.format("scout manquant %s : vanilla %s laissé (LocationScouts…)", loc.name, tostring(info.item_id)))
            return nil
        end
        local vanilla = vanilla_hint
            or (ctx.item_enum and ctx.item_enum(info.item_id))
            or info.item_id
        if sc.mine then
            local swap = own_swap(loc.id)
            local box_only = false
            if not swap then
                -- catégorie hors SWAP in-hand / enum KO → coffre via inject
                local gid, count = ctx.resolve_ap_item(sc.item, sc.name)
                if gid then
                    swap = {
                        gid = gid, count = count or 1,
                        enum = ctx.item_enum and ctx.item_enum(gid),
                        name = sc.name, loc_id = id,
                    }
                    box_only = true
                end
            end
            ctx.info(string.format("scout à toi %s : %s", loc.name,
                swap and ((box_only and "coffre → " or "swap → ") .. tostring(swap.gid))
                    or ("vanilla " .. tostring(info.item_id) .. " bloqué")))
            return {
                swap = swap, vanilla = vanilla, loc = loc.name, item_id = info.item_id,
                amount = info.amount or 1, box_fallback = box_only, loc_id = id,
            }
        end
        ctx.info(string.format("scout foreign %s : vanilla %s retiré", loc.name, tostring(info.item_id)))
        return { swap = nil, vanilla = vanilla, loc = loc.name, item_id = info.item_id, amount = info.amount or 1 }
    end

    local function drop_suppress_action(info, loc)
        return suppress_after_scout(info, loc, nil)
    end

    local function on_pickup(comp)
        local info = read_item(comp)
        if is_ignored(info) then
            if ctx.has_slot_data() and is_drop_folder(info.folder_path) then
                local world_loc, world_how = match_world_drop(info)
                if world_loc then
                    -- match monde : jamais FIFO Enemy Drop (même si déjà check / inactif)
                    if not ctx.is_active(world_loc.id) then
                        remember_pickup(info, world_loc, world_how, "emplacement monde inactif (pas Enemy Drop)")
                        return nil
                    end
                    if ctx.mark_checked(world_loc.id) then
                        remember_position(world_loc.id, info.pos)
                        announce_check(world_loc)
                        remember_pickup(info, world_loc, world_how or "monde (objet + position)", "check")
                        return drop_suppress_action(info, world_loc)
                    end
                    remember_pickup(info, world_loc, world_how, "emplacement monde déjà check (pas Enemy Drop)")
                    return nil
                end
                local drop = take_next_enemy_drop()
                if drop then
                    announce_check(drop)
                    remember_pickup(info, drop, "Enemy Drop #" .. (drop.name:match("%d+") or "?"), "check")
                    return drop_suppress_action(info, drop)
                else
                    remember_pickup(info, nil, nil, "objet généré en jeu")
                    if not warned_drops_empty then
                        warned_drops_empty = true
                        ctx.push_message(
                            ctx.T("Plus de checks Enemy Drop (pots / ennemis). Mets enemy_drops à 100 et régénère la seed."),
                            ctx.COLORS.warn, "warn")
                    end
                end
            else
                remember_pickup(info, nil, nil, "objet généré en jeu")
            end
            return nil
        end

        local loc, how = ctx.resolve_location(info.keys, info.item_id, info.pos)
        if not loc then
            remember_pickup(info, nil, nil, "pas un emplacement connu")
            return nil
        end

        if not ctx.has_slot_data() then
            remember_pickup(info, loc, how, "pas encore connecté au slot")
            if not warned_no_slot then
                warned_no_slot = true
                ctx.push_message(ctx.T("Connecte-toi à Archipelago avant de ramasser des objets !"), ctx.COLORS.bad, "error")
            end
            return nil
        end

        if not ctx.is_active(loc.id) then
            remember_pickup(info, loc, how, "pas un check dans ce slot (objet clé / difficulté)")
            return nil
        end

        if ctx.mark_checked(loc.id) then
            remember_position(loc.id, info.pos)
            announce_check(loc)
            remember_pickup(info, loc, how, "check")
        elseif not picked_before(loc.id, info.pos) then
            remember_pickup(info, loc, how, "check déjà envoyé par un autre objet : objet d'origine laissé")
            return nil
        else
            remember_pickup(info, loc, how, "check déjà envoyé")
        end
        if not ctx.suppress_vanilla then return nil end
        -- Flag / NEVER_BLOCK : le ramassage monde joue la ciné. HasLighter avant le pickup la saute.
        if ctx.should_keep_vanilla(info.item_id, info.folder_path) then
            if ctx.force_story_repick and ctx.force_story_repick[info.item_id] then
                ctx.force_story_repick[info.item_id] = nil
                ctx.info("repick histoire OK : " .. tostring(info.item_id))
            end
            ctx.info(string.format(
                "ramassage : %s (objet d'origine %s) -> laissé (ciné)",
                loc.name, info.item_id))
            return nil
        end
        local vanilla = try(function() return comp:get_field("_ItemIDCache") end)
            or try(function() return comp:call("get_ItemID()") end)
        return suppress_after_scout(info, loc, vanilla)
    end

    -- le jeu ajoute l'objet pendant pickup ou après l'animation, on intercepte le premier mergeOrAdd
    local PENDING_SECONDS = 15
    local action = nil

    local item_core_td = sdk.find_type_definition("app.ItemCore")
    local pickup_method
    for _, m in ipairs(item_core_td and (try(function() return item_core_td:get_methods() end) or {}) or {}) do
        if try(function() return m:get_name() end) == "pickup" then
            pickup_method = m
            break
        end
    end

    if not pickup_method then
        ctx.err("app.ItemCore.pickup introuvable : la détection des checks est désactivée")
        return
    end

    -- inventaire plein : l'objet AP du check va au coffre (le toast existait déjà, l'injection manquait)
    local function send_swap_to_box(sw)
        if not sw or not sw.gid or not ctx.inject_item then return false end
        local ok, err, n = ctx.inject_item(sw.gid, sw.count or 1)
        n = math.max(0, math.floor(tonumber(n) or 0))
        if ok or n > 0 then
            if ctx.note_delivery then ctx.note_delivery(sw.gid, 0, n > 0 and n or (sw.count or 1)) end
            if ctx.apply_item_story_flag then pcall(ctx.apply_item_story_flag, sw.gid) end
            ctx.push_message(ctx.TF("Pas de place : %s → coffre", sw.name), ctx.COLORS.warn, "item")
            if ctx.last_pickup then ctx.last_pickup.status = "check (objet AP au coffre, inventaire plein)" end
            ctx.info(string.format("inventaire plein : %s x%d → coffre", tostring(sw.name), sw.count or 1))
            return true
        end
        ctx.push_message(ctx.TF("Pas de place : %s (échec coffre)", sw.name), ctx.COLORS.bad, "error")
        ctx.warn("coffre après ramassage : " .. tostring(err))
        return false
    end

    local function strip_vanilla_after_failed_swap(a)
        if not a or not a.item_id or not ctx.consume_item_anywhere then return 0 end
        if ctx.should_keep_vanilla and ctx.should_keep_vanilla(a.item_id) then return 0 end
        local n = 0
        pcall(function()
            n = tonumber(ctx.consume_item_anywhere(a.item_id, math.max(1, a.amount or 1))) or 0
        end)
        if n > 0 then
            ctx.info(string.format("vanilla retiré (échec swap) : %s x%d", tostring(a.item_id), n))
        end
        return n
    end

    local function finish(a, how)
        if action == a then action = nil end
        ctx.info("ramassage : " .. tostring(a.loc) .. " : " .. how)
        local sw = a.swap
        local keep = type(how) == "string" and (
            how:find("NEVER_BLOCK", 1, true) or how:find("laissé passer", 1, true))
        -- foreign : pas de swap AP, juste strip vanilla (déjà fait via count 0) — clear pending si besoin
        if not sw then
            if a.loc_id and ctx.clear_local_grant_pending then
                ctx.clear_local_grant_pending(a.loc_id)
            end
            return
        end
        local granted = false
        if a.swapped then
            ctx.mark_local_grant(sw.loc_id)
            granted = true
            ctx.note_delivery(sw.gid, sw.count, 0)
            if ctx.last_pickup then ctx.last_pickup.status = "check (objet AP donné au ramassage)" end
        elseif not keep then
            -- timeout / pas d'intercept / inventaire plein / KeyItem hors mergeOrAdd
            strip_vanilla_after_failed_swap(a)
            if send_swap_to_box(sw) then
                ctx.mark_local_grant(sw.loc_id)
                granted = true
            end
        end
        if not granted then ctx.clear_local_grant_pending(sw.loc_id) end
    end

    local function current_action()
        if action and os.clock() > action.deadline then
            finish(action, "objet d'origine jamais ajouté à l'inventaire (rien intercepté)")
        end
        return action
    end

    sdk.hook(pickup_method,
        function(args)
            if current_action() then finish(action, "remplacé par un autre ramassage (rien intercepté)") end
            local skip_joint = false
            local ok, e = pcall(function()
                local self = sdk.to_managed_object(args[2])
                if not self then return end
                local info = read_item(self)
                -- Joint Plug panneau réel seulement (pas un spot rewrite mesh → Connecteur)
                if info and info.item_id == "it60_00_038" then
                    local loc = ctx.resolve_location(info.keys, info.item_id, info.pos)
                    local vanilla_jp = not loc or not loc.vanilla_game_id or loc.vanilla_game_id == "it60_00_038"
                    if vanilla_jp then
                        if loc and ctx.is_active(loc.id) then
                            pcall(ctx.force_check, loc, "Joint Plug (sans retirer le panneau)", info.pos)
                        end
                        skip_joint = true
                        return
                    end
                    -- sinon : check monde dont l'item AP est Joint Plug → ramassage normal
                end
                local a = on_pickup(self)
                if a then
                    a.deadline = os.clock() + PENDING_SECONDS
                    a.amount = a.amount or (info and info.amount) or 1
                    if a.swap and a.swap.loc_id then a.loc_id = a.swap.loc_id end
                    action = a
                    -- ReceivedItems attend le grant (évite double si le serveur répond pendant le swap)
                    if a.swap and a.swap.loc_id then
                        ctx.begin_local_grant(a.swap.loc_id)
                    elseif a.box_fallback and not a.swap then
                        -- scout à moi mais own_swap nil : livrer via ReceivedItems (pas de pending bloquant)
                    end
                end
            end)
            if not ok then ctx.err("hook pickup : " .. tostring(e)) end
            if skip_joint then return sdk.PreHookResult.SKIP_ORIGINAL end
        end,
        function(retval) return retval end
    )

    -- ramassage forcé si plus de place (collecteur plein...) tant que le check n'est pas envoyé
    -- canPickupTo tourne à chaque image près de l'objet, d'où le cache de 1 s
    local function is_pending_check(comp)
        local addr = try(function() return comp:get_address() end)
        if not addr then return false end
        local now = os.clock()
        local c = check_cache[addr]
        if c and now < c.expires then return c.value end
        local value = false
        if ctx.suppress_vanilla and ctx.has_slot_data() then
            local info = read_item(comp)
            if not is_ignored(info) then
                -- réparation ciné : forcer le ramassage même si NEVER_BLOCK / déjà acquis
                if ctx.force_story_repick and ctx.force_story_repick[info.item_id] then
                    value = true
                -- fusible / Flag : ne jamais forcer canPickupTo (sinon panneau vole l'interaction « insérer »)
                elseif not ctx.should_keep_vanilla(info.item_id, info.folder_path) then
                    local loc = ctx.resolve_location(info.keys, info.item_id, info.pos)
                    value = loc ~= nil and ctx.is_active(loc.id) and not ctx.is_checked(loc.id)
                end
            end
        end
        if not c then
            check_cache_size = check_cache_size + 1
            if check_cache_size > 200 then check_cache, check_cache_size = {}, 1 end
        end
        check_cache[addr] = { value = value, expires = now + 1 }
        return value
    end

    local can_pickup_method = item_core_td and try(function()
        return item_core_td:get_method("canPickupTo(app.Inventory)")
    end)
    if can_pickup_method then
        local asking = nil
        sdk.hook(can_pickup_method,
            function(args) asking = args[2] end,
            function(retval)
                local comp_ptr = asking
                asking = nil
                -- Joint Plug panneau réel : jamais ramassable (sinon la cellule ne s'ouvre pas)
                local block_joint = false
                pcall(function()
                    local self = sdk.to_managed_object(comp_ptr)
                    local info = self and read_item(self)
                    if info and info.item_id == "it60_00_038" then
                        local loc = ctx.resolve_location(info.keys, info.item_id, info.pos)
                        if not loc or not loc.vanilla_game_id or loc.vanilla_game_id == "it60_00_038" then
                            block_joint = true
                        end
                    end
                end)
                if block_joint then return sdk.to_ptr(0) end
                local n = comp_ptr and try(function() return sdk.to_int64(retval) end)
                if n == nil or (n & 1) == 1 then return retval end
                local ok, force = pcall(function()
                    local self = sdk.to_managed_object(comp_ptr)
                    return self ~= nil and is_pending_check(self)
                end)
                if ok and force then return sdk.to_ptr(1) end
                return retval
            end
        )
    else
        ctx.warn("app.ItemCore.canPickupTo introuvable : un check sans place dans l'inventaire ne pourra pas être ramassé")
    end

    -- seaux de sang : check 1× par récolte (BloodDrawing). Ne pas hooker Update* (spam = multi-checks)
    local BLOOD_ITEM = "it70_01_000"
    local BLOOD_RADIUS = 4.5
    local BLOOD_RADIUS2 = BLOOD_RADIUS * BLOOD_RADIUS
    local blood_lock_until = 0
    local blood_locs = nil

    local function blood_candidates()
        if blood_locs then return blood_locs end
        blood_locs = {}
        for _, loc in pairs(ctx.locations) do
            if loc.item_id == BLOOD_ITEM and loc.x then blood_locs[#blood_locs + 1] = loc end
        end
        return blood_locs
    end

    local function on_blood_drawing()
        if not ctx.has_slot_data() then return end
        local now = os.clock()
        if now < blood_lock_until then return end
        -- un mergeOrAdd AP en cours ne doit pas manger le fill du collecteur
        if action and action.item_id ~= BLOOD_ITEM then
            finish(action, "interrompu (récolte de sang)")
        end
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local pc = mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
        local p = pc and try(function() return pc:call("get_Position") end)
        local px = p and tonumber(try(function() return p.x end))
        if not px then return end
        local py, pz = tonumber(p.y), tonumber(p.z)
        local best, best_d2 = nil, BLOOD_RADIUS2
        for i = 1, #blood_candidates() do
            local loc = blood_locs[i]
            if ctx.is_active(loc.id) and not ctx.is_checked(loc.id) then
                local dx, dy, dz = loc.x - px, loc.y - py, loc.z - pz
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 < best_d2 then best, best_d2 = loc, d2 end
            end
        end
        if not best then
            ctx.info(string.format("sang infecté : aucun check à < %.1f m", BLOOD_RADIUS))
            return
        end
        if not ctx.mark_checked(best.id) then return end
        blood_lock_until = now + 2.5
        remember_position(best.id, { x = best.x, y = best.y, z = best.z })
        announce_check(best)
        local how = string.format("récolte au collecteur (%.1f m)", math.sqrt(best_d2))
        remember_pickup({ keys = {}, item_id = BLOOD_ITEM, item_name = ctx.item_display_name(BLOOD_ITEM),
            amount = best.amount, folder_path = "récolte de sang", pos = { x = px, y = py, z = pz } }, best, how, "check")
        ctx.info("sang infecté : " .. best.name .. " -> " .. how)
    end

    local blood_hooks = 0
    do
        local td = sdk.find_type_definition("app.BloodDrawingAction")
        local m = td and try(function() return td:get_method("start(via.behaviortree.ActionArg)") end)
        if m then
            sdk.hook(m, function()
                local ok, e = pcall(on_blood_drawing)
                if not ok then ctx.err("récolte de sang : " .. tostring(e)) end
            end, nil)
            blood_hooks = blood_hooks + 1
        end
        -- secours si BloodDrawingAction absent (éviter Update* : se déclenche en boucle)
        if blood_hooks == 0 then
            local td2 = sdk.find_type_definition("app.PlayerBehaviorTreeAction_UpdateStartBloodDrawing")
            local m2 = td2 and try(function() return td2:get_method("start(via.behaviortree.ActionArg)") end)
            if m2 then
                sdk.hook(m2, function()
                    local ok, e = pcall(on_blood_drawing)
                    if not ok then ctx.err("récolte de sang : " .. tostring(e)) end
                end, nil)
                blood_hooks = blood_hooks + 1
            end
        end
    end
    if blood_hooks == 0 then ctx.warn("récolte de sang introuvable : les seaux de sang infecté ne donneront pas de check") end

    local inv_td = sdk.find_type_definition("app.Inventory")
    local can_merge = inv_td and try(function()
        return inv_td:get_method("canMergeOrAdd(app.ItemID, System.Int32, System.Boolean)")
    end)

    local function arg_bool(v)
        local n = try(function() return sdk.to_int64(v) end)
        return n ~= nil and (n & 1) == 1
    end

    local function swap_fits(a, inv, flag)
        if a.fits == nil then
            local ok, r = false, nil
            if can_merge and inv then
                ok, r = pcall(function() return can_merge:call(inv, a.swap.enum, a.swap.count, flag) end)
            end
            a.fits = ok and r == true
        end
        return a.fits
    end

    -- app.ItemID arrive soit en objet (ToString), soit en nombre
    local function id_key(v)
        if v == nil then return nil end
        if type(v) == "number" then return tostring(math.floor(v) & 0xFFFFFFFF) end
        local s = try(function() return v:call("ToString()") end)
        if type(s) == "string" and s ~= "" then return s end
        local n = try(function() return sdk.to_int64(v) end)
        return n and tostring(math.floor(n) & 0xFFFFFFFF) or nil
    end

    -- app.ItemAmountData n'a pas de champ _Stock : seulement set_Stock(Int32)
    local function set_stock(entry, n)
        pcall(function() entry:call("set_Stock(System.Int32)", n) end)
    end

    local function swap_entry(entry, sw)
        pcall(function() entry:call("set_ItemID", sw.enum) end)
        pcall(function() entry:set_field("_ItemIDCache", sw.enum) end)
        pcall(function() entry:set_field("_ItemID", sdk.create_managed_string(sw.gid)) end)
        local now = try(function() return entry:call("get_ItemID") end)
        if id_key(now) ~= id_key(sw.enum) then
            ctx.info(string.format("remplacement refusé : objet resté %s (voulu %s)", tostring(now), tostring(sw.enum)))
            return false
        end
        set_stock(entry, sw.count)
        return true
    end

    local function item_id_str(v)
        if v == nil then return nil end
        local s = as_text(v) or tostring(v)
        return s:match("(it[%d_]+)") or s
    end

    local function on_merge(kind, args)
        local a = current_action()
        if not a then return end
        -- ne jamais manger un fusible / NEVER_BLOCK même si une autre action est en cours
        if a.item_id and ctx.should_keep_vanilla(a.item_id) then
            finish(a, "annulé (NEVER_BLOCK)")
            return
        end
        local want = id_key(a.vanilla)
        local inv = sdk.to_managed_object(args[2])
        if kind == "id" then
            local got = id_key(try(function() return sdk.to_int64(args[3]) end))
                or id_key(try(function() return sdk.to_managed_object(args[3]) end))
            local got_name = item_id_str(try(function() return sdk.to_managed_object(args[3]) end))
                or item_id_str(try(function() return sdk.to_int64(args[3]) end))
            -- sang infecté → collecteur : ne jamais bloquer / swapper le fill
            if got_name == BLOOD_ITEM then return end
            -- avant : si vanilla n'était pas un number, on bloquait N'IMPORTE quel mergeOrAdd (softlock fusible)
            if want and got and got ~= want then
                ctx.info(string.format("mergeOrAdd (%s) ignoré : objet %s, attendu %s", kind, tostring(got), tostring(want)))
                return
            end
            if got_name and ctx.should_keep_vanilla(got_name) then
                finish(a, "laissé passer (NEVER_BLOCK " .. got_name .. ")")
                return
            end
            if a.swap and a.swap.enum and not a.box_fallback and swap_fits(a, inv, arg_bool(args[5])) then
                args[3] = sdk.to_ptr(a.swap.enum)
                args[4] = sdk.to_ptr(a.swap.count)
                a.swapped = true
            else
                args[4] = sdk.to_ptr(0)
                if a.swap then a.box_fallback = true end
            end
            finish(a, string.format("intercepté (%s) -> %s", kind, a.swapped and "mon objet donné" or "bloqué"))
            return
        end
        local obj = sdk.to_managed_object(args[3])
        if not obj then return end
        local entries, seen = {}, {}
        local list = {}
        if kind == "array" then
            for i = 0, obj:get_Count() - 1 do list[#list + 1] = obj:get_Item(i) end
        else
            list[1] = obj
        end
        for _, entry in ipairs(list) do
            if entry then
                local got = id_key(try(function() return entry:call("get_ItemID") end))
                local gname = item_id_str(try(function() return entry:call("get_ItemID") end))
                    or item_id_str(try(function() return entry:get_field("_ItemID") end))
                seen[#seen + 1] = tostring(got)
                -- sang infecté dans le merge : laisser passer (remplit le collecteur)
                if gname == BLOOD_ITEM then return end
                if gname and ctx.should_keep_vanilla(gname) then
                    finish(a, "laissé passer (NEVER_BLOCK " .. gname .. ")")
                    return
                end
                if not want or got == want then entries[#entries + 1] = entry end
            end
        end
        if #entries == 0 then
            ctx.info(string.format("mergeOrAdd (%s) ignoré : objets %s, attendu %s", kind, table.concat(seen, ","), tostring(want)))
            -- KeyItem / autre chemin : ne pas laisser grant_pending bloqué — coffre au finish
            if a.swap then
                a.box_fallback = true
                for _, entry in ipairs(list) do
                    if entry then set_stock(entry, 0) end
                end
                finish(a, string.format("intercepté (%s) -> hors cible, coffre", kind))
            end
            return
        end
        local sw = a.swap and not a.box_fallback and swap_fits(a, inv, arg_bool(args[4])) and a.swap
        for i, entry in ipairs(entries) do
            if i == 1 and sw and sw.enum and swap_entry(entry, sw) then
                a.swapped = true
            else
                set_stock(entry, 0)
                if a.swap and not a.swapped then a.box_fallback = true end
            end
        end
        finish(a, string.format("intercepté (%s) -> %s", kind, a.swapped and "mon objet donné" or "bloqué"))
    end

    -- trois surcharges de mergeOrAdd, on les distingue par le 1er paramètre
    local merges = {}
    for _, m in ipairs(inv_td and (try(function() return inv_td:get_methods() end) or {}) or {}) do
        if try(function() return m:get_name() end) == "mergeOrAdd" then
            local p = try(function() return m:get_param_types()[1]:get_full_name() end) or ""
            local kind = (p:find("%[%]$") and "array") or (p == "app.ItemAmountData" and "single")
                or (p == "app.ItemID" and "id") or nil
            merges[#merges + 1] = { m = m, kind = kind }
        end
    end
    local hooked = 0
    for _, mm in ipairs(merges) do
        if mm.kind then
            local kind = mm.kind
            sdk.hook(mm.m, function(args)
                local ok, e = pcall(on_merge, kind, args)
                if not ok then ctx.err("hook mergeOrAdd : " .. tostring(e)) end
            end, nil)
            hooked = hooked + 1
        end
    end
    -- paramètres illisibles : on retombe sur la première surcharge
    if hooked == 0 and merges[1] then
        sdk.hook(merges[1].m, function(args) pcall(on_merge, "array", args) end, nil)
        hooked = 1
    end
    if hooked == 0 then
        ctx.warn("app.Inventory.mergeOrAdd introuvable : l'objet d'origine sera quand même donné")
    elseif not can_merge then
        ctx.warn("app.Inventory.canMergeOrAdd introuvable : mes objets AP arriveront au coffre")
    end

    -- Joint Plug : brancher dans le panneau (verts) ≠ ItemCore.pickup
    local JOINT_PLUG = "it60_00_038"
    local joint_locs = nil
    local joint_lock_until = 0
    local joint_enum = nil

    local function joint_candidates()
        if joint_locs then return joint_locs end
        joint_locs = {}
        for _, loc in pairs(ctx.locations or {}) do
            if loc.item_id == JOINT_PLUG then
                joint_locs[#joint_locs + 1] = loc
            end
        end
        return joint_locs
    end

    local function player_xyz()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local pc = mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
        local p = pc and try(function() return pc:call("get_Position") end)
        if not p then return nil end
        local x = tonumber(try(function() return p.x end))
        if not x then return nil end
        return x, tonumber(p.y), tonumber(p.z)
    end

    local function is_joint_plug_id(v)
        if v == nil then return false end
        if not joint_enum and ctx.item_enum then joint_enum = ctx.item_enum(JOINT_PLUG) end
        if joint_enum ~= nil and id_key(v) == id_key(joint_enum) then return true end
        local name = item_id_str(v)
        if name == JOINT_PLUG then return true end
        local s = as_text(v) or tostring(v or "")
        return type(s) == "string" and s:find(JOINT_PLUG, 1, true) ~= nil
    end

    -- marque N checks Joint Plug : zone stage > plus proche > chapitre
    local function on_joint_plug_used(count, reason)
        if not ctx.has_slot_data() then return 0 end
        local now = os.clock()
        if now < joint_lock_until then return 0 end
        count = math.max(1, math.floor(tonumber(count) or 1))
        local px, py, pz = player_xyz()
        local stage = tostring(ctx.current_stage or ctx.last_stage or "")
        local ch = ctx.ap_chapter and ctx.ap_chapter() or nil
        local checked = 0
        for _ = 1, count do
            local best, best_score = nil, nil
            for _, loc in ipairs(joint_candidates()) do
                if ctx.is_active(loc.id) and not ctx.is_checked(loc.id) then
                    local same_zone = stage ~= "" and loc.zone == stage
                    local same_ch = ch and loc.chapter == ch
                    local d2 = 1e12
                    if px and loc.x then
                        local dx, dy, dz = loc.x - px, (loc.y or 0) - (py or 0), (loc.z or 0) - (pz or 0)
                        d2 = dx * dx + dy * dy + dz * dz
                    end
                    local score
                    if same_zone then
                        score = d2 * 0.001
                    elseif same_ch then
                        score = 1e6 + d2
                    elseif px then
                        score = 1e9 + d2
                    else
                        score = nil
                    end
                    if score and (not best_score or score < best_score) then
                        best, best_score = loc, score
                    end
                end
            end
            if not best then break end
            local pos = px and { x = px, y = py, z = pz } or nil
            if ctx.force_check(best, reason or "insertion Joint Plug", pos) then
                checked = checked + 1
            end
        end
        if checked > 0 then
            joint_lock_until = now + 0.25
            ctx.info(string.format("Joint Plug : %d check(s) (%s)", checked, tostring(reason)))
        end
        return checked
    end
    ctx.force_joint_plug_checks = on_joint_plug_used

    -- 1) consumeStock (toute surcharge)
    local consume_hooks = 0
    for _, m in ipairs(inv_td and (try(function() return inv_td:get_methods() end) or {}) or {}) do
        if try(function() return m:get_name() end) == "consumeStock" then
            sdk.hook(m, function(args)
                local ok, e = pcall(function()
                    local id_obj = try(function() return sdk.to_managed_object(args[3]) end)
                        or try(function() return sdk.to_int64(args[3]) end)
                    if not is_joint_plug_id(id_obj) then return end
                    local n = try(function() return sdk.to_int64(args[4]) end) or 1
                    on_joint_plug_used(n, "consumeStock")
                end)
                if not ok then ctx.err("hook Joint Plug consume : " .. tostring(e)) end
            end, nil)
            consume_hooks = consume_hooks + 1
        end
    end

    -- 2) secours : panneau rempli (verts) sur le stage courant → checks de la zone
    local function joint_get_scene()
        return try(function()
            return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
        end)
    end
    local function joint_components(arr)
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
    local function bitcount(v)
        local n, x = 0, math.floor(tonumber(v) or 0)
        while x > 0 do
            if x % 2 == 1 then n = n + 1 end
            x = math.floor(x / 2)
        end
        return n
    end
    -- expire les swaps même sans nouveau ramassage (sinon grant_pending reste bloqué + clé vanilla)
    ctx.on_tick("pickup_swap", function()
        current_action()
        -- orphelins : pending sans action active (reload mid-swap, etc.)
        local pending = ctx.session and ctx.session.grant_pending
        if type(pending) ~= "table" then return end
        local active_loc = action and action.swap and action.swap.loc_id
        for k, v in pairs(pending) do
            if v and k ~= active_loc then
                ctx.warn("grant_pending orphelin nettoyé : " .. tostring(k))
                ctx.clear_local_grant_pending(k)
            end
        end
    end)

    local JOINT_ID = "it60_00_038"

    local function object_item_id(go)
        if not go then return nil end
        local core = try(function()
            return go:call("getComponent(System.Type)", sdk.typeof("app.ItemCore"))
        end)
        local info = core and read_item(core)
        return info and info.item_id
    end

    local function controller_is_joint(c)
        local infos = try(function() return c:get_field("_InstallationInfos") end)
        local list = infos and (try(function() return infos:get_elements() end) or {})
        for _, info in ipairs(type(list) == "table" and list or {}) do
            local targets = info and try(function() return info:get_field("_TargetObjects") end)
            local tos = targets and (try(function() return targets:get_elements() end) or {})
            for _, go in ipairs(type(tos) == "table" and tos or {}) do
                local id = object_item_id(go)
                if id == JOINT_ID then return true end
            end
        end
        return false
    end

    ctx.on_tick("joint_plug_panel", function()
        if not ctx.has_slot_data() then return end
        local stage = tostring(ctx.current_stage or ctx.last_stage or "")
        if stage == "" then return end
        local pending, total = 0, 0
        for _, loc in ipairs(joint_candidates()) do
            if loc.zone == stage then
                total = total + 1
                if ctx.is_active(loc.id) and not ctx.is_checked(loc.id) then
                    pending = pending + 1
                end
            end
        end
        if total == 0 then return end
        local scene = joint_get_scene()
        local typ = try(function() return sdk.typeof("app.GmItemInstallationController") end)
        if not (scene and typ) then return end
        local arr = try(function() return scene:call("findComponents(System.Type)", typ) end)
        local slots_filled = 0
        for _, c in ipairs(joint_components(arr)) do
            if controller_is_joint(c) then
                if try(function() return c:get_field("_OldIsSetAll") end) == true then
                    slots_filled = math.max(slots_filled, total)
                else
                    local put = tonumber(try(function() return c:get_field("_PutTagFlg") end)) or 0
                    slots_filled = math.max(slots_filled, bitcount(put))
                end
            end
        end
        if pending > 0 then
            local already = total - pending
            local need = slots_filled - already
            if need > 0 then
                on_joint_plug_used(math.min(need, pending), "panneau Joint Plug")
            end
        end
        -- réafficher les meshes connecteurs (TargetItemCore / TargetObjects) si branchés
        if slots_filled > 0 then
            pcall(function()
                local typ_inst = sdk.typeof("app.GmItemInstallation")
                local arr2 = typ_inst and scene:call("findComponents(System.Type)", typ_inst)
                for _, inst in ipairs(joint_components(arr2)) do
                    local params = try(function() return inst:get_field("_GmSetItemParam") end)
                    local elems = params and (try(function() return params:get_elements() end)
                        or try(function()
                            local n = params:call("get_Length()")
                            local o = {}
                            for i = 0, (tonumber(n) or 0) - 1 do
                                o[#o + 1] = params:call("Get(System.Int32)", i)
                            end
                            return o
                        end))
                    for _, p in ipairs(type(elems) == "table" and elems or {}) do
                        local core = p and try(function() return p:get_field("_TargetItemCore") end)
                        local info = core and read_item(core)
                        if not (info and info.item_id == JOINT_ID) then core = nil end
                        local go = core and try(function() return core:call("get_GameObject()") end)
                        if go then
                            local mesh = try(function()
                                return go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                            end)
                            if ctx.show_world_go then
                                ctx.show_world_go(go, mesh)
                            else
                                pcall(function() go:call("set_DrawSelf", true) end)
                                pcall(function() go:call("set_Draw", true) end)
                            end
                            -- ItemCore : interact off pour ne pas bloquer l'ouverture de cellule
                            if core then
                                pcall(function() core:call("set_Enabled", false) end)
                                pcall(function() core:set_field("_VanishHasAcquired", true) end)
                            end
                        end
                    end
                end
                for _, c in ipairs(joint_components(arr)) do
                    local infos = try(function() return c:get_field("_InstallationInfos") end)
                    local list = infos and (try(function() return infos:get_elements() end) or {})
                    for _, info in ipairs(type(list) == "table" and list or {}) do
                        local targets = info and try(function() return info:get_field("_TargetObjects") end)
                        local tos = targets and (try(function() return targets:get_elements() end) or {})
                        for _, go in ipairs(type(tos) == "table" and tos or {}) do
                            if go and ctx.show_world_go then ctx.show_world_go(go, nil)
                            elseif go then
                                pcall(function() go:call("set_DrawSelf", true) end)
                                pcall(function() go:call("set_Draw", true) end)
                            end
                        end
                    end
                end
            end)
        end
    end, { every = 0.5 })

    if consume_hooks > 0 then
        ctx.info(string.format("Joint Plug : insertion→check (%d consume + panneau)", consume_hooks))
    else
        ctx.warn("Joint Plug : consumeStock introuvable — secours panneau seul")
    end

    ctx.info("détecteur de ramassage installé")
end
