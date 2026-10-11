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
local right_edit_frame
local right_gutter, right_gutter_container
local right_scroll, right_input, right_cursor
local footer
local btn_decompile, btn_edit, btn_revert, btn_exit, btn_save

local mode = "view"
local cached_src = nil
local cached_for_bytecode = nil
local is_dirty = false

local dragOn, dragStart, dragPos, dragFrame, dragMoved
local DRAG_THRESHOLD = 6

local u = game:GetService("UserInputService")
local cam = workspace.CurrentCamera
local textService = game:GetService("TextService")

local function px(r, g, b) return Color3.fromRGB(r, g, b) end

local P = {
    bg = px(30,30,30), topbar = px(37,37,38), editor = px(24,24,24),
    gutter = px(35,35,38), gutter_ln = px(133,133,133),
    button = px(55,55,58), button_pri = px(0,122,204),
    border = px(80,80,80), txt = px(220,220,220), title = px(200,200,200),
    dim = px(140,140,145), hint = px(85,85,90),
    ok = px(120,200,120), warn = px(230,180,90), err = px(230,95,95),
    scroll = px(150,150,150),
}

local FONT = Enum.Font.Arcade
local TSIZE = 14
local LH = 14
local BUF_LEN = 1000
local BUF_MIN = 100
local BUF_MAX = 1900

local KW = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
    ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
    ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
    ["while"] = true, ["continue"] = true, ["export"] = true, ["type"] = true,
}

local BI = {
    ["game"] = true, ["workspace"] = true, ["script"] = true, ["task"] = true,
    ["print"] = true, ["warn"] = true, ["error"] = true, ["assert"] = true,
    ["pcall"] = true, ["xpcall"] = true, ["require"] = true, ["spawn"] = true,
    ["wait"] = true, ["delay"] = true, ["tick"] = true, ["time"] = true,
    ["typeof"] = true, ["pairs"] = true, ["ipairs"] = true, ["next"] = true,
    ["select"] = true, ["unpack"] = true, ["rawget"] = true, ["rawset"] = true,
    ["rawequal"] = true, ["rawlen"] = true, ["setmetatable"] = true,
    ["getmetatable"] = true, ["tostring"] = true, ["tonumber"] = true,
    ["Instance"] = true, ["Vector3"] = true, ["Vector2"] = true, ["CFrame"] = true,
    ["Color3"] = true, ["UDim2"] = true, ["UDim"] = true, ["TweenInfo"] = true,
    ["Enum"] = true, ["shared"] = true, ["_G"] = true, ["_VERSION"] = true,
    ["vector"] = true, ["buffer"] = true, ["bit32"] = true, ["utf8"] = true,
}

local HL = {
    keyword = "#569CD6", string = "#CE9178", number = "#B5CEA8",
    comment = "#6A9955", ident = "#DCDCDC", builtin = "#4EC9B0", op = "#DCDCDC",
}

