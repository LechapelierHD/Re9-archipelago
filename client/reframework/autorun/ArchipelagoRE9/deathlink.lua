return function(ctx)
    local T, TF = ctx.T, ctx.TF
    local try = ctx.try

    local CHECK_SECONDS = 0.25
    local PENDING_SECONDS = 20    -- pas appliquée à temps (menu, chargement) : abandonnée
    local ECHO_SECONDS = 15       -- évite de renvoyer la mort qu'on vient de recevoir

    local yaml_enabled = false
    local was_dead = nil
    local pending = nil
    local ignore_until = 0
    local next_check = 0
    ctx.deathlink_stats = { sent = 0, received = 0, last = nil }

    local function mode()
        local m = ctx.session and ctx.session.deathlink_mode
        if m == "on" or m == "off" then return m end
        return "yaml"
    end

    function ctx.deathlink_active()
        local m = mode()
        if m == "on" then return true end
        if m == "off" then return false end
        return yaml_enabled
    end

    function ctx.deathlink_yaml()
        return yaml_enabled
    end

    function ctx.deathlink_mode()
        return mode()
    end

    function ctx.deathlink_set_mode(m)
        if not ctx.session then return end
        ctx.session.deathlink_mode = m
        ctx.save_session()
        if ctx.ap_update_tags then ctx.ap_update_tags() end
    end

    local announced = false
    function ctx.deathlink_set_yaml(enabled)
        yaml_enabled = enabled and true or false
        if ctx.deathlink_active() and ctx.ap_update_tags then ctx.ap_update_tags() end
        if ctx.deathlink_active() and not announced then
            announced = true
            ctx.push_message(T("DeathLink activé : ta mort tue les autres joueurs, et la leur te tue."), ctx.COLORS.warn, "system")
        end
    end

    local function player_context()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        return mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
    end

    local function is_dead(pc)
        local v = try(function() return pc:call("get_IsDead") end)
        return v == true
    end

    function ctx.on_deathlink(source, cause, time)
        if not ctx.deathlink_active() then return end
        ctx.deathlink_stats.received = ctx.deathlink_stats.received + 1
        local text = (cause and cause ~= "") and cause or TF("%s est mort.", source or "?")
        ctx.deathlink_stats.last = text
        ctx.log_console("DeathLink : " .. text, ctx.COLORS.bad)
        pending = { source = source, cause = text, at = os.clock() }
    end

    local function apply_pending(pc, now)
        if not pending then return end
        if now - pending.at > PENDING_SECONDS then
            ctx.info("DeathLink reçu non appliqué (jeu pas prêt) : " .. tostring(pending.cause))
            pending = nil
            return
        end
        if not pc or not ctx.is_game_ready() then return end
        if is_dead(pc) then
            pending = nil
            return
        end
        local ok = pcall(function() pc:call("forceDead") end)
        if ok then
            ignore_until = now + ECHO_SECONDS
            ctx.push_message(TF("DeathLink : %s", pending.cause), ctx.COLORS.bad, "error")
            ctx.info("DeathLink appliqué : " .. tostring(pending.cause))
        else
            ctx.err("DeathLink : forceDead a échoué")
        end
        pending = nil
    end

    local function send_my_death(now)
        if now < ignore_until then return end
        local who = ctx.ap_state and ctx.ap_state.slot or "?"
        local cause = who .. " died in Resident Evil Requiem"
        if ctx.ap_send_death and ctx.ap_send_death(cause) then
            ctx.deathlink_stats.sent = ctx.deathlink_stats.sent + 1
            ctx.push_message(T("Tu es mort : DeathLink envoyé aux autres joueurs."), ctx.COLORS.bad, "error")
            ctx.info("DeathLink envoyé")
        end
    end

    local function tick()
        local now = os.clock()
        if now < next_check then return end
        next_check = now + CHECK_SECONDS
        local pc = player_context()
        if not pc then
            was_dead = nil
            return
        end
        local dead = is_dead(pc)
        local active = ctx.deathlink_active() and ctx.ap_is_connected and ctx.ap_is_connected()
        if active and dead and was_dead == false then send_my_death(now) end
        was_dead = dead
        if active then apply_pending(pc, now) else pending = nil end
    end

    ctx.on_tick("deathlink", tick)
end
