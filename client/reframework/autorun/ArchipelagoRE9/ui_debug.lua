-- outils développeur : chargé après ui, onglet visible seulement si prefs.dev_tools

return function(ctx)
    local theme = ctx.theme
    local T, TF = ctx.T, ctx.TF
    local S = ctx.scenes
    local DBG_CH = S.DBG_CH
    local DBG_LABELS = S.DBG_LABELS
    local DBG_SETTLE = 2.5

    local debug_item, debug_qty = "", 1
    local debug_ch_idx = 1
    local debug_sub = 1
    local goal_confirm_until = 0
    local redeliver_confirm_until, redeliver_from = 0, 1
    local journal_filter = 1
    local transfer = { index = 1, qty = 1 }
    local give = { search = "", qty = 1, selected = nil, list = nil }

    local dbg_pending_finish = nil
    local dbg_restore_scene = false
    local dbg_jump_target = nil
    local dbg_spawn = nil

    local KIND_PREFIX = { item = "<-", check = "->", goal = "*", error = "!" }
    local JOURNAL_FILTERS = { "Tout", "Reçus", "Checks", "Système" }

    local function dbg_make_vec3(x, y, z)
        local v = Vector3f and Vector3f.new(x, y, z)
        if v then return v end
        local ok, n = pcall(function()
            return sdk.create_instance("via.vec3"):add_ref()
        end)
        if ok and n then
            pcall(function() n:set_field("x", x) end)
            pcall(function() n:set_field("y", y) end)
            pcall(function() n:set_field("z", z) end)
            return n
        end
        return nil
    end

    local function dbg_set_player_pos(x, y, z)
        local try = ctx.try
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and try(function() return cm:call("getPlayerContextRefFast()") end)
        local go = pc and try(function() return pc:call("get_GameObject()") end)
        local xform = go and try(function() return go:call("get_Transform()") end)
        if not xform then return false end
        local pos = dbg_make_vec3(x, y, z)
        if not pos then return false end
        pcall(function() xform:call("set_UniversalPosition", pos) end)
        pcall(function() xform:call("set_Position", pos) end)
        local cc = try(function() return go:call("get_CharacterController") end)
        if cc then pcall(function() cc:call("warp()") end) end
        return true
    end

    local function dbg_apply_spawn(sp)
        if not sp or not sp.x then return end
        local x, y, z = sp.x, sp.y + 1.25, sp.z
        local stage = sp.stage
        local esm = sdk.get_managed_singleton("app.EnvStageManager")
        if esm and stage and tostring(stage):find("^st") then
            local pos = dbg_make_vec3(x, y, z)
            pcall(function()
                esm:set_field("_ChangeStagePlayerPosition", pos)
                esm:set_field("_IsSkipPlayerlengthCheck", true)
                esm:call("setOverrideStageName(System.String)", stage)
                esm:call("setStandbyFromController(System.String)", stage)
                esm:call("setChangeStageFromController(System.String, System.UInt32)", stage, 0)
                esm:call("setActivateFromController(System.String)", stage)
            end)
        end
        dbg_set_player_pos(x, y, z)
        ctx.push_message(TF("Spawn machine : %.0f, %.0f, %.0f", x, y, z), ctx.COLORS.ok, "info")
    end

    local function dbg_finish_chapters(chapters)
        if not ctx.is_game_ready or not ctx.is_game_ready() then return nil end
        local connected = ctx.has_slot_data and ctx.has_slot_data()
        local checks, given = 0, 0
        for id, loc in pairs(ctx.locations or {}) do
            if chapters[loc.chapter] and loc.x then
                if connected and ctx.is_active and ctx.is_active(id) then
                    if ctx.mark_checked(id) then checks = checks + 1 end
                elseif loc.item_id and loc.item_id ~= "" and ctx.inject_item then
                    if ctx.inject_item(loc.item_id, loc.amount or 1) then given = given + 1 end
                end
            end
        end
        if checks > 0 then
            ctx.checks_dirty = true
            if ctx.flush_location_checks then pcall(ctx.flush_location_checks) end
            if ctx.refresh_markers then pcall(ctx.refresh_markers) end
        end
        local msg = TF("Chapitres sautés terminés : %d check(s), %d objet(s) au coffre", checks, given)
        ctx.push_message(msg, ctx.COLORS.ok, "check")
        return msg
    end

    local function dbg_jump_to_scene(scene)
        local from = ctx.current_scene()
        if from == scene then
            ctx.push_message(TF("Déjà sur %s", scene), ctx.COLORS.info, "info")
            return false
        end
        local chapters = ctx.chapters_between(from, scene)
        local ok, err = ctx.jump_to_scene(scene, { bypass = 8 })
        if not ok then
            ctx.push_message(T("Échec warp : ") .. tostring(err or "managers"), ctx.COLORS.bad, "error")
            return false
        end
        dbg_jump_target = scene
        dbg_restore_scene = true
        dbg_pending_finish = { target = scene, chapters = chapters }
        return true
    end

    local function dbg_teleport_chapter(entry)
        local ok = dbg_jump_to_scene(entry[2])
        if ok then
            if entry[4] then
                dbg_spawn = {
                    x = entry[4], y = entry[5], z = entry[6],
                    stage = entry[7], at = nil,
                }
            else
                dbg_spawn = nil
            end
            ctx.push_message(
                TF("Téléport Debug → Ch%d (%s) — chapitres précédents terminés à l'arrivée", entry[1], entry[2]),
                ctx.COLORS.info, "info")
        end
        return ok
    end

    -- settle warp : on_frame (ImGui / arrivée scène)
    re.on_frame(function()
        if not (dbg_restore_scene or dbg_pending_finish or dbg_spawn) then return end
        local arrived = ctx.current_scene()
        if dbg_jump_target and arrived ~= dbg_jump_target then return end
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and ctx.try(function() return cm:call("getPlayerContextRefFast()") end)
        if not pc then return end
        if dbg_restore_scene then
            dbg_restore_scene = false
            local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
            pcall(function() mgr:call("setNewGameSceneName(System.String)", S.NEW_GAME) end)
            if dbg_spawn then dbg_spawn.at = os.clock() + DBG_SETTLE end
        end
        if dbg_pending_finish then
            local msg = dbg_finish_chapters(dbg_pending_finish.chapters or {})
            if msg then dbg_pending_finish = nil end
        end
        if dbg_spawn and dbg_spawn.at and os.clock() >= dbg_spawn.at then
            local sp = dbg_spawn
            dbg_spawn = nil
            dbg_apply_spawn(sp)
        end
    end)

    local function draw_chapter_warps()
        local here = ctx.current_scene and ctx.current_scene() or ""
        theme.heading(T("Chapitre"))
        theme.note(T("Sauvegarde avant de warper."))
        for i, e in ipairs(DBG_CH) do
            local scene = e[2]
            local label = DBG_LABELS[i] or ("Ch" .. tostring(e[1]))
            if scene == here then
                theme.note(label)
            elseif imgui.button(label .. "##dbgch" .. i) then
                local ok, err = ctx.warp_to_scene and ctx.warp_to_scene(scene)
                if ok then
                    ctx.push_message(TF("Warp vers %s", label), ctx.COLORS.info, "info")
                elseif err == "deja" then
                    ctx.push_message(T("Déjà dans ce chapitre."), ctx.COLORS.info, "info")
                else
                    ctx.push_message(TF("Échec warp : %s", tostring(err or "")), ctx.COLORS.bad, "error")
                end
            end
        end
    end

    local function draw_warp_panel()
        theme.heading(T("Téléport chapitre (Debug)"))
        theme.note(T("Changer la liste = saut immédiat au chapitre + fin des chapitres précédents."))
        theme.colored(T("Sauvegarde ta partie avant de sauter."), theme.ERROR)
        -- liste = uniquement le chapitre courant
        local cur_ch = ctx.ap_chapter_num and ctx.ap_chapter_num()
        local labels, entries = {}, {}
        for i, e in ipairs(DBG_CH) do
            if e[1] == cur_ch then
                entries[1] = e
                labels[1] = DBG_LABELS[i]
                break
            end
        end
        if #labels == 0 then
            labels[1] = cur_ch and ("Ch" .. cur_ch) or "?"
        end
        local c, idx = imgui.combo(T("Chapitre") .. "##ui_dbg_ch_tp", 1, labels)
        local entry = entries[1]
        if entry then
            theme.note(TF("Scène : %s", entry[2]))
        end
        if imgui.button(T("Téléporter + terminer les précédents") .. "##ui_dbg_ch_go") and entry then
            dbg_teleport_chapter(entry)
        end
    end

    -- alias : ancien nom du panneau
    local draw_chapter_teleport_combo = draw_warp_panel

    local function item_label(id)
        local known = ctx.items_by_id and ctx.items_by_id[id]
        local name = known and known.name or id
        return ctx.display_name and ctx.display_name(name) or name
    end

    local function draw_box_transfer()
        if not ctx.request_transfer then return end
        imgui.text("")
        theme.heading(T("Coffre -> mon inventaire"))
        ctx.box_cache_wanted = true
        local list = ctx.box_cache or {}
        if #list == 0 then
            theme.note(T("Coffre vide (ou pas encore chargé)."))
            return
        end
        local labels = {}
        for i, e in ipairs(list) do labels[i] = string.format("%s x%d  [%s]", item_label(e.id), e.count, e.id) end
        if transfer.index > #labels then transfer.index = 1 end
        local _
        _, transfer.index = imgui.combo(T("Objet du coffre") .. "##transfer_combo", transfer.index, labels)
        local e = list[transfer.index]
        _, transfer.qty = imgui.drag_int(T("Quantité") .. "##transfer_qty", transfer.qty or 1, 1, 1, math.max(1, e and e.count or 1))
        if e and imgui.button(T("Prendre dans mon inventaire") .. "##transfer_go") then
            local user = ctx.player_inventory_user and ctx.player_inventory_user() or ctx.GRACE_HAND_USER
            local label = item_label(e.id)
            ctx.request_transfer(e.id, transfer.qty, user, function(moved, err)
                if moved > 0 then
                    ctx.push_message(TF("Pris du coffre : %s x%d", label, moved), ctx.COLORS.ok, "item")
                else
                    ctx.push_message(T("Transfert impossible : ") .. tostring(err), ctx.COLORS.warn, "error")
                end
            end)
        end
    end

    local function draw_last_pickup()
        local p = ctx.last_pickup
        if not p then
            theme.note(T("Aucun ramassage depuis le lancement."))
            return
        end
        imgui.text(TF("Objet : %s x%s  [%s]", tostring(p.item_name), tostring(p.amount), tostring(p.item_id)))
        if p.location then
            theme.colored(T("Emplacement : ") .. p.location .. "  (" .. T(tostring(p.match)) .. ")", theme.DONE)
            local label = ctx.scout_label and ctx.scout_label(p.location_id)
            if label then theme.colored(T("Objet Archipelago : ") .. label, theme.DONE) end
        end
        theme.colored(T("Résultat : ") .. T(tostring(p.status)), p.status == "check" and theme.DONE or theme.WARN)
        theme.note(T("Position : ") .. tostring(p.pos or "?"))
    end

    local function give_items()
        if give.list == nil then
            give.list = {}
            local all = {}
            for id, it in pairs(ctx.items_by_id or {}) do all[id] = { name = it.name, category = it.category } end
            for _, it in pairs(ctx.ap_items or {}) do
                if it.game_id and not all[it.game_id] then all[it.game_id] = { name = it.name, category = it.category } end
            end
            for id, it in pairs(all) do
                local name = ctx.display_name and ctx.display_name(it.name or id) or (it.name or id)
                give.list[#give.list + 1] = { id = id, name = name, category = it.category or "",
                    lower = string.lower(name .. " " .. (it.name or "") .. " " .. id) }
            end
            table.sort(give.list, function(a, b) return a.name < b.name end)
        end
        return give.list
    end

    local function give_selected(to_hand)
        local e = give.selected
        if not e then return end
        local qty = math.max(1, math.floor(tonumber(give.qty) or 1))
        local in_hand = 0
        if to_hand and ctx.inject_to_hand then
            local user = ctx.player_inventory_user and ctx.player_inventory_user() or ctx.GRACE_HAND_USER
            in_hand = ctx.inject_to_hand(e.id, qty, user) or 0
        end
        local ok, err = true, nil
        if in_hand < qty then ok, err = ctx.inject_item(e.id, qty - in_hand) end
        local text = string.format("%s x%d", e.name, qty)
        if in_hand >= qty then
            ctx.push_message(T("Donné : ") .. text .. T(" (inventaire)"), ctx.COLORS.ok, "item")
        elseif ok then
            ctx.push_message(T("Donné : ") .. text .. (in_hand > 0 and TF(" (%d dans l'inventaire, le reste au coffre)", in_hand) or T(" (coffre)")),
                ctx.COLORS.ok, "item")
        else
            ctx.push_message(T("Échec : ") .. tostring(err), ctx.COLORS.bad, "error")
        end
    end

    local function draw_give_item()
        theme.heading(T("Se donner un objet"))
        theme.note(T("Si un check n'a pas donné son objet. Hors multiworld : à utiliser seulement en cas de problème."))
        local _
        _, give.search = imgui.input_text(T("Rechercher") .. "##give_search", give.search or "")
        _, give.qty = imgui.drag_int(T("Quantité") .. "##give_qty", give.qty or 1, 1, 1, 999)
        theme.note(T("« Inventaire » : ce qui ne tient pas va au coffre."))
        local needle = string.lower(((give.search or ""):gsub("^%s+", ""):gsub("%s+$", "")))
        local matches, labels, current = {}, {}, 1
        for _, e in ipairs(give_items()) do
            if needle == "" or e.lower:find(needle, 1, true) then
                matches[#matches + 1] = e
                labels[#labels + 1] = string.format("%s  [%s]  %s", e.name, e.id, T(e.category))
                if give.selected == e then current = #matches end
            end
        end
        if #matches == 0 then
            give.selected = nil
            theme.note(T("Aucun objet trouvé."))
            return
        end
        give.selected = matches[current]
        local changed, index = imgui.combo(TF("Objet (%d)", #matches) .. "##give_combo", current, labels)
        if changed and matches[index] then give.selected = matches[index] end
        if imgui.button(T("Donner dans mon inventaire") .. "##give_hand") then give_selected(true) end
        imgui.same_line()
        if imgui.button(T("Donner dans le coffre") .. "##give_box") then give_selected(false) end
    end

    local function draw_problems()
        theme.note(T("Un check qui ne part pas est un bug : signale-le."))
        theme.note(T("Le bouton « Rapport de bug » du lanceur rassemble les journaux à envoyer."))
        imgui.text("")
        local cols = theme.begin_columns("##re9ap_fix_cols", 2)
        theme.next_column(cols)
        theme.heading(T("Checks"))
        if imgui.button(T("Renvoyer tous les checks au serveur") .. "##resend") then
            ctx.ap_resend_all()
            ctx.push_message(T("Tous les checks seront renvoyés"), ctx.COLORS.ok, "system")
        end
        imgui.text("")
        theme.heading(T("Objets perdus"))
        theme.note(T("Après un rechargement de sauvegarde, par exemple."))
        local pending_n, pending_rows = 0, {}
        if ctx.deliveries_pending then pending_n, pending_rows = ctx.deliveries_pending() end
        if pending_n > 0 then
            theme.colored(TF("%d objet(s) reçus depuis la dernière sauvegarde", pending_n), theme.WARN)
            local show = math.min(#pending_rows, 8)
            for i = 1, show do
                local r = pending_rows[i]
                local where = {}
                if r.hand > 0 then where[#where + 1] = TF("inv×%d", r.hand) end
                if r.box > 0 then where[#where + 1] = TF("coffre×%d", r.box) end
                imgui.text(string.format("  • %s  (%s)", r.name, table.concat(where, ", ")))
            end
            if #pending_rows > show then
                theme.note(TF("… et %d de plus", #pending_rows - show))
            end
            if imgui.button(T("Rejouer les objets perdus au reload") .. "##replay_since_save") then
                if not ctx.is_game_ready or not ctx.is_game_ready() then
                    ctx.push_message(T("Charge une partie d'abord."), ctx.COLORS.warn, "warn")
                else
                    local n, err = ctx.replay_deliveries()
                    if n and n > 0 then
                        ctx.push_message(TF("Objets rejoués : %d (depuis la dernière save)", n), ctx.COLORS.ok, "system")
                    else
                        ctx.push_message(T("Rien à rejouer : ") .. tostring(err or "?"), ctx.COLORS.warn, "warn")
                    end
                end
            end
            theme.note(T("Ne vide pas la liste : une vraie sauvegarde le fera. Utile si l'auto-reload a raté."))
        else
            theme.note(T("Aucun objet en attente depuis la dernière sauvegarde."))
        end
        imgui.text("")
        theme.heading(T("File Archipelago entière"))
        theme.note(T("Plus lourd : rejoue toute la file d'objets reçus du serveur (pas seulement depuis la save)."))
        if redeliver_confirm_until > os.clock() then
            local _
            _, redeliver_from = imgui.drag_int(T("Redonner à partir du n°") .. "##redeliver_from", redeliver_from, 1, 1, math.max(1, ctx.session.last_index))
            if imgui.button(T("Oui, redonner") .. "##redeliver_yes") then
                redeliver_confirm_until = 0
                ctx.ap_redeliver_from((redeliver_from or 1) - 1)
            end
            imgui.same_line()
            if imgui.button(T("Annuler") .. "##redonner") then redeliver_confirm_until = 0 end
        elseif ctx.session.last_index > 0 and ctx.ap_redeliver_from then
            if imgui.button(T("Redonner des objets reçus...") .. "##redeliver") then
                redeliver_from = 1
                redeliver_confirm_until = os.clock() + 20
            end
        else
            theme.note(T("Aucun objet reçu pour l'instant."))
        end
        imgui.text("")
        theme.heading(T("Dernier ramassage"))
        draw_last_pickup()

        theme.next_column(cols)
        theme.heading(T("Partie finie ?"))
        if ctx.session.goal_sent then
            theme.colored(T("Victoire déjà envoyée pour cette partie."), theme.PROG)
        elseif goal_confirm_until > os.clock() then
            theme.colored(T("Seulement après le dernier boss : ça termine ta partie pour tout le monde."), theme.WARN)
            if imgui.button(T("Oui, j'ai battu le dernier boss") .. "##goal_yes") then
                goal_confirm_until = 0
                ctx.send_goal()
            end
            imgui.same_line()
            if imgui.button(T("Annuler") .. "##victoire") then goal_confirm_until = 0 end
        else
            if imgui.button(T("Envoyer la victoire...") .. "##goal") then goal_confirm_until = os.clock() + 8 end
            theme.note(T("Seulement après le dernier boss."))
        end
        imgui.text("")
        draw_give_item()
        theme.end_columns(cols)
    end

    local function message_prefix(m)
        local p = KIND_PREFIX[m.kind]
        return p and (p .. " ") or ""
    end

    local function draw_journal()
        local labels = {}
        for i, l in ipairs(JOURNAL_FILTERS) do labels[i] = T(l) end
        journal_filter = theme.tab_strip("##re9ap_journal", labels, journal_filter)
        theme.separator()
        local shown = 0
        for _, m in ipairs(ctx.messages) do
            local keep = journal_filter == 1
                or (journal_filter == 2 and m.kind == "item")
                or (journal_filter == 3 and m.kind == "check")
                or (journal_filter == 4 and m.kind ~= "item" and m.kind ~= "check")
            if keep then
                theme.colored(string.format("%s  %s%s", m.time or "--:--", message_prefix(m), m.text), m.color or theme.WHITE)
                shown = shown + 1
            end
        end
        if shown == 0 then theme.note(T("Aucun message.")) end
    end

    local function leon_wallets()
        local user_name = "User01"
        if ctx.current_character and ctx.current_character() == "leon" and ctx.player_inventory_user then
            user_name = ctx.player_inventory_user() or user_name
        end
        local found = {}
        local mgr = sdk.get_managed_singleton("app.InventoryManager")
        local elems = nil
        pcall(function()
            elems = mgr:get_field("_Inventories"):get_field("_entries"):get_elements()
        end)
        for _, entry in ipairs(elems or {}) do
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
                if name == user_name then
                    found[#found + 1] = { inv = inv, board = board, money = money or 0 }
                end
            end
        end
        return found
    end

    local function leon_credits()
        local best = 0
        for _, wallet in ipairs(leon_wallets()) do
            if wallet.money > best then best = wallet.money end
        end
        return best
    end

    local function add_leon_credits(amount)
        local wallets = leon_wallets()
        if #wallets == 0 then return nil, T("Inventaire de Leon introuvable.") end
        local have = 0
        for _, wallet in ipairs(wallets) do
            if wallet.money > have then have = wallet.money end
        end
        local next_n = have + amount
        local wrote = 0
        for _, wallet in ipairs(wallets) do
            local hit = (have > 0 and wallet.money == have) or (have == 0 and wallet.board == 0)
            if hit then
                local ok = pcall(function() wallet.inv:set_field("_Moneys", next_n) end)
                local read = nil
                pcall(function() read = tonumber(wallet.inv:get_field("_Moneys")) end)
                if ok and read == next_n then wrote = wrote + 1 end
            end
        end
        if wrote == 0 then
            local ok = pcall(function() wallets[1].inv:set_field("_Moneys", next_n) end)
            local read = nil
            pcall(function() read = tonumber(wallets[1].inv:get_field("_Moneys")) end)
            if not ok or read ~= next_n then return nil, T("Écriture du compte de Leon refusée.") end
        end
        return next_n
    end

    local function draw_inventory_tools()
        theme.heading(T("Crédits de Grace"))
        theme.note(T("Même solde pour Grace et Leon. Ajouter ici ajoute aussi au compte de Leon."))
        local have = math.max(0, math.floor(tonumber(ctx.session and ctx.session.grace_credits) or 0))
        imgui.text(TF("Crédits de Grace : %d", have))
        if imgui.button(T("+ 5000 crédits") .. "##dbg_grace_credits") then
            ctx.session.grace_credits = have + 5000
            if ctx.save_session then ctx.save_session() end
            ctx.push_message(TF("Crédits de Grace : %d", ctx.session.grace_credits), ctx.COLORS.ok, "system")
        end
        imgui.text("")
        theme.heading(T("Crédits de Leon"))
        theme.note(T("Même solde pour Grace et Leon. Ajouter ici ajoute aussi au compte de Grace."))
        imgui.text(TF("Crédits de Leon : %d", leon_credits()))
        if imgui.button(T("+ 5000 crédits") .. "##dbg_leon_credits") then
            local total, err = add_leon_credits(5000)
            ctx.push_message(total and TF("Crédits de Leon : %d", total) or tostring(err),
                total and ctx.COLORS.ok or ctx.COLORS.bad, "system")
        end
        imgui.text("")
        if ctx.request_open_item_box then
            theme.heading(T("Coffre"))
            if imgui.button(T("Ouvrir le coffre (F7)") .. "##open_box") then ctx.request_open_item_box() end
            imgui.same_line()
            theme.note(T("(ferme le menu REFramework pour utiliser le coffre)"))
            draw_box_transfer()
            imgui.text("")
        end
        if ctx.request_open_supply then
            theme.heading(T("Supply Box"))
            if imgui.button(T("Ouvrir le Supply Box") .. "##open_shop") then ctx.request_open_supply() end
            imgui.same_line()
            theme.note(T("(ferme le menu REFramework pour utiliser le magasin)"))
            imgui.text("")
        end
        theme.heading(T("Injection d'objets"))
        theme.note(T("Donne des objets hors du multiworld : seulement pour tester."))
        local _
        _, debug_item = imgui.input_text(T("Objet (nom ou it..)") .. "##debug_item", debug_item)
        _, debug_qty = imgui.drag_int(T("Quantité") .. "##debug_qty", debug_qty, 1, 1, 999)
        if imgui.button(T("Injecter dans le coffre") .. "##inject") then
            local id = ctx.resolve_ap_item(nil, debug_item) or debug_item
            local ok, err = ctx.inject_item(id, debug_qty or 1)
            ctx.push_message(ok and (T("Injecté : ") .. id) or (T("Échec : ") .. tostring(err)),
                ok and ctx.COLORS.ok or ctx.COLORS.bad, ok and "item" or "error")
        end
        imgui.text("")
        theme.heading(T("Exports / probes"))
        if imgui.button(T("Exporter les objets du jeu") .. "##export") then
            local ok, msg = ctx.export_item_ids()
            ctx.push_message((ok and T("Export : ") or T("Export impossible : ")) .. tostring(msg),
                ok and ctx.COLORS.ok or ctx.COLORS.bad, ok and "system" or "error")
        end
        imgui.same_line()
        if imgui.button(T("Analyser les personnages") .. "##probe_chars") then
            local ok, msg = ctx.export_character_probe()
            ctx.push_message((ok and T("Analyse : ") or T("Analyse impossible : ")) .. tostring(msg),
                ok and ctx.COLORS.ok or ctx.COLORS.bad, ok and "system" or "error")
        end
    end

    local function draw_inspect()
        theme.heading(T("Dernier ramassage (détails)"))
        local p = ctx.last_pickup
        if p then
            theme.note(T("Dossier : ") .. tostring(p.folder_path))
            for _, k in ipairs(p.keys or {}) do theme.note(T("  clé : ") .. k) end
            imgui.text(TF("Objet : %s x%s  [%s]", tostring(p.item_name), tostring(p.amount), tostring(p.item_id)))
            if p.location then
                theme.note(T("Emplacement : ") .. tostring(p.location) .. " (" .. tostring(p.match) .. ")")
            end
        else
            theme.note(T("Aucun."))
        end
        imgui.text("")
        if imgui.button(T("Aperçu de la bannière de victoire") .. "##celebrate") then
            ctx.celebrate("VICTOIRE !", { "Aperçu de la bannière" })
        end
        imgui.text("")
        theme.separator()
        theme.heading(T("Journal"))
        draw_journal()
    end

    -- sous-onglets : une job par panneau
    local DEBUG_TABS = {
        { "Chapitre", draw_chapter_warps },
        { "Réparer", draw_problems },
        { "Warp", draw_warp_panel },
        { "Objets", draw_inventory_tools },
        { "Inspect", draw_inspect },
    }

    function ctx.draw_debug_tab()
        theme.note(T("Outils développeur — hors multiworld / diagnostic."))
        local labels = {}
        for i, t in ipairs(DEBUG_TABS) do labels[i] = T(t[1]) end
        debug_sub = theme.tab_strip("##re9ap_dbg_sub", labels, debug_sub)
        debug_sub = math.max(1, math.min(#DEBUG_TABS, math.floor(tonumber(debug_sub) or 1)))
        theme.separator()
        local panel = theme.begin_panel()
        local ok, e = pcall(DEBUG_TABS[debug_sub][2])
        theme.end_panel(panel)
        if not ok then
            theme.colored(T("Erreur panneau debug : ") .. tostring(e), theme.ERROR)
            ctx.err("debug '" .. DEBUG_TABS[debug_sub][1] .. "' : " .. tostring(e))
        end
    end
end
