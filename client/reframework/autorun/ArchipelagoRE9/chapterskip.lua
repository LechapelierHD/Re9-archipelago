return function(ctx)
    local T, TF = ctx.T, ctx.TF
    local try = ctx.try
    local PREFS_FILE = ctx.DATA_DIR .. "chapter_skip.json"
    local S = ctx.scenes

    local last_jump_target = nil

    local cfg = {
        enabled = true,
        trigger_object = "Gm11_001",
        only_grace = true,
        target_scene = "Chap1_10",
        block_research = true,
        cooldown_sec = 5.0,
    }
    do
        local saved = json.load_file(PREFS_FILE)
        if type(saved) == "table" then
            for k, v in pairs(saved) do
                if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
            end
            -- migration ancienne clé player_kind
            if saved.player_kind ~= nil and saved.only_grace == nil then
                cfg.only_grace = tostring(saved.player_kind) ~= ""
            end
        end
        if cfg.target_scene == "" or cfg.target_scene == S.NEW_GAME
            or not S.INDEX[cfg.target_scene] then
            cfg.target_scene = "Chap1_10"
        end
        pcall(json.dump_file, PREFS_FILE, cfg, 4)
    end
    local function save_prefs() pcall(json.dump_file, PREFS_FILE, cfg, 4) end

    local function next_chapter_start(from_scene)
        local from_ch = S.CH[from_scene or ""]
        if not from_ch then return nil end
        for n = from_ch + 1, 20 do
            if S.CHAPTER_START[n] then return S.CHAPTER_START[n] end
        end
        return nil
    end

    local status = T("En attente de l'interaction F.")
    local last_jump_t = -1000.0
    local pending_jump = false
    local restore_scene = false
    local pending_finish

    local function player_kind_raw()
        if ctx.current_character then
            -- injection logue le KindID réel (ex. cp_A100 / cp_A101…)
            local who = ctx.current_character()
            return tostring(ctx.current_kind or who or "")
        end
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and (try(function() return cm:get_field("<PlayerContextFast>k__BackingField") end)
            or try(function() return cm:call("getPlayerContextRefFast()") end))
        local kind = pc and (try(function() return pc:get_field("<KindID>k__BackingField") end)
            or try(function() return pc:call("get_KindID()") end))
        local s = kind and try(function() return kind:call("ToString()") end)
        return s and tostring(s) or ""
    end

    local function is_grace()
        if ctx.current_character then
            return ctx.current_character() == "grace"
        end
        local low = string.lower(player_kind_raw())
        return low:find("grace", 1, true) ~= nil or low:find("^cp_a1") ~= nil
    end

    local function go_name(go)
        local n = go and (try(function() return go:call("get_Name()") end)
            or try(function() return go:call("get_Name") end))
        return n and tostring(n) or ""
    end

    local function go_of(comp)
        return comp and (try(function() return comp:call("get_GameObject()") end)
            or try(function() return comp:call("get_GameObject") end))
    end

    local function field_str(obj, field)
        local v = obj and try(function() return obj:get_field(field) end)
        if v == nil then return "" end
        local s = try(function() return v:call("ToString()") end) or tostring(v)
        s = s and tostring(s) or ""
        if s == "" or s == "nil" then return "" end
        return s
    end

    -- InteractTrigger n'a PAS _OwnerTransform : noms via _Name / _Key / GO (+ parents)
    local function collect_names(action, trig, research)
        local out, seen = {}, {}
        local function add(s)
            if not s or s == "" or seen[s] then return end
            seen[s] = true
            out[#out + 1] = s
        end
        local function add_go_chain(go)
            local cur, guard = go, 0
            while cur and guard < 8 do
                add(go_name(cur))
                local xf = try(function() return cur:call("get_Transform()") end)
                    or try(function() return cur:call("get_Transform") end)
                local parent = xf and (try(function() return xf:call("get_Parent()") end)
                    or try(function() return xf:call("get_Parent") end))
                cur = parent and (try(function() return parent:call("get_GameObject()") end)
                    or try(function() return parent:call("get_GameObject") end))
                guard = guard + 1
            end
        end
        add(field_str(action, "_TargetName"))
        add(field_str(action, "_Key"))
        add(field_str(trig, "_Name"))
        add(field_str(trig, "_CrimeKeyName"))
        local bind = action and try(function() return action:get_field("_BindTarget") end)
        add_go_chain(go_of(bind or research))
        local tr = trig and try(function() return trig:get_field("_OwnerTransform") end)
        if tr then
            add_go_chain(try(function() return tr:call("get_GameObject()") end))
        end
        return out
    end

    local function is_trigger(name)
        if not name or name == "" then return false end
        if name == cfg.trigger_object then return true end
        return name:find(cfg.trigger_object, 1, true) ~= nil
    end

    local function match_trigger(names)
        for _, n in ipairs(names) do
            if is_trigger(n) then return n end
        end
        return nil
    end

    local last_seen = ""
    local last_seen_t = 0

    local function skipped_chapters(scene_list, target)
        local list, set, stop = {}, {}, S.CH[target]
        for _, s in ipairs(scene_list) do
            local n = S.CH[s]
            if n and n ~= stop and not set["Ch" .. n] then
                set["Ch" .. n] = true
                list[#list + 1] = S.CHAPTER_NAMES[n] and (n .. " " .. S.CHAPTER_NAMES[n]) or tostring(n)
            end
        end
        return list, set
    end

    local function finish_skipped(chapters)
        if not ctx.is_game_ready() or not chapters then return nil end

        local connected = ctx.has_slot_data()
        local diff = connected and string.lower(tostring(ctx.session.difficulty or "")) or ""
        local checks, given, failed = 0, 0, 0

        for id, loc in pairs(ctx.locations) do
            if chapters[loc.chapter] and loc.x then
                if connected and ctx.is_active(id) then
                    if ctx.mark_checked(id) then checks = checks + 1 end
                elseif loc.item_id ~= "" and (loc.difficulties == nil or loc.difficulties[diff]) then
                    local ok = ctx.inject_item(loc.item_id, loc.amount or 1)
                    if ok then given = given + 1 else failed = failed + 1 end
                end
            end
        end

        if checks > 0 then
            ctx.checks_dirty = true
            if ctx.refresh_markers then ctx.refresh_markers() end
        end
        local msg = TF("Chapitres sautés terminés : %d check(s), %d objet(s) au coffre", checks, given)
        if failed > 0 then msg = msg .. TF(", %d échec(s)", failed) end
        ctx.push_message(msg, failed > 0 and ctx.COLORS.warn or ctx.COLORS.ok, "check")
        return msg
    end

    local function do_jump(target, chapters)
        if not target or target == "" then return false end
        local from = ctx.current_scene()
        if from == target then
            status = TF("Déjà dans %s", target)
            return false
        end
        local from_ch = S.CH[from]
        local ok, err = ctx.jump_to_scene(target, { bypass = 30 })
        restore_scene = ok
        last_jump_target = ok and target or nil
        if not ok then
            status = T("MainGameFlowManager introuvable (pas en partie ?).")
            if err then
                status = TF("Saut scène échoué : %s", tostring(err))
                ctx.err("saut de chapitre : " .. tostring(err))
            end
            ctx.push_message(status, ctx.COLORS.bad, "error")
        end
        if ok then
            local done = chapters
            if not done and from_ch and S.CH[target] ~= from_ch then
                done = { ["Ch" .. from_ch] = true }
            end
            if done and next(done) then
                pending_finish = { chapters = done, target = target }
            end
        end

        status = TF("[%s] Saut %s -> %s : %s", os.date("%H:%M:%S"), from, target,
            ok and T("demandé") or T("ÉCHEC"))
        ctx.info(status)
        if ok then
            ctx.push_message(TF("Saut vers %s… (progression héritée)", target), ctx.COLORS.info, "info")
        end
        return ok
    end

    function ctx.debug_teleport_chapter(ch_num)
        ch_num = tonumber(ch_num)
        local scene = ch_num and S.CHAPTER_START[ch_num]
        if not scene then
            status = TF("Chapitre inconnu : %s", tostring(ch_num))
            ctx.push_message(status, ctx.COLORS.bad, "error")
            return false
        end
        local ok = do_jump(scene, ctx.chapters_between(ctx.current_scene(), scene))
        if ok then
            ctx.push_message(
                TF("Téléport Debug → Ch%d (%s) — chapitres précédents terminés à l'arrivée", ch_num, scene),
                ctx.COLORS.info, "info")
        end
        return ok
    end

    -- Uniquement le début du chapitre suivant. Pas de saut lointain.
    local function resolve_jump_target()
        local here = ctx.current_scene()
        local nxt = next_chapter_start(here)
        if nxt and nxt ~= here then return nxt end
        return nil
    end

    local function request_jump(reason)
        if not cfg.enabled then
            status = T("Saut de chapitre désactivé.")
            return false
        end
        if cfg.only_grace and not is_grace() then
            status = TF("Saut refusé : pas Grace (personnage=%s)", player_kind_raw())
            ctx.info(status)
            return false
        end
        local target = resolve_jump_target()
        if not target then
            status = T("Aucune scène cible (déjà à la fin ?).")
            return false
        end
        if os.clock() - last_jump_t < cfg.cooldown_sec then
            status = T("Cooldownolissement saut…")
            return false
        end
        last_jump_t = os.clock()
        pending_jump = target
        status = TF("%s : saut vers %s…", reason or "Saut", target)
        ctx.info(status)
        return true
    end

    local function note_seen(names)
        if not names or #names == 0 then return end
        local joined = table.concat(names, " | ")
        local now = os.clock()
        if joined ~= last_seen or now - last_seen_t > 1.0 then
            last_seen, last_seen_t = joined, now
            status = TF("F détecté : %s", joined)
            ctx.info("saut de chapitre : interact " .. joined)
        end
    end

    local function on_interact(names)
        if not cfg.enabled then return false end
        note_seen(names)
        local hit = match_trigger(names)
        if not hit then return false end
        request_jump(TF("Interaction F sur %s", hit))
        return cfg.block_research
    end

    local function hook_method(m, pre, label)
        if not m then return false end
        sdk.hook(m, pre, nil)
        ctx.info("saut de chapitre : hook " .. tostring(label or "?"))
        return true
    end

    local function hook_named(type_name, pred, pre)
        local td = sdk.find_type_definition(type_name)
        if not td then
            ctx.warn("saut de chapitre : type " .. type_name .. " introuvable")
            return 0
        end
        local n = 0
        local methods = try(function() return td:get_methods() end) or {}
        for _, m in ipairs(methods) do
            local name = try(function() return m:get_name() end)
            if name and pred(name) and hook_method(m, pre, type_name .. "::" .. name) then
                n = n + 1
            end
        end
        return n
    end

    local function pre_action_process(args)
        local ok, names = pcall(function()
            local action = sdk.to_managed_object(args[2])
            local trig = sdk.to_managed_object(args[3])
            return collect_names(action, trig, nil)
        end)
        if ok and on_interact(names) then return sdk.PreHookResult.SKIP_ORIGINAL end
    end

    local function pre_research_start(args)
        local ok, names = pcall(function()
            local self_obj = sdk.to_managed_object(args[2])
            local key = try(function()
                local k = sdk.to_managed_object(args[3])
                return k and (k:call("ToString()") or tostring(k))
            end)
            local list = collect_names(nil, nil, self_obj)
            if key and tostring(key) ~= "" then list[#list + 1] = tostring(key) end
            return list
        end)
        if ok and on_interact(names) then return sdk.PreHookResult.SKIP_ORIGINAL end
    end

    local hooked = 0
    hooked = hooked + hook_named("app.InteractActionCrimeResearch",
        function(n) return n == "onProcess" end, pre_action_process)
    hooked = hooked + hook_named("app.InteractActionDetailSearch",
        function(n) return n == "onProcess" end, pre_action_process)
    hooked = hooked + hook_named("app.CrimeResearchObject",
        function(n) return n:find("requestResearch", 1, true) == 1 or n == "requestResearchStart" end,
        pre_research_start)
    if hooked == 0 then
        ctx.warn("saut de chapitre : aucun hook interact trouvé")
    end

    local function list_count(list)
        return tonumber(try(function() return list:call("get_Count()") end)
            or try(function() return list:get_Count() end)) or 0
    end

    local function list_at(list, i)
        return try(function() return list:call("get_Item(System.Int32)", i) end)
            or try(function() return list:get_Item(i) end)
    end

    local function active_interact_names()
        local mgr = sdk.get_managed_singleton("app.InteractManager")
        if not mgr then return {} end
        local list = try(function() return mgr:get_field("_ActiveTriggerInfoList") end)
            or try(function() return mgr:get_field("_TriggerInfoList") end)
        if not list then return {} end
        local n = list_count(list)
        if n == 0 then
            list = try(function() return list:get_field("_List") end)
                or try(function() return list:get_field("mList") end)
                or list
            n = list_count(list)
        end
        local out, seen = {}, {}
        local function add(s)
            if s and s ~= "" and not seen[s] then
                seen[s] = true
                out[#out + 1] = s
            end
        end
        for i = 0, n - 1 do
            local info = list_at(list, i)
            if info then
                local trig = try(function() return info:get_field("Trigger") end)
                local go = try(function() return info:get_field("TargetObj") end)
                add(field_str(trig, "_Name"))
                add(field_str(trig, "_CrimeKeyName"))
                add(go_name(go))
                local xf = go and (try(function() return go:call("get_Transform()") end))
                local parent = xf and try(function() return xf:call("get_Parent()") end)
                local pgo = parent and try(function() return parent:call("get_GameObject()") end)
                add(go_name(pgo))
            end
        end
        return out
    end

    -- Fallback : touche F quand le prompt d'interact pointe le panneau
    local F_KEY = 0x46
    local f_was_down = false
    re.on_frame(function()
        if not cfg.enabled then
            f_was_down = false
            return
        end
        local down = try(function() return reframework:is_key_down(F_KEY) end) == true
        if down and not f_was_down then
            local names = active_interact_names()
            if #names > 0 then
                note_seen(names)
                local hit = match_trigger(names)
                if hit then
                    request_jump(TF("Touche F sur %s", hit))
                elseif cfg.trigger_object == "Gm11_001" then
                    -- hôtel : tout prompt Crime/Gm suffit si un seul interact actif
                    for _, n in ipairs(names) do
                        if n:find("Gm11", 1, true) or n:lower():find("crime", 1, true) then
                            request_jump(TF("Touche F sur %s", n))
                            break
                        end
                    end
                end
            end
        end
        f_was_down = down
    end)

    ctx.on_tick("chapterskip", function()
        if pending_jump then
            local target = type(pending_jump) == "string" and pending_jump or resolve_jump_target()
            pending_jump = false
            do_jump(target)
        end

        local arrived = ctx.current_scene()
        local expect = last_jump_target
        local playing = player_kind_raw() ~= "" or (ctx.current_character and ctx.current_character() ~= nil)
        if (restore_scene or pending_finish) and playing then
            if restore_scene and expect and arrived == expect then
                restore_scene = false
                local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
                pcall(function() mgr:call("setNewGameSceneName(System.String)", S.NEW_GAME) end)
                ctx.info("saut de chapitre : arrivé dans " .. arrived .. ", nouvelle partie remise à " .. S.NEW_GAME)
            end
            if pending_finish and arrived == pending_finish.target then
                local chapters = pending_finish.chapters
                if not chapters then
                    local _, set = skipped_chapters(pending_finish.scenes or {}, pending_finish.target)
                    chapters = set
                end
                local msg = finish_skipped(chapters)
                if msg then
                    pending_finish = nil
                    status = status .. " | " .. msg
                    ctx.info(msg)
                end
            end
        end
    end)

    function ctx.draw_chapter_skip()
        local theme = ctx.theme
        if not theme then return end
        theme.heading(T("Saut de chapitre"))
        if cfg.enabled then
            theme.note(T("F sur le panneau de l'hôtel envoie au chapitre suivant."))
            if imgui.button(T("Désactiver le saut de chapitre") .. "##skip_off") then
                cfg.enabled = false
                save_prefs()
                status = T("Saut de chapitre désactivé.")
            end
        else
            theme.note(T("Saut de chapitre désactivé."))
            if imgui.button(T("Activer le saut") .. "##skip_on") then
                cfg.enabled = true
                save_prefs()
                status = T("En attente de l'interaction F.")
            end
        end
    end

    local preview = resolve_jump_target()
    ctx.info("saut de chapitre installé (F sur " .. cfg.trigger_object
        .. " -> chapitre suivant, ex. " .. tostring(preview or "?") .. ")")
end
