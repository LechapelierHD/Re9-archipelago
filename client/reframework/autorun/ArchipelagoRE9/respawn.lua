-- mort / menu « Recommencer » / reload : la save remet les objets monde
-- les checks AP restent dans la session → on re-cache + on redonne les objets reçus depuis la save

return function(ctx)
    local T, TF = ctx.T, ctx.TF
    local try = ctx.try

    local CHECK_SECONDS = 0.35
    local SETTLE_DELAY = 2.5

    ctx.redeliver_on_death = true

    local save_td = sdk.find_type_definition("app.SaveServiceManager")
    local hooked = 0
    for _, m in ipairs(save_td and (try(function() return save_td:get_methods() end) or {}) or {}) do
        local name = try(function() return m:get_name() end) or ""
        if name:find("^requestSave") then
            sdk.hook(m, function() pcall(ctx.clear_deliveries) end, nil)
            hooked = hooked + 1
        end
    end
    if hooked == 0 then
        ctx.warn("app.SaveServiceManager.requestSave introuvable : objets redonnés après reload désactivés")
        ctx.redeliver_on_death = nil
    end

    local function player_context()
        local mgr = sdk.get_managed_singleton("app.CharacterManager")
        return mgr and try(function() return mgr:get_field("<PlayerContextFast>k__BackingField") end)
    end

    local function restore_world_after_reload(reason, was_death)
        if ctx.reset_pickup_world_cache then pcall(ctx.reset_pickup_world_cache) end
        if ctx.refresh_markers then pcall(ctx.refresh_markers) end

        local pending = select(1, ctx.deliveries_pending and ctx.deliveries_pending() or 0) or 0
        local n = 0
        if ctx.redeliver_on_death and pending > 0 and ctx.replay_deliveries then
            n = select(1, ctx.replay_deliveries()) or 0
        end

        local n_checked = ctx.checked_count and ctx.checked_count() or 0
        if n > 0 then
            ctx.push_message(TF("Reload (%s) : %d check(s) gardés, %d objet(s) AP redonné(s)", reason, n_checked, n),
                ctx.COLORS.ok, "system")
        elseif was_death or pending > 0 then
            ctx.push_message(TF("Reload (%s) : %d check(s) déjà faits — pas besoin de tout refaire", reason, n_checked),
                ctx.COLORS.info, "system")
        end
        ctx.info(string.format("reload monde (%s) : checks=%d pending=%d redeliver=%d", reason, n_checked, pending, n))
    end

    local died = false
    local was_ready = false
    local settle_at = nil
    local settle_reason = nil
    local settle_was_death = false
    local next_check = 0

    local function tick()
        local now = os.clock()
        if now < next_check then return end
        next_check = now + CHECK_SECONDS

        local ready = ctx.is_game_ready and ctx.is_game_ready() == true
        local pc = player_context()
        local dead = pc and try(function() return pc:call("get_IsDead") end) == true

        if dead then
            died = true
            settle_at = nil
            was_ready = false
            return
        end

        -- passage non-prêt → prêt : mort, menu Recommencer, load save, retour titre
        if ready and not was_ready then
            settle_at = now + SETTLE_DELAY
            settle_was_death = died
            settle_reason = died and T("mort") or T("menu / chargement")
            died = false
        end
        was_ready = ready

        if settle_at and ready and now >= settle_at then
            settle_at = nil
            local reason = settle_reason or T("chargement")
            local was_death = settle_was_death
            settle_reason, settle_was_death = nil, false
            restore_world_after_reload(reason, was_death)
        elseif settle_at and not ready then
            -- encore en load : repousser
            settle_at = now + SETTLE_DELAY
        end
    end

    ctx.on_tick("respawn", tick)
end
