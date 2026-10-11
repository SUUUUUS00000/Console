local M = {}
M.name = "panel"

local BC
local console, parser, disasm, cfgs, patch, names, varflow

local C
local gui_root
local p_sg
local bp, bpTitle, bpBody, bpLeft, bpLeftScroll, bpRight, bpRightScroll
local bpFoot, bpExit, bpApply

local hex_lines = {}
local dis_lines = {}
local selected_byte = -1
local dragOn, dragStart, dragPos, dragFrame

local u = game:GetService("UserInputService")

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
        dragFrame.Position = UDim2.new(
            dragPos.X.Scale, dragPos.X.Offset + d.X,
            dragPos.Y.Scale, dragPos.Y.Offset + d.Y
        )
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
    if p_sg and p_sg.Parent == gui_root then
        return p_sg
    end
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

local function make_edit_row(ins, current_value, proto, labels, reg_names, indent, on_change)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 22)
    row.BackgroundTransparency = 1
    row.Parent = bpRightScroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -90, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep("  ", indent) .. string.format("%06X  %s",
        ins.byte_offset, disasm.fmt(ins, proto, labels, reg_names))
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

local function make_read_row(ins, proto, labels, reg_names, indent)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.BackgroundTransparency = 1
    row.Parent = bpRightScroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep("  ", indent) .. string.format("%06X  %s",
        ins.byte_offset, disasm.fmt(ins, proto, labels, reg_names))
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

local function safe_reg_names(proto, instrs)
    if names and names.for_proto then
        local ok, r = pcall(names.for_proto, proto, instrs)
        if ok and type(r) == "table" then return r end
    end
    return {}
end

