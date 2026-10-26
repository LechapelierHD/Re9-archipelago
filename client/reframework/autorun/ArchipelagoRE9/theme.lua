-- appels imgui optionnels protégés (type + pcall) : ils manquent selon la version de REFramework

return function(ctx)
    local theme = {}
    ctx.theme = theme

    local function has(name) return type(imgui[name]) == "function" end

    -- ImU32 : 0xAABBGGRR
    theme.MUTED = 0xFF9A9A9A
    theme.DONE = 0xFF7FD67F
    theme.WARN = 0xFF60C0FF
    theme.ERROR = 0xFF6B6BF0
    theme.WHITE = 0xFFFFFFFF
    theme.PROG = 0xFF4AB2E0
    theme.USEFUL = 0xFFE88B6D

    -- nuances stockées en écarts HSV au bleu Archipelago, pour suivre n'importe quelle couleur principale
    theme.REFERENCE_MAIN_RGB = { 0.31, 0.63, 1.0 }
    theme.DEFAULT_MAIN_RGB = { 0.78, 0.16, 0.16 }
    theme.DEFAULT_PROGRESS_RGB = { 0.85, 0.65, 0.13 }
    theme.PRESETS = {
        { "Rouge", { 0.78, 0.16, 0.16 } },
        { "Bleu Archipelago", { 0.31, 0.63, 1.0 } },
        { "Or", { 0.85, 0.65, 0.13 } },
        { "Vert", { 0.24, 0.66, 0.36 } },
        { "Violet", { 0.58, 0.36, 0.90 } },
        { "Cyan", { 0.16, 0.70, 0.78 } },
        { "Gris", { 0.55, 0.57, 0.62 } },
    }

    local REFERENCE_SHADES = {
        window_bg     = { 0.065, 0.075, 0.095 },
        child_bg      = { 0.085, 0.095, 0.12 },
        popup_bg      = { 0.075, 0.085, 0.11 },
        border        = { 0.19, 0.23, 0.30 },
        frame_bg      = { 0.13, 0.15, 0.19 },
        frame_hover   = { 0.17, 0.21, 0.28 },
        frame_active  = { 0.21, 0.29, 0.41 },
        title_bg      = { 0.07, 0.08, 0.105 },
        title_active  = { 0.10, 0.14, 0.21 },
        button        = { 0.14, 0.17, 0.22 },
        button_hover  = { 0.20, 0.28, 0.40 },
        header        = { 0.12, 0.16, 0.22 },
        header_hover  = { 0.18, 0.26, 0.37 },
        header_active = { 0.23, 0.34, 0.50 },
        separator     = { 0.20, 0.30, 0.45 },
        scroll_grab   = { 0.20, 0.25, 0.33 },
        scroll_hover  = { 0.26, 0.36, 0.52 },
        accent_hover  = { 0.45, 0.73, 1.0 },
    }

    local function clamp01(x)
        if x < 0 then return 0 end
        if x > 1 then return 1 end
        return x
    end

    local function rgb_to_hsv(rgb)
        local r, g, b = rgb[1], rgb[2], rgb[3]
        local max, min = math.max(r, g, b), math.min(r, g, b)
        local delta = max - min
        local h = 0
        if delta > 1e-6 then
            if max == r then h = 60 * (((g - b) / delta) % 6)
            elseif max == g then h = 60 * (((b - r) / delta) + 2)
            else h = 60 * (((r - g) / delta) + 4) end
        end
        return h, (max > 1e-6) and (delta / max) or 0, max
    end

    local function hsv_to_rgb(h, s, v)
        h = h % 360
        local c = v * s
        local x = c * (1 - math.abs(((h / 60) % 2) - 1))
        local m = v - c
        local r, g, b
        if h < 60 then r, g, b = c, x, 0
        elseif h < 120 then r, g, b = x, c, 0
        elseif h < 180 then r, g, b = 0, c, x
        elseif h < 240 then r, g, b = 0, x, c
        elseif h < 300 then r, g, b = x, 0, c
        else r, g, b = c, 0, x end
        return { clamp01(r + m), clamp01(g + m), clamp01(b + m) }
    end

    local REF_H, REF_S, REF_V = rgb_to_hsv(theme.REFERENCE_MAIN_RGB)
    local SHADE_OFFSETS = {}
    for key, rgb in pairs(REFERENCE_SHADES) do
        local h, s, v = rgb_to_hsv(rgb)
        local dh = h - REF_H
        if dh > 180 then dh = dh - 360 elseif dh < -180 then dh = dh + 360 end
        SHADE_OFFSETS[key] = { dh = dh, sr = (REF_S > 1e-6) and (s / REF_S) or 0, vr = (REF_V > 1e-6) and (v / REF_V) or 0 }
    end

    local function luminance(rgb) return 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3] end
    theme.luminance = luminance

    function theme.palette_from(main_rgb)
        local h, s, v = rgb_to_hsv(main_rgb)
        local v_scale = math.sqrt(math.max(v, 0.0))
        local shades = {}
        for key, o in pairs(SHADE_OFFSETS) do
            shades[key] = hsv_to_rgb(h + o.dh, clamp01(s * o.sr), math.max(0.02, clamp01(o.vr * v_scale)))
        end
        shades.accent = { main_rgb[1], main_rgb[2], main_rgb[3] }
        shades.accent_text = hsv_to_rgb(h, math.min(s, 0.70), math.max(v, 0.90))
        shades.accent_label = luminance(main_rgb) > 0.45 and { 0.05, 0.06, 0.08 } or { 0.95, 0.96, 0.98 }
        return shades
    end

    local function rgba(rgb, alpha) return { rgb[1], rgb[2], rgb[3], alpha or 1.0 } end

    function theme.rgb_to_u32(rgb)
        local r = math.floor(clamp01(rgb[1]) * 255 + 0.5)
        local g = math.floor(clamp01(rgb[2]) * 255 + 0.5)
        local b = math.floor(clamp01(rgb[3]) * 255 + 0.5)
        return 0xFF000000 | (b << 16) | (g << 8) | r
    end

    function theme.u32_to_rgba(value)
        value = math.floor(tonumber(value) or 0xFFFFFFFF)
        local a = ((value >> 24) & 0xFF) / 255
        return { (value & 0xFF) / 255, ((value >> 8) & 0xFF) / 255, ((value >> 16) & 0xFF) / 255, a > 0 and a or 1.0 }
    end

    -- ImGuiCol_PlotHistogram : 43 ou 42 selon la version
    local PROGRESS_COLOR_INDICES = { 43, 42 }
    local ACCENT_RGBA, ACCENT_HOVER_RGBA, ACCENT_TEXT_RGBA
    local TAB_IDLE_RGBA, TAB_IDLE_HOVER_RGBA, TAB_IDLE_TEXT_RGBA
    local WINDOW_COLORS = {}
    local TEXT_RGBA = { 0.90, 0.92, 0.95, 1.0 }
    local TEXT_DISABLED_RGBA = { 0.50, 0.54, 0.60, 1.0 }

    function theme.apply_colors(main_rgb, progress_rgb)
        main_rgb = main_rgb or theme.DEFAULT_MAIN_RGB
        progress_rgb = progress_rgb or theme.DEFAULT_PROGRESS_RGB
        local p = theme.palette_from(main_rgb)
        theme.MAIN_RGB = { main_rgb[1], main_rgb[2], main_rgb[3] }
        theme.PROGRESS_RGB = { progress_rgb[1], progress_rgb[2], progress_rgb[3] }
        theme.ACCENT = theme.rgb_to_u32(p.accent_text)
        ACCENT_RGBA = rgba(p.accent)
        ACCENT_HOVER_RGBA = rgba(p.accent_hover)
        ACCENT_TEXT_RGBA = rgba(p.accent_label)
        TAB_IDLE_RGBA = rgba(p.child_bg, 0.0)
        TAB_IDLE_HOVER_RGBA = rgba(p.button_hover, 0.55)
        TAB_IDLE_TEXT_RGBA = { 0.66, 0.70, 0.77, 1.0 }
        WINDOW_COLORS = {
            { 0, TEXT_RGBA }, { 1, TEXT_DISABLED_RGBA },
            { 2, rgba(p.window_bg, 0.96) }, { 3, rgba(p.child_bg, 0.85) }, { 4, rgba(p.popup_bg, 0.98) },
            { 5, rgba(p.border, 0.80) }, { 6, { 0, 0, 0, 0 } },
            { 7, rgba(p.frame_bg) }, { 8, rgba(p.frame_hover) }, { 9, rgba(p.frame_active) },
            { 10, rgba(p.title_bg) }, { 11, rgba(p.title_active) }, { 12, rgba(p.title_bg, 0.85) },
            { 14, rgba(p.window_bg, 0.0) }, { 15, rgba(p.scroll_grab) }, { 16, rgba(p.scroll_hover) }, { 17, ACCENT_RGBA },
            { 18, ACCENT_RGBA }, { 19, ACCENT_RGBA }, { 20, ACCENT_HOVER_RGBA },
            { 21, rgba(p.button) }, { 22, rgba(p.button_hover) }, { 23, ACCENT_RGBA },
            { 24, rgba(p.header) }, { 25, rgba(p.header_hover) }, { 26, rgba(p.header_active) },
            { 27, rgba(p.separator, 0.70) }, { 28, ACCENT_HOVER_RGBA }, { 29, ACCENT_RGBA },
            { 30, rgba(p.separator, 0.25) }, { 31, rgba(p.accent, 0.60) }, { 32, ACCENT_RGBA },
        }
        for _, index in ipairs(PROGRESS_COLOR_INDICES) do
            WINDOW_COLORS[#WINDOW_COLORS + 1] = { index, rgba(progress_rgb) }
        end
    end
    theme.apply_colors(theme.DEFAULT_MAIN_RGB, theme.DEFAULT_PROGRESS_RGB)

    local WINDOW_VARS = {
        { 3, 12.0 }, { 4, 1.0 }, { 6, { 0.5, 0.5 } }, { 7, 10.0 }, { 9, 8.0 }, { 12, 7.0 },
        { 18, 12.0 }, { 19, 8.0 }, { 21, 7.0 }, { 2, { 16.0, 14.0 } }, { 11, { 12.0, 6.0 } },
        { 14, { 10.0, 8.0 } }, { 15, { 8.0, 6.0 } }, { 16, 18.0 }, { 17, { 10.0, 6.0 } },
    }
    local TABLE_FLAGS = 512 + 32768   -- BordersInnerV | SizingStretchSame
    local COND_ONCE = 2

    function theme.push_color(index, c)
        if not has("push_style_color") then return 0 end
        if pcall(imgui.push_style_color, index, Vector4f.new(c[1], c[2], c[3], c[4] or 1.0)) then return 1 end
        return 0
    end

    function theme.pop_colors(count)
        if count > 0 and has("pop_style_color") then pcall(imgui.pop_style_color, count) end
    end

    function theme.push_var(index, value)
        if not has("push_style_var") then return 0 end
        local ok
        if type(value) == "table" then
            ok = pcall(imgui.push_style_var, index, Vector2f.new(value[1], value[2]))
        else
            ok = pcall(imgui.push_style_var, index, value)
        end
        return ok and 1 or 0
    end

    function theme.pop_vars(count)
        if count > 0 and has("pop_style_var") then pcall(imgui.pop_style_var, count) end
    end

    function theme.push_window_style()
        local handle = { vars = 0, colors = 0 }
        for _, e in ipairs(WINDOW_VARS) do handle.vars = handle.vars + theme.push_var(e[1], e[2]) end
        for _, e in ipairs(WINDOW_COLORS) do handle.colors = handle.colors + theme.push_color(e[1], e[2]) end
        return handle
    end

    function theme.pop_window_style(handle)
        if type(handle) ~= "table" then return end
        theme.pop_colors(handle.colors or 0)
        theme.pop_vars(handle.vars or 0)
    end

    -- imgui.text lit le texte comme un format printf : « 42% sure » -> « 42(null)ure »
    function theme.plain(text)
        return (tostring(text):gsub("%%", "%%%%"))
    end

    function theme.colored(text, color)
        text = theme.plain(text)
        if has("text_colored") and pcall(imgui.text_colored, text, color) then return end
        imgui.text(text)
    end
    function theme.heading(text) theme.colored(text, theme.ACCENT) end
    function theme.note(text) theme.colored(text, theme.MUTED) end

    function theme.separator()
        if has("separator") and pcall(imgui.separator) then return end
        imgui.text("----------------------------------------")
    end

    function theme.progress(found, total, label, width)
        if total <= 0 then return end
        local fraction = math.max(0, math.min(1, found / total))
        if has("progress_bar") and pcall(imgui.progress_bar, fraction, Vector2f.new(width or -1, 0), label or "") then return end
        if label and label ~= "" then imgui.text(label) end
    end

    function theme.section(title, id, count_text, default_open)
        if has("set_next_item_open") then pcall(imgui.set_next_item_open, default_open ~= false, COND_ONCE) end
        local label = title
        if count_text and count_text ~= "" then label = string.format("%s   %s", title, count_text) end
        if has("collapsing_header") then
            local ok, open = pcall(imgui.collapsing_header, label .. "##re9ap_sec_" .. tostring(id))
            if ok then return open end
        end
        theme.heading(label)
        return true
    end

    function theme.begin_columns(id, count)
        if not has("begin_table") then return nil end
        local ok, opened = pcall(imgui.begin_table, id, count, TABLE_FLAGS, Vector2f.new(0, 0), 0.0)
        if ok and opened then return true end
        ok, opened = pcall(imgui.begin_table, id, count, TABLE_FLAGS)
        if ok and opened then return true end
        return nil
    end
    function theme.next_column(handle) if handle then pcall(imgui.table_next_column) end end
    function theme.end_columns(handle) if handle then pcall(imgui.end_table) end end

    function theme.begin_panel()
        if not has("begin_child_window") or not has("end_child_window") then return { open = false } end
        return { open = pcall(imgui.begin_child_window, Vector2f.new(0, 0), true, 0) }
    end
    function theme.end_panel(handle)
        if type(handle) == "table" and handle.open then pcall(imgui.end_child_window) end
    end

    function theme.tab_strip(id, labels, active)
        local vars = theme.push_var(11, { 14.0, 7.0 }) + theme.push_var(12, 8.0) + theme.push_var(14, { 4.0, 8.0 })
        for index, label in ipairs(labels) do
            if index > 1 then imgui.same_line() end
            local pushed
            if index == active then
                pushed = theme.push_color(21, ACCENT_RGBA) + theme.push_color(22, ACCENT_HOVER_RGBA)
                    + theme.push_color(23, ACCENT_RGBA) + theme.push_color(0, ACCENT_TEXT_RGBA)
            else
                pushed = theme.push_color(21, TAB_IDLE_RGBA) + theme.push_color(22, TAB_IDLE_HOVER_RGBA)
                    + theme.push_color(23, ACCENT_RGBA) + theme.push_color(0, TAB_IDLE_TEXT_RGBA)
            end
            if imgui.button(tostring(label) .. id .. "_" .. index) then active = index end
            theme.pop_colors(pushed)
        end
        theme.pop_vars(vars)
        return active
    end

    function theme.status_badge(text, color) theme.colored("[ " .. tostring(text) .. " ]", color) end

    function theme.color_button(label, rgb)
        local pushed = theme.push_color(21, rgba(rgb)) + theme.push_color(22, rgba(rgb)) + theme.push_color(23, rgba(rgb))
        pushed = pushed + theme.push_color(0, luminance(rgb) > 0.45 and { 0.05, 0.06, 0.08, 1.0 } or { 0.95, 0.96, 0.98, 1.0 })
        local clicked = imgui.button(label)
        theme.pop_colors(pushed)
        return clicked == true
    end
end
