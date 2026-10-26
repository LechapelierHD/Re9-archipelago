-- barriere de chapitre :
-- 1) BLOQUE le jump de scene si checks restants (SKIP_ORIGINAL) — avant le clic
-- 2) WALLBACK en secours si la scene change quand meme

return function(ctx)
    local T, TF = ctx.T, ctx.TF
    local try = ctx.try
    local PREFS = ctx.DATA_DIR .. "chapter_gate.json"

    local cfg = { enabled = false, auto_force = false }
    do
        local saved = json.load_file(PREFS)
        if type(saved) == "table" then
            if type(saved.enabled) == "boolean" then cfg.enabled = saved.enabled end
            if type(saved.auto_force) == "boolean" then cfg.auto_force = saved.auto_force end
        else
            pcall(json.dump_file, PREFS, cfg, 4)
        end
    end
    local function save() pcall(json.dump_file, PREFS, cfg, 4) end

    local last_scene, last_i = "", 0
    local last_ch = nil
    local pending_ch = nil
    local pending_since = 0
    local last_pos = nil
    local bypass_until = 0
    local cooldown_until = 0
    local pending = nil
    local last_block_toast = 0
    local BLOCK_TOAST_CD = 2.5

    local function clear_fade()
        local fm = sdk.get_managed_singleton("app.FadeManager")
        if not fm then return end
        pcall(function() fm:call("clearAllFade(System.Single, System.String)", 0.0, "re9ap_gate") end)
    end

    local function player_pos()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local pc = mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
        local p = pc and try(function() return pc:call("get_Position") end)
        if not p then return nil end
        local x = tonumber(try(function() return p.x end))
        local y = tonumber(try(function() return p.y end))
        local z = tonumber(try(function() return p.z end))
        if not x then return nil end
        return { x = x, y = y or 0, z = z or 0 }
    end

    local function set_player_pos(x, y, z)
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        local pc = mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
        if not pc then return false end
        local go = try(function() return pc:call("get_Character") end)
            or try(function() return pc:get_field("<Character>k__BackingField") end)
        local xform = go and try(function() return go:call("get_Transform") end)
        if not xform then return false end
        local v3 = Vector3f.new(x, y, z)
        local ok = pcall(function() xform:call("set_Position", v3) end)
            or pcall(function() xform:set_Position(v3) end)
        local cc = try(function() return go:call("get_CharacterController") end)
            or try(function() return go:getComponent(sdk.typeof("via.physics.CharacterController")) end)
        if cc then pcall(function() cc:call("warp()") end) end
        return ok and true or false
    end

    local function unchecked_count(ch)
        if not ch or not ctx.has_slot_data or not ctx.has_slot_data() then return 0 end
        local n = 0
        for id in pairs(ctx.session.active or {}) do
            local loc = ctx.locations[id]
            if loc and loc.chapter == ch and not ctx.is_checked(id) then
                n = n + 1
            end
        end
        return n
    end

    local function note_scene(scene)
        if scene == "" then return end
        last_scene = scene
        last_i = ctx.scene_index(scene)
    end

    function ctx.chapter_gate_bypass(seconds)
        bypass_until = os.clock() + (tonumber(seconds) or 3)
    end

    function ctx.chapter_gate_enabled()
        return cfg.enabled == true
    end

    -- true si on doit empecher le jump vers target_scene
    local function should_block_jump(_)
        return false
    end

    local function notify_blocked(ch, left)
        local now = os.clock()
        if now - last_block_toast < BLOCK_TOAST_CD then return end
        last_block_toast = now
        local msg = TF("Chapitre %s incomplet (%d check(s)) — ramasse tout avant de partir.", ch, left)
        ctx.push_message(msg, ctx.COLORS.warn, "warn")
        ctx.warn("gate chapitre : jump bloque — " .. msg)
    end

    local function hook(type_name, method_sig, pre)
        local td = sdk.find_type_definition(type_name)
        local method = td and td:get_method(method_sig)
        if not method then
            ctx.warn("gate chapitre : " .. type_name .. "::" .. method_sig .. " introuvable")
            return false
        end
        sdk.hook(method, pre, nil)
        return true
    end

    -- cible du prochain jump (mise a jour par setOverride / setNewGame)
    local pending_target = nil

    hook("app.MainGameFlowManager", "setOverrideNextJumpScene(System.String)", function(args)
        local name = try(function() return sdk.to_managed_object(args[3]) end)
            or try(function() return sdk.to_ptr(args[3]) and tostring(args[3]) end)
        local s = name and (try(function() return name:call("ToString()") end) or tostring(name)) or ""
        if s ~= "" and s ~= "nil" then pending_target = s end
        local block, ch, left = should_block_jump(s)
        if block then
            notify_blocked(ch, left)
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end)

    hook("app.MainGameFlowManager", "setNewGameSceneName(System.String)", function(args)
        local name = try(function() return sdk.to_managed_object(args[3]) end)
        local s = name and (try(function() return name:call("ToString()") end) or tostring(name)) or ""
        -- ignorer reset vers NEW_GAME apres un jump (souvent Chap1_00)
        local new_game = ctx.scenes and ctx.scenes.NEW_GAME or "Chap1_00"
        if s == "" or s == new_game then return end
        pending_target = s
        local block, ch, left = should_block_jump(s)
        if block then
            notify_blocked(ch, left)
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end)

    hook("app.SceneTransitionManager", "requestMainGameJump(app.NewgameSetupRequestArgs)", function()
        local target = pending_target
        if not target or target == "" then
            local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
            target = mgr and try(function() return mgr:call("get_NewGameSceneName") end)
            target = target and tostring(target) or ""
        end
        local block, ch, left = should_block_jump(target)
        if block then
            notify_blocked(ch, left)
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end)

    local function abort_pending(msg)
        clear_fade()
        if msg then ctx.warn("gate chapitre : " .. msg) end
        pending = nil
    end

    local function tick_pending(scene, now)
        if not pending then return false end
        clear_fade()

        if pending.phase == "wait_ready" then
            local ready = not ctx.is_game_ready or ctx.is_game_ready()
            if not ready then
                if now - pending.t > 20 then
                    abort_pending("timeout attente scene — wallback annule")
                    note_scene(scene)
                end
                return true
            end
            if not pending.ready_at then pending.ready_at = now end
            if now - pending.ready_at < 2.0 then return true end
            pending.phase = "jumping"
            pending.jumped_at = now
            ctx.info("gate chapitre : wallback vers " .. tostring(pending.back))
            local ok, err = ctx.jump_to_scene(pending.back, { bypass = 20 })
            if not ok then
                abort_pending("wallback jump echoue : " .. tostring(err))
                note_scene(scene)
                return true
            end
            return true
        end

        if pending.phase == "jumping" or pending.phase == "settle" then
            if scene == pending.back then
                pending.phase = "settle"
                pending.arrived_at = pending.arrived_at or now
                clear_fade()
                local ready = not ctx.is_game_ready or ctx.is_game_ready()
                if ready and (now - pending.arrived_at) >= 0.8 then
                    local pos = pending.pos
                    if pos then
                        set_player_pos(pos.x, pos.y, pos.z)
                        set_player_pos(pos.x, pos.y, pos.z)
                    end
                    if pending.snap and ctx.restore_inventories then
                        pcall(ctx.restore_inventories, pending.snap)
                    end
                    clear_fade()
                    ctx.push_message(
                        TF("Chapitre %s incomplet (%d check(s)) — wallback.", pending.prev_ch, pending.left),
                        ctx.COLORS.warn, "warn")
                    note_scene(scene)
                    last_pos = pos
                    pending = nil
                    cooldown_until = now + 8
                elseif now - (pending.jumped_at or pending.t) > 25 then
                    if pending.pos then set_player_pos(pending.pos.x, pending.pos.y, pending.pos.z) end
                    if pending.snap and ctx.restore_inventories then
                        pcall(ctx.restore_inventories, pending.snap)
                    end
                    abort_pending("timeout settle wallback")
                    note_scene(scene)
                    cooldown_until = now + 8
                end
                return true
            end
            local jumped_at = pending.jumped_at or pending.t
            if not pending.retried and now - jumped_at > 12 then
                pending.retried = true
                pending.jumped_at = now
                ctx.info("gate chapitre : wallback relancé vers " .. tostring(pending.back))
                local ok, err = ctx.jump_to_scene(pending.back, { bypass = 20 })
                if not ok then
                    abort_pending("wallback jump echoue : " .. tostring(err))
                    note_scene(scene)
                end
                return true
            end
            if now - jumped_at > 25 then
                abort_pending("timeout jump wallback")
                note_scene(scene)
                return true
            end
            return true
        end
        return false
    end

    local function start_wallback(back_scene, prev_ch, left)
        local now = os.clock()
        if pending or now < cooldown_until then return end
        pending = {
            back = back_scene,
            prev_ch = prev_ch,
            left = left,
            t = now,
            phase = "wait_ready",
            pos = last_pos and { x = last_pos.x, y = last_pos.y, z = last_pos.z } or nil,
            snap = ctx.snapshot_inventories and ctx.snapshot_inventories() or nil,
        }
        ctx.push_message(
            TF("Chapitre %s incomplet (%d check(s)) — wallback…", prev_ch, left),
            ctx.COLORS.warn, "warn")
    end

    local function chapter_of(scene)
        if ctx.ap_chapter then return ctx.ap_chapter(scene) end
        return nil
    end

    -- quitter ChN : envoyer les checks encore ouverts de ce chapitre
    local function maybe_force_left(scene)
        local ch = chapter_of(scene)
        if not ch then return end
        if last_ch == nil then
            last_ch = ch
            return
        end
        if ch == last_ch then
            pending_ch = nil
            return
        end
        if pending_ch ~= ch then
            pending_ch = ch
            pending_since = os.clock()
            return
        end
        if os.clock() - pending_since < 1.0 then return end
        local left = last_ch
        last_ch = ch
        pending_ch = nil
        if not cfg.auto_force or not ctx.force_chapter_remaining then return end
        local n = ctx.force_chapter_remaining(left) or 0
        if n > 0 then
            ctx.info(string.format("checks oubliés : %s envoyé x%d", left, n))
            if ctx.push_message then
                ctx.push_message(TF("%s : %d check(s) oublié(s) envoyé(s)", left, n), ctx.COLORS.ok, "check")
            end
        end
    end

    local function tick()
        local scene = ctx.current_scene()
        if scene == "" then return end
        local now = os.clock()

        if tick_pending(scene, now) then return end
        maybe_force_left(scene)

        if cfg.enabled and scene == last_scene then
            local p = player_pos()
            if p then last_pos = p end
        end

        if not cfg.enabled then
            note_scene(scene)
            return
        end

        if last_scene == "" or last_i == 0 then
            note_scene(scene)
            return
        end

        -- Pas de wallback : un changement de chapitre du jeu ne doit pas relancer un new game.
        note_scene(scene)
    end

    ctx.on_tick("chapter_gate", tick)

    function ctx.draw_chapter_gate()
        local theme = ctx.theme
        if not theme then return end
        theme.heading(T("Barrière de chapitre"))
        theme.note(T("Plus de blocage : tu peux changer de chapitre même s'il reste des checks."))
        local changed, v = imgui.checkbox(
            T("Au changement de chapitre, envoyer les checks oubliés") .. "##auto_force_ch",
            cfg.auto_force == true)
        if changed then
            cfg.auto_force = v == true
            save()
            ctx.info(cfg.auto_force and "checks oubliés : envoi auto ON" or "checks oubliés : envoi auto OFF")
        end
        theme.note(T("En quittant un chapitre, les checks pas faits sont envoyés. Le chapitre ne recommence pas."))
    end

    ctx.info("gate chapitre : OFF (pas de blocage)")
end
