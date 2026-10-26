-- la police imgui n'a pas les symboles Unicode, ASCII seulement

return function(ctx)
    local theme = ctx.theme
    local T, TF = ctx.T, ctx.TF
    local PREFS_FILE = ctx.DATA_DIR .. "ui_settings.json"

    local MARGIN_X, MARGIN_Y, GAP_Y = 28, 28, 10
    local HEADER_HEIGHT, HEADER_LINE, HEADER_MIN_WIDTH, HEADER_PAD = 38, 18, 320, 20
    local TOAST_MIN_WIDTH, TOAST_PAD, TOAST_PAD_Y = 300, 14, 10
    local TOAST_TITLE_H, TOAST_LINE_H, TOAST_TIMER_H, TOAST_TITLE_SCALE = 17, 19, 3, 0.85
    local TOAST_MAIN_H, TOAST_MAIN_SCALE = 25, 1.2
    local TOAST_BAR, TOAST_BAR_GAP, TOAST_SLIDE = 4, 12, 60
    local TOAST_MS, FADE_IN_MS, FADE_OUT_MS, MAX_TOASTS = 6000, 260, 650, 4
    local TOAST_BACKDROP = 0.82
    local OVERLAY_FLAGS = 43 + 256 + 786944 + 4096 + 8192

    local C = {
        white     = { 1.0, 1.0, 1.0, 1.0 },
        progress  = { 0.878, 0.698, 0.290, 1.0 },
        useful    = { 0.427, 0.545, 0.910, 1.0 },
        connected = { 0.45, 0.85, 0.45, 1.0 },
        error     = { 0.92, 0.42, 0.42, 1.0 },
        grey      = { 0.7, 0.7, 0.7, 1.0 },
        area      = { 0.55, 0.82, 0.70, 1.0 },
        shadow    = { 0.0, 0.0, 0.0, 0.75 },
        gold      = { 1.0, 0.84, 0.35, 1.0 },
    }
    local KIND_PREFIX = { item = "<-", check = "->", goal = "*", error = "!" }

    local prefs = {
        show_toasts = true, show_hud = true, show_window = true, dev_tools = false, tab = 1, swap_items = true, received_to_hand = true,
        redeliver_on_death = true,
        main_rgb = theme.DEFAULT_MAIN_RGB, progress_rgb = theme.DEFAULT_PROGRESS_RGB,
    }
    local function save_prefs() pcall(json.dump_file, PREFS_FILE, prefs, 4) end
    function ctx.ui_dev_tools_enabled()
        return prefs.dev_tools == true
    end
    local function valid_rgb(v)
        return type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number"
    end
    do
        local saved = json.load_file(PREFS_FILE)
        if type(saved) == "table" then
            for k, v in pairs(saved) do
                if prefs[k] ~= nil and type(v) == type(prefs[k]) then
                    if type(v) ~= "table" or valid_rgb(v) then prefs[k] = v end
                end
            end
        else
            save_prefs()
        end
    end
    theme.apply_colors(prefs.main_rgb, prefs.progress_rgb)
    ctx.swap_own_items = prefs.swap_items
    ctx.received_to_hand = prefs.received_to_hand
    if ctx.redeliver_on_death ~= nil then ctx.redeliver_on_death = prefs.redeliver_on_death end

    local edit = { server = nil, slot = nil, password = nil, show_password = false }
    local command_text, hint_item, hint_location = "", "", ""

    local last_command, last_command_at = nil, -10
    local COMMAND_REPEAT_SECONDS = 2
    local force_ch_confirm = nil -- { name, expires }

    local function display_size()
        local ok, size = pcall(imgui.get_display_size)
        if ok and size and (size.x or 0) > 0 then return size.x, size.y end
        return 1920, 1080
    end

    local function text_width(text)
        local ok, size = pcall(imgui.calc_text_size, tostring(text))
        if ok and size and size.x then return size.x end
        return #tostring(text) * 7
    end

    local function strip_chapter(name, chapter)
        name = tostring(name or "")
        if chapter and chapter ~= "" and name:sub(1, #chapter) == chapter then
            name = name:sub(#chapter + 1):gsub("^%s+", "")
        end
        return name
    end

    local progress = { t = -10, done = 0, total = 0, chapters = {}, by_name = {} }
    local function refresh_progress()
        local now = os.clock()
        if now - progress.t < 1.0 then return progress end
        progress.t = now
        local per, done, total = {}, 0, 0
        for id in pairs(ctx.session.active or {}) do
            local loc = ctx.locations[id]
            local ch = loc and loc.chapter or "?"
            local c = per[ch]
            if not c then
                c = { name = ch, done = 0, total = 0, rows = {} }
                per[ch] = c
            end
            local checked = ctx.session.checked[id] == true
            c.total = c.total + 1
            total = total + 1
            if checked then
                c.done = c.done + 1
                done = done + 1
            end
            c.rows[#c.rows + 1] = { id = id, name = strip_chapter(loc and loc.name or id, ch), checked = checked }
        end
        local list, seen = {}, {}
        for _, ch in ipairs(ctx.chapters or {}) do
            if per[ch] then
                list[#list + 1] = per[ch]
                seen[ch] = true
            end
        end
        for ch, c in pairs(per) do
            if not seen[ch] then list[#list + 1] = c end
        end
        for _, c in ipairs(list) do
            table.sort(c.rows, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
        end
        progress.done, progress.total, progress.chapters, progress.by_name = done, total, list, per
        return progress
    end

    function ctx.ui_progress_by_name()
        return refresh_progress().by_name
    end

    -- batch : 1 save + 1 flush (pas force_check×N → freeze / session 150ko à chaque check)
    function ctx.force_chapter_remaining(ch_name)
        local n = 0
        for id in pairs(ctx.session.active or {}) do
            local loc = ctx.locations[id]
            local k = loc and loc.chapter == ch_name and ctx.id_str(id)
            if k and not ctx.session.checked[k] then
                ctx.session.checked[k] = true
                n = n + 1
                if ctx.fire_pickup_event_flags then
                    pcall(ctx.fire_pickup_event_flags, loc.id, "forcé chapitre")
                end
            end
        end
        if n > 0 then
            ctx.save_session()
            ctx.checks_dirty = true
            if ctx.flush_location_checks then ctx.flush_location_checks() end
            if ctx.refresh_markers then pcall(ctx.refresh_markers) end
            progress.t = -10
        end
        return n
    end

    local function status_info()
        local st = ctx.ap_state
        if not st then return T("Client AP non chargé"), C.error, theme.ERROR end
        local text = ctx.ap_status_text and ctx.ap_status_text() or tostring(st.status_text)
        if st.status == "connected" then return text, C.connected, theme.DONE end
        if st.status == "connecting" then return text, C.progress, theme.WARN end
        if st.status == "idle" then return text, C.grey, theme.MUTED end
        return text, C.error, theme.ERROR
    end

    local function faded(c, alpha)
        if alpha >= 0.999 then return c end
        return { c[1], c[2], c[3], (c[4] or 1.0) * alpha }
    end

    local function overlay_text(text, color, alpha)
        alpha = alpha or 1.0
        text = theme.plain(text)
        local okc, cur = pcall(imgui.get_cursor_pos)
        if okc and cur then
            if pcall(imgui.set_cursor_pos, Vector2f.new(cur.x + 1, cur.y + 1)) then
                local n = theme.push_color(0, faded(C.shadow, alpha))
                imgui.text(text)
                theme.pop_colors(n)
                pcall(imgui.set_cursor_pos, cur)
            end
        end
        local n = theme.push_color(0, faded(color or C.white, alpha))
        imgui.text(text)
        theme.pop_colors(n)
    end

    local function centered_overlay_text(text, color, window_width, alpha)
        local okc, cur = pcall(imgui.get_cursor_pos)
        if okc and cur then
            local x = math.max(18, math.floor((window_width - text_width(text)) * 0.5))
            pcall(imgui.set_cursor_pos, Vector2f.new(x, cur.y))
        end
        overlay_text(text, color, alpha)
    end

    local function push_overlay_style(backdrop, edge_rgb)
        local colors, vars = 0, 0
        if backdrop and backdrop > 0 then
            local edge = edge_rgb or theme.MAIN_RGB
            colors = colors + theme.push_color(2, { 0.06, 0.045, 0.05, backdrop })
            colors = colors + theme.push_color(5, { edge[1], edge[2], edge[3], backdrop * 0.8 })
            vars = theme.push_var(3, 8.0) + theme.push_var(4, 1.0)
        else
            colors = colors + theme.push_color(2, { 0, 0, 0, 0 }) + theme.push_color(5, { 0, 0, 0, 0 })
        end
        colors = colors + theme.push_color(6, { 0, 0, 0, 0 })
        return { colors = colors, vars = vars }
    end
    local function pop_overlay_style(h)
        theme.pop_colors(h.colors)
        theme.pop_vars(h.vars)
    end

    local function anchor_x(width)
        local sw = display_size()
        return math.max(MARGIN_X, sw - width - MARGIN_X)
    end

    local function pretty_zone(raw)
        raw = tostring(raw or "")
        if raw == "" or raw == "Area" then return nil end
        if raw:match("^Chap%d") or raw:match("^Item") then return nil end
        local room = raw:match("^st%d+_%d+%s+(.+)$")
        if raw:match("^st%d+_%d+$") then return nil end
        raw = room or raw
        raw = raw:gsub("%s+st%d+_%d+$", "")
        raw = raw:gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
        if raw == "" then return nil end
        return raw
    end

    -- stage (st30_031) → chapitre + pièce, d'après les checks. La scène AP reste chargée
    -- trop longtemps et affiche le mauvais chapitre.
    local stage_index
    local function place_for_stage(stage)
        stage = tostring(stage or "")
        if stage == "" then return nil end
        if not stage_index then
            if not (ctx.locations and next(ctx.locations)) then return nil end
            local votes = {}
            for _, loc in pairs(ctx.locations) do
                local stages = {}
                local zone = tostring(loc.zone or "")
                local zstage = zone:match("^(st%d+_%d+)")
                if zstage then stages[zstage] = true end
                for _, k in ipairs(loc.keys or {}) do
                    local st = tostring(k):match("(st%d+_%d+)")
                    if st then stages[st] = true end
                end
                local room = zone:match("^st%d+_%d+%s+(.+)$")
                for st in pairs(stages) do
                    local e = votes[st]
                    if not e then
                        e = { chapters = {}, room = nil }
                        votes[st] = e
                    end
                    local ch = loc.chapter
                    if type(ch) == "string" and ch ~= "" then
                        e.chapters[ch] = (e.chapters[ch] or 0) + 1
                    end
                    if room and room ~= "" and (not e.room or #room > #e.room) then
                        e.room = room
                    end
                end
            end
            stage_index = {}
            for st, e in pairs(votes) do
                local best, n = nil, 0
                for ch, c in pairs(e.chapters) do
                    if c > n then best, n = ch, c end
                end
                stage_index[st] = { chapter = best, room = e.room }
            end
        end
        return stage_index[stage]
    end

    local function hud_chapter()
        local stage = ctx.current_stage or ctx.last_stage
        local info = place_for_stage(stage)
        local scene = ctx.ap_chapter and ctx.ap_chapter()
        if info and info.chapter and info.chapter ~= "" then
            if not scene or scene == "" or info.chapter ~= scene then
                return info.chapter
            end
        end
        if scene and scene ~= "" then return scene end
        return ctx.current_chapter or ctx.last_chapter
    end

    local function header_place(ch)
        ch = tostring(ch or "")
        local title = ctx.chapter_title and ctx.chapter_title(ch) or nil
        local stage = ctx.current_stage or ctx.last_stage
        local info = place_for_stage(stage)
        local room = info and pretty_zone(info.room) or nil
        if not room then room = pretty_zone(ctx.current_zone) end
        local left = ch
        if title and title ~= "" then left = ch .. " " .. title end
        if room and room ~= "" and room ~= title then
            return left .. " | " .. room
        end
        return left
    end

    local function header_lines()
        local lines = {}
        local p = refresh_progress()
        if ctx.has_slot_data() and p.total > 0 then
            local ch = hud_chapter()
            local c = ch and p.by_name[ch]
            local place = header_place(ch)
            local text
            if c then
                if c.done >= c.total then
                    text = TF("%s | Les %d checks faits", place, c.total)
                else
                    text = TF("%s | %d/%d checks", place, c.done, c.total)
                end
                text = text .. TF(" | Total %d/%d", p.done, p.total)
            else
                text = TF("Resident Evil Requiem | %d/%d checks", p.done, p.total)
            end
            lines[#lines + 1] = { text, C.white }
        end
        local status, color = status_info()
        lines[#lines + 1] = { "AP : " .. status, color }
        if ctx.progression_near then
            lines[#lines + 1] = { T("Objet de progression à proximité"), C.progress }
        end
        if ctx.session and ctx.session.grace_tracker and ctx.current_character and ctx.current_character() == "grace" then
            lines[#lines + 1] = { TF("Crédits de Grace : %d", ctx.session.grace_credits or 0), C.gold }
        end
        local pending = ctx.ap_pending_items and ctx.ap_pending_items() or 0
        if pending > 0 then
            local held = ctx.ap_held_for_grace and ctx.ap_held_for_grace()
            lines[#lines + 1] = { TF(held and "%d objet(s) en attente pour le coffre de Grace"
                or "%d objet(s) en attente pour le coffre", pending), C.grey }
        end
        return lines
    end

    local header_height = 0
    local function draw_header()
        header_height = 0
        if not prefs.show_hud then return end
        local lines = header_lines()
        local width = HEADER_MIN_WIDTH
        for _, l in ipairs(lines) do width = math.max(width, text_width(l[1]) + HEADER_PAD * 2) end
        local height = HEADER_HEIGHT + (#lines - 1) * HEADER_LINE
        imgui.set_next_window_pos(Vector2f.new(anchor_x(width), MARGIN_Y), 1)
        imgui.set_next_window_size(Vector2f.new(width, height), 1)
        pcall(imgui.set_next_window_bg_alpha, 0.0)
        local style = push_overlay_style(0)
        if imgui.begin_window("##re9ap_header", true, OVERLAY_FLAGS) then
            for _, l in ipairs(lines) do centered_overlay_text(l[1], l[2], width) end
            imgui.end_window()
        end
        pop_overlay_style(style)
        header_height = height
    end

    local function toast_header(m)
        local flags = m.flags
        local rarity, rarity_color = nil, nil
        if (m.kind == "item" or m.kind == "check") and flags then
            if (flags & 1) ~= 0 then rarity, rarity_color = T("Progression"), C.progress
            elseif (flags & 4) ~= 0 then rarity, rarity_color = T("Piège"), C.error
            elseif (flags & 2) ~= 0 then rarity, rarity_color = T("Utile"), C.useful end
        end
        local label, color
        if m.kind == "item" then label, color = T("Objet reçu"), C.connected
        elseif m.kind == "check" then label, color = T("Check trouvé"), C.area
        elseif m.kind == "goal" then label, color = T("Victoire"), C.gold
        elseif m.kind == "error" then label, color = T("Attention"), C.error
        else label, color = T("Archipelago"), { theme.MAIN_RGB[1], theme.MAIN_RGB[2], theme.MAIN_RGB[3], 1.0 } end
        if rarity then label, color = label .. "  -  " .. rarity, rarity_color end
        return KIND_PREFIX[m.kind] and (KIND_PREFIX[m.kind] .. "  " .. label) or label, color, rarity ~= nil
    end

    local REDUNDANT_PREFIXES = { "Reçu : ", "Received: ", "Check : ", "Check: " }
    local function toast_body(text)
        for _, p in ipairs(REDUNDANT_PREFIXES) do
            if text:sub(1, #p) == p then return text:sub(#p + 1) end
        end
        return text
    end

    local function ease_out(x) return 1 - (1 - x) * (1 - x) * (1 - x) end

    local function draw_toasts()
        if not prefs.show_toasts or #ctx.messages == 0 then return end
        local now_ms = os.clock() * 1000
        local y = MARGIN_Y + header_height + GAP_Y
        local connected = ctx.ap_is_connected and ctx.ap_is_connected()
        local shown = 0
        for i, m in ipairs(ctx.messages) do
            if shown >= MAX_TOASTS then break end
            local age = now_ms - m.t * 1000
            if age < TOAST_MS then
                local alpha, slide = 1.0, 0
                if age < FADE_IN_MS then
                    alpha = age / FADE_IN_MS
                    slide = (1 - ease_out(alpha)) * TOAST_SLIDE
                end
                local remaining = TOAST_MS - age
                if remaining < FADE_OUT_MS then alpha = math.min(alpha, remaining / FADE_OUT_MS) end
                alpha = math.max(0, math.min(1, alpha))

                local header, accent, rare = toast_header(m)
                local card = m.card
                local body = card and card.title or toast_body(m.text)
                local body_scale = card and TOAST_MAIN_SCALE or 1.0
                local body_h = card and TOAST_MAIN_H or TOAST_LINE_H
                local body_color = card and (rare and accent or C.white) or theme.u32_to_rgba(m.color)
                local sub = card and card.sub or nil
                local detail = nil
                if m.kind == "check" and not connected then
                    detail = T("Serveur AP déconnecté : check gardé, envoyé à la reconnexion")
                end
                local stamp = m.time or ""
                local stamp_w = text_width(stamp) * TOAST_TITLE_SCALE
                local inner = math.max((text_width(header) + text_width(stamp) + 24) * TOAST_TITLE_SCALE,
                    text_width(body) * body_scale, sub and text_width(sub) or 0, detail and text_width(detail) or 0)
                local width = math.max(TOAST_MIN_WIDTH, inner + TOAST_PAD * 2 + TOAST_BAR + TOAST_BAR_GAP)
                inner = width - TOAST_PAD * 2 - TOAST_BAR - TOAST_BAR_GAP
                local height = TOAST_PAD_Y * 2 + TOAST_TITLE_H + body_h + (sub and TOAST_LINE_H or 0)
                    + (detail and TOAST_LINE_H or 0) + TOAST_TIMER_H + 6
                imgui.set_next_window_pos(Vector2f.new(anchor_x(width) + slide, y), 1)
                imgui.set_next_window_size(Vector2f.new(width, height), 1)
                local backdrop = TOAST_BACKDROP * alpha
                pcall(imgui.set_next_window_bg_alpha, backdrop)
                local style = push_overlay_style(backdrop, accent)
                local vars = theme.push_var(2, { TOAST_PAD, TOAST_PAD_Y }) + theme.push_var(14, { 0.0, 2.0 })
                if imgui.begin_window("##re9ap_toast" .. i, true, OVERLAY_FLAGS) then
                    local bar_h = height - TOAST_PAD_Y * 2
                    local bar_colors = theme.push_color(21, faded(accent, alpha)) + theme.push_color(22, faded(accent, alpha))
                        + theme.push_color(23, faded(accent, alpha))
                    local bar_vars = theme.push_var(12, 2.0)
                    local has_bar = pcall(imgui.button, "##toast_bar" .. i, Vector2f.new(TOAST_BAR, bar_h))
                    theme.pop_vars(bar_vars)
                    theme.pop_colors(bar_colors)
                    local text_x = has_bar and (TOAST_PAD + TOAST_BAR + TOAST_BAR_GAP) or TOAST_PAD
                    local line_y = TOAST_PAD_Y
                    local function at_line(h)
                        pcall(imgui.set_cursor_pos, Vector2f.new(text_x, line_y))
                        line_y = line_y + h
                    end
                    pcall(imgui.set_window_font_scale, TOAST_TITLE_SCALE)
                    if stamp ~= "" then
                        local sx = text_x + inner - stamp_w
                        pcall(imgui.set_cursor_pos, Vector2f.new(sx, line_y))
                        overlay_text(stamp, C.grey, alpha * 0.8)
                    end
                    at_line(TOAST_TITLE_H)
                    overlay_text(header, accent, alpha * 0.95)
                    pcall(imgui.set_window_font_scale, body_scale)
                    at_line(body_h)
                    overlay_text(body, body_color, alpha)
                    pcall(imgui.set_window_font_scale, 1.0)
                    if sub then
                        at_line(TOAST_LINE_H)
                        overlay_text(sub, C.grey, alpha)
                    end
                    if detail then
                        at_line(TOAST_LINE_H)
                        overlay_text(detail, C.progress, alpha)
                    end
                    pcall(imgui.set_cursor_pos, Vector2f.new(text_x, line_y + 4))
                    local timer_colors = theme.push_color(7, { 1, 1, 1, 0.08 * alpha })
                    for _, index in ipairs({ 42, 43 }) do
                        timer_colors = timer_colors + theme.push_color(index, faded({ accent[1], accent[2], accent[3], 0.85 }, alpha))
                    end
                    local timer_vars = theme.push_var(12, 2.0)
                    pcall(imgui.progress_bar, math.max(0, remaining / TOAST_MS), Vector2f.new(inner, TOAST_TIMER_H), "")
                    theme.pop_vars(timer_vars)
                    theme.pop_colors(timer_colors)
                    imgui.end_window()
                end
                theme.pop_vars(vars)
                pop_overlay_style(style)
                y = y + height + GAP_Y
                shown = shown + 1
            end
        end
    end

    local celebration = nil
    function ctx.celebrate(title, details)
        celebration = { title = tostring(title or ""), details = details or {}, t = os.clock() * 1000 }
    end

    local function draw_celebration()
        if not celebration then return end
        local LIFE, FIN, FOUT, PULSE, SCALE = 9000, 400, 1400, 1800, 1.6
        local age = os.clock() * 1000 - celebration.t
        if age >= LIFE then celebration = nil return end
        local alpha = 1.0
        if age < FIN then alpha = age / FIN end
        if LIFE - age < FOUT then alpha = math.min(alpha, (LIFE - age) / FOUT) end
        alpha = math.max(0, math.min(1, alpha * (0.90 + 0.10 * math.sin(age / PULSE * 2 * math.pi))))
        local sw, sh = display_size()
        local width = math.min(math.floor(sw * 0.9), 720)
        local height = math.floor((3 + #celebration.details) * 30 * SCALE + 60)
        imgui.set_next_window_pos(Vector2f.new(math.floor((sw - width) / 2), math.floor(sh * 0.30)), 1)
        imgui.set_next_window_size(Vector2f.new(width, height), 1)
        pcall(imgui.set_next_window_bg_alpha, 0.0)
        local style = push_overlay_style(0)
        if imgui.begin_window("##re9ap_celebration", true, OVERLAY_FLAGS) then
            pcall(imgui.set_window_font_scale, SCALE)
            local banner = "* * * * * * * * * * * * * * * *"
            centered_overlay_text(banner, C.gold, width, alpha)
            centered_overlay_text(T(celebration.title), C.gold, width, alpha)
            for _, d in ipairs(celebration.details) do centered_overlay_text(T(tostring(d)), C.white, width, alpha) end
            centered_overlay_text(banner, C.gold, width, alpha)
            pcall(imgui.set_window_font_scale, 1.0)
            imgui.end_window()
        end
        pop_overlay_style(style)
    end

    local function source_text()
        if not ctx.active_source then return nil end
        local text = T(ctx.active_source)
        local a = ctx.active_source_args
        if a then text = text .. " " .. TF("(%s, objets clés %s)", tostring(a[1]), tostring(a[2])) end
        return text
    end

    -- Options du YAML / slot_data (lecture seule, comme l'écran réglages RE4)
    local function draw_yaml_options()
        local s = ctx.session
        theme.heading(T("Options de la partie (YAML)"))
        if not ctx.has_slot_data() then
            theme.note(T("Connecte-toi au slot pour voir les options générées."))
            return
        end
        theme.note(T("Valeurs reçues du serveur (slot_data) — figées à la génération."))
        local function row(label, value)
            local v = tostring(value or "")
            if v == "" then v = "—" end
            imgui.text(string.format("%-22s  %s", label, v))
        end
        local dl = tostring(s.death_link or "")
        if dl == "true" or dl == "1" then dl = T("activé")
        elseif dl == "false" or dl == "0" then dl = T("désactivé") end
        local aw = tostring(s.apworld_version or "")
        local expect_aw = tostring(ctx.EXPECTED_APWORLD or "")
        if expect_aw ~= "" and aw ~= "" then
            row(T("Apworld"), aw .. "  (" .. T("client") .. " : " .. expect_aw .. ")")
        else
            row(T("Apworld"), aw)
        end
        if ctx.version_mismatch or (expect_aw ~= "" and aw ~= "" and expect_aw ~= aw) then
            theme.colored(T("Attention : version apworld de la seed ≠ version attendue par ce client."), theme.WARN)
        end
        row(T("Objectif"), s.goal)
        local diff_line = tostring(s.difficulty or "")
        if ctx.game_difficulty and ctx.game_difficulty ~= "" then
            diff_line = diff_line .. "  (" .. T("jeu") .. " : " ..
                (ctx.game_difficulty:sub(1, 1):upper() .. ctx.game_difficulty:sub(2)) .. ")"
        end
        row(T("Difficulté"), diff_line)
        if ctx.difficulty_mismatch then
            theme.colored(T("BLOQUÉ : difficulté seed ≠ jeu — checks AP désactivés. Aligne la difficulté."), theme.ERROR)
        end
        row(T("Objets clés"), s.key_items)
        row(T("Items Flag (ciné)"), s.flag_items)
        row(T("Drops ennemis"), s.enemy_drops)
        local shop = tostring(s.supply_box or "")
        if shop == "true" or shop == "1" then shop = T("activé")
        elseif shop == "false" or shop == "0" then shop = T("désactivé") end
        row(T("Supply Box"), shop)
        local priced = 0
        if type(s.supply_prices) == "table" then
            for _ in pairs(s.supply_prices) do priced = priced + 1 end
        end
        if priced > 0 then row(T("Prix Supply Box"), T("Archipelago")) end
        row(T("DeathLink"), dl)
        row(T("Checks (slot)"), tostring(ctx.count_table and ctx.count_table(s.active) or ""))
        if s.goal_sent then theme.colored(T("Victoire déjà envoyée."), theme.DONE) end
    end

    local function draw_checklist()
        local s = ctx.session
        if not ctx.has_slot_data() then
            theme.colored(T("Connecte-toi une fois au slot avant de jouer : la liste des checks est encore inconnue."), theme.WARN)
            return
        end
        local p = refresh_progress()
        theme.heading(TF("Checks trouvés : %d / %d", p.done, p.total))
        theme.progress(p.done, p.total, "")
        draw_yaml_options()
        imgui.text("")
        local src = source_text()
        if src then theme.note(T("Liste des checks : ") .. src) end
        imgui.text("")

        local spoil = ctx.marker_prefs and ctx.marker_prefs.show_item
        -- Un chapitre par bloc : le bouton des checks oubliés est au-dessus du titre.
        if theme.section(T("Détail par chapitre"), "by_chapter", string.format("%d / %d", p.done, p.total)) then
            local here = ctx.current_chapter
            for i, c in ipairs(p.chapters) do
                if i > 1 then
                    imgui.text("")
                    theme.separator()
                end
                local left = c.total - c.done
                if left > 0 then
                    local conf = force_ch_confirm
                    if conf and conf.name == c.name and conf.expires > os.clock() then
                        theme.colored(TF("Marquer %d check(s) de %s comme faits et les envoyer ?", left, c.name), theme.WARN)
                        if imgui.button(T("Oui, forcer") .. "##force_ch_yes_" .. c.name) then
                            local n = ctx.force_chapter_remaining(c.name)
                            force_ch_confirm = nil
                            ctx.push_message(
                                TF("%s : %d check(s) forcé(s)", c.name, n),
                                n > 0 and ctx.COLORS.ok or ctx.COLORS.warn, n > 0 and "check" or "warn")
                        end
                        imgui.same_line()
                        if imgui.button(T("Annuler") .. "##force_ch_no_" .. c.name) then
                            force_ch_confirm = nil
                        end
                    elseif imgui.button(TF("Forcer les %d check(s) oublié(s)", left) .. "##force_ch_" .. c.name) then
                        force_ch_confirm = { name = c.name, expires = os.clock() + 12 }
                    end
                end
                local missing = left > 0 and ctx.chapter_missing_keys(c.name) or {}
                local state = left <= 0 and T("  fini")
                    or (#missing > 0 and TF("  bloqué (%d objet(s) clé(s))", #missing) or "")
                local mark = (c.name == here) and T("  < tu es ici") or ""
                if imgui.tree_node(string.format("%s - %d / %d%s%s##re9ap_ch_%s", c.name, c.done, c.total, state, mark, c.name)) then
                    if #missing > 0 then
                        theme.colored(T("Pas encore en logique, il manque :"), theme.WARN)
                        for _, m in ipairs(missing) do
                            theme.colored(string.format("      %s  %d / %d", m.name, m.have, m.need), theme.WARN)
                        end
                    end
                    for _, r in ipairs(c.rows) do
                        local line, col = r.name, r.checked and theme.DONE or theme.WHITE
                        -- spoil ON : objet AP en titre (évite une liste de « Tracking Module »)
                        if spoil and not r.checked and ctx.scout_label then
                            local label, sc_col = ctx.scout_label(r.id)
                            if label and label ~= "" then
                                line, col = label, sc_col or theme.WHITE
                            end
                        end
                        theme.colored(string.format("%s %s", r.checked and "[x]" or "[ ]", line), col)
                        if spoil and not r.checked and line ~= r.name then
                            theme.colored("      " .. r.name, theme.MUTED)
                        end
                    end
                    imgui.tree_pop()
                end
            end
        end
        imgui.text("")
        theme.separator()
        theme.note(T("Un check ne part pas, ou partie finie ? Voir l'onglet « Un problème ? »."))
    end

    local function draw_guidance()
        local mp = ctx.marker_prefs
        theme.heading(T("Marqueurs dans le monde"))
        if mp then
            local changed, v
            local dirty = false
            changed, v = imgui.checkbox(T("Nom au-dessus des checks proches"), mp.enabled)
            if changed then mp.enabled, dirty = v, true end
            changed, v = imgui.checkbox(T("Seulement quand je regarde le check"), mp.look_only)
            if changed then mp.look_only, dirty = v, true end
            changed, v = imgui.checkbox(T("Montrer l'objet Archipelago (nom du check = objet AP)"), mp.show_item)
            if changed then mp.show_item, dirty = v, true end
            if mp.show_item then
                theme.note(T("Marqueurs / liste : objet AP d'abord (pas le vanilla Tracking Module…)."))
            end
            changed, v = imgui.checkbox(T("Icônes des checks sur la carte du jeu"), mp.map_icons)
            if changed then mp.map_icons, dirty = v, true end
            if mp.map_icon_sync ~= nil then
                changed, v = imgui.checkbox(T("Corriger les icônes Madhouse (sync)"), mp.map_icon_sync)
                if changed then mp.map_icon_sync, dirty = v, true end
            end
            if mp.map_containers ~= nil then
                changed, v = imgui.checkbox(T("Marqueurs [CAISSE] pour tiroirs / casiers / sans icône carte"), mp.map_containers)
                if changed then mp.map_containers, dirty = v, true end
            end
            if mp.map_chapter_only ~= nil then
                changed, v = imgui.checkbox(T("Carte / marqueurs : seulement mon chapitre actuel"), mp.map_chapter_only)
                if changed then mp.map_chapter_only, dirty = v, true end
            end
            if mp.map_floor_only ~= nil then
                changed, v = imgui.checkbox(T("Carte : seulement l'étage affiché (pas d'icônes dans le vide)"), mp.map_floor_only)
                if changed then mp.map_floor_only, dirty = v, true end
            end
            changed, v = imgui.slider_int(T("Distance (m)"), mp.distance, 3, 50)
            if changed then mp.distance, dirty = v, true end
            if dirty then ctx.save_marker_prefs() end
            if imgui.button(T("Forcer sync icônes carte")) and ctx.sync_map_icons then
                local n = ctx.sync_map_icons() or 0
                ctx.info(string.format("carte : sync forcée — %d icône(s)", n))
            end
            theme.note(T("« Montrer l'objet » révèle aussi le contenu dans la liste des checks."))
            theme.note(T("Carte : comme RE2R AP — toutes les icônes de l'étage, sans entrer dans chaque salle."))
            theme.note(T("Sans icône native (caisse/tiroir) : marqueurs [CAISSE] dans le monde."))
            local st = ctx.marker_stats
            if st then
                theme.note(TF("Objets de la scène : %d reconnus, %d déjà faits, %d cachés par le jeu, %d dans un dossier inactif",
                    st.found, st.done, st.object, st.folder))
            end
            imgui.text("")
            theme.heading(T("Checks inaccessibles"))
            theme.note(T("Pas d'objet dans la scène : envoie le check quand même."))
            local stuck = ctx.inaccessible_checks or {}
            if #stuck == 0 then
                theme.note(T("Aucun check inaccessible à proximité."))
            else
                for _, r in ipairs(stuck) do
                    local title = r.name or tostring(r.id)
                    imgui.text(string.format("%s  (%.0fm)", title, r.d or 0))
                    imgui.same_line()
                    if imgui.button(T("Forcer ce check") .. "##force_stuck_" .. tostring(r.id)) then
                        local loc = ctx.locations and ctx.locations[r.id]
                        if loc and ctx.force_check and ctx.force_check(loc, "forcé (inaccessible)", { x = loc.x, y = loc.y, z = loc.z }) then
                            ctx.push_message(T("Check forcé : ") .. title, ctx.COLORS.ok, "check")
                        else
                            ctx.push_message(T("Échec du forçage : ") .. title, ctx.COLORS.bad, "error")
                        end
                    end
                end
            end
        else
            theme.note(T("Module des marqueurs non chargé."))
        end
        imgui.text("")
        if ctx.draw_chapter_skip then
            imgui.text("")
            theme.separator()
            ctx.draw_chapter_skip()
        end
        if ctx.draw_chapter_gate then
            imgui.text("")
            theme.separator()
            ctx.draw_chapter_gate()
        end
    end


    local QUICK_COMMANDS = {
        { "!hint", "Mes indices" },
        { "!remaining", "Objets restants" },
        { "!missing", "Checks manquants" },
        { "!checked", "Checks faits" },
        { "!players", "Joueurs" },
        { "!help", "Aide" },
    }

    local function display(text)
        return ctx.display_name and ctx.display_name(text) or tostring(text or "")
    end

    local function trimmed(text)
        return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function send_command(text)
        text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return false end
        local now = os.clock()
        if text == last_command and now - last_command_at < COMMAND_REPEAT_SECONDS then return false end
        last_command, last_command_at = text, now
        local ok, err = false, T("pas connecté au serveur")
        if ctx.ap_say then ok, err = ctx.ap_say(text) end
        ctx.info("commande envoyée : " .. text .. (ok and "" or (" (échec : " .. tostring(err) .. ")")))
        ctx.log_console("> " .. display(text), ok and ctx.COLORS.info or ctx.COLORS.bad)
        if not ok then ctx.log_console(T("Pas envoyé : ") .. tostring(err), ctx.COLORS.bad) end
        return ok
    end

    -- le serveur veut le nom complet (« Blood Collector (it99_06_000) »), on n'affiche que le nom court
    local function labelled(list)
        table.sort(list)
        local count, seen, entries, exact = {}, {}, {}, {}
        for _, n in ipairs(list) do
            local base = display(n)
            count[base] = (count[base] or 0) + 1
        end
        for _, n in ipairs(list) do
            local base = display(n)
            local label = base
            if count[base] > 1 then
                seen[base] = (seen[base] or 0) + 1
                label = base .. " #" .. seen[base]
            end
            entries[#entries + 1] = { label = label, lower = string.lower(label) }
            exact[string.lower(label)] = n
        end
        return { entries = entries, exact = exact }
    end

    local name_lists = nil
    local function apworld_names()
        if name_lists then return name_lists end
        local items, locations, seen = {}, {}, {}
        for _, it in pairs(ctx.ap_items or {}) do
            if it.name and not seen[it.name] then seen[it.name] = true items[#items + 1] = it.name end
        end
        for _, loc in pairs(ctx.locations or {}) do locations[#locations + 1] = loc.name end
        name_lists = { items = labelled(items), locations = labelled(locations) }
        return name_lists
    end

    local MAX_SUGGESTIONS = 6
    local function suggestions(names, text)
        local needle = string.lower(trimmed(text))
        if #needle < 2 or names.exact[needle] then return {} end
        local out = {}
        for _, e in ipairs(names.entries) do
            if e.lower:find(needle, 1, true) then
                out[#out + 1] = e.label
                if #out >= MAX_SUGGESTIONS then break end
            end
        end
        return out
    end

    -- seul le bouton envoie : un champ actif réécrit son texte à chaque image, son « changed » ne valide rien
    local function input_and_send(label, id, value, button, prefix, names)
        local _, v = imgui.input_text(label .. "##" .. id, value)
        value = v or value
        imgui.same_line()
        if imgui.button(button .. "##" .. id .. "_btn") and trimmed(value) ~= "" then
            local full = names and names.exact[string.lower(trimmed(value))] or trimmed(value)
            if send_command(prefix .. full) then return "" end
        end
        for i, n in ipairs(names and suggestions(names, value) or {}) do
            if imgui.button(n .. "##" .. id .. "_s" .. i) then value = n end
        end
        return value
    end

    local function draw_hints()
        local hints = ctx.session.hints or {}
        local open = 0
        for _, h in ipairs(hints) do if not h.found then open = open + 1 end end
        theme.heading(TF("Indices : %d à trouver, %d au total", open, #hints))
        local points, cost, percent = nil, nil, nil
        if ctx.ap_hint_points then points, cost, percent = ctx.ap_hint_points() end
        if points == nil then
            theme.note(T("Points d'indice : connecte-toi au serveur pour les voir."))
        elseif not cost or cost <= 0 then
            theme.colored(TF("Points d'indice : %d (les indices sont gratuits)", points), theme.DONE)
        else
            local can = math.floor(points / cost)
            theme.colored(TF("Points d'indice : %d, un indice coûte %d (%d %% des emplacements) : %d indice(s) possible(s)",
                points, cost, percent or 0, can), can > 0 and theme.DONE or theme.WARN)
            if can == 0 then
                theme.note(TF("Encore %d point(s) : chaque check envoyé en rapporte.", cost - points))
            end
        end
        if imgui.button(T("Rafraîchir (!hint)") .. "##hint_refresh") then send_command("!hint") end
        if #hints == 0 then
            theme.note(T("Aucun indice pour l'instant : demande-en un ci-dessous."))
            return
        end
        for _, found in ipairs({ false, true }) do
            for _, h in ipairs(hints) do
                if h.found == found then theme.colored(display(h.text), found and theme.MUTED or theme.WARN) end
            end
        end
    end

    local function draw_commands()
        if not (ctx.ap_is_connected and ctx.ap_is_connected()) then
            theme.colored(T("Pas connecté au serveur : les commandes ne partiront pas."), theme.WARN)
        end
        local cols = theme.begin_columns("##re9ap_cmd_cols", 2)
        theme.next_column(cols)
        draw_hints()
        imgui.text("")
        theme.heading(T("Demander un indice"))
        theme.note(T("Coûte des points d'indice. Tape une partie du nom, puis clique le nom exact proposé."))
        local names = apworld_names()
        theme.colored(T("Où est mon objet ? (ex. Cherub Key : dans quel monde et à quel endroit)"), theme.WHITE)
        hint_item = input_and_send(T("Objet"), "hint_item", hint_item, T("Où est-il ?"), "!hint ", names.items)
        theme.colored(T("Qu'y a-t-il à cet endroit de mon jeu ? (ex. Ch3 Area - Cherub Key : l'objet caché dedans)"), theme.WHITE)
        hint_location = input_and_send(T("Emplacement"), "hint_loc", hint_location, T("Qu'y a-t-il ?"), "!hint_location ", names.locations)

        theme.next_column(cols)
        theme.heading(T("Commande ou message"))
        theme.note(T("Comme dans le client texte : !commande, ou un message pour la room."))
        command_text = input_and_send(T("Texte"), "command", command_text, T("Envoyer"), "")
        for i, q in ipairs(QUICK_COMMANDS) do
            if i > 1 and (i - 1) % 3 ~= 0 then imgui.same_line() end
            if imgui.button(T(q[2]) .. "##quick" .. i) then send_command(q[1]) end
        end
        imgui.text("")
        theme.heading(T("Réponses du serveur"))
        if #ctx.console == 0 then theme.note(T("Aucun message.")) end
        for i, m in ipairs(ctx.console) do
            if i > 60 then break end
            theme.colored(string.format("%s  %s", m.time or "--:--", display(m.text)), m.color or theme.WHITE)
        end
        theme.end_columns(cols)
    end

    local function draw_server()
        local st = ctx.ap_state
        if not st then
            theme.colored(T("Client AP non chargé (lua-apclientpp.dll ?)"), theme.ERROR)
            return
        end
        local text, _, color = status_info()
        theme.heading(T("Connexion"))
        theme.colored(T("État : ") .. text, color)
        imgui.text(T("Adresse : ") .. (st.server ~= "" and st.server or T("(aucune)")))
        imgui.text(T("Slot : ") .. (st.slot ~= "" and st.slot or T("(aucun)"))
            .. (st.player_number and TF("  (joueur %s)", tostring(st.player_number)) or ""))
        imgui.text(T("Seed : ") .. (ctx.session.seed ~= "" and ctx.session.seed or T("(inconnue)")))
        local expected_seed = st.room and tostring(st.room.seed or "") or ""
        if expected_seed ~= "" then
            imgui.text(T("Seed lanceur : ") .. expected_seed)
            if ctx.session.seed ~= "" and expected_seed ~= ctx.session.seed then
                theme.colored(T("MAUVAISE SEED : room ≠ lanceur — ce n'est pas ta partie."), theme.ERROR)
            elseif ctx.session.seed ~= "" then
                theme.colored(T("Seed : correspond à cette session."), theme.DONE)
            end
        end
        if ctx.seed_mismatch then
            theme.colored(T("MAUVAISE SEED détectée — reconnecte la bonne room Archipelago."), theme.ERROR)
        end
        if ctx.has_slot_data and not ctx.has_slot_data()
            and (st.status == "connected" or (ctx.ap_is_connected and ctx.ap_is_connected())) then
            theme.colored(T("MAUVAISE SEED / checks vides : les objets ne seront pas des checks."), theme.ERROR)
        end
        imgui.text("")
        theme.heading(T("Changer l'adresse"))
        if edit.server == nil then
            edit.server, edit.slot, edit.password = st.server, st.slot, st.password
        end
        local _
        _, edit.server = imgui.input_text(T("Serveur") .. "##server", edit.server or "")
        _, edit.slot = imgui.input_text(T("Nom du slot") .. "##slot", edit.slot or "")
        if edit.show_password then
            _, edit.password = imgui.input_text(T("Mot de passe") .. "##password", edit.password or "")
        else
            imgui.text(T("Mot de passe : ") .. (((edit.password or "") ~= "") and "********" or T("(aucun)")))
        end
        imgui.same_line()
        _, edit.show_password = imgui.checkbox(T("Afficher") .. "##show_password", edit.show_password)
        if imgui.button(T("Enregistrer et connecter") .. "##connect") then
            ctx.ap_save_connection(edit.server, edit.slot, edit.password)
            ctx.ap_connect()
        end
        imgui.same_line()
        if imgui.button(T("Déconnecter") .. "##disconnect") then ctx.ap_disconnect() end
    end

    local function draw_language_picker()
        for i, l in ipairs(ctx.LANGUAGES or {}) do
            if i > 1 then imgui.same_line() end
            local active = ctx.LANG == l[1]
            if theme.color_button((active and "> " or "") .. l[2] .. "##lang_" .. l[1], active and theme.MAIN_RGB or { 0.20, 0.22, 0.27 }) then
                ctx.set_language(l[1])
            end
        end
    end

    local function draw_customize()
        local changed, v
        draw_yaml_options()
        imgui.text("")
        theme.heading(T("Langue / Language"))
        draw_language_picker()
        imgui.text("")
        theme.heading(T("Affichage"))
        changed, v = imgui.checkbox(T("Notifications à l'écran") .. "##toasts", prefs.show_toasts)
        if changed then prefs.show_toasts = v save_prefs() end
        imgui.same_line()
        if imgui.button(T("Tester") .. "##toast_test") then
            ctx.push_message(T("Connecté à Archipelago en tant que ") .. "Grace", ctx.COLORS.ok, "system")
            ctx.push_message(T("Check : ") .. "Ch1 Herbe verte", ctx.COLORS.ok, "check", 2,
                { title = "Green Herb", sub = TF("Pour %s", "Bob") .. "  |  Ch1 Area - Green Herb" })
            ctx.push_message(TF("Reçu : %s%s%s (coffre)", "Handgun Ammo", " x15", ""), ctx.COLORS.item, "item", 0,
                { title = "Handgun Ammo x15", sub = TF("De %s", "Bob") .. "  |  " .. T("Coffre") })
            ctx.push_message(TF("Reçu : %s%s%s (inventaire de Grace)", "Cherub Key", "", ""), ctx.COLORS.progress, "item", 1,
                { title = "Cherub Key", sub = TF("De %s", "Alice") .. "  |  " .. T("Inventaire") })
        end
        changed, v = imgui.checkbox(T("Bandeau en haut à droite") .. "##hud", prefs.show_hud)
        if changed then prefs.show_hud = v save_prefs() end
        local _
        _, ctx.suppress_vanilla = imgui.checkbox(T("Bloquer l'objet d'origine sur les checks") .. "##suppress", ctx.suppress_vanilla)
        changed, v = imgui.checkbox(T("Mes objets AP donnés directement au ramassage (sinon au coffre)") .. "##swap", prefs.swap_items)
        if changed then prefs.swap_items = v ctx.swap_own_items = v save_prefs() end
        changed, v = imgui.checkbox(T("Reçus dans mon inventaire : munitions, soins, objets clés du chapitre (le reste au coffre)") .. "##tohand", prefs.received_to_hand)
        if changed then prefs.received_to_hand = v ctx.received_to_hand = v save_prefs() end
        if ctx.redeliver_on_death ~= nil then
            changed, v = imgui.checkbox(T("Après une mort / menu Recommencer : garder les checks + redonner les objets AP") .. "##respawn", prefs.redeliver_on_death)
            if changed then prefs.redeliver_on_death = v ctx.redeliver_on_death = v save_prefs() end
        end
        if ctx.draw_chapter_skip then
            imgui.text("")
            ctx.draw_chapter_skip()
        end
        if ctx.draw_chapter_gate then
            imgui.text("")
            ctx.draw_chapter_gate()
        end
        changed, v = imgui.checkbox(T("Outils développeur (onglet Debug)") .. "##dev", prefs.dev_tools)
        if changed then prefs.dev_tools = v save_prefs() end
        if ctx.deathlink_mode then
            imgui.text("")
            theme.heading("DeathLink")
            local modes = { "yaml", "on", "off" }
            local labels = {
                TF("Selon le YAML (%s)", ctx.deathlink_yaml() and T("activé") or T("désactivé")),
                T("Toujours activé pour cette partie"),
                T("Désactivé pour cette partie"),
            }
            local current = 1
            for i, m in ipairs(modes) do if m == ctx.deathlink_mode() then current = i end end
            changed, v = imgui.combo("##deathlink_mode", current, labels)
            if changed and modes[v] then ctx.deathlink_set_mode(modes[v]) end
            local s = ctx.deathlink_stats
            imgui.text(ctx.deathlink_active() and T("Actif : ta mort tue les autres joueurs, et la leur te tue.") or T("Inactif."))
            imgui.text(TF("Morts envoyées : %d  |  reçues : %d", s.sent, s.received))
            if s.last then imgui.text(T("Dernière reçue : ") .. s.last) end
        end
        imgui.text("")
        theme.heading(T("Couleur principale"))
        for i, preset in ipairs(theme.PRESETS) do
            if i > 1 then imgui.same_line() end
            if theme.color_button(T(preset[1]) .. "##main" .. i, preset[2]) then
                prefs.main_rgb = preset[2]
                theme.apply_colors(prefs.main_rgb, prefs.progress_rgb)
                save_prefs()
            end
        end
        imgui.text("")
        theme.heading(T("Couleur des barres de progression"))
        for i, preset in ipairs(theme.PRESETS) do
            if i > 1 then imgui.same_line() end
            if theme.color_button(T(preset[1]) .. "##bar" .. i, preset[2]) then
                prefs.progress_rgb = preset[2]
                theme.apply_colors(prefs.main_rgb, prefs.progress_rgb)
                save_prefs()
            end
        end
        theme.progress(2, 3, T("Aperçu"))
        imgui.text("")
        if imgui.button(T("Couleurs par défaut") .. "##default_colors") then
            prefs.main_rgb, prefs.progress_rgb = theme.DEFAULT_MAIN_RGB, theme.DEFAULT_PROGRESS_RGB
            theme.apply_colors(prefs.main_rgb, prefs.progress_rgb)
            save_prefs()
        end
    end

    local TABS = {
        { "La liste des checks", draw_checklist },
        { "Guidage", draw_guidance },
        { "Commandes", draw_commands },
        { "Serveur", draw_server },
        { "Personnaliser", draw_customize },
    }

    local last_error = nil
    local function draw_window()
        if not prefs.show_window or not reframework:is_drawing_ui() then return end
        local tabs = {}
        for _, t in ipairs(TABS) do
            if not t.needs or ctx[t.needs] then tabs[#tabs + 1] = t end
        end
        if prefs.dev_tools and ctx.draw_debug_tab then tabs[#tabs + 1] = { "Debug", ctx.draw_debug_tab } end
        if ctx.draw_grace_supply and ctx.current_character and ctx.current_character() == "grace" then
            tabs[#tabs + 1] = { "Achats de Grace", ctx.draw_grace_supply }
        end
        local labels = {}
        for i, t in ipairs(tabs) do labels[i] = T(t[1]) end

        local style = theme.push_window_style()
        imgui.set_next_window_size(Vector2f.new(940, 620), 4)
        local open = imgui.begin_window("Archipelago RE Requiem##re9ap_main_v2", true, 0)
        if open == false then
            prefs.show_window = false
            save_prefs()
        end
        theme.heading("ARCHIPELAGO  -  RESIDENT EVIL REQUIEM")
        imgui.same_line()
        local mv = tostring(ctx.MOD_VERSION or "dev")
        theme.note(mv:match("^%d") and ("v" .. mv) or mv)
        imgui.same_line()
        local text, _, color = status_info()
        theme.status_badge(text, color)

        local active = math.max(1, math.min(#tabs, math.floor(tonumber(prefs.tab) or 1)))
        local picked = theme.tab_strip("##re9ap_tab", labels, active)
        if picked ~= prefs.tab then
            prefs.tab = picked
            save_prefs()
        end
        theme.separator()

        local panel = theme.begin_panel()
        local ok, e = pcall(tabs[picked][2])
        theme.end_panel(panel)
        if not ok then
            theme.colored(T("Cet onglet a rencontré une erreur (voir le journal REFramework)."), theme.ERROR)
            if last_error ~= tostring(e) then
                last_error = tostring(e)
                ctx.err("onglet '" .. tabs[picked][1] .. "' : " .. last_error)
            end
        end
        imgui.end_window()
        theme.pop_window_style(style)
    end

    local function draw_markers()
        local sw, sh = display_size()
        if ctx.screen_size then ctx.screen_size[1], ctx.screen_size[2] = sw, sh end
        local list = ctx.marker_screen
        if not list or #list == 0 then return end
        imgui.set_next_window_pos(Vector2f.new(0, 0), 1)
        imgui.set_next_window_size(Vector2f.new(sw, sh), 1)
        pcall(imgui.set_next_window_bg_alpha, 0.0)
        local style = push_overlay_style(0)
        if imgui.begin_window("##re9ap_markers", true, OVERLAY_FLAGS) then
            pcall(imgui.set_window_font_scale, 1.15)
            for _, m in ipairs(list) do
                local text = tostring(m[3])
                local x = math.floor(m[1] - text_width(text) * 1.15 * 0.5)
                local y = math.floor(m[2] - 10)
                if pcall(imgui.set_cursor_pos, Vector2f.new(x, y)) then
                    overlay_text(text, theme.u32_to_rgba(m[4] or ctx.COLORS.info))
                end
            end
            pcall(imgui.set_window_font_scale, 1.0)
            imgui.end_window()
        end
        pop_overlay_style(style)
    end

    re.on_frame(function()
        local ok, e = pcall(draw_markers)
        if not ok then ctx.err("affichage des marqueurs : " .. tostring(e)) ctx.marker_screen = {} end
        ok, e = pcall(draw_header)
        if not ok then ctx.err("bandeau : " .. tostring(e)) prefs.show_hud = false end
        ok, e = pcall(draw_toasts)
        if not ok then ctx.err("notifications : " .. tostring(e)) prefs.show_toasts = false end
        ok, e = pcall(draw_celebration)
        if not ok then ctx.err("bannière : " .. tostring(e)) celebration = nil end
        ok, e = pcall(draw_window)
        if not ok then ctx.err("fenêtre : " .. tostring(e)) end
    end)

    re.on_draw_ui(function()
        if not imgui.tree_node("Archipelago - Resident Evil Requiem") then return end
        local ok, e = pcall(function()
            local text, _, color = status_info()
            theme.colored(text, color)
            local changed, v = imgui.checkbox(T("Fenêtre Archipelago (visible avec le menu REFramework)") .. "##window", prefs.show_window)
            if changed then prefs.show_window = v save_prefs() end
            imgui.text(T("Langue / Language") .. " :")
            imgui.same_line()
            draw_language_picker()
        end)
        if not ok then theme.colored(T("Erreur UI : ") .. tostring(e), theme.ERROR) end
        imgui.tree_pop()
    end)
end
