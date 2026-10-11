local M = {}
M.name = "panel"

local BC
local console, parser, patch, decompile

local C
local gui_root
local p_sg
local bp
local header_info, status_dot
local left_pane, left_scroll
local right_pane
local right_view_frame, right_view_scroll, right_view_content
local right_edit_frame, right_edit_scroll, right_edit_display, right_edit_box
local footer
local btn_decompile, btn_edit, btn_revert, btn_exit, btn_save

local mode = "view"
local cached_src = nil
local cached_for_bytecode = nil
local is_dirty = false
local loading_edit = false

local dragOn, dragStart, dragPos, dragFrame, dragMoved
local DRAG_THRESHOLD = 6

local u = game:GetService("UserInputService")
local cam = workspace.CurrentCamera

--=====================================================================
-- PIXEL PALETTE
--=====================================================================

local function px(r, g, b)
    return Color3.fromRGB(r, g, b)
end

local P = {
    bg         = px(24, 24, 28),
    bg2        = px(32, 32, 38),
    panel      = px(18, 18, 22),
    header     = px(40, 40, 48),
    border     = px(56, 56, 66),
    border_hi  = px(84, 84, 100),
    accent     = px(94, 164, 244),
    ok         = px(88, 214, 122),
    warn       = px(232, 184, 96),
    err        = px(240, 96, 96),
    txt        = px(224, 224, 232),
    dim        = px(138, 138, 152),
    hint       = px(74, 74, 86),
}

--=====================================================================
-- LUA HIGHLIGHTING
--=====================================================================

local KEYWORDS = {
    ["and"]=1,["break"]=1,["do"]=1,["else"]=1,["elseif"]=1,["end"]=1,["false"]=1,
    ["for"]=1,["function"]=1,["if"]=1,["in"]=1,["local"]=1,["nil"]=1,["not"]=1,
    ["or"]=1,["repeat"]=1,["return"]=1,["then"]=1,["true"]=1,["until"]=1,
    ["while"]=1,["continue"]=1,["export"]=1,["type"]=1,
}

local BUILTINS = {
    ["game"]=1,["workspace"]=1,["script"]=1,["task"]=1,["print"]=1,["warn"]=1,
    ["error"]=1,["assert"]=1,["pcall"]=1,["xpcall"]=1,["require"]=1,["spawn"]=1,
    ["wait"]=1,["delay"]=1,["tick"]=1,["time"]=1,["typeof"]=1,
    ["pairs"]=1,["ipairs"]=1,["next"]=1,["select"]=1,["unpack"]=1,
    ["rawget"]=1,["rawset"]=1,["rawequal"]=1,["rawlen"]=1,
    ["setmetatable"]=1,["getmetatable"]=1,
    ["tostring"]=1,["tonumber"]=1,
    ["Instance"]=1,["Vector3"]=1,["Vector2"]=1,["CFrame"]=1,["Color3"]=1,
    ["UDim2"]=1,["UDim"]=1,["TweenInfo"]=1,["Enum"]=1,
    ["shared"]=1,["_G"]=1,["_VERSION"]=1,
    ["vector"]=1,["buffer"]=1,["bit32"]=1,["utf8"]=1,
}

local HL = {
    keyword = "#c586c0",
    string  = "#ce9178",
    number  = "#b5cea8",
    comment = "#6a9955",
    ident   = "#9cdcfe",
    builtin = "#4ec9b0",
    op      = "#d4d4d4",
}

local function is_ws(c)
    return c == " " or c == "\t" or c == "\n" or c == "\r"
end

local function is_digit(c)
    return c >= "0" and c <= "9"
end

local function is_alpha(c)
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end

local function is_alnum(c)
    return is_alpha(c) or is_digit(c)
end

