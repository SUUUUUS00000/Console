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
local right_gutter, right_gutter_inner
local right_view_frame, right_view_scroll, right_view_content
local right_edit_frame, right_edit_scroll, right_edit_display, right_edit_box
local footer
local btn_decompile, btn_edit, btn_revert, btn_exit, btn_save

local mode = "view"
local cached_src = nil
local cached_for_bytecode = nil
local original_src = nil
local is_dirty = false
local loading_edit = false
local is_focused = false

local dragOn, dragStart, dragPos, dragFrame, dragMoved
local DRAG_THRESHOLD = 6

local u = game:GetService("UserInputService")
local cam = workspace.CurrentCamera

--=====================================================================
-- FE PALETTE
--=====================================================================

local function px(r, g, b) return Color3.fromRGB(r, g, b) end

local P = {
    bg = px(30,30,30), topbar = px(37,37,38), editor = px(24,24,24),
    gutter = px(35,35,38), gutter_ln = px(133,133,133),
    button = px(55,55,58), button_pri = px(0,122,204),
    border = px(80,80,80), txt = px(220,220,220), title = px(200,200,200),
    dim = px(140,140,145), hint = px(85,85,90),
    ok = px(120,200,120), warn = px(230,180,90), err = px(230,95,95),
    scroll = px(150,150,150),
    marker_changed = px(220,180,60),
    marker_added = px(90,200,120),
    marker_removed = px(220,90,90),
}

local FONT = Enum.Font.Arcade
local TSIZE = 14
local LINE_H = 14

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
    keyword = "#569CD6", string = "#CE9178", number = "#B5CEA8",
    comment = "#6A9955", ident = "#DCDCDC", builtin = "#4EC9B0", op = "#DCDCDC",
}

local function is_ws(c) return c==" " or c=="\t" or c=="\n" or c=="\r" end
local function is_digit(c) return c>="0" and c<="9" end
local function is_alpha(c) return (c>="a" and c<="z") or (c>="A" and c<="Z") or c=="_" end
local function is_alnum(c) return is_alpha(c) or is_digit(c) end

