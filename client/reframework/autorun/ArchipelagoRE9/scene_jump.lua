-- un seul chemin pour sauter de scène (gate wallback + debug warp)

return function(ctx)
    local try = ctx.try

    function ctx.jump_to_scene(scene, opts)
        opts = opts or {}
        local bypass = opts.bypass
        if bypass == nil then bypass = 8 end

        local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
        local stm = sdk.get_managed_singleton("app.SceneTransitionManager")
        local ssm = sdk.get_managed_singleton("app.SaveServiceManager")
        if not (mgr and stm) then return false, "managers absents" end

        local args_td = sdk.find_type_definition("app.NewgameSetupRequestArgs")
        local args = try(function() return args_td:get_field("Default"):get_data(nil) end)
        if not args then return false, "NewgameSetupRequestArgs absent" end

        if ssm then
            local detail = try(function() return ssm:call("get_ProcessingSaveSlot") end)
                or try(function() return ssm:get_field("_ProcessingSaveSlot") end)
            if detail then
                local addr_td = sdk.find_type_definition("app.SaveSlotAddressDetail")
                local addr = try(function()
                    return addr_td:get_method("op_Implicit(app.SaveSlotAddressDetail)"):call(nil, detail)
                end) or try(function()
                    return addr_td:get_method("op_Implicit"):call(nil, detail)
                end)
                if addr then
                    pcall(function()
                        args_td:get_method("set_InheritSlotAddress(app.SaveSlotAddress)"):call(args, addr)
                    end)
                end
            end
        end

        if bypass and bypass > 0 and ctx.chapter_gate_bypass then
            ctx.chapter_gate_bypass(bypass)
        end

        return pcall(function()
            pcall(function() stm:call("set_IsDataLoadJump(System.Boolean)", true) end)
            pcall(function() mgr:call("setOverrideNextJumpScene(System.String)", scene) end)
            mgr:call("setNewGameSceneName(System.String)", scene)
            stm:call("requestMainGameJump(app.NewgameSetupRequestArgs)", args)
        end)
    end

    local pending_restore = nil

    function ctx.warp_to_scene(scene)
        if type(scene) ~= "string" or scene == "" then return false, "scène vide" end
        if ctx.current_scene() == scene then return false, "deja" end
        local ok, err = ctx.jump_to_scene(scene, { bypass = 30 })
        if ok then pending_restore = scene end
        return ok, err
    end

    re.on_frame(function()
        if not pending_restore then return end
        if ctx.current_scene() ~= pending_restore then return end
        local scene = pending_restore
        pending_restore = nil
        local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
        local newbie = ctx.scenes and ctx.scenes.NEW_GAME or "Chap1_00"
        if mgr then
            pcall(function() mgr:call("setNewGameSceneName(System.String)", newbie) end)
        end
        if ctx.info then ctx.info("warp chapitre : arrivé dans " .. scene) end
    end)
end
