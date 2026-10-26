-- Warp machines a ecrire (style RE4R / JumperDenfer) :
-- preload stage -> attendre ready -> requestWarp + UniversalPosition
-- inventaire intact ; unlock apres visite machine / scene

return function(ctx)
    local T, TF = ctx.T, ctx.TF
    local try = ctx.try
    local S = ctx.scenes
    local DATA = ctx.DATA_DIR .. "re9_typewriters_list.json"
    local UNLOCKS = ctx.DATA_DIR .. "typewriter_unlocks.json"
    local THEME = ctx.theme

    local SCENE_INDEX = S.INDEX
    local SCENE_CH = S.CH

    local typewriters = {}
    local by_chapter = {} -- "Ch5" -> { tw, ... }
    local unlocked = {} -- place_id lower -> true
    local max_scene_i = 0
    local status = ""
    local pending = nil -- stage (RE4R) ou jump
    -- attendre geo chargee sinon TP = vide -> mort (comme preloadZone RE4R)
    local SAFE_PRELOAD_DELAY = 1.5
    local PRELOAD_RETRY = 0.10
    local JUMP_SETTLE = 2.5
    local STAGE_WAIT_MAX = 15.0
    local SAFE_Y_LIFT = 1.35
    local TP_RETRIES = 4

    local function load_typewriters()
        typewriters, by_chapter = {}, {}
        local data = json.load_file(DATA)
        local list = type(data) == "table" and data.typewriters or nil
        if type(list) ~= "table" then return end
        local seen = {}
        for _, tw in ipairs(list) do
            local pid = tostring(tw.place_id or "")
            local key = string.lower(pid)
            if key ~= "" and not seen[key] then
                seen[key] = true
                local scene = tostring(tw.scene or "")
                if scene == "" or scene == "MainGame" then
                    scene = tostring(tw.folder_path or ""):match("MainGame/(Chap[^/]+)") or scene
                end
                local ap = tostring(tw.ap_chapter or "")
                if ap == "" then
                    local n = SCENE_CH[scene]
                    ap = n and ("Ch" .. n) or ""
                end
                local entry = {
                    place_id = pid,
                    scene = scene,
                    stage = tostring(tw.stage or ""),
                    label = tostring(tw.label or (pid .. " " .. tostring(tw.stage or ""))),
                    ap_chapter = ap,
                    chapter = tonumber(tw.chapter) or tonumber(ap:match("%d+")) or 0,
                    x = tonumber(tw.x) or 0,
                    y = tonumber(tw.y) or 0,
                    z = tonumber(tw.z) or 0,
                    scene_i = SCENE_INDEX[scene] or 0,
                }
                typewriters[#typewriters + 1] = entry
                if ap ~= "" then
                    by_chapter[ap] = by_chapter[ap] or {}
                    by_chapter[ap][#by_chapter[ap] + 1] = entry
                end
            end
        end
        table.sort(typewriters, function(a, b)
            if a.scene_i ~= b.scene_i then return a.scene_i < b.scene_i end
            return a.place_id < b.place_id
        end)
    end

    local function save_unlocks()
        pcall(json.dump_file, UNLOCKS, {
            max_scene = max_scene_i,
            places = unlocked,
        }, 4)
    end

    local function load_unlocks()
        local data = json.load_file(UNLOCKS)
        if type(data) ~= "table" then return end
        max_scene_i = math.floor(tonumber(data.max_scene) or 0)
        if type(data.places) == "table" then
            for k, v in pairs(data.places) do
                if v then unlocked[string.lower(tostring(k))] = true end
            end
        end
    end

    local function current_scene()
        return ctx.current_scene and ctx.current_scene() or ""
    end

    local function note_progress(scene)
        local i = SCENE_INDEX[scene]
        if i and i > max_scene_i then
            max_scene_i = i
            -- débloque aussi les warps « chapitre » / machines de scènes déjà atteintes
            for _, tw in ipairs(typewriters) do
                if tw.scene_i > 0 and tw.scene_i <= max_scene_i then
                    unlocked[string.lower(tw.place_id)] = true
                end
            end
            save_unlocks()
        end
    end

    -- visite machine OU scène déjà atteinte (warps chapitre Ch2/Ch4 sans machine)
    local function is_unlocked(tw)
        if unlocked[string.lower(tw.place_id)] == true then return true end
        if tw.scene_i > 0 and max_scene_i >= tw.scene_i then return true end
        return false
    end

    local function player_context()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local pc = cm and (try(function() return cm:call("getPlayerContextRefFast()") end)
            or try(function() return cm:get_field("<PlayerContextFast>k__BackingField") end))
        return pc, cm
    end

    local function player_xform()
        local pc = player_context()
        if not pc then return nil end
        local go = try(function() return pc:call("get_GameObject()") end)
            or try(function() return pc:call("getBody()") end)
            or try(function() return pc:call("get_Character()") end)
        if go and not try(function() return go:call("get_Transform()") end) then
            go = try(function() return go:call("get_GameObject()") end) or go
        end
        return go and try(function() return go:call("get_Transform()") end)
    end

    -- via.vec3 natif (comme RE4R) — Vector3f seul est souvent ignoré
    local function make_vec3(x, y, z)
        local pos = try(function() return sdk.create_instance("via.vec3") end)
        local td = sdk.find_type_definition("via.vec3")
        if pos and td then
            pcall(function() sdk.set_native_field(pos, td, "x", tonumber(x) or 0.0) end)
            pcall(function() sdk.set_native_field(pos, td, "y", tonumber(y) or 0.0) end)
            pcall(function() sdk.set_native_field(pos, td, "z", tonumber(z) or 0.0) end)
            return pos
        end
        return Vector3f.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
    end

    local function character_controller()
        local xform = player_xform()
        if not xform then return nil end
        local go = try(function() return xform:call("get_GameObject()") end)
        local td = sdk.find_type_definition("via.physics.CharacterController")
            or sdk.find_type_definition("via.CharacterController")
        local typ = td and try(function() return td:get_type() end) or try(function() return sdk.typeof("via.physics.CharacterController") end)
        if not (go and typ) then return nil end
        return try(function() return go:call("getComponent(System.Type)", typ) end)
    end

    -- force UniversalPosition (coords machines = Universal du scan)
    local function set_player_pos(x, y, z)
        local xform = player_xform()
        if not xform then return false, "joueur introuvable" end
        local v3 = make_vec3(x, y, z)
        local vf = Vector3f.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
        local cc = character_controller()
        if cc then pcall(function() cc:call("warp()") end) end
        local ok = pcall(function() xform:call("set_UniversalPosition", v3) end)
            or pcall(function() xform:call("set_UniversalPosition", vf) end)
            or pcall(function() xform:call("set_Position", v3) end)
            or pcall(function() xform:call("set_Position", vf) end)
            or pcall(function() xform:set_Position(vf) end)
        if cc then pcall(function() cc:call("warp()") end) end
        return ok, ok and "ok" or "set_Position refusé"
    end

    local function player_pos()
        local xform = player_xform()
        if not xform then return nil end
        local p = try(function() return xform:call("get_UniversalPosition()") end)
            or try(function() return xform:call("get_Position()") end)
            or try(function() return xform:get_Position() end)
        if not p then return nil end
        return {
            x = tonumber(try(function() return p.x end) or try(function() return p:get_field("x") end)) or 0,
            y = tonumber(try(function() return p.y end) or try(function() return p:get_field("y") end)) or 0,
            z = tonumber(try(function() return p.z end) or try(function() return p:get_field("z") end)) or 0,
        }
    end

    local function dist2(a, b)
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return dx * dx + dy * dy + dz * dz
    end

    -- warp live : inventaire / coffre / flags intacts (pas de Newgame)
    local function live_warp(x, y, z)
        local pc, cm = player_context()
        if pc and cm then
            local cid = try(function() return pc:get_field("_ID") end)
                or try(function() return pc:call("get_ContextID()") end)
                or try(function() return pc:get_field("<ID>k__BackingField") end)
            local pos = make_vec3(x, y, z)
            if cid ~= nil then
                local ok = pcall(function()
                    cm:call(
                        "requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)",
                        cid, pos, nil)
                end) or pcall(function() cm:call("requestWarp", cid, pos, nil) end)
                if ok then return true, "requestWarp" end
            end
        end
        return set_player_pos(x, y, z)
    end

    local function is_real_stage(stage)
        stage = tostring(stage or "")
        -- "ch2"/"ch4" = points chapitre fictifs, pas des EnvStage
        return stage ~= "" and not stage:find("^[cC][hH]%d") and stage:find("^st") ~= nil
    end

    -- équivalent RE4R preloadZone : UNIQUEMENT dans la même MainScene
    local function preload_stage(stage, x, y, z)
        if not is_real_stage(stage) then return false end
        local esm = sdk.get_managed_singleton("app.EnvStageManager")
        if not esm then return false end
        local pos = make_vec3(x, y, z)
        return pcall(function()
            esm:set_field("_ChangeStagePlayerPosition", pos)
            esm:set_field("_IsSkipPlayerlengthCheck", true)
            esm:call("setOverrideStageName(System.String)", stage)
            esm:call("setStandbyFromController(System.String)", stage)
            esm:call("setChangeStageFromController(System.String, System.UInt32)", stage, 0)
            esm:call("setActivateFromController(System.String)", stage)
            pcall(function() esm:call("executeActiveStandby()") end)
            pcall(function() esm:call("startActivate()") end)
        end)
    end

    -- TP live (pas de warpPlayer seul — il te remet souvent au stage courant)
    local function execute_warp_now(x, y, z)
        local esm = sdk.get_managed_singleton("app.EnvStageManager")
        if esm then
            pcall(function() esm:set_field("_ChangeStagePlayerPosition", make_vec3(x, y, z)) end)
            pcall(function() esm:set_field("_IsSkipPlayerlengthCheck", true) end)
        end
        live_warp(x, y, z)
        -- toujours forcer UniversalPosition : requestWarp rate souvent pendant settle
        set_player_pos(x, y, z)
        local cur = player_pos()
        local tgt = { x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }
        if cur and dist2(cur, tgt) > 25.0 then
            -- encore loin (ex. resté à East Raccoon) → 2e passe
            set_player_pos(x, y, z)
            live_warp(x, y, z)
        end
        cur = player_pos()
        if cur and dist2(cur, tgt) > 100.0 then
            return false, string.format("TP raté (reste à %.0f,%.0f,%.0f cible %.0f,%.0f,%.0f)",
                cur.x, cur.y, cur.z, tgt.x, tgt.y, tgt.z)
        end
        return true, "ok"
    end

    local function clear_fade()
        local fm = sdk.get_managed_singleton("app.FadeManager")
        if not fm then return end
        pcall(function() fm:call("clearAllFade(System.Single, System.String)", 0.0, "re9ap_warp") end)
    end

    local function lift_y(y)
        return (tonumber(y) or 0) + SAFE_Y_LIFT
    end

    -- pose le spawn sur la machine (pas le début de chapitre)
    local function prepare_spawn_at(tw)
        local esm = sdk.get_managed_singleton("app.EnvStageManager")
        if not esm then return end
        local pos = make_vec3(tw.x, lift_y(tw.y), tw.z)
        pcall(function() esm:set_field("_ChangeStagePlayerPosition", pos) end)
        pcall(function() esm:set_field("_IsSkipPlayerlengthCheck", true) end)
        if is_real_stage(tw.stage) then
            pcall(function() esm:call("setOverrideStageName(System.String)", tw.stage) end)
        end
    end

    -- true si le stage machine est chargé (sinon TP = chute dans le vide)
    local function stage_ready(stage)
        if not is_real_stage(stage) then return true end
        local esm = sdk.get_managed_singleton("app.EnvStageManager")
        if not esm then return true end
        local cur = try(function() return esm:get_field("_CurrentStageName") end)
        if cur and tostring(cur) == stage then return true end
        local ok_a = try(function()
            return esm:call("isCompleteActivateFromController(System.String)", stage)
        end)
        if ok_a == true then return true end
        local ok_s = try(function()
            return esm:call("isCompleteStandbyFromController(System.String)", stage)
        end)
        return ok_s == true
    end

    local function near_target(x, y, z, max_d)
        max_d = max_d or 3.5
        local cur = player_pos()
        if not cur then return false end
        -- tolérance Y large (lift de sécurité)
        local dx, dz = cur.x - x, cur.z - z
        local dy = cur.y - y
        if dy < -2 then return false end -- encore sous le sol / vide
        return (dx * dx + dz * dz) <= (max_d * max_d) and dy < 8
    end

    local function player_is_dead()
        local pc = player_context()
        return pc and try(function() return pc:call("get_IsDead") end) == true
    end

    local function queue_stage_warp(tw)
        preload_stage(tw.stage, tw.x, tw.y, tw.z)
        pending = {
            kind = "stage",
            stage = tw.stage,
            scene = tw.scene,
            x = tw.x, y = tw.y, z = tw.z,
            label = tw.label,
            t = os.clock(),
            last_preload = os.clock(),
            tp_tries = 0,
        }
        status = TF("Warp live → machine : %s…", tw.label)
        ctx.push_message(status, ctx.COLORS.info, "info")
        return true
    end

    local function warp_to(tw)
        if not is_unlocked(tw) then
            status = T("Verrouillé — trouve cette machine en jeu")
            ctx.push_message(status, ctx.COLORS.warn, "warn")
            return false
        end
        local here = current_scene()

        -- même MainScene : TP live sur la machine (RE4R)
        if here ~= "" and here == tw.scene then
            if is_real_stage(tw.stage) then
                return queue_stage_warp(tw)
            end
            local ok, err = execute_warp_now(tw.x, lift_y(tw.y), tw.z)
            status = ok and TF("Téléporté à la machine : %s", tw.label) or TF("Échec warp : %s", tostring(err))
            ctx.push_message(status, ok and ctx.COLORS.ok or ctx.COLORS.bad, ok and "ok" or "error")
            return ok
        end

        -- autre MainScene : jump (scene_jump) puis TP machine apres settle
        local snap = ctx.snapshot_inventories and ctx.snapshot_inventories() or nil
        prepare_spawn_at(tw)
        pending = {
            kind = "jump",
            scene = tw.scene, stage = tw.stage,
            x = tw.x, y = tw.y, z = tw.z,
            label = tw.label, t = os.clock(),
            snap = snap, restore_tries = 0, pos_done = false,
            last_tp = 0, tp_tries = 0,
        }
        local ok, err = ctx.jump_to_scene(tw.scene, { bypass = 8 })
        if not ok then
            pending = nil
            status = TF("Saut scène échoué : %s", tostring(err))
            ctx.push_message(status, ctx.COLORS.bad, "error")
            return false
        end
        status = TF("Saut → machine %s…", tw.label)
        ctx.push_message(status, ctx.COLORS.info, "info")
        return true
    end

    local function unlock_nearby()
        local tw_type = try(function() return sdk.typeof("app.GmTypewriterV3") end)
        local scene = try(function()
            return sdk.call_native_func(
                sdk.get_native_singleton("via.SceneManager"),
                sdk.find_type_definition("via.SceneManager"),
                "get_CurrentScene()")
        end)
        if not (tw_type and scene) then return end
        local comps = try(function() return scene:call("findComponents(System.Type)", tw_type) end)
        local n = comps and tonumber(try(function() return comps:get_size() end)) or 0
        local dirty = false
        for i = 0, n - 1 do
            local comp = try(function() return comps:get_element(i) end)
            local pid = comp and try(function() return comp:get_field("_SavedataPlaceID") end)
            local s = pid and (try(function() return pid:call("ToString()") end)
                or try(function() return tostring(pid) end))
            if s and s ~= "" then
                local k = string.lower(tostring(s))
                if not unlocked[k] then
                    unlocked[k] = true
                    dirty = true
                end
            end
        end
        if dirty then save_unlocks() end
    end

    pcall(load_typewriters)
    pcall(load_unlocks)

    local next_tick = 0
    local function tick_warp()
        local now = os.clock()

        -- pending stage / jump : attendre geo, puis TP machine (pas le vide)
        if pending and (pending.kind == "stage" or pending.kind == "jump") then
            local scene = current_scene()
            local tx, ty, tz = pending.x, lift_y(pending.y), pending.z

            if pending.kind == "jump" then
                if scene ~= pending.scene then
                    if now - pending.t > 30 then
                        status = T("Warp annulé (timeout scène)")
                        pending = nil
                    end
                    return
                end
                if not pending.arrived_at then pending.arrived_at = now end
                if ctx.is_game_ready and not ctx.is_game_ready() and (now - pending.arrived_at) < 20 then
                    return
                end
                -- NE PAS TP pendant le settle : sinon chute dans le vide → mort
                if (now - pending.arrived_at) < JUMP_SETTLE then
                    prepare_spawn_at(pending)
                    if is_real_stage(pending.stage) then
                        preload_stage(pending.stage, tx, ty, tz)
                    end
                    return
                end
            end

            if pending.kind == "stage" then
                if now - (pending.last_preload or 0) >= PRELOAD_RETRY then
                    preload_stage(pending.stage, tx, ty, tz)
                    pending.last_preload = now
                end
                if now - (pending.t or now) < SAFE_PRELOAD_DELAY then
                    return
                end
            end

            -- attendre activate du stage machine
            if is_real_stage(pending.stage) then
                local wait_t = pending.arrived_at or pending.t
                if not stage_ready(pending.stage) and (now - wait_t) < STAGE_WAIT_MAX then
                    if now - (pending.last_preload or 0) >= PRELOAD_RETRY then
                        preload_stage(pending.stage, tx, ty, tz)
                        pending.last_preload = now
                    end
                    return
                end
            end

            if player_is_dead() then
                -- mort pendant settle : attendre respawn save, abandonner ce pending
                if now - pending.t > 8 then
                    status = T("Warp annulé (mort dans le vide — réessaie après save)")
                    ctx.push_message(status, ctx.COLORS.bad, "error")
                    pending = nil
                end
                return
            end

            if not pending.pos_done then
                -- comme RE4R : plusieurs essais apres preload (geo parfois pas prete au 1er)
                if now - (pending.last_tp or 0) >= 0.40 then
                    prepare_spawn_at(pending)
                    if is_real_stage(pending.stage) then
                        preload_stage(pending.stage, tx, ty, tz)
                    end
                    execute_warp_now(tx, ty, tz)
                    pending.last_tp = now
                    pending.tp_tries = (pending.tp_tries or 0) + 1
                end
                if near_target(pending.x, pending.y, pending.z, 4.0) then
                    pending.pos_done = true
                    clear_fade()
                elseif (pending.tp_tries or 0) >= TP_RETRIES
                    and now - (pending.arrived_at or pending.t) > 8 then
                    set_player_pos(tx, ty, tz)
                    pending.pos_done = true
                    clear_fade()
                elseif now - (pending.arrived_at or pending.t) > 22 then
                    set_player_pos(tx, ty, tz)
                    pending.pos_done = true
                    clear_fade()
                else
                    return
                end
            end

            if pending.kind == "jump" and pending.snap and ctx.restore_inventories then
                if ctx.is_game_ready and not ctx.is_game_ready() and pending.restore_tries < 40 then
                    pending.restore_tries = pending.restore_tries + 1
                    return
                end
                local ok_r, n = ctx.restore_inventories(pending.snap)
                status = ok_r
                    and TF("Arrivé à la machine : %s (inv OK%s)", pending.label, n and n > 0 and (", +" .. tostring(n)) or "")
                    or TF("Arrivé à la machine : %s (restore inv échoué)", pending.label)
                ctx.push_message(status, ok_r and ctx.COLORS.ok or ctx.COLORS.warn, ok_r and "ok" or "warn")
            else
                status = TF("Arrivé à la machine : %s", pending.label)
                ctx.push_message(status, ctx.COLORS.ok, "ok")
            end
            pending = nil
            return
        end

        if now < next_tick then return end
        next_tick = now + 1.0
        local scene = current_scene()
        if scene ~= "" then note_progress(scene) end
        pcall(unlock_nearby)
    end

    ctx.on_tick("typewriter_warp", tick_warp)

    local function draw_exp_tag(theme)
        theme = theme or THEME or ctx.theme
        if imgui.same_line then pcall(imgui.same_line) end
        theme.colored(T("(expérimental)"), theme.MUTED or 0xFF9A9A9A)
    end

    local function draw_warp_here(tw, id_suffix)
        local theme = THEME or ctx.theme
        local open = is_unlocked(tw)
        local label = string.format("%s##tw_warp_%s", T("Warp Here"), id_suffix or tw.place_id)
        local has_dis = type(imgui.begin_disabled) == "function" and type(imgui.end_disabled) == "function"
        if not open and has_dis then imgui.begin_disabled(true) end
        local pressed = imgui.button(label)
        if not open and has_dis then imgui.end_disabled() end
        if not open and not has_dis then
            -- fallback gris si pas begin_disabled
            if pressed then pressed = false end
        end
        draw_exp_tag(theme)
        if pressed and open then warp_to(tw) end
        if imgui.is_item_hovered and imgui.is_item_hovered() and imgui.set_tooltip then
            pcall(imgui.set_tooltip, string.format("%s | %s | %.1f, %.1f, %.1f | %s | %s",
                tw.label, tw.scene, tw.x, tw.y, tw.z,
                open and T("Débloqué") or T("Verrouillé — trouve cette machine en jeu"),
                T("(expérimental)")))
        end
    end

    function ctx.draw_typewriter_warps_for_chapter(ch)
        local list = by_chapter[tostring(ch or "")]
        if not list or #list == 0 then return end
        local theme = THEME or ctx.theme
        theme.colored(T("Warp :"), theme.MUTED or theme.WHITE)
        draw_exp_tag(theme)
        for i, tw in ipairs(list) do
            draw_warp_here(tw, "ch_" .. tostring(ch) .. "_" .. i)
        end
    end

    -- Campagne style RE4R : une ligne par machine + Warp Here
    -- progress_by_name: { Ch5 = { done, total, name }, ... } depuis ui.refresh_progress
    function ctx.draw_typewriter_campaign(progress_by_name)
        local theme = THEME or ctx.theme
        if #typewriters == 0 then
            theme.note(T("Aucune machine dans re9_typewriters_list.json"))
            return
        end
        theme.colored(T("Warp"), theme.MUTED or theme.WHITE)
        draw_exp_tag(theme)
        theme.note(T("Les warps se débloquent après avoir trouvé la machine en jeu."))
        theme.note(T("(Ch2/Ch4 = point de chapitre, pas de machine en jeu)"))
        theme.note(T("Comme RE4R : tu arrives à la machine à écrire (pas au début du chapitre)."))
        theme.note(T("Sauvegarde à une machine avant un warp vers un autre chapitre."))
        imgui.text("")

        local cols = theme.begin_columns and theme.begin_columns("##re9ap_tw_campaign", 2) or nil
        for i, tw in ipairs(typewriters) do
            if theme.next_column then theme.next_column(cols) end
            local ch = progress_by_name and progress_by_name[tw.ap_chapter] or nil
            local done = ch and ch.done or 0
            local total = ch and ch.total or 0
            local title = string.format("%s - %d / %d##ap_tw_%s",
                tw.label, done, total, tw.place_id)
            if imgui.tree_node(title) then
                theme.colored(string.format("    %s  -  %d / %d",
                    tw.ap_chapter ~= "" and tw.ap_chapter or "?", done, total),
                    (total > 0 and done >= total) and theme.DONE or theme.WHITE)
                draw_warp_here(tw, "camp_" .. i)
                imgui.tree_pop()
            end
        end
        if theme.end_columns then theme.end_columns(cols) end

        imgui.text("")
        theme.plain(T("Dernier warp : ") .. (status ~= "" and status or T("(idle)")))
    end

    function ctx.draw_typewriter_warp()
        local theme = THEME or ctx.theme
        theme.heading(T("Warp machines à écrire"))
        draw_exp_tag(theme)
        theme.note(T("Principalement dans l'onglet « La liste des checks » (Campagne), comme RE4R."))
        theme.note(T("Les warps se débloquent après avoir trouvé la machine en jeu."))
        theme.note(T("Inventaire et coffre sont conservés (comme RE4R)."))
        imgui.text("")
        if status ~= "" then theme.plain(T("Statut : ") .. status) end
        imgui.text("")
        ctx.draw_typewriter_campaign(nil)
    end

    function ctx.is_typewriter_unlocked(tw_or_place)
        if type(tw_or_place) == "table" then return is_unlocked(tw_or_place) end
        return unlocked[string.lower(tostring(tw_or_place or ""))] == true
    end

    function ctx.typewriters_by_chapter()
        return by_chapter
    end

    -- label machine pour HUD (stage ou chapitre AP)
    function ctx.warp_label_for_stage(stage)
        stage = tostring(stage or "")
        if stage == "" then return nil end
        for _, tw in ipairs(typewriters) do
            if tw.stage == stage then return tw.label end
        end
        return nil
    end

    function ctx.warp_label_for_chapter(ch)
        ch = tostring(ch or "")
        local list = by_chapter[ch]
        if list and list[1] then return list[1].label end
        return nil
    end

    ctx.info(string.format("warp typewriters : %d machine(s), %d débloquée(s)",
        #typewriters, (function()
            local n = 0
            for _, tw in ipairs(typewriters) do if is_unlocked(tw) then n = n + 1 end end
            return n
        end)()))
end
