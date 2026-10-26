-- ordonnanceur unique : ordre d'enregistrement = ordre d'exécution

return function(ctx)
    local steps = {}

    -- name, fn([now]), opts.every (secondes, 0 = chaque tick)
    function ctx.on_tick(name, fn, opts)
        opts = opts or {}
        steps[#steps + 1] = {
            name = name,
            fn = fn,
            every = tonumber(opts.every) or 0,
            next_at = 0,
        }
    end

    local function run()
        local now = os.clock()
        for _, s in ipairs(steps) do
            if s.every <= 0 or now >= s.next_at then
                if s.every > 0 then s.next_at = now + s.every end
                local ok, e = pcall(s.fn, now)
                if not ok then ctx.err("tick '" .. s.name .. "' : " .. tostring(e)) end
            end
        end
    end

    if re.on_pre_application_entry then
        re.on_pre_application_entry("UpdateBehavior", run)
    else
        re.on_frame(run)
    end
end