local function tokenize(src)
    local tokens = {}
    local i, n = 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if is_ws(c) then
            local j = i
            while j <= n and is_ws(src:sub(j, j)) do j = j + 1 end
            tokens[#tokens + 1] = {t="ws", v=src:sub(i, j - 1)}
            i = j
        elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
            if src:sub(i, i + 3) == "--[[" then
                local j = src:find("]]", i + 4, true)
                if j then
                    tokens[#tokens + 1] = {t="comment", v=src:sub(i, j + 1)}
                    i = j + 2
                else
                    tokens[#tokens + 1] = {t="comment", v=src:sub(i)}
                    i = n + 1
                end
            else
                local j = src:find("\n", i, true) or (n + 1)
                tokens[#tokens + 1] = {t="comment", v=src:sub(i, j - 1)}
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
            tokens[#tokens + 1] = {t="string", v=src:sub(i, j - 1)}
            i = j
        elseif is_digit(c) or (c == "." and is_digit(src:sub(i + 1, i + 1))) then
            local j = i
            while j <= n and (is_digit(src:sub(j,j)) or src:sub(j,j)=="." or src:sub(j,j)=="x" or src:sub(j,j)=="X" or src:sub(j,j):match("[a-fA-F]")) do j = j + 1 end
            tokens[#tokens + 1] = {t="number", v=src:sub(i, j - 1)}
            i = j
        elseif is_alpha(c) then
            local j = i
            while j <= n and is_alnum(src:sub(j, j)) do j = j + 1 end
            local word = src:sub(i, j - 1)
            local t = "ident"
            if KEYWORDS[word] then t = "keyword"
            elseif BUILTINS[word] then t = "builtin" end
            tokens[#tokens + 1] = {t=t, v=word}
            i = j
        else
            local two = src:sub(i, i + 1)
            if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." then
                tokens[#tokens + 1] = {t="op", v=two}
                i = i + 2
            else
                tokens[#tokens + 1] = {t="op", v=c}
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
    if #src > 200000 then return "-- source too large" end
    local parts = {}
    for _, tok in ipairs(tokenize(src)) do
        if tok.t == "ws" then
            parts[#parts + 1] = tok.v
        else
            parts[#parts + 1] = '<font color="' .. (HL[tok.t] or HL.ident) .. '">' .. escape_rich(tok.v) .. '</font>'
        end
    end
    return table.concat(parts)
end

--=====================================================================
-- DIFF: сравнение строк оригинала и текущего
--=====================================================================

local function split_lines(s)
    local t = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = line end
    return t
end

-- Возвращает массив статусов: "same", "changed", "added", "removed"
local function compute_line_diff(orig, curr)
    local o = split_lines(orig)
    local c = split_lines(curr)
    local status = {}
    local om = {}
    local cm = {}
    for i, l in ipairs(o) do om[l] = om[l] or {}; table.insert(om[l], i) end
    for i, l in ipairs(c) do cm[l] = cm[l] or {}; table.insert(cm[l], i) end
    local oi, ci = 1, 1
    while oi <= #o or ci <= #c do
        if oi <= #o and ci <= #c and o[oi] == c[ci] then
            status[ci] = "same"
            oi = oi + 1
            ci = ci + 1
        elseif ci <= #c and cm[c[ci]] and #cm[c[ci]] > 0 then
            -- строка есть в оригинале где-то дальше — значит добавленная
            status[ci] = "added"
            ci = ci + 1
        elseif oi <= #o then
            -- строка в оригинале есть, но в текущем её нет — удалённая (пропускаем, но помечаем следующую как сдвиг)
            oi = oi + 1
        else
            if ci <= #c then status[ci] = "added" end
            ci = ci + 1
        end
    end
    for i = 1, #c do
        if not status[i] then status[i] = "changed" end
    end
    return status
end

--=====================================================================
-- FE-STYLE BUTTON
--=====================================================================

local function mk_button(parent, text, w, x, y)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, w, 0, 26)
    b.Position = UDim2.new(0, x, 0, y)
    b.BackgroundColor3 = P.button
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = px(255,255,255)
    b.Font = FONT
    b.TextSize = 15
    b.AutoButtonColor = false
    b.Parent = parent
    return b
end

local function setup_scroll(sf)
    sf.ScrollBarThickness = 10
    sf.ScrollBarImageColor3 = P.scroll
    sf.ScrollBarImageTransparency = 0.15
    sf.ElasticBehavior = Enum.ElasticBehavior.Never
    sf.ScrollingDirection = Enum.ScrollingDirection.Y
end

local function drag_begin(frame)
    frame.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragOn = true; dragMoved = false
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
        nx = math.clamp(nx, -(sz.X - 60), vp.X - 60)
        ny = math.clamp(ny, -6, vp.Y - 40)
        dragFrame.Position = UDim2.new(0, nx, 0, ny)
    end
end)

u.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
        dragOn = false; dragMoved = false; dragFrame = nil
    end
end)

--=====================================================================
-- RENDERING
--=====================================================================

local function clear_scroll(sc)
    for _, v in ipairs(sc:GetChildren()) do
        if v:IsA("Frame") or v:IsA("TextLabel") then v:Destroy() end
    end
end

local function render_hex()
    clear_scroll(left_scroll)
    local st = patch and patch.state
    if not st or not st.working then
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, LINE_H)
        l.BackgroundTransparency = 1
        l.Text = "  no bytecode"
        l.TextColor3 = P.dim
        l.Font = FONT
        l.TextSize = TSIZE
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Parent = left_scroll
        return
    end
    local d = st.working
    for i = 1, #d, 16 do
        local chunk = string.sub(d, i, i + 15)
        local hp = {}
        for j = 1, #chunk do hp[j] = string.format("%02X", string.byte(chunk, j)) end
        local r = Instance.new("Frame")
        r.Size = UDim2.new(1, 0, 0, LINE_H)
        r.BackgroundTransparency = 1
        r.Parent = left_scroll
        local addr = Instance.new("TextLabel")
        addr.Size = UDim2.new(0, 50, 1, 0)
        addr.BackgroundTransparency = 1
        addr.Text = string.format("%06X", i - 1)
        addr.TextColor3 = P.gutter_ln
        addr.Font = FONT
        addr.TextSize = TSIZE
        addr.TextXAlignment = Enum.TextXAlignment.Left
        addr.LineHeight = 1
        addr.Parent = r
        local bytes = Instance.new("TextLabel")
        bytes.Size = UDim2.new(1, -100, 1, 0)
        bytes.Position = UDim2.new(0, 52, 0, 0)
        bytes.BackgroundTransparency = 1
        bytes.Text = table.concat(hp, " ")
        bytes.TextColor3 = P.txt
        bytes.Font = FONT
        bytes.TextSize = TSIZE
        bytes.TextXAlignment = Enum.TextXAlignment.Left
        bytes.LineHeight = 1
        bytes.Parent = r
        local asc = Instance.new("TextLabel")
        asc.Size = UDim2.new(0, 44, 1, 0)
        asc.Position = UDim2.new(1, -48, 0, 0)
        asc.BackgroundTransparency = 1
        asc.Text = chunk:gsub("[^%g ]", ".")
        asc.TextColor3 = P.hint
        asc.Font = FONT
        asc.TextSize = TSIZE
        asc.TextXAlignment = Enum.TextXAlignment.Left
        asc.LineHeight = 1
        asc.Parent = r
    end
end

local function get_source(force)
    local st = patch and patch.state
    if not st or not st.working then return nil, "no script" end
    if st.user_src then return st.user_src, "user" end
    if not force and cached_src and cached_for_bytecode == st.working then
        return cached_src, "cache"
    end
    if not decompile or not decompile.decompile_best then return nil, "no decompiler" end
    local ok, result, kind, err = pcall(decompile.decompile_best, st.working)
    if not ok then return nil, "crash: " .. tostring(result) end
    if not result then return nil, "failed: " .. tostring(err) end
    cached_src = result
    cached_for_bytecode = st.working
    if not original_src then original_src = result end
    return result, kind
end

local function update_gutter(src, diff_status)
    if not right_gutter_inner then return end
    for _, v in ipairs(right_gutter_inner:GetChildren()) do
        if v:IsA("TextLabel") or v:IsA("Frame") then v:Destroy() end
    end
    local n = 1
    for _ in src:gmatch("\n") do n = n + 1 end
    if n > 3000 then n = 3000 end

    for i = 1, n do
        -- маркер изменения
        if diff_status and diff_status[i] and diff_status[i] ~= "same" then
            local color = P.marker_changed
            if diff_status[i] == "added" then color = P.marker_added end
            if diff_status[i] == "removed" then color = P.marker_removed end
            local marker = Instance.new("Frame")
            marker.Size = UDim2.new(0, 3, 0, LINE_H)
            marker.Position = UDim2.new(0, 0, 0, (i - 1) * LINE_H)
            marker.BackgroundColor3 = color
            marker.BorderSizePixel = 0
            marker.ZIndex = 7
            marker.Parent = right_gutter_inner
        end

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -4, 0, LINE_H)
        lbl.Position = UDim2.new(0, 0, 0, (i - 1) * LINE_H)
        lbl.BackgroundTransparency = 1
        lbl.Text = tostring(i)
        lbl.TextColor3 = P.gutter_ln
        lbl.Font = FONT
        lbl.TextSize = TSIZE
        lbl.TextXAlignment = Enum.TextXAlignment.Right
        lbl.LineHeight = 1
        lbl.ZIndex = 6
        lbl.Parent = right_gutter_inner
    end
    right_gutter_inner.Size = UDim2.new(1, 0, 0, n * LINE_H + 8)
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
        right_view_content.Text = '<font color="#5a5a5f">-- no script loaded</font>'
        update_gutter("")
        return
    end
    local src, kind = get_source(force)
    if not src then
        right_view_content.Text = '<font color="#e05f5f">-- ' .. escape_rich(tostring(kind)) .. '</font>'
        update_gutter("")
        return
    end
    right_view_content.Text = highlight(src)
    local status = original_src and compute_line_diff(original_src, src) or nil
    update_gutter(src, status)
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
        parts[#parts + 1] = #st.working .. "b"
    else
        parts[#parts + 1] = "no script"
    end
    header_info.Text = table.concat(parts, "  ·  ")
    local dot_c = P.hint
    if st and st.script then
        dot_c = is_dirty and P.warn or P.ok
    end
    status_dot.BackgroundColor3 = dot_c
    btn_save.BackgroundColor3 = is_dirty and P.button_pri or P.button
    if mode == "edit" then
        btn_edit.Text = "DONE"; btn_edit.BackgroundColor3 = P.button_pri
    else
        btn_edit.Text = "EDIT"; btn_edit.BackgroundColor3 = P.button
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
    local src = right_edit_box.Text
    right_edit_display.Text = highlight(src)
    local status = original_src and compute_line_diff(original_src, src) or nil
    update_gutter(src, status)
end

local function enter_edit_mode()
    loading_edit = true
    mode = "edit"
    local src = get_source(false) or ""
    right_edit_box.Text = src
    right_edit_display.Text = highlight(src)
    local status = original_src and compute_line_diff(original_src, src) or nil
    update_gutter(src, status)
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
            st.user_src = new_src; is_dirty = true
        else
            st.user_src = nil; is_dirty = false
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
    original_src = nil
    if patch and patch.revert then patch.revert() end
    M.render_all()
end

local function do_save()
    local st = patch and patch.state
    if not st or not st.script then console.log("no script", P.err); return end
    if not is_dirty and not st.dirty and not st.user_src then
        console.log("nothing to save", P.dim); return
    end
    if not patch or not patch.do_apply then console.log("no apply", P.err); return end
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
        local ok, r = pcall(gethui); if ok and r then gui_root = r end
    end
    if not gui_root then gui_root = game:GetService("CoreGui") end
    if p_sg and p_sg.Parent == gui_root then return p_sg end
    if p_sg then p_sg:Destroy() end
    p_sg = Instance.new("ScreenGui")
    p_sg.Name = "BCEditor"
    p_sg.ResetOnSpawn = false
    p_sg.IgnoreGuiInset = true
    p_sg.DisplayOrder = 100
    p_sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    p_sg.Parent = gui_root
    return p_sg
end

function M.start()
    ensure_sg()

    local PANEL_W, PANEL_H = 900, 520
    local HEADER_H, FOOTER_H = 30, 44
    local PAD = 6
    local BODY_Y = HEADER_H + PAD
    local BODY_H = PANEL_H - HEADER_H - FOOTER_H - PAD * 2

    bp = Instance.new("Frame")
    bp.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
    bp.Position = UDim2.new(0.5, -PANEL_W/2, 0.5, -PANEL_H/2)
    bp.BackgroundColor3 = P.bg
    bp.BorderColor3 = P.border
    bp.BorderSizePixel = 2
    bp.ClipsDescendants = true
    bp.Visible = false
    bp.Parent = p_sg

    -- HEADER
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, -4, 0, HEADER_H)
    header.Position = UDim2.new(0, 2, 0, 2)
    header.BackgroundColor3 = P.topbar
    header.BorderSizePixel = 0
    header.Parent = bp

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 1, 0)
    title.BackgroundTransparency = 1
    title.Text = "BYTECODE EDITOR"
    title.TextColor3 = P.title
    title.Font = FONT
    title.TextSize = 16
    title.ZIndex = 2
    title.Parent = header

    header_info = Instance.new("TextLabel")
    header_info.Size = UDim2.new(0, 300, 1, 0)
    header_info.Position = UDim2.new(0, 8, 0, 0)
    header_info.BackgroundTransparency = 1
    header_info.Text = ""
    header_info.TextColor3 = P.dim
    header_info.Font = FONT
    header_info.TextSize = 12
    header_info.TextXAlignment = Enum.TextXAlignment.Left
    header_info.ZIndex = 3
    header_info.Parent = header

    status_dot = Instance.new("Frame")
    status_dot.Size = UDim2.new(0, 10, 0, 10)
    status_dot.Position = UDim2.new(1, -16, 0.5, -5)
    status_dot.BackgroundColor3 = P.hint
    status_dot.BorderSizePixel = 0
    status_dot.ZIndex = 3
    status_dot.Parent = header

    drag_begin(header)

    -- LEFT / RIGHT PANES
    local gap = 4
    local half_w = (PANEL_W - gap * 3 - 4) / 2

    left_pane = Instance.new("Frame")
    left_pane.Size = UDim2.new(0, half_w, 0, BODY_H)
    left_pane.Position = UDim2.new(0, PAD, 0, BODY_Y)
    left_pane.BackgroundColor3 = P.editor
    left_pane.ClipsDescendants = true
    left_pane.Parent = bp

    left_scroll = Instance.new("ScrollingFrame")
    left_scroll.Size = UDim2.new(1, 0, 1, 0)
    left_scroll.BackgroundTransparency = 1
    left_scroll.BorderSizePixel = 0
    left_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    setup_scroll(left_scroll)
    left_scroll.Parent = left_pane

    local left_layout = Instance.new("UIListLayout")
    left_layout.SortOrder = Enum.SortOrder.LayoutOrder
    left_layout.Parent = left_scroll

    local left_pad = Instance.new("UIPadding")
    left_pad.PaddingLeft = UDim.new(0, 6)
    left_pad.PaddingTop = UDim.new(0, 4)
    left_pad.Parent = left_scroll

    -- RIGHT PANE
    right_pane = Instance.new("Frame")
    right_pane.Size = UDim2.new(0, half_w, 0, BODY_H)
    right_pane.Position = UDim2.new(0, PAD * 2 + half_w, 0, BODY_Y)
    right_pane.BackgroundColor3 = P.editor
    right_pane.ClipsDescendants = true
    right_pane.Parent = bp

    local GUTTER_W = 40
    right_gutter = Instance.new("Frame")
    right_gutter.Size = UDim2.new(0, GUTTER_W, 1, 0)
    right_gutter.BackgroundColor3 = P.gutter
    right_gutter.BorderSizePixel = 0
    right_gutter.ClipsDescendants = true
    right_gutter.ZIndex = 5
    right_gutter.Parent = right_pane

    right_gutter_inner = Instance.new("Frame")
    right_gutter_inner.Size = UDim2.new(1, 0, 0, 0)
    right_gutter_inner.Position = UDim2.new(0, 0, 0, 4)
    right_gutter_inner.BackgroundTransparency = 1
    right_gutter_inner.ZIndex = 6
    right_gutter_inner.Parent = right_gutter

    -- VIEW FRAME
    right_view_frame = Instance.new("Frame")
    right_view_frame.Size = UDim2.new(1, -GUTTER_W, 1, 0)
    right_view_frame.Position = UDim2.new(0, GUTTER_W, 0, 0)
    right_view_frame.BackgroundTransparency = 1
    right_view_frame.Parent = right_pane

    right_view_scroll = Instance.new("ScrollingFrame")
    right_view_scroll.Size = UDim2.new(1, 0, 1, 0)
    right_view_scroll.BackgroundTransparency = 1
    right_view_scroll.BorderSizePixel = 0
    right_view_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    setup_scroll(right_view_scroll)
    right_view_scroll.Parent = right_view_frame

    right_view_content = Instance.new("TextLabel")
    right_view_content.Size = UDim2.new(0, 0, 0, 0)
    right_view_content.Position = UDim2.new(0, 6, 0, 4)
    right_view_content.BackgroundTransparency = 1
    right_view_content.RichText = true
    right_view_content.Text = ""
    right_view_content.TextColor3 = P.txt
    right_view_content.TextXAlignment = Enum.TextXAlignment.Left
    right_view_content.TextYAlignment = Enum.TextYAlignment.Top
    right_view_content.Font = FONT
    right_view_content.TextSize = TSIZE
    right_view_content.TextWrapped = false
    right_view_content.LineHeight = 1
    right_view_content.AutomaticSize = Enum.AutomaticSize.XY
    right_view_content.ZIndex = 3
    right_view_content.Parent = right_view_scroll

    -- EDIT FRAME
    right_edit_frame = Instance.new("Frame")
    right_edit_frame.Size = UDim2.new(1, -GUTTER_W, 1, 0)
    right_edit_frame.Position = UDim2.new(0, GUTTER_W, 0, 0)
    right_edit_frame.BackgroundTransparency = 1
    right_edit_frame.Visible = false
    right_edit_frame.Parent = right_pane

    right_edit_scroll = Instance.new("ScrollingFrame")
    right_edit_scroll.Size = UDim2.new(1, 0, 1, 0)
    right_edit_scroll.BackgroundTransparency = 1
    right_edit_scroll.BorderSizePixel = 0
    right_edit_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    setup_scroll(right_edit_scroll)
    right_edit_scroll.Parent = right_edit_frame

    right_edit_display = Instance.new("TextLabel")
    right_edit_display.Size = UDim2.new(0, 0, 0, 0)
    right_edit_display.Position = UDim2.new(0, 6, 0, 4)
    right_edit_display.BackgroundTransparency = 1
    right_edit_display.RichText = true
    right_edit_display.Text = ""
    right_edit_display.TextColor3 = P.txt
    right_edit_display.TextXAlignment = Enum.TextXAlignment.Left
    right_edit_display.TextYAlignment = Enum.TextYAlignment.Top
    right_edit_display.Font = FONT
    right_edit_display.TextSize = TSIZE
    right_edit_display.TextWrapped = false
    right_edit_display.LineHeight = 1
    right_edit_display.AutomaticSize = Enum.AutomaticSize.XY
    right_edit_display.ZIndex = 3
    right_edit_display.Parent = right_edit_scroll

    right_edit_box = Instance.new("TextBox")
    right_edit_box.Size = UDim2.new(0, 0, 0, 0)
    right_edit_box.Position = UDim2.new(0, 6, 0, 4)
    right_edit_box.BackgroundTransparency = 1
    right_edit_box.Text = ""
    right_edit_box.TextColor3 = P.editor
    right_edit_box.TextTransparency = 1
    right_edit_box.TextXAlignment = Enum.TextXAlignment.Left
    right_edit_box.TextYAlignment = Enum.TextYAlignment.Top
    right_edit_box.Font = FONT
    right_edit_box.TextSize = TSIZE
    right_edit_box.LineHeight = 1
    right_edit_box.TextWrapped = false
    right_edit_box.MultiLine = true
    right_edit_box.ClearTextOnFocus = false
    right_edit_box.AutomaticSize = Enum.AutomaticSize.XY
    right_edit_box.ZIndex = 4
    right_edit_box.Parent = right_edit_scroll

    -- Sync gutter with scroll
    right_edit_scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        right_gutter_inner.Position = UDim2.new(0, 0, 0, -right_edit_scroll.CanvasPosition.Y + 4)
    end)
    right_view_scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        right_gutter_inner.Position = UDim2.new(0, 0, 0, -right_view_scroll.CanvasPosition.Y + 4)
    end)

    -- Update scroll canvas when content changes
    right_edit_display:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        right_edit_scroll.CanvasSize = UDim2.new(0, right_edit_display.AbsoluteSize.X + 20, 0, right_edit_display.AbsoluteSize.Y + 20)
    end)
    right_view_content:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        right_view_scroll.CanvasSize = UDim2.new(0, right_view_content.AbsoluteSize.X + 20, 0, right_view_content.AbsoluteSize.Y + 20)
    end)

    right_edit_box:GetPropertyChangedSignal("Text"):Connect(function()
        if loading_edit then return end
        is_dirty = true
        refresh_edit_display()
        update_header()
    end)

    right_edit_box.Focused:Connect(function() is_focused = true end)
    right_edit_box.FocusLost:Connect(function() is_focused = false end)

    -- FOOTER
    footer = Instance.new("Frame")
    footer.Size = UDim2.new(1, -4, 0, FOOTER_H - PAD - 2)
    footer.Position = UDim2.new(0, 2, 1, -FOOTER_H + 2)
    footer.BackgroundTransparency = 1
    footer.Parent = bp

    btn_decompile = mk_button(footer, "DECOMPILE", 110, 0, 4)
    btn_edit = mk_button(footer, "EDIT", 80, 116, 4)
    btn_revert = mk_button(footer, "REVERT", 90, 202, 4)
    btn_save = mk_button(footer, "SAVE", 100, PANEL_W - PAD * 2 - 100 - 4, 4)
    btn_exit = mk_button(footer, "EXIT", 80, PANEL_W - PAD * 2 - 100 - 80 - 10, 4)

    btn_decompile.MouseButton1Click:Connect(function()
        if mode == "edit" then exit_edit_mode() end
        cached_src = nil; cached_for_bytecode = nil; original_src = nil
        M.render_all()
        console.log("re-decompiled via D1", P.ok)
    end)

    btn_edit.MouseButton1Click:Connect(function()
        if mode == "view" then enter_edit_mode() else exit_edit_mode() end
    end)

    btn_revert.MouseButton1Click:Connect(revert_all)
    btn_exit.MouseButton1Click:Connect(function() bp.Visible = false end)
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
