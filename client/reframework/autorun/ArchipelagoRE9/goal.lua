-- Victoire automatique à la mort du boss de Hope (Cp_C900).

return function(ctx)
    local HOPE = { Chap5_03 = true, Chap5_04 = true, Chap5_05 = true }
    local pending = false

    local function in_hope()
        local scene = ctx.current_scene and ctx.current_scene() or ""
        return HOPE[scene] == true
    end

    local function try_goal(why)
        if ctx.session and ctx.session.goal_sent then
            pending = false
            return
        end
        if not in_hope() then
            ctx.info("boss mort hors Hope, victoire non envoyée : " .. tostring(why))
            return
        end
        pending = true
        ctx.info("boss Hope mort : " .. tostring(why))
        if ctx.ap_is_connected and ctx.ap_is_connected() and ctx.send_goal and ctx.send_goal() then
            pending = false
        end
    end

    ctx.on_tick("goal", function()
        if not pending then return end
        if ctx.session and ctx.session.goal_sent then
            pending = false
            return
        end
        if ctx.ap_is_connected and ctx.ap_is_connected() and ctx.send_goal and ctx.send_goal() then
            pending = false
        end
    end)

    local function type_name(obj)
        local name = ""
        pcall(function() name = obj:get_type_definition():get_full_name() end)
        return name or ""
    end

    local function is_final_boss(obj)
        return type_name(obj):find("C900", 1, true) ~= nil
    end

    local hooked = {}
    local function hook(type_name, method_name, match_boss)
        local key = type_name .. ":" .. method_name
        if hooked[key] then return end
        local td = sdk.find_type_definition(type_name)
        local method = td and td:get_method(method_name)
        if not method then return end
        hooked[key] = true
        sdk.hook(method, function(args)
            local obj = sdk.to_managed_object(args[2])
            if match_boss and not is_final_boss(obj) then return end
            try_goal(key)
        end)
        ctx.info("goal hook " .. key)
    end

    hook("app.Cp_C900Context", "onDead", false)
    hook("app.Cp_C900Context", "onDie", false)
    hook("app.EnemyContext", "onDead", true)
    hook("app.EnemyContext", "onDie", true)
    hook("app.LevelFlowBehaviorTreeAction_FSM_Cp_C900FinalBlow", "start", false)
    hook("app.LevelFlowBehaviorTreeAction_FSM_Cp_C900FinalBlow", "onStart", false)
    hook("app.LevelFlowBehaviorTreeAction_FSM_Cp_C900FinalBlow", "execute", false)

    if not next(hooked) then
        ctx.warn("goal : aucun hook de mort du boss C900")
    end
end