local function is_ws(c) return c == " " or c == "\t" or c == "\n" or c == "\r" end
local function is_digit(c) return c >= "0" and c <= "9" end
local function is_alpha(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" end
local function is_alnum(c) return is_alpha(c) or is_digit(c) end

local function tokenize(s)
    local t = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if is_ws(c) then
            local j = i
            while j <= n and is_ws(s:sub(j, j)) do j = j + 1 end
            t[#t + 1] = {tok = "ws", v = s:sub(i, j - 1)}
            i = j
        elseif c == "-" and s:sub(i + 1, i + 1) == "-" then
            if s:sub(i, i + 3) == "--[[" then
                local j = s:find("]]", i + 4, true)
                if j then
                    t[#t + 1] = {tok = "comment", v = s:sub(i, j + 1)}
                    i = j + 2
                else
                    t[#t + 1] = {tok = "comment", v = s:sub(i)}
                    i = n + 1
                end
            else
                local j = s:find("\n", i, true) or (n + 1)
                t[#t + 1] = {tok = "comment", v = s:sub(i, j - 1)}
                i = j
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local cc = s:sub(j, j)
                if cc == "\\" then j = j + 2
                elseif cc == c then j = j + 1; break
                else j = j + 1 end
            end
            t[#t + 1] = {tok = "string", v = s:sub(i, j - 1)}
            i = j
        elseif is_digit(c) or (c == "." and is_digit(s:sub(i + 1, i + 1))) then
            local j = i
            while j <= n and (is_digit(s:sub(j, j)) or s:sub(j, j) == "." or s:sub(j, j):match("[xXa-fA-F]")) do
                j = j + 1
            end
            t[#t + 1] = {tok = "number", v = s:sub(i, j - 1)}
            i = j
        elseif is_alpha(c) then
            local j = i
            while j <= n and is_alnum(s:sub(j, j)) do j = j + 1 end
            local w = s:sub(i, j - 1)
            local k = "ident"
            if KW[w] then k = "keyword"
            elseif BI[w] then k = "builtin" end
            t[#t + 1] = {tok = k, v = w}
            i = j
        else
            local two = s:sub(i, i + 1)
            if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." then
                t[#t + 1] = {tok = "op", v = two}
                i = i + 2
            else
                t[#t + 1] = {tok = "op", v = c}
                i = i + 1
            end
        end
    end
    return t
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
        if tok.tok == "ws" then
            parts[#parts + 1] = tok.v
        else
            parts[#parts + 1] = '<font color="' .. (HL[tok.tok] or HL.ident) .. '">' .. escape_rich(tok.v) .. '</font>'
        end
    end
    return table.concat(parts)
end

local ed_code = {""}
local ed_line = 1
local ed_col = 1
local ed_line_labels = {}
local ed_gutter_labels = {}
local ed_visible = {}
local ed_syntax = {}
local ed_focused = false
local ed_buf = string.rep("x", BUF_LEN)
local ed_prev = ed_buf
local ed_skip = false
local ed_del_held = false
local ed_rst_token = 0
local ed_pending = false
local ed_gutter_width = 40

local function ed_get_code() return table.concat(ed_code, "\n") end

local function ed_req_render()
    if ed_pending then return end
    ed_pending = true
    task.defer(function()
        ed_pending = false
        M.render_editor()
    end)
end

local function ed_reset_sentinel()
    ed_skip = true
    right_input.Text = ""
    right_input.Text = ed_buf
    ed_prev = ed_buf
    ed_skip = false
end

local function ed_sched_reset()
    ed_rst_token = ed_rst_token + 1
    local token = ed_rst_token
    task.defer(function()
        if token == ed_rst_token and not ed_del_held then
            ed_reset_sentinel()
        end
    end)
end

local function ed_set_code(txt)
    txt = txt:gsub("\r\n", "\n"):gsub("\r", "\n")
    ed_code = {}
    for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
        ed_code[#ed_code + 1] = line
    end
    if #ed_code == 0 then ed_code = {""} end
    if #ed_code > 5000 then
        local t2 = {}
        for i = 1, 5000 do t2[i] = ed_code[i] end
        ed_code = t2
    end
    ed_syntax = {}
    ed_line = 1
    ed_col = 1
    ed_reset_sentinel()
    M.render_editor()
end

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
        l.Size = UDim2.new(1, 0, 0, LH)
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
        local chunk = d:sub(i, i + 15)
        local hp = {}
        for j = 1, #chunk do hp[j] = string.format("%02X", chunk:byte(j)) end
        local r = Instance.new("Frame")
        r.Size = UDim2.new(1, 0, 0, LH)
        r.BackgroundTransparency = 1
        r.Parent = left_scroll
        local a = Instance.new("TextLabel")
        a.Size = UDim2.new(0, 50, 1, 0)
        a.BackgroundTransparency = 1
        a.Text = string.format("%06X", i - 1)
        a.TextColor3 = P.gutter_ln
        a.Font = FONT
        a.TextSize = TSIZE
        a.TextXAlignment = Enum.TextXAlignment.Left
        a.LineHeight = 1
        a.Parent = r
        local b = Instance.new("TextLabel")
        b.Size = UDim2.new(1, -100, 1, 0)
        b.Position = UDim2.new(0, 52, 0, 0)
        b.BackgroundTransparency = 1
        b.Text = table.concat(hp, " ")
        b.TextColor3 = P.txt
        b.Font = FONT
        b.TextSize = TSIZE
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.LineHeight = 1
        b.Parent = r
        local c2 = Instance.new("TextLabel")
        c2.Size = UDim2.new(0, 44, 1, 0)
        c2.Position = UDim2.new(1, -48, 0, 0)
        c2.BackgroundTransparency = 1
        c2.Text = chunk:gsub("[^%g ]", ".")
        c2.TextColor3 = P.hint
        c2.Font = FONT
        c2.TextSize = TSIZE
        c2.TextXAlignment = Enum.TextXAlignment.Left
        c2.LineHeight = 1
        c2.Parent = r
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
    local ok, r, kind, err = pcall(decompile.decompile_best, st.working)
    if not ok then return nil, "crash: " .. tostring(r) end
    if not r then return nil, "failed: " .. tostring(err) end
    cached_src = r
    cached_for_bytecode = st.working
    if st and not st.original_src then
        st.original_src = r
    end
    return r, kind
end

local function render_view()
    local st = patch and patch.state
    if not st or not st.script then
        right_view_content.Text = '<font color="#5a5a5f">-- no script loaded</font>'
        return
    end
    local src, kind = get_source(false)
    if not src then
        right_view_content.Text = '<font color="#e05f5f">-- ' .. escape_rich(tostring(kind)) .. '</font>'
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
        parts[#parts + 1] = #st.working .. "b"
    else
        parts[#parts + 1] = "no script"
    end
    header_info.Text = table.concat(parts, "  ·  ")
    local dot = P.hint
    if st and st.script then
        dot = is_dirty and P.warn or P.ok
    end
    status_dot.BackgroundColor3 = dot
    btn_save.BackgroundColor3 = is_dirty and P.button_pri or P.button
    if mode == "edit" then
        btn_edit.Text = "DONE"
        btn_edit.BackgroundColor3 = P.button_pri
    else
        btn_edit.Text = "EDIT"
        btn_edit.BackgroundColor3 = P.button
    end
end

function M.render_all()
    render_hex()
    if mode == "view" then render_view() end
    update_header()
end

local function ed_update_gutter_width()
    local n = #ed_code
    local sample = textService:GetTextSize("0", TSIZE, FONT, Vector2.new(100, 100)).X
    local w = math.max(24, string.len(tostring(n)) * sample + 8)
    if w ~= ed_gutter_width then
        ed_gutter_width = w
        right_gutter.Size = UDim2.new(0, w, 1, 0)
        right_scroll.Position = UDim2.new(0, w, 0, 0)
        right_scroll.Size = UDim2.new(1, -w, 1, 0)
    end
end

function M.render_editor(isUserScrolling)
    if mode ~= "edit" then return end
    if #ed_code == 0 then ed_code = {""} end
    ed_line = math.clamp(ed_line, 1, #ed_code)
    ed_col = math.clamp(ed_col, 1, #(ed_code[ed_line] or "") + 1)
    ed_update_gutter_width()

    local total = #ed_code
    local view = right_scroll.AbsoluteSize
    local vx = view.X > 0 and view.X or 300
    local vy = view.Y > 0 and view.Y or 200
    right_scroll.CanvasSize = UDim2.new(0, math.max(vx, 2000), 0, math.max(vy, total * LH + 20))

    local cam_y = right_scroll.CanvasPosition.Y
    local start_l = math.max(1, math.floor(cam_y / LH) - 2)
    local end_l = math.min(total, math.ceil((cam_y + vy) / LH) + 3)

    local new_visible = {}
    for idx = start_l, end_l do
        new_visible[idx] = true
        local lbl = ed_line_labels[idx]
        if not lbl then
            lbl = Instance.new("TextLabel")
            lbl.BackgroundTransparency = 1
            lbl.TextColor3 = P.txt
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextYAlignment = Enum.TextYAlignment.Top
            lbl.Font = FONT
            lbl.TextSize = TSIZE
            lbl.LineHeight = 1
            lbl.RichText = true
            lbl.ZIndex = 3
            lbl.Parent = right_scroll
            ed_line_labels[idx] = lbl
        end
        lbl.Position = UDim2.new(0, 4, 0, (idx - 1) * LH + 4)
        lbl.Size = UDim2.new(0, 2000, 0, LH)
        lbl.Visible = true
        local txt = ed_code[idx] or ""
        local cached = ed_syntax[idx]
        if not cached then
            if #txt <= 1000 then
                local ok, res = pcall(highlight, txt)
                cached = (ok and res) or txt
            else
                cached = txt
            end
            ed_syntax[idx] = cached
        end
        lbl.Text = cached

        local g = ed_gutter_labels[idx]
        if not g then
            g = Instance.new("TextLabel")
            g.BackgroundTransparency = 1
            g.TextColor3 = P.gutter_ln
            g.TextXAlignment = Enum.TextXAlignment.Right
            g.TextYAlignment = Enum.TextYAlignment.Top
            g.Font = FONT
            g.TextSize = TSIZE
            g.LineHeight = 1
            g.ZIndex = 4
            g.Parent = right_gutter_container
            ed_gutter_labels[idx] = g
        end
        g.Size = UDim2.new(1, -4, 0, LH)
        g.Position = UDim2.new(0, 0, 0, (idx - 1) * LH + 4)
        g.Text = tostring(idx)
        g.Visible = true
    end

    for idx in pairs(ed_visible) do
        if not new_visible[idx] then
            if ed_line_labels[idx] then ed_line_labels[idx].Visible = false end
            if ed_gutter_labels[idx] then ed_gutter_labels[idx].Visible = false end
        end
    end
    ed_visible = new_visible

    local cur_line_str = ed_code[ed_line] or ""
    local left = cur_line_str:sub(1, ed_col - 1)
    local cx = textService:GetTextSize(left, TSIZE, FONT, Vector2.new(99999, 100)).X + 4
    local cy = (ed_line - 1) * LH + 4
    right_cursor.Position = UDim2.new(0, cx, 0, cy)
    right_input.Position = UDim2.new(0, cx, 0, cy)

    right_gutter_container.Position = UDim2.new(0, 0, 0, -cam_y)

    if not isUserScrolling then
        local tx, ty = right_scroll.CanvasPosition.X, right_scroll.CanvasPosition.Y
        if cy < ty then
            ty = math.max(0, cy - 4)
        elseif cy + LH > ty + vy - 8 then
            ty = cy + LH - vy + 8
        end
        if cx < tx then
            tx = math.max(0, cx - 10)
        elseif cx + 10 > tx + vx then
            tx = cx - vx + 20
        end
        if tx ~= right_scroll.CanvasPosition.X or ty ~= right_scroll.CanvasPosition.Y then
            right_scroll.CanvasPosition = Vector2.new(tx, ty)
        end
    end
end

local function apply_text_change()
    local cur = right_input.Text
    if cur == ed_prev then return end
    local old_len, new_len = #ed_prev, #cur
    local min_len = math.min(old_len, new_len)
    local prefix = 0
    while prefix < min_len and ed_prev:byte(prefix + 1) == cur:byte(prefix + 1) do
        prefix = prefix + 1
    end
    local suffix = 0
    while suffix < min_len - prefix
        and ed_prev:byte(old_len - suffix) == cur:byte(new_len - suffix) do
        suffix = suffix + 1
    end
    local removed = old_len - prefix - suffix
    local inserted = cur:sub(prefix + 1, new_len - suffix)

    if removed > 400 then
        ed_reset_sentinel()
        ed_req_render()
        return
    end

    if removed > 0 then
        for _ = 1, removed do
            if ed_col > 1 then
                local cur_line = ed_code[ed_line] or ""
                ed_code[ed_line] = cur_line:sub(1, ed_col - 2) .. cur_line:sub(ed_col)
                ed_col = ed_col - 1
                ed_syntax[ed_line] = nil
            elseif ed_line > 1 then
                local prev = ed_code[ed_line - 1] or ""
                ed_code[ed_line - 1] = prev .. (ed_code[ed_line] or "")
                table.remove(ed_code, ed_line)
                table.remove(ed_syntax, ed_line)
                ed_line = ed_line - 1
                ed_col = #ed_code[ed_line] + 1
                ed_syntax[ed_line] = nil
            else
                break
            end
        end
    end

    if inserted ~= "" then
        local cur_line = ed_code[ed_line] or ""
        local left = cur_line:sub(1, ed_col - 1)
        local right = cur_line:sub(ed_col)
        if inserted:find("\n", 1, true) then
            local parts = {}
            for p in (inserted .. "\n"):gmatch("([^\n]*)\n") do
                parts[#parts + 1] = p
            end
            ed_code[ed_line] = left .. parts[1]
            ed_syntax[ed_line] = nil
            for i = 2, #parts do
                table.insert(ed_code, ed_line + i - 1, parts[i])
                table.insert(ed_syntax, ed_line + i - 1, false)
            end
            ed_code[ed_line + #parts - 1] = ed_code[ed_line + #parts - 1] .. right
            ed_syntax[ed_line + #parts - 1] = nil
            ed_line = ed_line + #parts - 1
            ed_col = #ed_code[ed_line] - #right + 1
        else
            ed_code[ed_line] = left .. inserted .. right
            ed_syntax[ed_line] = nil
            ed_col = ed_col + #inserted
        end
    end

    ed_prev = cur
    ed_req_render()

    if not ed_del_held and (new_len <= BUF_MIN or new_len >= BUF_MAX) then
        ed_sched_reset()
    end
end

local function position_by_click(pos)
    local origin = right_scroll.AbsolutePosition
    local rel_x = pos.X - origin.X + right_scroll.CanvasPosition.X - 4
    local rel_y = pos.Y - origin.Y + right_scroll.CanvasPosition.Y - 4
    ed_line = math.clamp(math.floor(rel_y / LH) + 1, 1, #ed_code)
    local line = ed_code[ed_line] or ""
    local best_col, best_diff = 1, math.huge
    for col = 1, #line + 1 do
        local w = textService:GetTextSize(line:sub(1, col - 1), TSIZE, FONT, Vector2.new(99999, 100)).X
        local d = math.abs(w - rel_x)
        if d < best_diff then
            best_diff = d
            best_col = col
        else
            break
        end
    end
    ed_col = best_col
    ed_reset_sentinel()
    task.defer(function()
        if not right_input:IsFocused() then
            right_input:CaptureFocus()
        end
    end)
    M.render_editor(true)
end

local touch_start = nil

local function setup_editor_input()
    u.InputBegan:Connect(function(inp, gpe)
        if inp.KeyCode == Enum.KeyCode.Backspace or inp.KeyCode == Enum.KeyCode.Delete then
            if ed_focused then ed_del_held = true end
        end
        if not ed_focused or gpe then return end

        if inp.KeyCode == Enum.KeyCode.Delete then
            local line = ed_code[ed_line] or ""
            if ed_col <= #line then
                ed_code[ed_line] = line:sub(1, ed_col - 1) .. line:sub(ed_col + 1)
                ed_syntax[ed_line] = nil
            elseif ed_line < #ed_code then
                ed_code[ed_line] = line .. (ed_code[ed_line + 1] or "")
                table.remove(ed_code, ed_line + 1)
                table.remove(ed_syntax, ed_line + 1)
                ed_syntax[ed_line] = nil
            end
            ed_reset_sentinel()
            ed_req_render()
        elseif inp.KeyCode == Enum.KeyCode.Return or inp.KeyCode == Enum.KeyCode.KeypadEnter then
            if #ed_code < 5000 then
                local line = ed_code[ed_line] or ""
                local left = line:sub(1, ed_col - 1)
                local right = line:sub(ed_col)
                ed_code[ed_line] = left
                ed_syntax[ed_line] = nil
                table.insert(ed_code, ed_line + 1, right)
                table.insert(ed_syntax, ed_line + 1, false)
                ed_line = ed_line + 1
                ed_col = 1
                ed_reset_sentinel()
                ed_req_render()
            end
        elseif inp.KeyCode == Enum.KeyCode.Left then
            if ed_col > 1 then
                ed_col = ed_col - 1
            elseif ed_line > 1 then
                ed_line = ed_line - 1
                ed_col = #ed_code[ed_line] + 1
            end
            ed_reset_sentinel()
            M.render_editor(true)
        elseif inp.KeyCode == Enum.KeyCode.Right then
            if ed_col <= #(ed_code[ed_line] or "") then
                ed_col = ed_col + 1
            elseif ed_line < #ed_code then
                ed_line = ed_line + 1
                ed_col = 1
            end
            ed_reset_sentinel()
            M.render_editor(true)
        elseif inp.KeyCode == Enum.KeyCode.Up then
            if ed_line > 1 then
                ed_line = ed_line - 1
                ed_col = math.min(ed_col, #(ed_code[ed_line] or "") + 1)
            end
            ed_reset_sentinel()
            M.render_editor(true)
        elseif inp.KeyCode == Enum.KeyCode.Down then
            if ed_line < #ed_code then
                ed_line = ed_line + 1
                ed_col = math.min(ed_col, #(ed_code[ed_line] or "") + 1)
            end
            ed_reset_sentinel()
            M.render_editor(true)
        elseif inp.KeyCode == Enum.KeyCode.Home then
            ed_col = 1
            ed_reset_sentinel()
            M.render_editor(true)
        elseif inp.KeyCode == Enum.KeyCode.End then
            ed_col = #(ed_code[ed_line] or "") + 1
            ed_reset_sentinel()
            M.render_editor(true)
        elseif inp.KeyCode == Enum.KeyCode.Tab then
            local line = ed_code[ed_line] or ""
            ed_code[ed_line] = line:sub(1, ed_col - 1) .. "    " .. line:sub(ed_col)
            ed_syntax[ed_line] = nil
            ed_col = ed_col + 4
            ed_reset_sentinel()
            ed_req_render()
        end
    end)

    u.InputEnded:Connect(function(inp)
        if inp.KeyCode == Enum.KeyCode.Backspace or inp.KeyCode == Enum.KeyCode.Delete then
            ed_del_held = false
            if ed_focused then ed_reset_sentinel() end
        end
    end)

    u.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
            local pos = inp.Position
            local ap = right_scroll.AbsolutePosition
            local as = right_scroll.AbsoluteSize
            if pos.X >= ap.X and pos.X <= ap.X + as.X
                and pos.Y >= ap.Y and pos.Y <= ap.Y + as.Y then
                touch_start = {pos = pos, t = tick()}
            end
        end
    end)

    u.InputEnded:Connect(function(inp)
        if (inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch) and touch_start then
            local d = (inp.Position - touch_start.pos).Magnitude
            local dt = tick() - touch_start.t
            if d < 12 and dt < 0.4 and mode == "edit" then
                position_by_click(inp.Position)
            end
            touch_start = nil
        end
    end)

    right_scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        right_gutter_container.Position = UDim2.new(0, 0, 0, -right_scroll.CanvasPosition.Y)
        M.render_editor(true)
    end)
end

local function mk_button(parent, text, w, x, y)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, w, 0, 26)
    b.Position = UDim2.new(0, x, 0, y)
    b.BackgroundColor3 = P.button
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = px(255, 255, 255)
    b.Font = FONT
    b.TextSize = 15
    b.AutoButtonColor = false
    b.Parent = parent
    return b
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
        nx = math.clamp(nx, -(sz.X - 60), vp.X - 60)
        ny = math.clamp(ny, -6, vp.Y - 40)
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

local function enter_edit_mode()
    mode = "edit"
    right_view_frame.Visible = false
    right_edit_frame.Visible = true
    local src = get_source(false) or ""
    ed_set_code(src)
    ed_focused = true
    is_dirty = false
    update_header()
    task.defer(function()
        right_input:CaptureFocus()
    end)
end

local function exit_edit_mode()
    mode = "view"
    right_edit_frame.Visible = false
    right_view_frame.Visible = true
    right_input:ReleaseFocus()
    ed_focused = false

    local new_src = ed_get_code()
    local prev = cached_src or ""
    local st = patch and patch.state
    if st then
        if new_src ~= prev then
            st.user_src = new_src
            is_dirty = true
        else
            st.user_src = nil
            is_dirty = false
        end
    end
    render_view()
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
    if mode == "edit" then
        local new_src = ed_get_code()
        local prev = cached_src or ""
        if new_src ~= prev then
            st.user_src = new_src
            is_dirty = true
        end
    end
    if not is_dirty and not st.dirty and not st.user_src then
        console.log("nothing to save", P.dim)
        return
    end
    if not patch or not patch.do_apply then
        console.log("no apply", P.err)
        return
    end
    patch.do_apply()
    is_dirty = false
    cached_src = nil
    cached_for_bytecode = nil
    M.render_all()
end

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
    p_sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    p_sg.Parent = gui_root
    return p_sg
end

function M.start()
    ensure_sg()

    local PANEL_W, PANEL_H = 900, 520
    local HEADER_H, FOOTER_H, PAD = 30, 44, 6
    local BODY_Y = HEADER_H + PAD
    local BODY_H = PANEL_H - HEADER_H - FOOTER_H - PAD * 2

    bp = Instance.new("Frame")
    bp.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
    bp.Position = UDim2.new(0.5, -PANEL_W / 2, 0.5, -PANEL_H / 2)
    bp.BackgroundColor3 = P.bg
    bp.BorderColor3 = P.border
    bp.BorderSizePixel = 2
    bp.ClipsDescendants = true
    bp.Visible = false
    bp.Parent = p_sg

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
    left_scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    left_scroll.ScrollBarThickness = 10
    left_scroll.ScrollBarImageColor3 = P.scroll
    left_scroll.ScrollBarImageTransparency = 0.15
    left_scroll.ScrollingDirection = Enum.ScrollingDirection.Y
    left_scroll.Parent = left_pane

    local ll = Instance.new("UIListLayout")
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Parent = left_scroll

    local lp = Instance.new("UIPadding")
    lp.PaddingLeft = UDim.new(0, 6)
    lp.PaddingTop = UDim.new(0, 4)
    lp.Parent = left_scroll

    right_pane = Instance.new("Frame")
    right_pane.Size = UDim2.new(0, half_w, 0, BODY_H)
    right_pane.Position = UDim2.new(0, PAD * 2 + half_w, 0, BODY_Y)
    right_pane.BackgroundColor3 = P.editor
    right_pane.ClipsDescendants = true
    right_pane.Parent = bp

    right_view_frame = Instance.new("Frame")
    right_view_frame.Size = UDim2.new(1, 0, 1, 0)
    right_view_frame.BackgroundTransparency = 1
    right_view_frame.Parent = right_pane

    right_view_scroll = Instance.new("ScrollingFrame")
    right_view_scroll.Size = UDim2.new(1, 0, 1, 0)
    right_view_scroll.BackgroundTransparency = 1
    right_view_scroll.BorderSizePixel = 0
    right_view_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    right_view_scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
    right_view_scroll.ScrollBarThickness = 10
    right_view_scroll.ScrollBarImageColor3 = P.scroll
    right_view_scroll.ScrollBarImageTransparency = 0.15
    right_view_scroll.Parent = right_view_frame

    right_view_content = Instance.new("TextLabel")
    right_view_content.Size = UDim2.new(0, 0, 0, 0)
    right_view_content.Position = UDim2.new(0, 4, 0, 4)
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

    right_edit_frame = Instance.new("Frame")
    right_edit_frame.Size = UDim2.new(1, 0, 1, 0)
    right_edit_frame.BackgroundTransparency = 1
    right_edit_frame.Visible = false
    right_edit_frame.Parent = right_pane

    right_gutter = Instance.new("Frame")
    right_gutter.Size = UDim2.new(0, ed_gutter_width, 1, 0)
    right_gutter.BackgroundColor3 = P.gutter
    right_gutter.BorderSizePixel = 0
    right_gutter.ClipsDescendants = true
    right_gutter.ZIndex = 5
    right_gutter.Parent = right_edit_frame

    right_gutter_container = Instance.new("Frame")
    right_gutter_container.Size = UDim2.new(1, 0, 0, 0)
    right_gutter_container.Position = UDim2.new(0, 0, 0, 0)
    right_gutter_container.BackgroundTransparency = 1
    right_gutter_container.ZIndex = 6
    right_gutter_container.Parent = right_gutter

    right_scroll = Instance.new("ScrollingFrame")
    right_scroll.Size = UDim2.new(1, -ed_gutter_width, 1, 0)
    right_scroll.Position = UDim2.new(0, ed_gutter_width, 0, 0)
    right_scroll.BackgroundTransparency = 1
    right_scroll.BorderSizePixel = 0
    right_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    right_scroll.ScrollBarThickness = 10
    right_scroll.ScrollBarImageColor3 = P.scroll
    right_scroll.ScrollBarImageTransparency = 0.15
    right_scroll.ScrollingDirection = Enum.ScrollingDirection.XY
    right_scroll.ClipsDescendants = true
    right_scroll.Parent = right_edit_frame

    right_input = Instance.new("TextBox")
    right_input.Size = UDim2.new(0, 4, 0, LH)
    right_input.Position = UDim2.new(0, 4, 0, 4)
    right_input.BackgroundTransparency = 1
    right_input.Text = ""
    right_input.TextColor3 = P.editor
    right_input.TextTransparency = 1
    right_input.ClearTextOnFocus = false
    right_input.MultiLine = true
    right_input.Font = FONT
    right_input.TextSize = TSIZE
    right_input.TextXAlignment = Enum.TextXAlignment.Left
    right_input.TextYAlignment = Enum.TextYAlignment.Top
    right_input.TextWrapped = false
    right_input.ZIndex = 7
    right_input.Parent = right_scroll

    right_cursor = Instance.new("Frame")
    right_cursor.Size = UDim2.new(0, 2, 0, TSIZE)
    right_cursor.Position = UDim2.new(0, 4, 0, 4)
    right_cursor.BackgroundColor3 = px(255, 255, 255)
    right_cursor.BorderSizePixel = 0
    right_cursor.ZIndex = 6
    right_cursor.Parent = right_scroll

    right_input:GetPropertyChangedSignal("Text"):Connect(function()
        if ed_skip or not ed_focused then return end
        apply_text_change()
    end)

    right_input.Focused:Connect(function()
        ed_focused = true
        right_cursor.Visible = true
        ed_reset_sentinel()
    end)

    right_input.FocusLost:Connect(function()
        ed_focused = false
        right_cursor.Visible = false
        ed_del_held = false
    end)

    setup_editor_input()

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
        cached_src = nil
        cached_for_bytecode = nil
        M.render_all()
        console.log("re-decompiled", P.ok)
    end)

    btn_edit.MouseButton1Click:Connect(function()
        if mode == "view" then enter_edit_mode() else exit_edit_mode() end
    end)

    btn_revert.MouseButton1Click:Connect(revert_all)

    btn_exit.MouseButton1Click:Connect(function()
        bp.Visible = false
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
