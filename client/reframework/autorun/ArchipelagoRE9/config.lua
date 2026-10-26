return function(ctx)
    ctx.TAG            = "[RE9 AP]"
    ctx.GAME_NAME      = "Resident Evil Requiem"
    ctx.ITEMS_HANDLING = 0x7               -- tous les objets, y compris les nôtres
    ctx.CLIENT_TAGS    = { "AP" }
    ctx.CLIENT_VERSION = { 0, 6, 2 }

    ctx.DATA_DIR = "ArchipelagoRE9\\"
    ctx.FILES = {
        connection   = ctx.DATA_DIR .. "ap_connection.json",
        ids          = ctx.DATA_DIR .. "re9_ap_ids.json",
        item_list    = ctx.DATA_DIR .. "item_list.json",
        session      = ctx.DATA_DIR .. "session_state.json",
        last_pickups = ctx.DATA_DIR .. "last_pickups.json",
        version      = ctx.DATA_DIR .. "client_version.json",
        pickup_flags = ctx.DATA_DIR .. "pickup_event_flags.json",
        -- Pont Python (websockets officiel, permessage-deflate)
        bridge_status = ctx.DATA_DIR .. "bridge_status.json",
        bridge_inbox  = ctx.DATA_DIR .. "bridge_inbox.jsonl",
        bridge_cmd    = ctx.DATA_DIR .. "bridge_cmd.jsonl",
        bridge_offset = ctx.DATA_DIR .. "bridge_inbox_offset.json",
    }

    do
        local v = json.load_file(ctx.FILES.version)
        if type(v) ~= "table" then v = {} end
        -- version = numéro de patch client ; label = affichage ; apworld = world_version attendu
        ctx.CLIENT_BUILD = type(v.version) == "string" and v.version ~= "" and v.version or "dev"
        ctx.MOD_VERSION = type(v.label) == "string" and v.label ~= "" and v.label or ctx.CLIENT_BUILD
        ctx.EXPECTED_APWORLD = type(v.apworld) == "string" and v.apworld ~= "" and v.apworld
            or type(v.apworld_version) == "string" and v.apworld_version ~= "" and v.apworld_version
            or ""
    end

    -- Le mesh du spot reste celui de Capcom. Pas de rewrite vers l'objet AP ni l'injecteur.
    ctx.AP_VISUAL_ENABLED = false
    ctx.AP_PLACEHOLDER_GID = "it50_00_018"

    -- index du coffre dans app.InventoryManager._Inventories
    ctx.BOX_INVENTORY_INDEX = 2

    -- reçus pendant Leon : mis en file, livrés au coffre au retour sur Grace
    ctx.HOLD_ITEMS_FOR_LEON = true
    ctx.CHARACTER_PATTERNS = {
        leon  = { "leon", "^cp_a0" },
        grace = { "grace", "^cp_a1" },
    }

    -- User01 = inventaire de Leon, il refuse les objets clés de Grace
    ctx.GRACE_HAND_USER = "User00"
    ctx.received_to_hand = true

    -- tolérances en mètres, réglées en jeu
    ctx.KEY_POS_TOLERANCE  = 1.5
    ctx.ITEM_POS_TOLERANCE = 1.0
    ctx.EXACT_KEY_MAX_DIST = 5.0   -- les ctx:: changent d'une session à l'autre

    -- drops et objets de script, jamais des checks
    ctx.IGNORED_FOLDER_PREFIXES = { "AppResident/Instance" }

    -- emplacements laissés vanilla (pas un check, même si la seed les liste)
    -- 7091021 : fusible st30_001, boîte du début. L'autre fusible (7091022) reste un check.
    -- 7091024 : tournevis st30_004.
    ctx.VANILLA_LOCATIONS = {
        ["7091021"] = true,
        ["7091024"] = true,
    }

    -- objet d'origine laissé sinon le jeu gèle / softlock
    -- Blood Collector : tutoriel de récolte ; Fuse : ouverture de la boîte à fusibles
    -- laisser l'objet d'origine au ramassage local (check AP part quand même) pour poser le flag
    -- check AP part ; objet+flag vanilla laissés (briquet / fusible / gimmick)
    ctx.NEVER_BLOCK_ITEMS = {
        it99_06_000 = true,  -- Blood Collector
        it60_00_040 = true,  -- Fuse
        it60_00_038 = true,  -- Joint Plug (mesh = connecteur dans le panneau)
        it99_05_000 = true,  -- Lighter
        it99_05_001 = true,  -- Flashlight
        it99_05_002 = true,  -- Flag inconnu
        it99_50_011 = true,  -- Override Manual
        it60_00_039 = true,  -- Screwdriver
    }

    -- une seule règle : table + Flag + gimmick it60_ (fusible / connecteur)
    -- folder_path optionnel (detector) ; sans dossier → table + Flag seulement
    function ctx.should_keep_vanilla(item_id, folder_path)
        if type(item_id) ~= "string" or item_id == "" then return false end
        if ctx.NEVER_BLOCK_ITEMS[item_id] then return true end
        if item_id == "it60_00_063" or item_id == "it99_50_006" then return false end
        local known = ctx.items_by_id and ctx.items_by_id[item_id]
        if known and known.category == "KeyItem" then return false end
        if known and known.category == "Flag" then return true end
        if type(folder_path) == "string" and folder_path:find("Gimmick", 1, true) then
            if item_id == "it60_00_040" or item_id:find("^it60_", 1) then return true end
        end
        return false
    end

    -- toujours en inventaire Grace (pas au coffre) : usage / ciné refusés depuis le coffre
    ctx.ALWAYS_HAND_ITEMS = {
        it60_00_013 = true,  -- Cherub Key
        it60_00_045 = true,  -- West Wing Keycard
        it60_00_046 = true,  -- East Wing Keycard
        it60_00_055 = true,  -- ID Wristband (Level 1)
        it60_00_068 = true,  -- ID Wristband (Level 2)
        it60_00_063 = true,  -- Corrosive
        it60_00_080 = true,  -- Emergency Exit Key
        it60_00_076 = true,  -- Wire Cutters
        it60_00_089 = true,  -- Old Key
        it60_00_040 = true,  -- Fuse
        it60_00_038 = true,  -- Joint Plug
        it60_00_039 = true,  -- Screwdriver
        it99_05_000 = true,  -- Lighter
        it99_05_001 = true,  -- Flashlight
        it99_50_011 = true,  -- Override Manual
    }

    -- les autres catégories restent au coffre, pas testées en jeu
    ctx.SWAP_CATEGORIES = { Ammo = true, Heal = true, Material = true, SubWeapon = true, Other = true, KeyItem = true }

    ctx.ZERO_GUID = "00000000-0000-0000-0000-000000000000"

    function ctx.info(msg)  log.info(ctx.TAG .. " " .. tostring(msg));  print(ctx.TAG .. " " .. tostring(msg)) end
    function ctx.warn(msg)  log.warn(ctx.TAG .. " " .. tostring(msg));  print(ctx.TAG .. " [!] " .. tostring(msg)) end
    function ctx.err(msg)   log.error(ctx.TAG .. " " .. tostring(msg)); print(ctx.TAG .. " [ERREUR] " .. tostring(msg)) end

    function ctx.try(fn)
        local ok, v = pcall(fn)
        if ok and v ~= nil then return v end
        return nil
    end

    -- les nombres JSON peuvent arriver en flottants
    function ctx.id_str(v)
        local n = tonumber(v)
        if n == nil then return nil end
        return string.format("%d", math.floor(n))
    end

    function ctx.count_table(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end

    ctx.messages = {}
    ctx.MAX_MESSAGES = 40
    -- flags AP : 1 progression, 2 utile, 4 piège
    function ctx.push_message(text, color, kind, flags, card)
        table.insert(ctx.messages, 1, { text = tostring(text), color = color or 0xFFFFFFFF, t = os.clock(),
            kind = kind or "system", flags = flags, time = os.date("%H:%M"), card = card })
        if #ctx.messages > ctx.MAX_MESSAGES then ctx.messages[ctx.MAX_MESSAGES + 1] = nil end
    end

    -- affichage seulement, le serveur ne connaît que le nom complet
    function ctx.display_name(text)
        return (tostring(text or ""):gsub("%s*%(it%d%d_%d%d_%d%d%d%)", ""))
    end

    ctx.console = {}
    function ctx.log_console(text, color)
        table.insert(ctx.console, 1, { text = tostring(text), color = color or 0xFFFFFFFF, time = os.date("%H:%M") })
        if #ctx.console > 200 then ctx.console[201] = nil end
    end

    ctx.received_log = {}
    function ctx.log_received(name, from, progression)
        table.insert(ctx.received_log, 1, { name = tostring(name), from = from or "", progression = progression, t = os.date("%H:%M") })
        if #ctx.received_log > 200 then ctx.received_log[201] = nil end
    end

    -- ABGR (0xAABBGGRR)
    ctx.COLORS = {
        ok       = 0xFF73D973,
        warn     = 0xFF60C0FF,
        bad      = 0xFF6B6BEB,
        info     = 0xFFFFFFFF,
        item     = 0xFFE88B6D,   -- bleu
        progress = 0xFF4AB2E0,   -- or
        muted    = 0xFFB3B3B3,
    }
end