local function safe_cfgs_analysis(instrs)
    if cfgs and cfgs.analyze then
        local ok, r = pcall(cfgs.analyze, instrs)
        if ok and type(r) == "table" then return r end
    end
    return { labels = {}, ends = {}, indents = {} }
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
    local analysis = safe_cfgs_analysis(st.instrs)
    local labels = analysis.labels or {}
    local ends = analysis.ends or {}
    local indents = analysis.indents or {}
    local reg_names = safe_reg_names(proto, st.instrs)

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
            make_edit_row(ins, ins.d, proto, labels, reg_names, indent, function(v)
                patch.apply_edit_loadn(ins, v)
            end)
        elseif ins.name == "LOADB" then
            make_edit_row(ins, ins.b, proto, labels, reg_names, indent, function(v)
                patch.apply_edit_loadb(ins, v ~= 0)
            end)
        elseif ins.name == "LOADK" then
            local c = proto.constants[ins.d + 1]
            if c and c.kind == 2 and type(c.value) == "number" then
                make_edit_row(ins, c.value, proto, labels, reg_names, indent, function(v)
                    patch.apply_edit_loadk(ins, v)
                end)
            else
                make_read_row(ins, proto, labels, reg_names, indent)
            end
        else
            make_read_row(ins, proto, labels, reg_names, indent)
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
        bpTitle.Text = string.format(
            "BYTECODE  %s   proto=%d   size=%d   %s",
            st.script.Name, st.proto_idx, #st.working,
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
    bp.Size = UDim2.new(0, 780, 0, 440)
    bp.Position = UDim2.new(0.5, -390, 0.5, -220)
    bp.BackgroundColor3 = C.bg
    bp.BorderSizePixel = 1
    bp.BorderColor3 = C.border
    bp.Visible = false
    bp.Parent = p_sg

    drag(bp)

    local bpHead = Instance.new("Frame")
    bpHead.Size = UDim2.new(1, 0, 0, 26)
    bpHead.BackgroundColor3 = C.bar
    bpHead.BorderSizePixel = 1
    bpHead.BorderColor3 = C.border
    bpHead.Parent = bp
    drag(bpHead)

    bpTitle = Instance.new("TextLabel")
    bpTitle.Size = UDim2.new(1, -12, 1, 0)
    bpTitle.Position = UDim2.new(0, 6, 0, 0)
    bpTitle.BackgroundTransparency = 1
    bpTitle.Text = "BYTECODE"
    bpTitle.TextColor3 = C.accent
    bpTitle.Font = Enum.Font.Code
    bpTitle.TextSize = 13
    bpTitle.TextXAlignment = Enum.TextXAlignment.Left
    bpTitle.Parent = bpHead

    bpBody = Instance.new("Frame")
    bpBody.Size = UDim2.new(1, 0, 1, -26 - 32)
    bpBody.Position = UDim2.new(0, 0, 0, 26)
    bpBody.BackgroundTransparency = 1
    bpBody.Parent = bp

    bpLeft = Instance.new("Frame")
    bpLeft.Size = UDim2.new(0.5, -8, 1, -8)
    bpLeft.Position = UDim2.new(0, 4, 0, 4)
    bpLeft.BackgroundColor3 = C.input
    bpLeft.BorderSizePixel = 1
    bpLeft.BorderColor3 = C.border
    bpLeft.ClipsDescendants = true
    bpLeft.Parent = bpBody

    local bpLeftLbl = Instance.new("TextLabel")
    bpLeftLbl.Size = UDim2.new(1, 0, 0, 18)
    bpLeftLbl.BackgroundColor3 = C.bar
    bpLeftLbl.BorderSizePixel = 1
    bpLeftLbl.BorderColor3 = C.border
    bpLeftLbl.Text = " HEX"
    bpLeftLbl.TextColor3 = C.dim
    bpLeftLbl.Font = Enum.Font.Code
    bpLeftLbl.TextSize = 11
    bpLeftLbl.TextXAlignment = Enum.TextXAlignment.Left
    bpLeftLbl.Parent = bpLeft

    bpLeftScroll = Instance.new("ScrollingFrame")
    bpLeftScroll.Size = UDim2.new(1, 0, 1, -18)
    bpLeftScroll.Position = UDim2.new(0, 0, 0, 18)
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
    bpRight.Size = UDim2.new(0.5, -8, 1, -8)
    bpRight.Position = UDim2.new(0.5, 4, 0, 4)
    bpRight.BackgroundColor3 = C.input
    bpRight.BorderSizePixel = 1
    bpRight.BorderColor3 = C.border
    bpRight.ClipsDescendants = true
    bpRight.Parent = bpBody

    local bpRightLbl = Instance.new("TextLabel")
    bpRightLbl.Size = UDim2.new(1, 0, 0, 18)
    bpRightLbl.BackgroundColor3 = C.bar
    bpRightLbl.BorderSizePixel = 1
    bpRightLbl.BorderColor3 = C.border
    bpRightLbl.Text = " DISASM"
    bpRightLbl.TextColor3 = C.dim
    bpRightLbl.Font = Enum.Font.Code
    bpRightLbl.TextSize = 11
    bpRightLbl.TextXAlignment = Enum.TextXAlignment.Left
    bpRightLbl.Parent = bpRight

    bpRightScroll = Instance.new("ScrollingFrame")
    bpRightScroll.Size = UDim2.new(1, 0, 1, -18)
    bpRightScroll.Position = UDim2.new(0, 0, 0, 18)
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
    bpFoot.Size = UDim2.new(1, 0, 0, 32)
    bpFoot.Position = UDim2.new(0, 0, 1, -32)
    bpFoot.BackgroundColor3 = C.bar
    bpFoot.BorderSizePixel = 1
    bpFoot.BorderColor3 = C.border
    bpFoot.Parent = bp

    bpExit = Instance.new("TextButton")
    bpExit.Size = UDim2.new(0, 90, 0, 24)
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
    bpApply.Size = UDim2.new(0, 90, 0, 24)
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

    if console and console.log then
        console.log("panel: created, screenGui parent=" .. tostring(p_sg.Parent), C.dim)
    end
end

function M.show()
    if not bp then
        M.start()
    end
    if not bp then
        if console and console.log then
            console.log("panel: failed to create", C.err)
        end
        return
    end

    ensure_sg()
    if bp.Parent ~= p_sg then
        bp.Parent = p_sg
    end

    bp.Visible = true
    bp.Position = UDim2.new(0.5, -390, 0.5, -220)

    if console and console.log then
        console.log("panel: visible=" .. tostring(bp.Visible)
            .. " parent=" .. tostring(bp.Parent and bp.Parent.ClassName)
            .. " screenGui=" .. tostring(p_sg.Parent and p_sg.Parent.ClassName), C.ok)
    end

    local ok, err = pcall(M.render_all)
    if not ok then
        if console and console.log then
            console.log("panel render error: " .. tostring(err), C.err)
        end
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
    C = console.colors()
end

return M
