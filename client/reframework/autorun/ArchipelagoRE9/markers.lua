return function(ctx)
    local try = ctx.try
    local UPDATE_SECONDS = 0.25
    local HEIGHT = 0.35
    local EYE_HEIGHT = 1.6         -- la caméra est à hauteur des yeux
    local HEIGHT_MIN = 1.5         -- « +2m » / « -3m » affiché au-delà
    local COLOR_INACTIVE = 0x99AAAAAA   -- zone pas encore active : grisé, pas caché
    local LOOK_X, LOOK_Y = 0.18, 0.25   -- fraction de l'écran
    local HINT_DISTANCE = 150
    local COLOR_HINT = 0xFF4040FF
    local PREFS_FILE = ctx.DATA_DIR .. "markers.json"

    local PREFS_VERSION = 7
    -- map_icons / map_icon_sync : même logique qu'AutoItemReveal (OverZ3)
    -- map_containers : marqueurs monde pour checks sans icône carte (tiroirs / casiers / caisses)
    -- map_chapter_only : n'affiche que les items du chapitre courant
    -- map_floor_only : uniquement l'étage de carte actuel (évite les icônes dans le vide)
    -- show_item : libellé = objet AP (scout), pas le vanilla (sinon tout « Tracking Module »)
    ctx.marker_prefs = {
        enabled = true, distance = 15, look_only = true, show_item = true,
        map_icons = true, map_icon_sync = true, map_containers = true,
        map_chapter_only = true, map_floor_only = true, version = PREFS_VERSION,
    }
    do
        local saved = json.load_file(PREFS_FILE)
        if type(saved) == "table" then
            for k, v in pairs(saved) do
                if ctx.marker_prefs[k] ~= nil and type(v) == type(ctx.marker_prefs[k]) then ctx.marker_prefs[k] = v end
            end
            -- avant la v2, une erreur d'affichage décochait les marqueurs et c'était sauvegardé
            local ver = tonumber(saved.version) or 1
            if ver < 2 then ctx.marker_prefs.enabled = true end
            if ver < 3 then
                ctx.marker_prefs.map_icons = true
                ctx.marker_prefs.map_icon_sync = true
            end
            if ver < 4 then ctx.marker_prefs.map_containers = true end
            if ver < 5 then ctx.marker_prefs.map_chapter_only = true end
            if ver < 6 then ctx.marker_prefs.map_floor_only = true end
            if ver < 7 then ctx.marker_prefs.show_item = true end
            if ver < PREFS_VERSION then ctx.marker_prefs.version = PREFS_VERSION end
        end
    end
    function ctx.save_marker_prefs() pcall(json.dump_file, PREFS_FILE, ctx.marker_prefs, 4) end

    -- libellé monde : objet AP (scout) en priorité — le vanilla se répète trop (Tracking Module…)
    local function clean_item_name(s)
        s = tostring(s or "")
        s = s:gsub("%s*%(it[%w_]+%)%s*", "")
        s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        return s
    end

    function ctx.marker_check_name(loc)
        if not loc then return ctx.T("Check") end
        local zone = tostring(loc.zone or "")
        if zone == "" or zone == "Area" then zone = nil end
        local item = clean_item_name(loc.vanilla_item)
        if item == "" then
            local n = tostring(loc.name or "")
            item = clean_item_name(n:match(" %- (.+)$") or n)
        end
        local num = tostring(loc.name or ""):match("( #%d+)$")
        if num and item ~= "" and not item:find("%#%d+$") then item = item .. num end
        if zone and item ~= "" then return zone .. " · " .. item end
        if item ~= "" then return item end
        if zone then return zone end
        local full = loc.name and loc.name ~= "" and ctx.display_name(loc.name)
        return full or ctx.T("Check")
    end

    -- Texte affiché au-dessus du check : AP d'abord si scout connu
    function ctx.marker_shown_label(loc_id, loc, prefer_ap)
        local spot = ctx.marker_check_name(loc)
        local label = ctx.scout_label and select(1, ctx.scout_label(loc_id)) or nil
        if prefer_ap and label and label ~= "" then return label, true end
        return spot, false
    end

    local markers = {}
    local next_update = 0
    function ctx.refresh_markers() next_update = 0 end

    local function xyz(v)
        if v == nil then return nil end
        local x = tonumber(try(function() return v.x end))
        local y = tonumber(try(function() return v.y end))
        local z = tonumber(try(function() return v.z end))
        if x and y and z then return x, y, z end
        return nil
    end

    -- locale pour dessiner, universelle pour comparer aux données
    local function camera_positions()
        local xform = try(function()
            return sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
        end)
        if not xform then return nil end
        local lx, ly, lz = xyz(try(function() return xform:call("get_Position()") end))
        if not lx then return nil end
        local ux, uy, uz = xyz(try(function() return xform:call("get_UniversalPosition()") end))
        if not ux then ux, uy, uz = lx, ly, lz end
        return lx, ly, lz, ux, uy, uz
    end

    local CHAPTER_RADIUS = 40
    ctx.current_chapter = nil
    ctx.nearby_checks = {}
    ctx.inaccessible_checks = {}
    ctx.progression_near = false

    -- un emplacement sans objet dans la scène (ramassé, pas encore apparu...) n'a pas de nom
    local SCAN_SECONDS = 2
    local next_scan = 0
    local SCAN_RETRY_SECONDS = 30
    local known = {}   -- false = pas un emplacement
    local live = {}
    local scan_failures = 0
    ctx.live_item_count = 0

    local function get_scene()
        return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    end

    -- get_elements absent selon la version de REFramework
    local function elements(arr)
        if type(arr) == "number" then arr = sdk.to_managed_object(arr) end
        if arr == nil then return {} end
        local ok, list = pcall(function() return arr:get_elements() end)
        if ok and type(list) == "table" then return list end
        local n = tonumber(try(function() return arr:call("get_Length()") end))
            or tonumber(try(function() return arr:call("get_Count()") end)) or 0
        local out = {}
        for i = 0, n - 1 do
            local e = try(function() return arr:call("Get(System.Int32)", i) end)
                or try(function() return arr:call("GetValue(System.Int32)", i) end)
                or try(function() return arr:call("get_Item(System.Int32)", i) end)
            if e then out[#out + 1] = e end
        end
        return out
    end

    -- une méthode absente ne compte pas comme désactivée
    local function off(obj, method)
        if obj == nil then return false end
        local ok, v = pcall(function() return obj:call(method) end)
        return ok and v == false
    end

    local function folder_active(go)
        local folder = try(function() return go:call("get_Folder()") end)
        local depth = 0
        while folder and depth < 16 do
            if off(folder, "get_Active") then return false end
            folder = try(function() return folder:call("get_Parent()") end)
            depth = depth + 1
        end
        return true
    end

    local function in_world(e)
        return not (off(e.go, "get_Draw") or off(e.go, "get_DrawSelf") or off(e.go, "get_Update") or off(e.go, "get_UpdateSelf")
            or off(e.comp, "get_Enabled") or off(e.mesh, "get_Enabled"))
    end

    -- après une mort le jeu remet les objets déjà ramassés ; on les re-cache si check AP fait
    -- (NEVER_BLOCK / Flag : laissés pour reposer le flag scénario)
    ctx.hide_checked_pickups = true
    ctx.hidden_pickups = 0

    -- draw only : ne pas réactiver Update/ItemCore (sinon on arrache les connecteurs → cellule ne s'ouvre pas)
    local function show_go_draw(go, mesh)
        if not go then return end
        pcall(function() go:call("set_DrawSelf", true) end)
        pcall(function() go:call("set_Draw", true) end)
        if mesh then pcall(function() mesh:call("set_Enabled", true) end) end
    end

    local function collect_meshes(go, out, depth)
        out = out or {}
        depth = depth or 0
        if not go then return out end
        local mesh = try(function()
            return go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        end)
        if mesh then out[#out + 1] = mesh end
        if depth < 2 then
            local xf = try(function() return go:call("get_Transform()") end)
            local child = xf and (try(function() return xf:call("get_Child") end)
                or try(function() return xf:call("get_Child()") end))
            local guard = 0
            while child and guard < 32 do
                local cgo = try(function() return child:call("get_GameObject") end)
                    or try(function() return child:call("get_GameObject()") end)
                collect_meshes(cgo, out, depth + 1)
                child = try(function() return child:call("get_Next") end)
                    or try(function() return child:call("get_Next()") end)
                guard = guard + 1
            end
        end
        return out
    end

    local function hide_if_taken(id, e)
        if not e or e.hidden then return end
        if ctx.should_keep_vanilla(e.item_id) then return end
        local done = ctx.is_checked(id) or e.checked_when_seen
        if not done then return end
        if not e.go then return end
        -- draw + update + composant : plus d'interact possible sans re-ramasser
        pcall(function() e.go:call("set_DrawSelf", false) end)
        pcall(function() e.go:call("set_Draw", false) end)
        pcall(function() e.go:call("set_UpdateSelf", false) end)
        pcall(function() e.go:call("set_Update", false) end)
        if e.mesh then pcall(function() e.mesh:call("set_Enabled", false) end) end
        if e.comp then
            pcall(function() e.comp:call("set_Enabled", false) end)
            pcall(function() e.comp:set_field("_VanishHasAcquired", true) end)
            pcall(function() e.comp:set_field("_VanishHasFamilyAcquired", true) end)
        end
        e.hidden = true
        ctx.hidden_pickups = (ctx.hidden_pickups or 0) + 1
        local loc = ctx.locations[id] or ctx.locations[tonumber(id)]
        ctx.info("objet déjà ramassé caché : " .. tostring(loc and loc.name or id))
    end

    -- Joint Plug déjà caché : mesh visible, interact toujours off (panneau / ouverture cellule)
    local function unhide_never_block(e)
        if not e or not e.hidden then return end
        if not ctx.should_keep_vanilla(e.item_id) then return end
        show_go_draw(e.go, e.mesh)
        if e.comp then
            pcall(function() e.comp:call("set_Enabled", false) end)
            pcall(function() e.comp:set_field("_VanishHasAcquired", true) end)
            pcall(function() e.comp:set_field("_VanishHasFamilyAcquired", true) end)
        end
        e.hidden = false
        ctx.info("connecteur réaffiché (draw only) : " .. tostring(e.item_id))
    end
    ctx.unhide_never_block_pickup = unhide_never_block
    ctx.show_world_go = show_go_draw

    -- après mort / reload : vider le cache ItemCore pour re-scanner et re-cacher
    function ctx.reset_pickup_world_cache()
        known, live = {}, {}
        ctx.hidden_pickups = 0
        next_update = 0
        next_scan = 0
    end

    -- Carte : même approche qu'AutoItemReveal (OverZ3)
    -- 1) get_IsDiscovered → true seulement pour les checks AP pas encore faits
    -- 2) sync icônes : _ViewItemID → set_MarkedCharacters (corrige Madhouse / mauvais pictos)
    -- 3) parents gimmick (tiroirs / casiers) : MapIconControllerForGimmickV2 + unhide
    -- Note : caisses en bois cassables n'ont souvent AUCUNE icône native → marqueurs monde (map_containers)
    local map_icon_type = try(function() return sdk.typeof("app.MapIconControllerForItem") end)
    local map_gimmick_type = try(function() return sdk.typeof("app.MapIconControllerForGimmickV2") end)
    local map_stats = { shown = 0, missing = 0, synced = 0, gimmick = 0 }
    local CONTAINER_DISTANCE = 40
    -- addr MapIconStatus -> location id (persisté pour cacher l'icône après ramassage / mort)
    local status_to_loc = {}

    local function map_controller(go)
        local function find_on(g, typ)
            return g and typ and try(function() return g:call("getComponent(System.Type)", typ) end)
        end
        local cur, depth = go, 0
        while cur and depth < 8 do
            local ctrl = find_on(cur, map_icon_type) or find_on(cur, map_gimmick_type)
            if ctrl then return ctrl end
            cur = try(function()
                return cur:call("get_Transform()"):call("get_Parent()"):call("get_GameObject()")
            end)
            depth = depth + 1
        end
        return nil
    end

    local function unhide_status(status)
        if not status then return end
        -- _Hiding / _IsDiscoveredAll = GmMapIconStatusV2 seulement (pas ItemMapIconStatus)
        local td = try(function() return status:get_type_definition() end)
        if not td then return end
        if td:get_field("_Hiding") then
            pcall(function() status:set_field("_Hiding", false) end)
        end
        if td:get_field("_IsDiscoveredAll") then
            pcall(function() status:set_field("_IsDiscoveredAll", true) end)
        end
    end

    local function here_chapter()
        local from_scene = ctx.ap_chapter and ctx.ap_chapter()
        if from_scene and from_scene ~= "" then return from_scene end
        return ctx.current_chapter or ctx.last_chapter
    end

    local function in_here_chapter(loc)
        if not loc then return false end
        local prefs = ctx.marker_prefs
        if not (prefs and prefs.map_chapter_only) then return true end
        local ch = here_chapter()
        if not ch or ch == "" then return true end
        return loc.chapter == ch
    end

    -- adresses MapIconStatus / ItemContext du chapitre courant (reconstruites au sync)
    local allowed_status, allowed_item_ctx = {}, {}

    local function as_text(v)
        if v == nil then return nil end
        if type(v) == "string" then return v end
        local s = try(function() return v:call("ToString()") end)
        return type(s) == "string" and s or nil
    end

    local function item_ctx_location(item_ctx)
        if not item_ctx or not ctx.resolve_location then return nil end
        local pos = try(function() return item_ctx:call("get_UniversalPosition()") end)
            or try(function() return item_ctx:call("get_Position()") end)
        local px, py, pz = xyz(pos)
        if not px then
            px = tonumber(try(function() return pos:get_field("x") end))
            py = tonumber(try(function() return pos:get_field("y") end))
            pz = tonumber(try(function() return pos:get_field("z") end))
        end
        local pos_t = (px and py and pz) and { x = px, y = py, z = pz } or nil
        local vid = try(function() return item_ctx:call("get_ViewItemID()") end)
        local item_id = as_text(vid) or tostring(vid or "")
        item_id = item_id:match("(it[%d_]+)") or item_id
        local keys = {}
        local cid = try(function() return item_ctx:call("get_ContextID()") end)
        local raw = cid and as_text(try(function() return cid:get_field("_RawID") end))
        if raw and raw ~= "" and raw ~= ctx.ZERO_GUID then
            keys[#keys + 1] = string.lower("ctx::" .. raw)
        end
        local loc = ctx.resolve_location(keys, item_id, pos_t)
        return loc
    end

    local function allow_item_ctx(item_ctx, status)
        local addr = item_ctx and try(function() return item_ctx:get_address() end)
        local saddr = status and try(function() return status:get_address() end)
        if addr then allowed_item_ctx[addr] = true end
        if saddr then allowed_status[saddr] = true end
    end

    -- Comme RE2R AP : icônes image sur TOUT l'étage actuel, sans entrer dans chaque salle.
    -- 1) get_IsDiscovered → true (AutoItemReveal)
    -- 2) isStayIn / IsEnteredSection → true SEULEMENT pour les sections de l'étage affiché
    --    (évite les icônes dans le vide / autres étages)
    -- 3) sync Madhouse pictos
    local floor_sec_keys = {} -- sections de l'étage courant

    local function id_key(obj)
        if not obj then return nil end
        return as_text(obj) or tostring(try(function() return obj:get_address() end) or "")
    end

    local map_hooks_disabled = false
    local map_hook_fails = 0

    local function map_icons_on()
        if map_hooks_disabled then return false end
        return ctx.marker_prefs and ctx.marker_prefs.map_icons
    end

    local function map_world_ok()
        if not map_icons_on() then return false end
        if ctx.is_safe_to_mutate then return ctx.is_safe_to_mutate() end
        return ctx.is_game_ready and ctx.is_game_ready()
    end

    local function safe_hook_post(fn)
        return function(retval)
            local ok, r = pcall(fn, retval)
            if not ok then
                map_hook_fails = map_hook_fails + 1
                if map_hook_fails >= 8 and not map_hooks_disabled then
                    map_hooks_disabled = true
                    ctx.warn("carte : hooks désactivés après erreurs répétées (relance Reset Scripts pour réessayer)")
                end
                return retval
            end
            return r
        end
    end

    local function section_on_floor(sec)
        local k = id_key(sec)
        return k and k ~= "" and floor_sec_keys[k] == true
    end

    local function item_section(item_ctx)
        if not item_ctx then return nil end
        return try(function() return item_ctx:call("get_StaySection()") end)
            or try(function() return item_ctx:call("get_SpawnSection()") end)
            or try(function() return item_ctx:get_field("_AssignSectionID") end)
            or try(function() return item_ctx:get_field("_CachedAssignSectionID") end)
    end

    local function refresh_floor_sections()
        local fresh = {}
        local gm = sdk.get_managed_singleton("app.GuiManager")
        if not gm then
            floor_sec_keys = fresh
            return 0
        end
        local bridge = try(function() return gm:get_field("<Map>k__BackingField") end)
            or try(function() return gm:call("get_Map()") end)
        local floor = try(function() return gm:call("get_CurrentStayFloorId()") end)
            or try(function() return gm:get_field("<CurrentStayFloorId>k__BackingField") end)
        if not bridge or not floor then
            floor_sec_keys = fresh
            return 0
        end
        local list = try(function() return bridge:call("getSectionVariationIdList", floor) end)
            or try(function() return bridge:call("getSectionVariationIdList(app.GuiMapFloorID)", floor) end)
        local n = list and tonumber(try(function() return list:get_Count() end)
            or try(function() return list:get_field("_size") end)) or 0
        if list and n > 0 then
            for i = 0, n - 1 do
                local sec = try(function() return list:call("get_Item", i) end)
                    or try(function() return list:get_Item(i) end)
                local k = id_key(sec)
                if k and k ~= "" then fresh[k] = true end
            end
        end
        local secs = try(function() return bridge:call("tryGetSectionIds", floor) end)
            or try(function() return bridge:call("tryGetSectionIds(app.GuiMapFloorID)", floor) end)
        local sn = secs and tonumber(try(function() return secs:get_size() end)) or 0
        if secs and sn > 0 then
            for i = 0, sn - 1 do
                local sec = try(function() return secs:get_element(i) end)
                local k = id_key(sec)
                if k and k ~= "" then fresh[k] = true end
            end
        end
        floor_sec_keys = fresh
        local count = 0
        for _ in pairs(fresh) do count = count + 1 end
        return count
    end

    -- get_IsDiscovered / Any : oui si check AP pas fait ; non si déjà checké ; sinon AutoItemReveal
    local function hook_discovered(method)
        local td = sdk.find_type_definition("app.structure.MapIconStatus")
        local m = td and td:get_method(method)
        if not m then
            if method == "get_IsDiscovered" then
                ctx.warn("carte : MapIconStatus." .. method .. " introuvable")
            end
            return
        end
        local asking = nil
        sdk.hook(m,
            function(args)
                asking = try(function() return sdk.to_int64(args[2]) end)
            end,
            safe_hook_post(function(retval)
                local addr = asking
                asking = nil
                if not map_world_ok() then return retval end
                local id = addr and status_to_loc[addr]
                if id then
                    if ctx.session.active[id] and not ctx.is_checked(id) then
                        return sdk.to_ptr(1)
                    end
                    return sdk.to_ptr(0)
                end
                return sdk.to_ptr(1)
            end))
    end
    hook_discovered("get_IsDiscovered")
    hook_discovered("get_IsDiscoveredAny")

    -- ItemContext.isStayIn : vrai si l'item est sur l'étage actuel
    do
        local td = sdk.find_type_definition("app.ItemContext")
        local methods = td and try(function() return td:get_methods() end)
        local function hook_is_stay(m)
            if not m then return end
            local asking = nil
            sdk.hook(m,
                function(args)
                    local ok, o = pcall(sdk.to_managed_object, args[2])
                    asking = ok and o or nil
                end,
                safe_hook_post(function(retval)
                    if not map_world_ok() then return retval end
                    if not next(floor_sec_keys) then return retval end
                    if section_on_floor(item_section(asking)) then return sdk.to_ptr(1) end
                    return retval
                end))
        end
        if methods then
            for _, m in ipairs(methods) do
                if try(function() return m:get_name() end) == "isStayIn" then hook_is_stay(m) end
            end
        elseif td then
            hook_is_stay(td:get_method("isStayIn"))
        end
    end

    -- StaySectionData.isStayIn(section) : vrai pour les salles de l'étage (sans entrer)
    do
        local td = sdk.find_type_definition("app.structure.StaySectionData")
        local m = td and td:get_method("isStayIn(app.GuiMapSectionVariationID)")
            or (td and td:get_method("isStayIn"))
        if m then
            local asking = nil
            sdk.hook(m,
                function(args)
                    local ok, o = pcall(sdk.to_managed_object, args[3])
                    asking = ok and o or nil
                end,
                safe_hook_post(function(retval)
                    if not map_world_ok() then return retval end
                    if not next(floor_sec_keys) then return retval end
                    if section_on_floor(asking) then return sdk.to_ptr(1) end
                    return retval
                end))
        end
    end

    -- GuiManager.IsEnteredSection : même logique (étage actuel = « entré »)
    do
        local td = sdk.find_type_definition("app.GuiManager")
        local m = td and td:get_method("IsEnteredSection")
        if m then
            local asking = nil
            sdk.hook(m,
                function(args)
                    local ok, o = pcall(sdk.to_managed_object, args[3])
                    asking = ok and o or nil
                end,
                safe_hook_post(function(retval)
                    if not map_world_ok() then return retval end
                    if not next(floor_sec_keys) then return retval end
                    if section_on_floor(asking) then return sdk.to_ptr(1) end
                    return retval
                end))
        end
    end
    ctx.info("carte : mode RE2R — icônes de tout l'étage (hooks sécurisés)")

    -- Sync Madhouse : _ViewItemID → set_MarkedCharacters
    function ctx.sync_map_icons()
        if map_hooks_disabled then return 0 end
        if not (ctx.marker_prefs and ctx.marker_prefs.map_icon_sync) then return 0 end
        if ctx.is_safe_to_mutate and not ctx.is_safe_to_mutate() then return 0 end
        pcall(refresh_floor_sections)
        local mgr = sdk.get_managed_singleton("app.ItemManager")
        if not mgr then return 0 end
        local ready = try(function() return mgr:get_field("_ReadyContextDB") end)
        if ready == false or ready == nil then return 0 end
        local db = try(function() return mgr:get_field("_ContextDB") end)
        local entries = db and try(function() return db:get_field("_entries") end)
        if not entries then return 0 end
        local capacity = tonumber(try(function() return entries:get_size() end)) or 0
        if capacity <= 0 then return 0 end
        local n = 0
        for i = 0, capacity - 1 do
            local entry = try(function() return entries:get_element(i) end)
            if entry then
                local hash = try(function() return entry:get_field("hashCode") end)
                if hash ~= nil and hash >= 0 then
                    local item_ctx = try(function() return entry:get_field("value") end)
                    local status = item_ctx and try(function() return item_ctx:get_field("_MapIconStatus") end)
                    local view_id = item_ctx and try(function() return item_ctx:get_field("_ViewItemID") end)
                    local bit = view_id and tonumber(view_id)
                    if status and bit then
                        pcall(function() status:call("set_MarkedCharacters", bit) end)
                        n = n + 1
                    end
                    local saddr = status and try(function() return status:get_address() end)
                    local loc = item_ctx and item_ctx_location(item_ctx)
                    if saddr and loc and loc.id then
                        local id = tostring(loc.id)
                        status_to_loc[saddr] = id
                        if ctx.is_checked(id) then
                            local td = try(function() return status:get_type_definition() end)
                            if td and td:get_field("_Hiding") then
                                pcall(function() status:set_field("_Hiding", true) end)
                            end
                        end
                    end
                end
            end
        end
        map_stats.synced = n
        return n
    end

    local MAP_TRIES = 5
    local function reveal_on_map(e, checked)
        if e.on_map == false and (e.map_tries or 0) >= MAP_TRIES then return end
        if not (map_icon_type or map_gimmick_type) then
            e.on_map = false
            return
        end
        local ctrl = map_controller(e.go)
        local status = ctrl and try(function() return ctrl:get_field("_MapIconStatus") end)
        local addr = status and try(function() return status:get_address() end)
        if not addr then
            e.map_tries = (e.map_tries or 0) + 1
            if e.map_tries >= MAP_TRIES then e.on_map = false end
            return
        end
        e.status_addr, e.on_map = addr, true
        if checked then
            local td = try(function() return status:get_type_definition() end)
            if td and td:get_field("_Hiding") then
                pcall(function() status:set_field("_Hiding", true) end)
            end
        else
            unhide_status(status)
        end
    end

    -- Force les icônes gimmick déjà présentes (tiroirs verrouillés « ! », etc.)
    local function unhide_all_gimmick_icons(scene)
        if not map_gimmick_type or not scene then return 0 end
        local arr = try(function() return scene:call("findComponents(System.Type)", map_gimmick_type) end)
        local elems = elements(arr)
        local n = 0
        for _, ctrl in ipairs(elems) do
            local status = try(function() return ctrl:get_field("_MapIconStatus") end)
            if status then
                unhide_status(status)
                n = n + 1
            end
        end
        map_stats.gimmick = n
        return n
    end

    -- pas d'étiquette [AP] sans ItemCore visible (casier vide, coords seules, mesh clé/module)
    local function has_pickup_object(e)
        if not e or not e.go or not e.mesh then return false end
        if not in_world(e) then return false end
        return true
    end

    local function is_container_name(name)
        if type(name) ~= "string" then return false end
        local n = name:lower()
        return n:find("drawer", 1, true) or n:find("locker", 1, true)
            or n:find("safe", 1, true) or n:find("supply box", 1, true)
            or n:find("gimmick", 1, true) or n:find("crate", 1, true)
            or n:find("caisse", 1, true) or n:find("tiroir", 1, true)
            or n:find("casier", 1, true) or n:find("box", 1, true)
    end

    local function log_map_stats()
        local shown, missing = {}, {}
        for id, e in pairs(live) do
            if e.on_map ~= nil and ctx.session.active[id] and not ctx.is_checked(id) then
                local loc = ctx.locations[id] or ctx.locations[tonumber(id)]
                local name = tostring(loc and loc.name or id)
                if e.on_map then
                    local x, y, z = xyz(e.pos)
                    shown[#shown + 1] = x and string.format("%s @ %.1f, %.1f, %.1f", name, x, y, z) or name
                else
                    missing[#missing + 1] = name
                end
            end
        end
        if #shown ~= map_stats.shown or #missing ~= map_stats.missing then
            map_stats.shown, map_stats.missing = #shown, #missing
            ctx.info(string.format("carte : %d check(s) affiché(s), %d sans icône de carte%s", #shown, #missing,
                #missing > 0 and (" (" .. table.concat(missing, ", ") .. ")") or ""))
            for _, s in ipairs(shown) do ctx.info("carte :   " .. s) end
        end
    end

    local last_map_sync = 0
    local function maybe_sync_map_icons()
        -- comme AutoItemReveal : sync Madhouse indépendant du reveal
        if map_hooks_disabled then return end
        if not (ctx.marker_prefs and ctx.marker_prefs.map_icon_sync) then return end
        if ctx.is_safe_to_mutate then
            if not ctx.is_safe_to_mutate() then return end
        elseif not (ctx.is_game_ready and ctx.is_game_ready()) then
            return
        end
        local now = os.clock()
        if now - last_map_sync < 3.0 then return end
        last_map_sync = now
        local ok, n = pcall(ctx.sync_map_icons)
        if not ok then
            map_hook_fails = map_hook_fails + 1
            if map_hook_fails >= 8 and not map_hooks_disabled then
                map_hooks_disabled = true
                ctx.warn("carte : sync Madhouse désactivé après erreurs (Reset Scripts pour réessayer)")
            end
        end
    end

    -- Storage / Map / Procedure : pas de prompt Capcom. F à portée, comme le ramassage vanilla.
    local NO_VOLUME_RADIUS = 2.0
    local NO_VOLUME_CAT = { Storage = true, Map = true, Procedure = true }

    local function no_volume_item(item_id)
        if type(item_id) ~= "string" or item_id == "" then return false end
        if ctx.should_keep_vanilla and ctx.should_keep_vanilla(item_id) then return false end
        if ctx.NEVER_BLOCK_ITEMS and ctx.NEVER_BLOCK_ITEMS[item_id] then return false end
        local gid = item_id
        local known = ctx.items_by_id and ctx.items_by_id[gid]
        if not known then
            gid = item_id:match("^(it%d+_%d+_%d+)") or item_id
            known = ctx.items_by_id and ctx.items_by_id[gid]
        end
        local cat = known and tostring(known.category) or ""
        return NO_VOLUME_CAT[cat] == true
    end

    local function camera_look()
        local xform = try(function()
            return sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
        end)
        if not xform then return nil end
        local zx, zy, zz = xyz(try(function() return xform:call("get_AxisZ()") end))
        if not zx then return nil end
        return -zx, -zy, -zz
    end

    -- le plus proche devant la caméra. F le prend ; rien ne part tout seul.
    local function focus_no_volume(lx, ly, lz)
        ctx.f_pickup = nil
        if not lx then return end
        local fx, fy, fz = camera_look()
        local best, best_d2 = nil, NO_VOLUME_RADIUS * NO_VOLUME_RADIUS
        for id, e in pairs(live) do
            if ctx.session.active[id] and not ctx.is_checked(id) and no_volume_item(e.item_id) and has_pickup_object(e) then
                local ox, oy, oz = xyz(try(function() return e.xform:call("get_Position()") end))
                if ox then
                    local dx, dy, dz = ox - lx, oy - ly, oz - lz
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 <= best_d2 and d2 > 0.04 then
                        local facing = true
                        if fx then
                            local inv = 1 / math.sqrt(d2)
                            facing = dx * inv * fx + dy * inv * fy + dz * inv * fz > 0.35
                        end
                        if facing then
                            best_d2 = d2
                            best = {
                                id = id, comp = e.comp, entry = e, pos = e.pos,
                                loc = ctx.locations[id] or ctx.locations[tonumber(id)],
                            }
                        end
                    end
                end
            end
        end
        ctx.f_pickup = best
    end

    local function interact_busy()
        local mgr = sdk.get_managed_singleton("app.InteractManager")
        if not mgr then return false end
        local list = try(function() return mgr:get_field("_ActiveTriggerInfoList") end)
        if not list then return false end
        local n = tonumber(try(function() return list:call("get_Count()") end)) or 0
        return n > 0
    end

    -- casier ouvert / gimmick : l'ItemCore disparaît parfois sans hook pickup
    local DESPAWN_CHECK_RADIUS = 8.0

    local function force_nearby_despawns(prev_live, fresh_live, itemcore_count)
        if itemcore_count == 0 then return end
        if not ctx.has_slot_data() or not ctx.force_check then return end
        if ctx.is_safe_to_mutate then
            if not ctx.is_safe_to_mutate() then return end
        elseif not ctx.is_game_ready() then
            return
        end
        if not next(prev_live) then return end
        local _, _, _, ux, uy, uz = camera_positions()
        if not ux then return end
        local r2 = DESPAWN_CHECK_RADIUS * DESPAWN_CHECK_RADIUS
        for id, e in pairs(prev_live) do
            if not fresh_live[id] and ctx.session.active[id] and not ctx.is_checked(id) then
                local px = e.pos and e.pos.x
                local py = e.pos and e.pos.y
                local pz = e.pos and e.pos.z
                if not px then
                    local loc = ctx.locations[id]
                    if loc then px, py, pz = loc.x, loc.y, loc.z end
                end
                if px then
                    local dx, dy, dz = px - ux, py - uy, pz - uz
                    if dx * dx + dy * dy + dz * dz <= r2 then
                        local loc = ctx.locations[id]
                        if loc then
                            pcall(ctx.force_check, loc, "objet disparu près du joueur (casier / gimmick)", e.pos)
                        end
                    end
                end
            end
        end
    end

    local function scan()
        local scene = get_scene()
        if not scene then return end
        local arr = scene:call("findComponents(System.Type)", sdk.typeof("app.ItemCore"))
        local elems = elements(arr)
        local prev_live = live
        local fresh_known, fresh_live = {}, {}
        for _, comp in ipairs(elems) do
            local addr = try(function() return comp:get_address() end)
            if addr then
                local entry = known[addr]
                if entry == nil then
                    entry = false
                    local info = ctx.read_item and try(function() return ctx.read_item(comp) end)
                    local loc = info and ctx.resolve_location(info.keys, info.item_id, info.pos)
                    local go = loc and try(function() return comp:call("get_GameObject()") end)
                    local xf = go and try(function() return go:call("get_Transform()") end)
                    if loc and loc.id and xf then
                        local mesh = try(function() return go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
                        if not mesh then
                            local ms = collect_meshes(go)
                            mesh = ms[1]
                        end
                        entry = { id = tostring(loc.id), xform = xf, go = go, comp = comp, mesh = mesh,
                                  item_id = info.item_id, pos = info.pos,
                                  checked_when_seen = ctx.is_checked(tostring(loc.id)) }
                    end
                end
                fresh_known[addr] = entry
                if entry then fresh_live[entry.id] = entry end
            end
        end
        force_nearby_despawns(prev_live, fresh_live, #elems)
        known, live = fresh_known, fresh_live
        if ctx.hide_checked_pickups then
            for id, e in pairs(live) do
                hide_if_taken(id, e)
                unhide_never_block(e)
            end
        end
        if map_world_ok() then
            for id, e in pairs(live) do
                local loc = ctx.locations[id] or ctx.locations[tonumber(id)]
                if ctx.session.active[id] and in_here_chapter(loc) then
                    local done = ctx.is_checked(id)
                    pcall(reveal_on_map, e, done)
                    if e.status_addr then
                        status_to_loc[e.status_addr] = id
                        if not done then allowed_status[e.status_addr] = true end
                    end
                end
            end
            pcall(unhide_all_gimmick_icons, scene)
            pcall(log_map_stats)
        end
        maybe_sync_map_icons()
        local st = { found = 0, done = 0, object = 0, folder = 0 }
        for id, e in pairs(live) do
            st.found = st.found + 1
            if not ctx.session.active[id] or ctx.is_checked(id) then st.done = st.done + 1
            elseif not in_world(e) then st.object = st.object + 1
            elseif not folder_active(e.go) then st.folder = st.folder + 1 end
        end
        ctx.marker_stats = st
        ctx.live_item_count = st.found - st.object
    end

    local function update()
        local now = os.clock()
        if now < next_update then return end
        next_update = now + UPDATE_SECONDS
        local p = ctx.marker_prefs
        local out, nearby, stuck, prog_near, chapter = {}, {}, {}, false, nil
        local playable = false
        if ctx.is_safe_to_mutate then
            playable = ctx.is_safe_to_mutate()
        elseif ctx.is_game_ready then
            playable = ctx.is_game_ready()
        end
        if ctx.has_slot_data() and playable then
            if now >= next_scan then
                next_scan = now + SCAN_SECONDS
                local ok, e = pcall(scan)
                if ok then
                    scan_failures = 0
                else
                    scan_failures = scan_failures + 1
                    next_scan = now + SCAN_RETRY_SECONDS
                    known, live = {}, {}
                    if scan_failures <= 3 then ctx.err("recherche des objets de la scène : " .. tostring(e)) end
                end
            end
            local lx, ly, lz, ux, uy, uz = camera_positions()
            if lx then
                focus_no_volume(lx, ly, lz)
                local max_d2 = p.distance * p.distance
                -- chapitre = scène AP en priorité ; XYZ seulement si scène inconnue
                chapter = ctx.ap_chapter and ctx.ap_chapter() or nil
                if not chapter then
                    local best_d2 = CHAPTER_RADIUS * CHAPTER_RADIUS
                    for id, loc in pairs(ctx.locations) do
                        if loc.x and loc.chapter then
                            local dx, dy, dz = loc.x - ux, loc.y - uy, loc.z - uz
                            local d2 = dx * dx + dy * dy + dz * dz
                            if d2 < best_d2 then best_d2, chapter = d2, loc.chapter end
                        end
                    end
                end
                for id, loc in pairs(ctx.locations) do
                    if loc.x and in_here_chapter(loc) then
                        local dx, dy, dz = loc.x - ux, loc.y - uy, loc.z - uz
                        local d2 = dx * dx + dy * dy + dz * dz
                        if d2 <= max_d2 and ctx.session.active[id] and not ctx.is_checked(id) then
                            local label, color, sc = nil, nil, nil
                            if ctx.scout_label then label, color, sc = ctx.scout_label(id) end
                            local shown = ctx.marker_shown_label(id, loc, p.show_item)
                            local row = {
                                id = id, d = math.sqrt(d2),
                                name = shown,
                                label = label, color = color,
                            }
                            if has_pickup_object(live[id]) then
                                if sc and (sc.flags & 1) ~= 0 then prog_near = true end
                                nearby[#nearby + 1] = row
                            else
                                stuck[#stuck + 1] = row
                            end
                        end
                    end
                end
                if p.enabled then
                    local hinted = ctx.hinted_locations()
                    local hint_d2 = HINT_DISTANCE * HINT_DISTANCE
                    local function add_marker(id, ox, oy, oz, d2, inactive, container)
                        local hint = hinted[id] == true
                        local loc = ctx.locations[id]
                        local label, color = nil, nil
                        if ctx.scout_label then label, color = ctx.scout_label(id) end
                        local prefer_ap = p.show_item or hint
                        local shown = select(1, ctx.marker_shown_label(id, loc, prefer_ap))
                        local rise = oy - (ly - EYE_HEIGHT)
                        local height = ""
                        if rise >= HEIGHT_MIN then height = string.format("  +%dm", math.floor(rise + 0.5))
                        elseif rise <= -HEIGHT_MIN then height = string.format("  -%dm", math.floor(-rise + 0.5)) end
                        local col = (prefer_ap and color) or ctx.COLORS.info
                        if inactive then col = COLOR_INACTIVE end
                        if hint then col = COLOR_HINT end
                        local tag = hint and "[HINT]" or (container and "[CAISSE]" or "[AP]")
                        if ctx.f_pickup and ctx.f_pickup.id == id then tag = "[F]" end
                        out[#out + 1] = { ox, oy + HEIGHT, oz,
                            string.format("%s %s  %dm%s", tag, shown,
                                math.floor(math.sqrt(d2) + 0.5), height),
                            col, hint }
                    end
                    local marked = {}
                    local chap_now = chapter or here_chapter()
                    for id, e in pairs(live) do
                        local loc = ctx.locations[id]
                        if ctx.session.active[id] and not ctx.is_checked(id) and in_here_chapter(loc) then
                            local ox, oy, oz = xyz(try(function() return e.xform:call("get_Position()") end))
                            if ox then
                                local dx, dy, dz = ox - lx, oy - ly, oz - lz
                                local d2 = dx * dx + dy * dy + dz * dz
                                local no_icon = e.on_map == false
                                local cont_d2 = CONTAINER_DISTANCE * CONTAINER_DISTANCE
                                local lim = hinted[id] and hint_d2 or max_d2
                                if p.map_containers and no_icon then lim = math.max(lim, cont_d2) end
                                if d2 <= lim and has_pickup_object(e) then
                                    add_marker(id, ox, oy, oz, d2, e.go and not folder_active(e.go), no_icon)
                                    marked[id] = true
                                end
                            end
                        end
                    end
                    -- pas de marqueur sur des coords seules : sans ItemCore, le casier est vide
                    if chap_now then ctx.last_chapter = chap_now end
                end
            end
        end
        table.sort(nearby, function(a, b) return a.d < b.d end)
        table.sort(stuck, function(a, b) return a.d < b.d end)
        markers = out
        ctx.nearby_checks, ctx.inaccessible_checks, ctx.progression_near, ctx.current_chapter = nearby, stuck, prog_near, chapter
        if chapter then ctx.last_chapter = chapter end
        if chapter and chapter ~= ctx._tracker_zone and ctx.ap_send_zone then
            ctx._tracker_zone = chapter
            pcall(ctx.ap_send_zone, chapter)
        end
        -- zone / stage pour le HUD (nom lisible)
        local zone, stage = nil, nil
        local esm = sdk.get_managed_singleton("app.EnvStageManager")
        stage = esm and try(function() return esm:get_field("_CurrentStageName") end)
        stage = stage and tostring(stage) or ""
        if stage == "" then stage = nil end
        if chapter and lx then
            local best_z, best_zd2 = nil, CHAPTER_RADIUS * CHAPTER_RADIUS
            for id, loc in pairs(ctx.locations) do
                if loc.chapter == chapter and loc.x then
                    local dx, dy, dz = loc.x - ux, loc.y - uy, loc.z - uz
                    local d2 = dx * dx + dy * dy + dz * dz
                    local z = tostring(loc.zone or "")
                    if z ~= "" and z ~= "Area" and d2 < best_zd2 then
                        best_zd2, best_z = d2, z
                    end
                end
            end
            zone = best_z
        end
        ctx.current_stage = stage
        ctx.current_zone = zone
        if zone then ctx.last_zone = zone end
        if stage then ctx.last_stage = stage end
    end

    -- projection faite ici : draw.world_text et draw.world_to_screen plantent dans RE9
    ctx.marker_screen = {}
    ctx.screen_size = { 1920, 1080 }   -- imgui n'est lisible qu'à l'affichage, ui.lua le met à jour

    local function lens(cam, w, h)
        local ok, pm = pcall(function() return cam:call("get_ProjectionMatrix()") end)
        if ok and pm then
            local okx, sx = pcall(function() return math.abs(pm[0].x) end)
            local oky, sy = pcall(function() return math.abs(pm[1].y) end)
            if okx and oky and sx > 0.05 and sx < 50 and sy > 0.05 and sy < 50 then return 1 / sx, 1 / sy end
        end
        local fov = tonumber(try(function() return cam:call("get_FOV()") end)) or 70
        local ty = math.tan(math.rad(fov) / 2)
        return ty * w / h, ty
    end

    local function project()
        if #markers == 0 or not ctx.marker_prefs.enabled then
            if #ctx.marker_screen > 0 then ctx.marker_screen = {} end
            return
        end
        local cam = sdk.get_primary_camera()
        if not cam then return end
        local xf = cam:call("get_GameObject"):call("get_Transform")
        local px, py, pz = xyz(xf:call("get_Position()"))
        local q = xf:call("get_Rotation()")
        if not px or not q then return end
        -- la caméra regarde vers -Z
        local ux, uy, uz, qw = -q.x, -q.y, -q.z, q.w
        local w, h = ctx.screen_size[1], ctx.screen_size[2]
        local tx, ty = lens(cam, w, h)
        local look_only = ctx.marker_prefs.look_only
        local out = {}
        for _, m in ipairs(markers) do
            local vx, vy, vz = m[1] - px, m[2] - py, m[3] - pz
            local t1, t2, t3 = 2 * (uy * vz - uz * vy), 2 * (uz * vx - ux * vz), 2 * (ux * vy - uy * vx)
            local cx = vx + qw * t1 + (uy * t3 - uz * t2)
            local cy = vy + qw * t2 + (uz * t1 - ux * t3)
            local cz = vz + qw * t3 + (ux * t2 - uy * t1)
            local depth = -cz
            if depth > 0.1 then
                local nx, ny = cx / (depth * tx), cy / (depth * ty)
                local visible = math.abs(nx) <= 1 and math.abs(ny) <= 1
                if visible and look_only and not m[6] then
                    visible = math.abs(nx) <= LOOK_X * 2 and math.abs(ny) <= LOOK_Y * 2
                end
                if visible then
                    out[#out + 1] = { (nx + 1) * 0.5 * w, (1 - ny) * 0.5 * h, m[4], m[5] }
                end
            end
        end
        ctx.marker_screen = out
    end

    local project_failures = 0
    local function safe_update()
        local ok, e = pcall(update)
        if not ok then
            ctx.err("marqueurs : " .. tostring(e))
            markers = {}
            next_update = os.clock() + 5
        end
        if project_failures < 20 then
            ok, e = pcall(project)
            if not ok then
                project_failures = project_failures + 1
                ctx.marker_screen = {}
                if project_failures == 1 or project_failures == 20 then
                    ctx.err("position des marqueurs : " .. tostring(e))
                end
            else
                project_failures = 0
            end
        end
    end

    ctx.on_tick("markers", safe_update)

    local F_KEY = 0x46
    local f_was = false
    re.on_frame(function()
        local down = try(function() return reframework:is_key_down(F_KEY) end) == true
        local pressed = down and not f_was
        f_was = down
        if not pressed then return end
        local t = ctx.f_pickup
        if not t or not t.loc or ctx.is_checked(t.id) then return end
        if interact_busy() then return end
        local ok, sent = pcall(ctx.force_check, t.loc, "touche F", t.pos)
        if ok and sent and t.entry then hide_if_taken(t.id, t.entry) end
    end)
end