local function tokenize(src)
    local tokens = {}
    local i, n = 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if is_ws(c) then
            local j = i
            while j <= n and is_ws(src:sub(j, j)) do j = j + 1 end
            tokens[#tokens + 1] = {t = "ws", v = src:sub(i, j - 1)}
            i = j
        elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
            if src:sub(i, i + 3) == "--[[" then
                local j = src:find("]]", i + 4, true)
                if j then
                    tokens[#tokens + 1] = {t = "comment", v = src:sub(i, j + 1)}
                    i = j + 2
                else
                    tokens[#tokens + 1] = {t = "comment", v = src:sub(i)}
                    i = n + 1
                end
            else
                local j = src:find("\n", i, true) or (n + 1)
                tokens[#tokens + 1] = {t = "comment", v = src:sub(i, j - 1)}
                i = j
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local cc = src:sub(j, j)
                if cc == "\\" then j = j + 2
                elseif cc == c then j = j + 1; break
                else j = j + 1 end
            end
            tokens[#tokens + 1] = {t = "string", v = src:sub(i, j - 1)}
            i = j
        elseif c == "`" then
            local j = i + 1
            while j <= n do
                local cc = src:sub(j, j)
                if cc == "\\" then j = j + 2
                elseif cc == "`" then j = j + 1; break
                else j = j + 1 end
            end
            tokens[#tokens + 1] = {t = "string", v = src:sub(i, j - 1)}
            i = j
        elseif is_digit(c) or (c == "." and is_digit(src:sub(i + 1, i + 1))) then
            local j = i
            if c == "0" and src:sub(i + 1, i + 1):lower() == "x" then
                j = i + 2
                while j <= n and src:sub(j, j):match("[%x]") do j = j + 1 end
                if src:sub(j, j) == "i" then j = j + 1 end
            else
                local seen_dot, seen_e = false, false
                while j <= n do
                    local cc = src:sub(j, j)
                    if is_digit(cc) then j = j + 1
                    elseif cc == "." and not seen_dot and not seen_e then
                        seen_dot = true; j = j + 1
                    elseif (cc == "e" or cc == "E") and not seen_e then
                        seen_e = true; j = j + 1
                        if src:sub(j, j) == "+" or src:sub(j, j) == "-" then j = j + 1 end
                    elseif cc == "i" and not seen_e and not seen_dot then
                        j = j + 1; break
                    else break end
                end
            end
            tokens[#tokens + 1] = {t = "number", v = src:sub(i, j - 1)}
            i = j
        elseif is_alpha(c) then
            local j = i
            while j <= n and is_alnum(src:sub(j, j)) do j = j + 1 end
            local word = src:sub(i, j - 1)
            local t = "ident"
            if KEYWORDS[word] then t = "keyword"
            elseif BUILTINS[word] then t = "builtin" end
            tokens[#tokens + 1] = {t = t, v = word}
            i = j
        else
            local three = src:sub(i, i + 2)
            local two = src:sub(i, i + 1)
            if three == "..." then
                tokens[#tokens + 1] = {t = "op", v = "..."}
                i = i + 3
            elseif two == "==" or two == "~=" or two == "<=" or two == ">="
                or two == ".." or two == "//" or two == "::" or two == "->" then
                tokens[#tokens + 1] = {t = "op", v = two}
                i = i + 2
            else
                tokens[#tokens + 1] = {t = "op", v = c}
                i = i + 1
            end
        end
    end
    return tokens
end

local function escape_rich(s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end

local function highlight(src)
    if #src > 200000 then
        return "-- source too long to highlight (" .. #src .. " bytes)"
    end
    local tokens = tokenize(src)
    local parts = {}
    for _, tok in ipairs(tokens) do
        if tok.t == "ws" then
            parts[#parts + 1] = tok.v
        else
            local color = HL[tok.t] or HL.ident
            parts[#parts + 1] = '<font color="' .. color .. '">' .. escape_rich(tok.v) .. '</font>'
        end
    end
    return table.concat(parts)
end

--=====================================================================
-- PIXEL WIDGETS
--=====================================================================

-- Кнопка пиксельного стиля: внешняя рамка, внутренний фон, без закруглений
local function mk_button(parent, text, w, x, color)
    local outer = Instance.new("Frame")
    outer.Size = UDim2.new(0, w, 0, 26)
    outer.Position = UDim2.new(0, x, 0.5, -13)
    outer.BackgroundColor3 = P.border
    outer.BorderSizePixel = 0
    outer.Parent = parent

    local inner = Instance.new("TextButton")
    inner.Size = UDim2.new(1, -2, 1, -2)
    inner.Position = UDim2.new(0, 1, 0, 1)
    inner.BackgroundColor3 = P.panel
    inner.BorderSizePixel = 0
    inner.Text = text
    inner.TextColor3 = color or P.txt
    inner.Font = Enum.Font.Code
    inner.TextSize = 11
    inner.AutoButtonColor = false
    inner.Parent = outer

    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(1, -2, 0, 1)
    sep.Position = UDim2.new(0, 1, 1, -2)
    sep.BackgroundColor3 = P.border_hi
    sep.BorderSizePixel = 0
    sep.Parent = outer

    return inner, outer
end

local function drag_begin(frame)
    frame.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragOn = true
            dragMoved = false
            dragFrame = bp
            dragStart = i.Position
            dragPos = bp.Position
        end
    end)
end

u.InputChanged:Connect(function(i)
    if dragOn and dragFrame and (i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - dragStart
        if not dragMoved then
            if math.abs(d.X) + math.abs(d.Y) < DRAG_THRESHOLD then return end
            dragMoved = true
        end
        local nx = dragPos.X.Offset + d.X
        local ny = dragPos.Y.Offset + d.Y
        local vp = cam.ViewportSize
        local sz = dragFrame.AbsoluteSize
        if nx < -(sz.X - 100) then nx = -(sz.X - 100) end
        if nx > vp.X - 100 then nx = vp.X - 100 end
        if ny < -6 then ny = -6 end
        if ny > vp.Y - 40 then ny = vp.Y - 40 end
        dragFrame.Position = UDim2.new(0, nx, 0, ny)
    end
end)

u.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
        dragOn = false
        dragMoved = false
        dragFrame = nil
    end
end)

--=====================================================================
-- RENDERING
--=====================================================================

local function clear_scroll(sc)
    for _, v in ipairs(sc:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end
end

local function render_hex()
    clear_scroll(left_scroll)
    local st = patch and patch.state
    if not st or not st.working then
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 20)
        l.BackgroundTransparency = 1
        l.Text = "  no bytecode"
        l.TextColor3 = P.dim
        l.Font = Enum.Font.Code
        l.TextSize = 12
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Parent = left_scroll
        return
    end
    local d = st.working
    for i = 1, #d, 16 do
        local chunk = string.sub(d, i, i + 15)
        local hp = {}
        for j = 1, #chunk do hp[j] = string.format("%02X", string.byte(chunk, j)) end
        local hx = table.concat(hp, " ")
        while #hx < 47 do hx = hx .. " " end
        local asc = chunk:gsub("[^%g ]", ".")

        local r = Instance.new("Frame")
        r.Size = UDim2.new(1, 0, 0, 16)
        r.BackgroundTransparency = 1
        r.Parent = left_scroll

        local addr = Instance.new("TextLabel")
        addr.Size = UDim2.new(0, 52, 1, 0)
        addr.BackgroundTransparency = 1
        addr.Text = string.format("%06X", i - 1)
        addr.TextColor3 = P.dim
        addr.Font = Enum.Font.Code
        addr.TextSize = 12
        addr.TextXAlignment = Enum.TextXAlignment.Left
        addr.Parent = r

        local bytes = Instance.new("TextLabel")
        bytes.Size = UDim2.new(1, -100, 1, 0)
        bytes.Position = UDim2.new(0, 54, 0, 0)
        bytes.BackgroundTransparency = 1
        bytes.Text = hx
        bytes.TextColor3 = P.txt
        bytes.Font = Enum.Font.Code
        bytes.TextSize = 12
        bytes.TextXAlignment = Enum.TextXAlignment.Left
        bytes.Parent = r

        local asc_lbl = Instance.new("TextLabel")
        asc_lbl.Size = UDim2.new(0, 44, 1, 0)
        asc_lbl.Position = UDim2.new(1, -48, 0, 0)
        asc_lbl.BackgroundTransparency = 1
        asc_lbl.Text = "|" .. asc .. "|"
        asc_lbl.TextColor3 = P.hint
        asc_lbl.Font = Enum.Font.Code
        asc_lbl.TextSize = 12
        asc_lbl.TextXAlignment = Enum.TextXAlignment.Left
        asc_lbl.Parent = r
    end
end

local function get_source(force)
    local st = patch and patch.state
    if not st or not st.working then return nil, "no script" end
    if st.user_src then return st.user_src, "user" end
    if not force and cached_src and cached_for_bytecode == st.working then
        return cached_src, "cache"
    end
    if not decompile or not decompile.decompile_best then
        return nil, "no decompiler"
    end
    local ok, result, kind, err = pcall(decompile.decompile_best, st.working)
    if not ok then return nil, "decompile crash: " .. tostring(result) end
    if not result then return nil, "decompile failed: " .. tostring(err) end
    cached_src = result
    cached_for_bytecode = st.working
    return result, kind
end

local function render_source_view(force)
    if mode == "edit" then
        right_view_frame.Visible = false
        right_edit_frame.Visible = true
        return
    end
    right_view_frame.Visible = true
    right_edit_frame.Visible = false

    local st = patch and patch.state
    if not st or not st.script then
        right_view_content.Text = '<font color="#606060">-- no script loaded</font>'
        return
    end
    local src, kind = get_source(force)
    if not src then
        right_view_content.Text = '<font color="#dc6e6e">-- ' .. escape_rich(tostring(kind)) .. '</font>'
        return
    end
    right_view_content.Text = highlight(src)
end

local function update_header()
    local st = patch and patch.state
    local parts = {}
    if st and st.script then
        parts[#parts + 1] = st.script.Name
        if st.parsed then
            parts[#parts + 1] = "proto " .. st.proto_idx .. "/" .. #st.parsed.protos
            parts[#parts + 1] = (st.parsed.scheme or "?")
        end
        parts[#parts + 1] = #st.working .. " b"
    else
        parts[#parts + 1] = "no script loaded"
    end
    header_info.Text = "  " .. table.concat(parts, "   ·   ")

    local dot_c = P.hint
    if st and st.script then
        if is_dirty then dot_c = P.warn else dot_c = P.ok end
    end
    status_dot.BackgroundColor3 = dot_c

    if is_dirty then
        btn_save.BackgroundColor3 = px(34, 76, 46)
        btn_save.TextColor3 = P.ok
    else
        btn_save.BackgroundColor3 = P.panel
        btn_save.TextColor3 = P.dim
    end

    if mode == "edit" then
        btn_edit.Text = "DONE"
        btn_edit.TextColor3 = P.ok
    else
        btn_edit.Text = "EDIT"
        btn_edit.TextColor3 = P.txt
    end
end

function M.render_all()
    render_hex()
    render_source_view(false)
    update_header()
end

--=====================================================================
-- EDIT MODE
--=====================================================================

local function refresh_edit_display()
    if not right_edit_display or not right_edit_box then return end
    right_edit_display.Text = highlight(right_edit_box.Text)
end

local function enter_edit_mode()
    loading_edit = true
    mode = "edit"
    local src = get_source(false) or ""
    right_edit_box.Text = src
    right_edit_display.Text = highlight(src)
    loading_edit = false
    is_dirty = false
    render_source_view(false)
    update_header()
end

local function exit_edit_mode()
    mode = "view"
    local st = patch and patch.state
    local new_src = right_edit_box.Text
    local prev_src = cached_src or ""
    if st then
        if new_src ~= prev_src then
            st.user_src = new_src
            is_dirty = true
        else
            st.user_src = nil
            is_dirty = false
        end
    end
    render_source_view(true)
    update_header()
end

local function revert_all()
    local st = patch and patch.state
    if st then st.user_src = nil end
    is_dirty = false
    cached_src = nil
    cached_for_bytecode = nil
    if patch and patch.revert then patch.revert() end
    M.render_all()
end

local function do_save()
    local st = patch and patch.state
    if not st or not st.script then
        console.log("no script", P.err)
        return
    end
    if not is_dirty and not st.dirty and not st.user_src then
        console.log("nothing to save", P.dim)
        return
    end
    if not patch or not patch.do_apply then
        console.log("no apply method", P.err)
        return
    end
    patch.do_apply()
    is_dirty = false
    cached_src = nil
    cached_for_bytecode = nil
    M.render_all()
end

--=====================================================================
-- BUILD
--=====================================================================

local function ensure_sg()
    gui_root = console.gui_root()
    if not gui_root and gethui then
        local ok, r = pcall(gethui)
        if ok and r then gui_root = r end
    end
    if not gui_root then gui_root = game:GetService("CoreGui") end
    if p_sg and p_sg.Parent == gui_root then return p_sg end
    if p_sg then p_sg:Destroy() end
    p_sg = Instance.new("ScreenGui")
    p_sg.Name = "BCEditor"
    p_sg.ResetOnSpawn = false
    p_sg.IgnoreGuiInset = true
    p_sg.DisplayOrder = 100
    p_sg.Parent = gui_root
    return p_sg
end

function M.start()
    ensure_sg()

    local PANEL_W = 900
    local PANEL_H = 520
    local HEADER_H = 30
    local FOOTER_H = 38
    local BODY_Y = HEADER_H
    local BODY_H = PANEL_H - HEADER_H - FOOTER_H

    -- Внешняя пиксельная рамка вокруг всей панели
    local outer = Instance.new("Frame")
    outer.Size = UDim2.new(0, PANEL_W + 4, 0, PANEL_H + 4)
    outer.Position = UDim2.new(0.5, -(PANEL_W + 4) / 2, 0.5, -(PANEL_H + 4) / 2)
    outer.BackgroundColor3 = P.border_hi
    outer.BorderSizePixel = 0
    outer.Visible = false
    outer.Parent = p_sg

    bp = Instance.new("Frame")
    bp.Size = UDim2.new(1, -4, 1, -4)
    bp.Position = UDim2.new(0, 2, 0, 2)
    bp.BackgroundColor3 = P.bg
    bp.BorderSizePixel = 0
    bp.Parent = outer

    -- Внешняя рамка должна двигаться вместе с bp — привязываем логику к outer
    local old_bp = bp
    bp = outer  -- для drag_begin и позиционирования используем outer

    -- Реальная внутренняя панель - это old_bp
    local body = old_bp

    --========================
    -- HEADER
    --========================
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, HEADER_H)
    header.Position = UDim2.new(0, 0, 0, 0)
    header.BackgroundColor3 = P.header
    header.BorderSizePixel = 0
    header.Parent = body

    -- Нижняя граница шапки — двойная линия для пиксельности
    local hs1 = Instance.new("Frame")
    hs1.Size = UDim2.new(1, 0, 0, 1)
    hs1.Position = UDim2.new(0, 0, 1, -2)
    hs1.BackgroundColor3 = P.border
    hs1.BorderSizePixel = 0
    hs1.Parent = header

    local hs2 = Instance.new("Frame")
    hs2.Size = UDim2.new(1, 0, 0, 1)
    hs2.Position = UDim2.new(0, 0, 1, -1)
    hs2.BackgroundColor3 = P.border_hi
    hs2.BorderSizePixel = 0
    hs2.Parent = header

    -- Пиксельный бейдж — три вертикальные полосы
    local badge = Instance.new("Frame")
    badge.Size = UDim2.new(0, 20, 0, 20)
    badge.Position = UDim2.new(0, 8, 0.5, -10)
    badge.BackgroundColor3 = P.panel
    badge.BorderSizePixel = 0
    badge.Parent = header

    local badge_border = Instance.new("Frame")
    badge_border.Size = UDim2.new(1, 2, 1, 2)
    badge_border.Position = UDim2.new(0, -1, 0, -1)
    badge_border.BackgroundTransparency = 1
    badge_border.BorderSizePixel = 1
    badge_border.BorderColor3 = P.border
    badge_border.Parent = badge

    for i = 1, 3 do
        local bar = Instance.new("Frame")
        bar.Size = UDim2.new(0, 2, 0, 4 + i * 3)
        bar.Position = UDim2.new(0, 3 + (i - 1) * 5, 1, -3)
        bar.BackgroundColor3 = P.accent
        bar.BorderSizePixel = 0
        bar.Parent = badge
    end

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0, 220, 1, 0)
    title.Position = UDim2.new(0, 36, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "BYTECODE EDITOR"
    title.TextColor3 = P.txt
    title.Font = Enum.Font.Code
    title.TextSize = 12
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    header_info = Instance.new("TextLabel")
    header_info.Size = UDim2.new(1, -320, 1, 0)
    header_info.Position = UDim2.new(0, 200, 0, 0)
    header_info.BackgroundTransparency = 1
    header_info.Text = ""
    header_info.TextColor3 = P.dim
    header_info.Font = Enum.Font.Code
    header_info.TextSize = 11
    header_info.TextXAlignment = Enum.TextXAlignment.Left
    header_info.Parent = header

    -- Статусный светодиод — пиксельный квадрат
    local dot_outer = Instance.new("Frame")
    dot_outer.Size = UDim2.new(0, 12, 0, 12)
    dot_outer.Position = UDim2.new(1, -22, 0.5, -6)
    dot_outer.BackgroundColor3 = P.border
    dot_outer.BorderSizePixel = 0
    dot_outer.Parent = header

    status_dot = Instance.new("Frame")
    status_dot.Size = UDim2.new(1, -2, 1, -2)
    status_dot.Position = UDim2.new(0, 1, 0, 1)
    status_dot.BackgroundColor3 = P.hint
    status_dot.BorderSizePixel = 0
    status_dot.Parent = dot_outer

    drag_begin(header)

    --========================
    -- LEFT PANE (HEX)
    --========================
    local gap = 4
    local half_w = (PANEL_W - gap * 3) / 2

    left_pane = Instance.new("Frame")
    left_pane.Size = UDim2.new(0, half_w, 0, BODY_H - 2)
    left_pane.Position = UDim2.new(0, gap, 0, BODY_Y + 1)
    left_pane.BackgroundColor3 = P.panel
    left_pane.BorderSizePixel = 0
    left_pane.ClipsDescendants = true
    left_pane.Parent = body

    local lb = Instance.new("Frame")
    lb.Size = UDim2.new(1, 2, 1, 2)
    lb.Position = UDim2.new(0, -1, 0, -1)
    lb.BackgroundTransparency = 1
    lb.BorderSizePixel = 1
    lb.BorderColor3 = P.border
    lb.Parent = left_pane

    local left_head = Instance.new("TextLabel")
    left_head.Size = UDim2.new(1, 0, 0, 18)
    left_head.BackgroundColor3 = P.header
    left_head.BorderSizePixel = 0
    left_head.Text = "  HEX"
    left_head.TextColor3 = P.dim
    left_head.Font = Enum.Font.Code
    left_head.TextSize = 10
    left_head.TextXAlignment = Enum.TextXAlignment.Left
    left_head.Parent = left_pane

    local left_sep = Instance.new("Frame")
    left_sep.Size = UDim2.new(1, 0, 0, 1)
    left_sep.Position = UDim2.new(0, 0, 0, 17)
    left_sep.BackgroundColor3 = P.border
    left_sep.BorderSizePixel = 0
    left_sep.Parent = left_pane

    left_scroll = Instance.new("ScrollingFrame")
    left_scroll.Size = UDim2.new(1, 0, 1, -18)
    left_scroll.Position = UDim2.new(0, 0, 0, 18)
    left_scroll.BackgroundTransparency = 1
    left_scroll.BorderSizePixel = 0
    left_scroll.ScrollBarThickness = 3
    left_scroll.ScrollBarImageColor3 = P.border
    left_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    left_scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    left_scroll.Parent = left_pane

    local left_layout = Instance.new("UIListLayout")
    left_layout.Padding = UDim.new(0, 0)
    left_layout.SortOrder = Enum.SortOrder.LayoutOrder
    left_layout.Parent = left_scroll

    local left_pad = Instance.new("UIPadding")
    left_pad.PaddingLeft = UDim.new(0, 8)
    left_pad.PaddingTop = UDim.new(0, 4)
    left_pad.Parent = left_scroll

    --========================
    -- RIGHT PANE (SOURCE)
    --========================
    right_pane = Instance.new("Frame")
    right_pane.Size = UDim2.new(0, half_w, 0, BODY_H - 2)
    right_pane.Position = UDim2.new(0, gap * 2 + half_w, 0, BODY_Y + 1)
    right_pane.BackgroundColor3 = P.panel
    right_pane.BorderSizePixel = 0
    right_pane.ClipsDescendants = true
    right_pane.Parent = body

    local rb = Instance.new("Frame")
    rb.Size = UDim2.new(1, 2, 1, 2)
    rb.Position = UDim2.new(0, -1, 0, -1)
    rb.BackgroundTransparency = 1
    rb.BorderSizePixel = 1
    rb.BorderColor3 = P.border
    rb.Parent = right_pane

    local right_head = Instance.new("TextLabel")
    right_head.Size = UDim2.new(1, 0, 0, 18)
    right_head.BackgroundColor3 = P.header
    right_head.BorderSizePixel = 0
    right_head.Text = "  SOURCE"
    right_head.TextColor3 = P.dim
    right_head.Font = Enum.Font.Code
    right_head.TextSize = 10
    right_head.TextXAlignment = Enum.TextXAlignment.Left
    right_head.Parent = right_pane

    local right_sep = Instance.new("Frame")
    right_sep.Size = UDim2.new(1, 0, 0, 1)
    right_sep.Position = UDim2.new(0, 0, 0, 17)
    right_sep.BackgroundColor3 = P.border
    right_sep.BorderSizePixel = 0
    right_sep.Parent = right_pane

    -- VIEW
    right_view_frame = Instance.new("Frame")
    right_view_frame.Size = UDim2.new(1, 0, 1, -18)
    right_view_frame.Position = UDim2.new(0, 0, 0, 18)
    right_view_frame.BackgroundTransparency = 1
    right_view_frame.BorderSizePixel = 0
    right_view_frame.Parent = right_pane

    right_view_scroll = Instance.new("ScrollingFrame")
    right_view_scroll.Size = UDim2.new(1, 0, 1, 0)
    right_view_scroll.BackgroundTransparency = 1
    right_view_scroll.BorderSizePixel = 0
    right_view_scroll.ScrollBarThickness = 3
    right_view_scroll.ScrollBarImageColor3 = P.border
    right_view_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    right_view_scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
    right_view_scroll.ScrollingDirection = Enum.ScrollingDirection.XY
    right_view_scroll.Parent = right_view_frame

    right_view_content = Instance.new("TextLabel")
    right_view_content.Size = UDim2.new(0, 0, 0, 0)
    right_view_content.Position = UDim2.new(0, 8, 0, 4)
    right_view_content.BackgroundTransparency = 1
    right_view_content.RichText = true
    right_view_content.Text = ""
    right_view_content.TextColor3 = P.txt
    right_view_content.TextXAlignment = Enum.TextXAlignment.Left
    right_view_content.TextYAlignment = Enum.TextYAlignment.Top
    right_view_content.Font = Enum.Font.Code
    right_view_content.TextSize = 13
    right_view_content.TextWrapped = false
    right_view_content.AutomaticSize = Enum.AutomaticSize.XY
    right_view_content.Parent = right_view_scroll

    -- EDIT — overlay: снизу подсвеченный RichText, сверху невидимый TextBox
    right_edit_frame = Instance.new("Frame")
    right_edit_frame.Size = UDim2.new(1, 0, 1, -18)
    right_edit_frame.Position = UDim2.new(0, 0, 0, 18)
    right_edit_frame.BackgroundTransparency = 1
    right_edit_frame.BorderSizePixel = 0
    right_edit_frame.Visible = false
    right_edit_frame.Parent = right_pane

    right_edit_scroll = Instance.new("ScrollingFrame")
    right_edit_scroll.Size = UDim2.new(1, 0, 1, 0)
    right_edit_scroll.BackgroundTransparency = 1
    right_edit_scroll.BorderSizePixel = 0
    right_edit_scroll.ScrollBarThickness = 3
    right_edit_scroll.ScrollBarImageColor3 = P.border
    right_edit_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    right_edit_scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
    right_edit_scroll.ScrollingDirection = Enum.ScrollingDirection.XY
    right_edit_scroll.Parent = right_edit_frame

    -- Подсвеченный текст (фон)
    right_edit_display = Instance.new("TextLabel")
    right_edit_display.Size = UDim2.new(0, 0, 0, 0)
    right_edit_display.Position = UDim2.new(0, 8, 0, 4)
    right_edit_display.BackgroundTransparency = 1
    right_edit_display.RichText = true
    right_edit_display.Text = ""
    right_edit_display.TextColor3 = P.txt
    right_edit_display.TextXAlignment = Enum.TextXAlignment.Left
    right_edit_display.TextYAlignment = Enum.TextYAlignment.Top
    right_edit_display.Font = Enum.Font.Code
    right_edit_display.TextSize = 13
    right_edit_display.TextWrapped = false
    right_edit_display.AutomaticSize = Enum.AutomaticSize.XY
    right_edit_display.ZIndex = 1
    right_edit_display.Parent = right_edit_scroll

    -- Невидимый TextBox — ловит ввод
    right_edit_box = Instance.new("TextBox")
    right_edit_box.Size = UDim2.new(0, 0, 0, 0)
    right_edit_box.Position = UDim2.new(0, 8, 0, 4)
    right_edit_box.BackgroundTransparency = 1
    right_edit_box.Text = ""
    right_edit_box.TextColor3 = P.panel
    right_edit_box.TextTransparency = 1
    right_edit_box.TextXAlignment = Enum.TextXAlignment.Left
    right_edit_box.TextYAlignment = Enum.TextYAlignment.Top
    right_edit_box.Font = Enum.Font.Code
    right_edit_box.TextSize = 13
    right_edit_box.TextWrapped = false
    right_edit_box.MultiLine = true
    right_edit_box.ClearTextOnFocus = false
    right_edit_box.AutomaticSize = Enum.AutomaticSize.XY
    right_edit_box.ZIndex = 2
    right_edit_box.Parent = right_edit_scroll

    right_edit_box:GetPropertyChangedSignal("Text"):Connect(function()
        if loading_edit then return end
        is_dirty = true
        refresh_edit_display()
        update_header()
    end)

    --========================
    -- FOOTER
    --========================
    footer = Instance.new("Frame")
    footer.Size = UDim2.new(1, 0, 0, FOOTER_H)
    footer.Position = UDim2.new(0, 0, 1, -FOOTER_H)
    footer.BackgroundColor3 = P.header
    footer.BorderSizePixel = 0
    footer.Parent = body

    local fs1 = Instance.new("Frame")
    fs1.Size = UDim2.new(1, 0, 0, 1)
    fs1.Position = UDim2.new(0, 0, 0, 0)
    fs1.BackgroundColor3 = P.border_hi
    fs1.BorderSizePixel = 0
    fs1.Parent = footer

    local fs2 = Instance.new("Frame")
    fs2.Size = UDim2.new(1, 0, 0, 1)
    fs2.Position = UDim2.new(0, 0, 0, 1)
    fs2.BackgroundColor3 = P.border
    fs2.BorderSizePixel = 0
    fs2.Parent = footer

    local _, btn_dec_outer = mk_button(footer, "DECOMPILE", 96, 8, P.accent)
    btn_decompile = btn_dec_outer:FindFirstChildOfClass("TextButton")

    local _, btn_edit_outer = mk_button(footer, "EDIT", 70, 110, P.txt)
    btn_edit = btn_edit_outer:FindFirstChildOfClass("TextButton")

    local _, btn_rev_outer = mk_button(footer, "REVERT", 76, 186, P.warn)
    btn_revert = btn_rev_outer:FindFirstChildOfClass("TextButton")

    local _, btn_exit_outer = mk_button(footer, "EXIT", 60, PANEL_W - 140, P.err)
    btn_exit = btn_exit_outer:FindFirstChildOfClass("TextButton")

    local _, btn_save_outer = mk_button(footer, "SAVE", 72, PANEL_W - 76, P.dim)
    btn_save = btn_save_outer:FindFirstChildOfClass("TextButton")

    --========================
    -- EVENTS
    --========================
    btn_decompile.MouseButton1Click:Connect(function()
        if mode == "edit" then exit_edit_mode() end
        cached_src = nil
        cached_for_bytecode = nil
        M.render_all()
        console.log("re-decompiled via D1", P.accent)
    end)

    btn_edit.MouseButton1Click:Connect(function()
        if mode == "view" then
            enter_edit_mode()
        else
            exit_edit_mode()
        end
    end)

    btn_revert.MouseButton1Click:Connect(revert_all)

    btn_exit.MouseButton1Click:Connect(function()
        outer.Visible = false
    end)

    btn_save.MouseButton1Click:Connect(do_save)
end

function M.show()
    if not bp then M.start() end
    ensure_sg()
    if bp.Parent ~= p_sg then bp.Parent = p_sg end
    bp.Visible = true
    M.render_all()
end

function M.hide()
    if bp then bp.Visible = false end
end

function M.init(bc)
    BC = bc
    console = bc.modules.console
    parser = bc.modules.parser
    patch = bc.modules.patch
    decompile = bc.modules.decompile
    C = console.colors()
end

return M
