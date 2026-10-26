-- source unique : ordre des scènes, chapitres AP, labels, teleports debug

return function(ctx)
    local try = ctx.try

    local SCENE_ORDER = {
        "Chap1_00", "Chap1_01", "Chap1_10",
        "Chap3_01", "Chap3_10", "Chap3_02", "Chap3_20",
        "Chap3_0304", "Chap3_03", "Chap3_324", "Chap3_04",
        "Chap3_40", "Chap3_05", "Chap3_06",
        "Chap4_00", "Chap4_1020", "Chap4_10", "Chap4_20", "Chap4_30",
        "Chap4_4050", "Chap4_40", "FF_02", "Chap4_50",
        "Chap5_10", "Chap5_02", "Chap5_03", "Chap5_04", "Chap5_05",
    }

    local SCENE_CH = {
        Chap1_00 = 1, Chap1_01 = 1, Chap1_10 = 2,
        Chap3_01 = 3, Chap3_10 = 4, Chap3_02 = 5, Chap3_20 = 6,
        Chap3_0304 = 7, Chap3_03 = 7, Chap3_324 = 9, Chap3_04 = 8,
        Chap3_40 = 10, Chap3_05 = 11, Chap3_06 = 12,
        Chap4_00 = 13, Chap4_1020 = 13, Chap4_10 = 13, Chap4_20 = 13, Chap4_30 = 14,
        Chap4_4050 = 15, Chap4_40 = 15, FF_02 = 16, Chap4_50 = 17,
        Chap5_10 = 18, Chap5_02 = 19, Chap5_03 = 20, Chap5_04 = 20, Chap5_05 = 20,
    }

    local CHAPTER_NAMES = {
        [1] = "Wrenwood Hotel", [2] = "After Hotel",
        [3] = "Care Center - Room 203", [4] = "Care Center - Main Hall",
        [5] = "Care Center", [6] = "Care Center - Attic", [7] = "Care Center",
        [8] = "Courtyard (Grace)", [9] = "Courtyard", [10] = "Courtyard (Leon)",
        [11] = "Water Treatment", [12] = "Water Treatment",
        [13] = "East Raccoon", [14] = "Highway", [15] = "Raccoon City Center",
        [16] = "Orphanage", [17] = "Blackthorn Station",
        [18] = "ARK (Leon)", [19] = "ARK (Grace)", [20] = "Hope",
    }

    -- { n, scene, label, x?, y?, z?, stage? } — coords = machine à écrire
    local DBG_CH = {
        { 1, "Chap1_00", "Wrenwood Hotel" },
        { 2, "Chap1_10", "After Hotel", -50.22, 0.50, -42.33 },
        { 3, "Chap3_01", "Care Center Room 203", 17.79, 8.02, 16.59, "st30_003" },
        { 4, "Chap3_10", "Care Center Main Hall", 31.82, 3.99, 67.24 },
        { 5, "Chap3_02", "Care Center", -7.77, 2.54, 44.52, "st30_006" },
        { 6, "Chap3_20", "Care Center Attic" },
        { 7, "Chap3_03", "Care Center", -2.42, -8.12, 45.02, "st30_021" },
        { 8, "Chap3_04", "Courtyard (Grace)", -27.83, -26.15, -49.71, "st30_084" },
        { 9, "Chap3_324", "Courtyard" },
        { 10, "Chap3_40", "Courtyard (Leon)" },
        { 11, "Chap3_05", "Water Treatment", 189.17, -5.20, -14.37, "st30_093" },
        { 12, "Chap3_06", "Water Treatment" },
        { 13, "Chap4_20", "East Raccoon", 32.58, -2.43, -276.54, "st40_210" },
        { 14, "Chap4_30", "Highway" },
        { 15, "Chap4_40", "Raccoon City Center", -13.97, -0.04, -105.70, "st40_471" },
        { 16, "FF_02", "Orphanage" },
        { 17, "Chap4_50", "Blackthorn Station" },
        { 18, "Chap5_10", "ARK (Leon)", -128.80, 57.78, 21.44, "st50_003" },
        { 19, "Chap5_02", "ARK (Grace)", 7.55, 14.00, -60.76, "st50_038" },
        { 20, "Chap5_03", "Hope" },
    }

    local SCENE_INDEX, CHAPTER_START = {}, {}
    for i, s in ipairs(SCENE_ORDER) do SCENE_INDEX[s] = i end
    for _, s in ipairs(SCENE_ORDER) do
        local n = SCENE_CH[s]
        if n and not CHAPTER_START[n] then CHAPTER_START[n] = s end
    end

    local DBG_LABELS = {}
    for i, e in ipairs(DBG_CH) do
        DBG_LABELS[i] = string.format("Ch%d — %s", e[1], e[3])
    end

    ctx.scenes = {
        ORDER = SCENE_ORDER,
        CH = SCENE_CH,
        INDEX = SCENE_INDEX,
        CHAPTER_NAMES = CHAPTER_NAMES,
        CHAPTER_START = CHAPTER_START,
        DBG_CH = DBG_CH,
        DBG_LABELS = DBG_LABELS,
        NEW_GAME = "Chap1_00",
    }

    function ctx.current_scene()
        local mgr = sdk.get_managed_singleton("app.MainGameFlowManager")
        local ctrl = mgr and try(function() return mgr:get_field("_CurrentController") end)
        local name = ctrl and try(function() return ctrl:get_field("_CurrentMainSceneName") end)
        return name and tostring(name) or ""
    end

    function ctx.scene_index(scene)
        return SCENE_INDEX[scene or ""] or 0
    end

    function ctx.ap_chapter_num(scene)
        return SCENE_CH[scene or ctx.current_scene()]
    end

    function ctx.ap_chapter(scene)
        local n = ctx.ap_chapter_num(scene)
        return n and ("Ch" .. n) or nil
    end

    function ctx.chapter_title(ch)
        local n = tonumber(tostring(ch or ""):match("^Ch?(%d+)$")) or tonumber(ch)
        return n and CHAPTER_NAMES[n] or nil
    end

    -- préfixe stage attendu (scan offline) : st10 hôtel, st30 care, st40 ville, st50 ARK
    local STAGE_PREFIX_BY_CH = {
        [1] = "st10", [2] = "st10",
        [3] = "st30", [4] = "st30", [5] = "st30", [6] = "st30", [7] = "st30",
        [8] = "st30", [9] = "st30", [10] = "st30", [11] = "st30", [12] = "st30",
        [13] = "st40", [14] = "st40", [15] = "st40", [16] = "st40", [17] = "st40",
        [18] = "st50", [19] = "st50", [20] = "st50",
    }

    function ctx.stage_matches_chapter(stage, ch)
        stage = tostring(stage or "")
        local n = tonumber(tostring(ch or ""):match("^Ch?(%d+)$")) or tonumber(ch)
        local pref = n and STAGE_PREFIX_BY_CH[n]
        if not pref or stage == "" then return true end
        return stage:sub(1, #pref) == pref
    end

    -- set de "ChN" entre from (inclus) et target (exclu), hors chapitre cible
    function ctx.chapters_between(from_scene, target_scene)
        local stop = SCENE_CH[target_scene]
        local from_i = SCENE_INDEX[from_scene]
        local to_i = SCENE_INDEX[target_scene]
        local chapters = {}
        if not (stop and from_i and to_i) then return chapters end
        for i = from_i, to_i - 1 do
            local n = SCENE_CH[SCENE_ORDER[i]]
            if n and n ~= stop then chapters["Ch" .. n] = true end
        end
        return chapters
    end

    function ctx.scenes_between(from_scene, target_scene)
        local out, a, b = {}, SCENE_INDEX[from_scene], SCENE_INDEX[target_scene]
        if a and b then
            for i = a, b - 1 do out[#out + 1] = SCENE_ORDER[i] end
        end
        return out
    end
end
