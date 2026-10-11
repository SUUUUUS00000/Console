local M = {}
M.name = "panel"

local BC
local console, parser, disasm, cfgs, patch, names, varflow, ssa, expr

local C
local gui_root
local p_sg
local bp, bpHead, bpTitle
local bpLeft, bpLeftScroll, bpRight, bpRightScroll
local bpFoot, bpExit, bpApply

local hex_lines = {}
local dis_lines = {}
local selected_byte = -1
local dragOn, dragStart, dragPos, dragFrame
local ssa_error_reported = false
local expr_error_reported = false

local u = game:GetService("UserInputService")
local cam = workspace.CurrentCamera

local function drag(frame)
    frame.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragOn = true
            dragFrame = frame
            dragStart = i.Position
            dragPos = frame.Position
        end
    end)
end

u.InputChanged:Connect(function(i)
    if dragOn and dragFrame and (i.UserInputType == Enum.UserInputType.MouseMovement
    or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - dragStart
        local newX = dragPos.X.Offset + d.X
        local newY = dragPos.Y.Offset + d.Y

        local vp = cam.ViewportSize
        local sz = dragFrame.AbsoluteSize
        local minX = -(sz.X - 120)
        local maxX = vp.X - 120
        local minY = 0
        local maxY = vp.Y - 40

        if newX < minX then newX = minX end
        if newX > maxX then newX = maxX end
        if newY < minY then newY = minY end
        if newY > maxY then newY = maxY end

        dragFrame.Position = UDim2.new(dragPos.X.Scale, newX, dragPos.Y.Scale, newY)
    end
end)

u.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        dragOn = false
        dragFrame = nil
    end
end)

local function resolve_gui_root()
    if console and console.gui_root then
        local r = console.gui_root()
        if r then return r end
    end
    if gethui then
        local ok, r = pcall(gethui)
        if ok and r then return r end
    end
    return game:GetService("CoreGui")
end

local function ensure_sg()
    gui_root = resolve_gui_root()
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

local function clear_hex()
    for _, v in ipairs(bpLeftScroll:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end
    hex_lines = {}
end

local function clear_dis()
    for _, v in ipairs(bpRightScroll:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end
    dis_lines = {}
end

local function clear_highlight()
    for _, l in ipairs(hex_lines) do
        if l.f then l.f.BackgroundTransparency = 1 end
    end
    for _, l in ipairs(dis_lines) do
        if l.f then l.f.BackgroundTransparency = 1 end
    end
end

local function select_line(byte_offset)
    selected_byte = byte_offset
    clear_highlight()

    local hi = math.floor(byte_offset / 16)
    if hex_lines[hi + 1] and hex_lines[hi + 1].f then
        hex_lines[hi + 1].f.BackgroundTransparency = 0.7
        hex_lines[hi + 1].f.BackgroundColor3 = C.accent
    end

    local dis_idx = nil
    for i, l in ipairs(dis_lines) do
        if l.byte_offset == byte_offset then
            l.f.BackgroundTransparency = 0.85
            l.f.BackgroundColor3 = C.accent
            dis_idx = i
            break
        end
    end

    local y = math.max(0, hi * 16 - 60)
    bpLeftScroll.CanvasPosition = Vector2.new(0, y)

    if dis_idx then
        local dy = math.max(0, (dis_idx - 1) * 20 - 80)
        bpRightScroll.CanvasPosition = Vector2.new(0, dy)
    end
end

local function render_hex()
    clear_hex()
    local st = patch and patch.state
    if not st or not st.working then return end
    local d = st.working
    local count = 0
    for i = 1, #d, 16 do
        count = count + 1
        if count > 4000 then
            local r = Instance.new("Frame")
            r.Size = UDim2.new(1, 0, 0, 16)
            r.BackgroundTransparency = 1
            r.Parent = bpLeftScroll
            local t2 = Instance.new("TextLabel")
            t2.Size = UDim2.new(1, 0, 1, 0)
            t2.BackgroundTransparency = 1
            t2.Text = "... truncated ..."
            t2.TextColor3 = C.dim
            t2.Font = Enum.Font.Code
            t2.TextSize = 12
            t2.TextXAlignment = Enum.TextXAlignment.Left
            t2.Parent = r
            break
        end
        local chunk = string.sub(d, i, i + 15)
        local hp = {}
        for j = 1, #chunk do hp[j] = string.format("%02X", string.byte(chunk, j)) end
        local hx = table.concat(hp, " ")
        while #hx < 47 do hx = hx .. " " end
        local asc = chunk:gsub("[^%g ]", ".")

        local r = Instance.new("Frame")
        r.Size = UDim2.new(1, 0, 0, 16)
        r.BackgroundTransparency = 1
        r.Parent = bpLeftScroll

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = string.format("%06X  %s |%s|", i - 1, hx, asc)
        lbl.TextColor3 = C.hex
        lbl.Font = Enum.Font.Code
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = r

        table.insert(hex_lines, {f = r, offset = i - 1})
    end
end

local function fmt_expr(ins, ssa_data, expr_db, proto, labels)
    if not ssa_data then
        return disasm.fmt(ins, proto, labels, {})
    end

    local pc = ins.word_idx
    local reads = ssa_data.read_at[pc] or {}
    local writes = ssa_data.write_at[pc] or {}

    local function W(reg)
        local v = writes[reg]
        if v then return ssa_data.name_of[v] or ("t" .. v) end
        return "R" .. reg
    end

    local function R(reg)
        local v = reads[reg]
        if not v then return "R" .. reg end
        local e = expr_db and expr_db.get(v)
        if e then return e.code end
        return ssa_data.name_of[v] or ("t" .. v)
    end

    local function cstr(i) return disasm.const_str(proto, i) end
    local function L(t)
        if labels and labels[t] then return labels[t] end
        return string.format("%+d", t - ins.word_idx - ins.length)
    end

    local n = ins.name
    if n == "NOP" then return "" end
    if n == "LOADNIL" then return W(ins.a) .. " = nil" end
    if n == "LOADB" then
        if ins.c ~= 0 then
            return W(ins.a) .. " = " .. (ins.b ~= 0 and "true" or "false") .. " ; goto " .. L(disasm.jump_target(ins))
        end
        return W(ins.a) .. " = " .. (ins.b ~= 0 and "true" or "false")
    end
    if n == "LOADN" then return W(ins.a) .. " = " .. ins.d end
    if n == "LOADK" then return W(ins.a) .. " = " .. cstr(ins.d) end
    if n == "LOADKX" then return W(ins.a) .. " = " .. cstr(ins.aux or 0) end
    if n == "MOVE" then return W(ins.a) .. " = " .. R(ins.b) end
    if n == "GETUPVAL" then return W(ins.a) .. " = upval" .. ins.b end
    if n == "SETUPVAL" then return "upval" .. ins.b .. " = " .. R(ins.a) end
    if n == "GETGLOBAL" then return W(ins.a) .. " = " .. cstr(ins.aux or 0) end
    if n == "SETGLOBAL" then return cstr(ins.aux or 0) .. " = " .. R(ins.a) end
    if n == "GETIMPORT" then return W(ins.a) .. " = " .. cstr(ins.d) end
    if n == "GETTABLE" then return W(ins.a) .. " = " .. R(ins.b) .. "[" .. R(ins.c) .. "]" end
    if n == "SETTABLE" then return R(ins.b) .. "[" .. R(ins.c) .. "] = " .. R(ins.a) end
    if n == "GETTABLEKS" then
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value
        if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
            return W(ins.a) .. " = " .. R(ins.b) .. "." .. kn
        end
        return W(ins.a) .. " = " .. R(ins.b) .. "[" .. cstr(ins.aux or 0) .. "]"
    end
    if n == "SETTABLEKS" then
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value
        if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
            return R(ins.b) .. "." .. kn .. " = " .. R(ins.a)
        end
        return R(ins.b) .. "[" .. cstr(ins.aux or 0) .. "] = " .. R(ins.a)
    end
    if n == "GETTABLEN" then return W(ins.a) .. " = " .. R(ins.b) .. "[" .. (ins.c + 1) .. "]" end
    if n == "SETTABLEN" then return R(ins.b) .. "[" .. (ins.c + 1) .. "] = " .. R(ins.a) end
    if n == "NEWTABLE" then return W(ins.a) .. " = {}" end
    if n == "DUPTABLE" then return W(ins.a) .. " = {dup K" .. ins.d .. "}" end
    if n == "SETLIST" then return R(ins.a) .. "[..] = {..}" end
    if n == "NEWCLOSURE" then return W(ins.a) .. " = closure(P" .. ins.d .. ")" end
    if n == "DUPCLOSURE" then return W(ins.a) .. " = closure(K" .. ins.d .. ")" end
    if n == "CAPTURE" then return "capture " .. ins.a .. " " .. R(ins.b) end
    if n == "NAMECALL" then
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value or "?"
        return W(ins.a) .. " = " .. R(ins.b) .. ":" .. tostring(kn) .. "(...)"
    end
    if n == "CALL" or n == "CALLFB" then
        local nargs = ins.b - 1
        local nres = ins.c - 1
        local args = {}
        for i = 1, nargs do args[#args + 1] = R(ins.a + i) end
        local res
        if nres == 1 then
            res = W(ins.a) .. " = "
        elseif nres == 0 then
            res = ""
        else
            local parts = {}
            for i = 0, nres - 1 do parts[#parts + 1] = W(ins.a + i) end
            res = table.concat(parts, ", ") .. " = "
        end
        return res .. "call(" .. R(ins.a) .. (#args > 0 and (", " .. table.concat(args, ", ")) or "") .. ")"
    end
    if n == "RETURN" then
        local nres = ins.b - 1
        if nres <= 0 then return "return" end
        local vals = {}
        for i = 0, nres - 1 do vals[#vals + 1] = R(ins.a + i) end
        return "return " .. table.concat(vals, ", ")
    end
    if n == "JUMP" then return "goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPBACK" then return "back " .. L(disasm.jump_target(ins)) end
    if n == "JUMPX" then return "gotoX " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIF" then return "if " .. R(ins.a) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFNOT" then return "if not " .. R(ins.a) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFEQ" then return "if " .. R(ins.a) .. " == " .. R(ins.aux or 0) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFNOTEQ" then return "if " .. R(ins.a) .. " ~= " .. R(ins.aux or 0) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFLE" then return "if " .. R(ins.a) .. " <= " .. R(ins.aux or 0) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFLT" then return "if " .. R(ins.a) .. " < " .. R(ins.aux or 0) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFNOTLE" then return "if " .. R(ins.a) .. " > " .. R(ins.aux or 0) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPIFNOTLT" then return "if " .. R(ins.a) .. " >= " .. R(ins.aux or 0) .. " then goto " .. L(disasm.jump_target(ins)) end
    if n == "JUMPXEQKNIL" then
        local nf = (ins.aux or 0) >= 0x80000000
        return "if " .. R(ins.a) .. " " .. (nf and "~=" or "==") .. " nil then goto " .. L(disasm.jump_target(ins))
    end
    if n == "JUMPXEQKB" then
        local v = (ins.aux or 0) % 2
        return "if " .. R(ins.a) .. " == " .. (v == 1 and "true" or "false") .. " then goto " .. L(disasm.jump_target(ins))
    end
    if n == "JUMPXEQKN" or n == "JUMPXEQKS" then
        local k = (ins.aux or 0) % 0x1000000
        return "if " .. R(ins.a) .. " == " .. cstr(k) .. " then goto " .. L(disasm.jump_target(ins))
    end
    if n == "ADD" then return W(ins.a) .. " = " .. R(ins.b) .. " + " .. R(ins.c) end
    if n == "SUB" then return W(ins.a) .. " = " .. R(ins.b) .. " - " .. R(ins.c) end
    if n == "MUL" then return W(ins.a) .. " = " .. R(ins.b) .. " * " .. R(ins.c) end
    if n == "DIV" then return W(ins.a) .. " = " .. R(ins.b) .. " / " .. R(ins.c) end
    if n == "IDIV" then return W(ins.a) .. " = " .. R(ins.b) .. " // " .. R(ins.c) end
    if n == "MOD" then return W(ins.a) .. " = " .. R(ins.b) .. " % " .. R(ins.c) end
    if n == "POW" then return W(ins.a) .. " = " .. R(ins.b) .. " ^ " .. R(ins.c) end
    if n == "ADDK" then return W(ins.a) .. " = " .. R(ins.b) .. " + " .. cstr(ins.c) end
    if n == "SUBK" then return W(ins.a) .. " = " .. R(ins.b) .. " - " .. cstr(ins.c) end
    if n == "MULK" then return W(ins.a) .. " = " .. R(ins.b) .. " * " .. cstr(ins.c) end
    if n == "DIVK" then return W(ins.a) .. " = " .. R(ins.b) .. " / " .. cstr(ins.c) end
    if n == "MODK" then return W(ins.a) .. " = " .. R(ins.b) .. " % " .. cstr(ins.c) end
    if n == "POWK" then return W(ins.a) .. " = " .. R(ins.b) .. " ^ " .. cstr(ins.c) end
    if n == "SUBRK" then return W(ins.a) .. " = " .. cstr(ins.b) .. " - " .. R(ins.c) end
    if n == "DIVRK" then return W(ins.a) .. " = " .. cstr(ins.b) .. " / " .. R(ins.c) end
    if n == "AND" then return W(ins.a) .. " = " .. R(ins.b) .. " and " .. R(ins.c) end
    if n == "OR" then return W(ins.a) .. " = " .. R(ins.b) .. " or " .. R(ins.c) end
    if n == "ANDK" then return W(ins.a) .. " = " .. R(ins.b) .. " and " .. cstr(ins.c) end
    if n == "ORK" then return W(ins.a) .. " = " .. R(ins.b) .. " or " .. cstr(ins.c) end
    if n == "CONCAT" then
        local parts = {}
        for i = ins.b, ins.c do parts[#parts + 1] = R(i) end
        return W(ins.a) .. " = " .. table.concat(parts, " .. ")
    end
    if n == "NOT" then return W(ins.a) .. " = not " .. R(ins.b) end
    if n == "MINUS" then return W(ins.a) .. " = -" .. R(ins.b) end
    if n == "LENGTH" then return W(ins.a) .. " = #" .. R(ins.b) end
    if n == "FORNPREP" then return "for prep -> " .. L(disasm.jump_target(ins)) end
    if n == "FORNLOOP" then return "for loop -> " .. L(disasm.jump_target(ins)) end
    if n == "FORGPREP" then return "forgen prep -> " .. L(disasm.jump_target(ins)) end
    if n == "FORGLOOP" then
        local cnt = (ins.aux or 0) % 256
        return "forgen loop -> " .. L(disasm.jump_target(ins)) .. " vars=" .. cnt
    end
    if n == "GETVARARGS" then return W(ins.a) .. " = ..." end
    if n == "PREPVARARGS" then return "prep varargs " .. ins.a end

    return string.format("%s A=%d B=%d C=%d D=%d", n, ins.a, ins.b, ins.c, ins.d)
end

local function is_inlined_call(ins, ssa_data, expr_db)
    if not ssa_data or not expr_db then return false end
    if ins.name ~= "CALL" and ins.name ~= "CALLFB" then return false end
    local nres = ins.c - 1
    if nres ~= 1 then return false end
    local writes = ssa_data.write_at[ins.word_idx]
    if not writes then return false end
    local v = writes[ins.a]
    if not v then return false end
    return expr_db.inlineable and expr_db.inlineable[v]
end

local function make_edit_row(ins, current_value, proto, labels, indent, on_change, ssa_data, expr_db)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 22)
    row.BackgroundTransparency = 1
    row.Parent = bpRightScroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -90, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep("  ", indent) .. string.format("%06X  %s",
        ins.byte_offset, fmt_expr(ins, ssa_data, expr_db, proto, labels))
    local col = C.txt
    if ins.name == "LOADN" or ins.name == "LOADK" then
        col = C.warn
    elseif ins.name == "LOADB" then
        col = C.accent
    elseif ins.name:find("JUMP") then
        col = C.dim
    elseif ins.name == "RETURN" then
        col = C.ok
    end
    lbl.TextColor3 = col
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local tb = Instance.new("TextBox")
    tb.Size = UDim2.new(0, 80, 1, -2)
    tb.Position = UDim2.new(1, -84, 0, 1)
    tb.BackgroundColor3 = C.bg
    tb.BorderSizePixel = 1
    tb.BorderColor3 = C.border
    tb.Text = tostring(current_value)
    tb.TextColor3 = C.ok
    tb.Font = Enum.Font.Code
    tb.TextSize = 12
    tb.ClearTextOnFocus = false
    tb.Parent = row

    tb.FocusLost:Connect(function()
        local v = tonumber(tb.Text)
        if not v then
            tb.Text = tostring(current_value)
            console.log("bad number", C.err)
            return
        end
        on_change(v)
    end)

    row.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            select_line(ins.byte_offset)
        end
    end)

    table.insert(dis_lines, {f = row, byte_offset = ins.byte_offset, ins = ins})
end

local function make_read_row(ins, proto, labels, indent, ssa_data, expr_db, dim)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.BackgroundTransparency = 1
    row.Parent = bpRightScroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep("  ", indent) .. string.format("%06X  %s",
        ins.byte_offset, fmt_expr(ins, ssa_data, expr_db, proto, labels))
    local col = C.txt
    if dim then
        col = C.dim
    elseif ins.name == "LOADN" or ins.name == "LOADK" then
        col = C.warn
    elseif ins.name == "LOADB" then
        col = C.accent
    elseif ins.name:find("JUMP") then
        col = C.dim
    elseif ins.name == "RETURN" then
        col = C.ok
    end
    lbl.TextColor3 = col
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    row.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            select_line(ins.byte_offset)
        end
    end)

    table.insert(dis_lines, {f = row, byte_offset = ins.byte_offset, ins = ins})
end

local function make_label_row(text, byte_offset, indent_level)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.BackgroundTransparency = 1
    row.Parent = bpRightScroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep("  ", indent_level or 0) .. text .. ":"
    lbl.TextColor3 = C.accent
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row
end

local function make_end_row(text, indent_level)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.BackgroundTransparency = 1
    row.Parent = bpRightScroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep("  ", indent_level or 0) .. "end: " .. text
    lbl.TextColor3 = C.dim
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row
end

local function safe_cfgs(instrs)
    if cfgs and cfgs.analyze then
        local ok, r = pcall(cfgs.analyze, instrs)
        if ok and type(r) == "table" then return r end
    end
    return { labels = {}, ends = {}, indents = {} }
end

local function safe_ssa(instrs, proto)
    if not ssa or not ssa.build then return nil end
    local ok, r = pcall(ssa.build, instrs, proto)
    if ok and type(r) == "table" then return r end
    if not ssa_error_reported then
        ssa_error_reported = true
        if console and console.log then
            console.log("[ssa] build failed: " .. tostring(r), C.err)
        end
    end
    return nil
end

local function safe_expr(ssa_data, proto, instrs)
    if not expr or not expr.build or not ssa_data then return nil end
    local ok, r = pcall(expr.build, ssa_data, proto, instrs)
    if ok and type(r) == "table" then return r end
    if not expr_error_reported then
        expr_error_reported = true
        if console and console.log then
            console.log("[expr] build failed: " .. tostring(r), C.err)
        end
    end
    return nil
end

local function render_dis()
    clear_dis()
    local st = patch and patch.state
    if not st or not st.instrs or not st.parsed then
        local e = Instance.new("TextLabel")
        e.Size = UDim2.new(1, 0, 0, 18)
        e.BackgroundTransparency = 1
        e.Text = "  no data"
        e.TextColor3 = C.dim
        e.Font = Enum.Font.Code
        e.TextSize = 12
        e.Parent = bpRightScroll
        return
    end

    local proto = st.parsed.protos[st.proto_idx]
    local analysis = safe_cfgs(st.instrs)
    local labels = analysis.labels or {}
    local ends = analysis.ends or {}
    local indents = analysis.indents or {}

    local ssa_data = safe_ssa(st.instrs, proto)
    local expr_db = safe_expr(ssa_data, proto, st.instrs)

    for _, ins in ipairs(st.instrs) do
        local pc = ins.word_idx
        local indent = indents[pc] or 0

        if ends[pc] then
            for _, txt in ipairs(ends[pc]) do
                make_end_row(txt, indent)
            end
        end

        if labels[pc] then
            make_label_row(labels[pc], ins.byte_offset, indent)
        end

        if ins.name == "LOADN" then
            make_edit_row(ins, ins.d, proto, labels, indent, function(v)
                patch.apply_edit_loadn(ins, v)
            end, ssa_data, expr_db)
        elseif ins.name == "LOADB" then
            make_edit_row(ins, ins.b, proto, labels, indent, function(v)
                patch.apply_edit_loadb(ins, v ~= 0)
            end, ssa_data, expr_db)
        elseif ins.name == "LOADK" then
            local c = proto.constants[ins.d + 1]
            if c and c.kind == 2 and type(c.value) == "number" then
                make_edit_row(ins, c.value, proto, labels, indent, function(v)
                    patch.apply_edit_loadk(ins, v)
                end, ssa_data, expr_db)
            else
                make_read_row(ins, proto, labels, indent, ssa_data, expr_db)
            end
        elseif is_inlined_call(ins, ssa_data, expr_db) then
            -- результат вызова ушёл в место использования; показываем как затенённую
            -- строку, чтобы понимать, где реально был CALL
            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, 0, 0, 16)
            row.BackgroundTransparency = 1
            row.Parent = bpRightScroll
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, 0, 1, 0)
            lbl.BackgroundTransparency = 1
            lbl.Text = string.rep("  ", indent) .. string.format("%06X  -- call inlined", ins.byte_offset)
            lbl.TextColor3 = C.dim
            lbl.Font = Enum.Font.Code
            lbl.TextSize = 11
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Parent = row
        else
            make_read_row(ins, proto, labels, indent, ssa_data, expr_db)
        end
    end

    if selected_byte >= 0 then
        for _, l in ipairs(dis_lines) do
            if l.byte_offset == selected_byte then
                l.f.BackgroundTransparency = 0.85
                l.f.BackgroundColor3 = C.accent
                break
            end
        end
    end
end

local function update_save_state()
    local st = patch and patch.state
    if not st then return end
    if st.dirty then
        bpApply.BackgroundColor3 = Color3.fromRGB(45, 110, 55)
        bpApply.BorderColor3 = Color3.fromRGB(120, 200, 120)
        bpApply.TextColor3 = Color3.fromRGB(255, 255, 255)
    else
        bpApply.BackgroundColor3 = C.input
        bpApply.BorderColor3 = C.border
        bpApply.TextColor3 = C.dim
    end
    if st.script and st.working then
        local sch = st.parsed and st.parsed.scheme or "?"
        local ssa_status = ssa_error_reported and "ssa:ERR" or "ssa:OK"
        bpTitle.Text = string.format(
            "BYTECODE   %s   proto=%d   size=%d   op=%s   %s   %s",
            st.script.Name, st.proto_idx, #st.working, sch, ssa_status,
            st.dirty and "[modified]" or "[clean]"
        )
    else
        bpTitle.Text = "BYTECODE  (no script)"
    end
end

function M.render_all()
    render_hex()
    render_dis()
    update_save_state()
end

function M.start()
    ensure_sg()

    bp = Instance.new("Frame")
    bp.Size = UDim2.new(0, 820, 0, 460)
    bp.Position = UDim2.new(0.5, -410, 0.5, -230)
    bp.BackgroundColor3 = C.bg
    bp.BorderSizePixel = 1
    bp.BorderColor3 = C.border
    bp.Visible = false
    bp.Parent = p_sg

    -- заголовок: без отдельной рамки, сливается с панелью
    bpHead = Instance.new("Frame")
    bpHead.Size = UDim2.new(1, -2, 0, 26)
    bpHead.Position = UDim2.new(0, 1, 0, 1)
    bpHead.BackgroundColor3 = C.bar
    bpHead.BorderSizePixel = 0
    bpHead.Parent = bp

    local headSep = Instance.new("Frame")
    headSep.Size = UDim2.new(1, 0, 0, 1)
    headSep.Position = UDim2.new(0, 0, 1, 0)
    headSep.BackgroundColor3 = C.border
    headSep.BorderSizePixel = 0
    headSep.Parent = bpHead

    bpTitle = Instance.new("TextLabel")
    bpTitle.Size = UDim2.new(1, -12, 1, 0)
    bpTitle.Position = UDim2.new(0, 8, 0, 0)
    bpTitle.BackgroundTransparency = 1
    bpTitle.Text = "BYTECODE"
    bpTitle.TextColor3 = C.accent
    bpTitle.Font = Enum.Font.Code
    bpTitle.TextSize = 13
    bpTitle.TextXAlignment = Enum.TextXAlignment.Left
    bpTitle.Parent = bpHead

    drag(bpHead)

    local bodyY = 28
    local footH = 34
    local bodyH = bp.AbsoluteSize.Y - bodyY - footH

    bpLeft = Instance.new("Frame")
    bpLeft.Size = UDim2.new(0.5, -8, 1, -bodyY - footH - 4)
    bpLeft.Position = UDim2.new(0, 4, 0, bodyY)
    bpLeft.BackgroundColor3 = C.input
    bpLeft.BorderSizePixel = 1
    bpLeft.BorderColor3 = C.border
    bpLeft.ClipsDescendants = true
    bpLeft.Parent = bp

    local bpLeftLbl = Instance.new("TextLabel")
    bpLeftLbl.Size = UDim2.new(1, 0, 0, 20)
    bpLeftLbl.BackgroundColor3 = C.bar
    bpLeftLbl.BorderSizePixel = 0
    bpLeftLbl.Text = "  HEX"
    bpLeftLbl.TextColor3 = C.dim
    bpLeftLbl.Font = Enum.Font.Code
    bpLeftLbl.TextSize = 11
    bpLeftLbl.TextXAlignment = Enum.TextXAlignment.Left
    bpLeftLbl.Parent = bpLeft

    local leftSep = Instance.new("Frame")
    leftSep.Size = UDim2.new(1, 0, 0, 1)
    leftSep.Position = UDim2.new(0, 0, 1, 0)
    leftSep.BackgroundColor3 = C.border
    leftSep.BorderSizePixel = 0
    leftSep.Parent = bpLeftLbl

    bpLeftScroll = Instance.new("ScrollingFrame")
    bpLeftScroll.Size = UDim2.new(1, 0, 1, -20)
    bpLeftScroll.Position = UDim2.new(0, 0, 0, 20)
    bpLeftScroll.BackgroundTransparency = 1
    bpLeftScroll.BorderSizePixel = 0
    bpLeftScroll.ScrollBarThickness = 3
    bpLeftScroll.ScrollBarImageColor3 = C.border
    bpLeftScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    bpLeftScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    bpLeftScroll.Parent = bpLeft

    local bpLLayout = Instance.new("UIListLayout")
    bpLLayout.Padding = UDim.new(0, 0)
    bpLLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bpLLayout.Parent = bpLeftScroll

    local bpLPad = Instance.new("UIPadding")
    bpLPad.PaddingLeft = UDim.new(0, 6)
    bpLPad.PaddingTop = UDim.new(0, 4)
    bpLPad.Parent = bpLeftScroll

    bpRight = Instance.new("Frame")
    bpRight.Size = UDim2.new(0.5, -8, 1, -bodyY - footH - 4)
    bpRight.Position = UDim2.new(0.5, 4, 0, bodyY)
    bpRight.BackgroundColor3 = C.input
    bpRight.BorderSizePixel = 1
    bpRight.BorderColor3 = C.border
    bpRight.ClipsDescendants = true
    bpRight.Parent = bp

    local bpRightLbl = Instance.new("TextLabel")
    bpRightLbl.Size = UDim2.new(1, 0, 0, 20)
    bpRightLbl.BackgroundColor3 = C.bar
    bpRightLbl.BorderSizePixel = 0
    bpRightLbl.Text = "  DISASM"
    bpRightLbl.TextColor3 = C.dim
    bpRightLbl.Font = Enum.Font.Code
    bpRightLbl.TextSize = 11
    bpRightLbl.TextXAlignment = Enum.TextXAlignment.Left
    bpRightLbl.Parent = bpRight

    local rightSep = Instance.new("Frame")
    rightSep.Size = UDim2.new(1, 0, 0, 1)
    rightSep.Position = UDim2.new(0, 0, 1, 0)
    rightSep.BackgroundColor3 = C.border
    rightSep.BorderSizePixel = 0
    rightSep.Parent = bpRightLbl

    bpRightScroll = Instance.new("ScrollingFrame")
    bpRightScroll.Size = UDim2.new(1, 0, 1, -20)
    bpRightScroll.Position = UDim2.new(0, 0, 0, 20)
    bpRightScroll.BackgroundTransparency = 1
    bpRightScroll.BorderSizePixel = 0
    bpRightScroll.ScrollBarThickness = 3
    bpRightScroll.ScrollBarImageColor3 = C.border
    bpRightScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    bpRightScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    bpRightScroll.Parent = bpRight

    local bpRLayout = Instance.new("UIListLayout")
    bpRLayout.Padding = UDim.new(0, 0)
    bpRLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bpRLayout.Parent = bpRightScroll

    local bpRPad = Instance.new("UIPadding")
    bpRPad.PaddingLeft = UDim.new(0, 6)
    bpRPad.PaddingTop = UDim.new(0, 4)
    bpRPad.Parent = bpRightScroll

    bpFoot = Instance.new("Frame")
    bpFoot.Size = UDim2.new(1, 0, 0, footH)
    bpFoot.Position = UDim2.new(0, 0, 1, -footH)
    bpFoot.BackgroundColor3 = C.bar
    bpFoot.BorderSizePixel = 1
    bpFoot.BorderColor3 = C.border
    bpFoot.Parent = bp

    bpExit = Instance.new("TextButton")
    bpExit.Size = UDim2.new(0, 90, 0, 26)
    bpExit.Position = UDim2.new(0, 6, 0, 4)
    bpExit.BackgroundColor3 = C.input
    bpExit.BorderSizePixel = 1
    bpExit.BorderColor3 = C.border
    bpExit.Text = "EXIT"
    bpExit.TextColor3 = C.err
    bpExit.Font = Enum.Font.Code
    bpExit.TextSize = 12
    bpExit.Parent = bpFoot

    bpApply = Instance.new("TextButton")
    bpApply.Size = UDim2.new(0, 90, 0, 26)
    bpApply.Position = UDim2.new(1, -96, 0, 4)
    bpApply.BackgroundColor3 = C.input
    bpApply.BorderSizePixel = 1
    bpApply.BorderColor3 = C.border
    bpApply.Text = "SAVE"
    bpApply.TextColor3 = C.dim
    bpApply.Font = Enum.Font.Code
    bpApply.TextSize = 12
    bpApply.Parent = bpFoot

    bpExit.MouseButton1Click:Connect(function()
        bp.Visible = false
    end)

    bpApply.MouseButton1Click:Connect(function()
        if patch and patch.do_apply then patch.do_apply() end
    end)

    drag(bp)
end

function M.show()
    if not bp then M.start() end
    if not bp then
        if console and console.log then
            console.log("panel: failed to create", C.err)
        end
        return
    end

    ensure_sg()
    if bp.Parent ~= p_sg then bp.Parent = p_sg end

    bp.Visible = true
    bp.Position = UDim2.new(0.5, -410, 0.5, -230)

    local ok, err = pcall(M.render_all)
    if not ok and console and console.log then
        console.log("panel render error: " .. tostring(err), C.err)
    end
end

function M.hide()
    if bp then bp.Visible = false end
end

function M.init(bc)
    BC = bc
    console = bc.modules.console
    parser = bc.modules.parser
    disasm = bc.modules.disasm
    cfgs = bc.modules.cfgs
    patch = bc.modules.patch
    names = bc.modules.names
    varflow = bc.modules.varflow
    ssa = bc.modules.ssa
    expr = bc.modules.expr
    C = console.colors()
end

return M
