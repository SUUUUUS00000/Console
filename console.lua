local M = {}
M.name = "console"

local BC
local u = game:GetService("UserInputService")
local t = game:GetService("TweenService")

local function px(r, g, b) return Color3.fromRGB(r, g, b) end

local C = {
    bg = px(30,30,30), bar = px(37,37,38), input = px(24,24,24),
    out = px(24,24,24), border = px(80,80,80), txt = px(220,220,220),
    dim = px(140,140,145), hint = px(85,85,90), accent = px(86,156,214),
    ok = px(120,200,120), err = px(230,95,95), warn = px(230,180,90),
    hex = px(200,200,200), button = px(55,55,58),
    button_hover = px(72,72,78), suggest_bg = px(28,28,30),
    scroll = px(150,150,150),
}

local FONT = Enum.Font.Arcade
local TSIZE = 14
local MAX_LOG = 5000
local logCount = 0
local min = false
local dragOn, dragStart, dragPos
local commands = {}
local gui_root, sg
local main, inp, minBtn, hbar, vbar
local panel, hintBar, hl, out, sb
local suggest_frame, suggest_scroll
local suggest_clicked = false

local function setup_scroll(sf)
    sf.ScrollBarThickness = 8
    sf.ScrollBarImageColor3 = C.scroll
    sf.ScrollBarImageTransparency = 0.2
    sf.ElasticBehavior = Enum.ElasticBehavior.Never
end

u.InputChanged:Connect(function(i)
    if dragOn and (i.UserInputType == Enum.UserInputType.MouseMovement
    or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - dragStart
        main.Position = UDim2.new(dragPos.X.Scale, dragPos.X.Offset + d.X,
            dragPos.Y.Scale, dragPos.Y.Offset + d.Y)
    end
end)

u.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        dragOn = false
    end
end)

local function is_over(ui, pos)
    local ap = ui.AbsolutePosition
    local as = ui.AbsoluteSize
    return pos.X >= ap.X and pos.X <= ap.X + as.X
        and pos.Y >= ap.Y and pos.Y <= ap.Y + as.Y
end

local function drag_begin(frame)
    frame.InputBegan:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1
        and i.UserInputType ~= Enum.UserInputType.Touch then return end
        if is_over(inp, i.Position) then return end
        if is_over(minBtn, i.Position) then return end
        dragOn = true
        dragStart = i.Position
        dragPos = main.Position
    end)
end

function M.log(txt, c)
    if not sb then return end
    local x = Instance.new("TextLabel")
    x.Size = UDim2.new(1, 0, 0, 0)
    x.BackgroundTransparency = 1
    x.Text = tostring(txt)
    x.TextColor3 = c or C.txt
    x.Font = FONT
    x.TextSize = TSIZE
    x.TextXAlignment = Enum.TextXAlignment.Left
    x.TextWrapped = true
    x.TextYAlignment = Enum.TextYAlignment.Top
    x.LineHeight = 1
    x.AutomaticSize = Enum.AutomaticSize.Y
    x.Parent = sb
    logCount = logCount + 1
    if logCount > MAX_LOG then
        for _, v in ipairs(sb:GetChildren()) do
            if v:IsA("TextLabel") then
                v:Destroy(); logCount = logCount - 1; break
            end
        end
    end
end

function M.clear()
    if not sb then return end
    for _, v in ipairs(sb:GetChildren()) do
        if v:IsA("TextLabel") then v:Destroy() end
    end
    logCount = 0
end

function M.colors() return C end
function M.gui_root() return gui_root end

function M.register(name, handler, description)
    commands[name:lower()] = {handler = handler, description = description or ""}
end

local function hide_suggestions()
    if suggest_frame then suggest_frame.Visible = false end
end

local function rebuild_suggestions(specs)
    if not suggest_scroll then return end
    for _, v in ipairs(suggest_scroll:GetChildren()) do
        if v:IsA("TextButton") then v:Destroy() end
    end
    if not specs or #specs == 0 then
        hide_suggestions()
        return
    end

    local ROW_H = 30
    for i, spec in ipairs(specs) do
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, 0, 0, ROW_H)
        row.Position = UDim2.new(0, 0, 0, (i - 1) * ROW_H)
        row.BackgroundColor3 = C.suggest_bg
        row.BorderSizePixel = 0
        row.Text = ""
        row.AutoButtonColor = false
        row.ZIndex = 2
        row.Parent = suggest_scroll

        local lbl = Instance.new("TextLabel")
        lbl.Size = spec.subtitle and UDim2.new(0.62, 0, 1, 0) or UDim2.new(1, -10, 1, 0)
        lbl.Position = UDim2.new(0, 8, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = spec.text
        lbl.TextColor3 = C.txt
        lbl.Font = FONT
        lbl.TextSize = 14
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Center
        lbl.LineHeight = 1
        lbl.ZIndex = 3
        lbl.Parent = row

        if spec.subtitle then
            local sub = Instance.new("TextLabel")
            sub.Size = UDim2.new(0.38, -10, 1, 0)
            sub.Position = UDim2.new(0.62, 0, 0, 0)
            sub.BackgroundTransparency = 1
            sub.Text = spec.subtitle
            sub.TextColor3 = C.hint
            sub.Font = FONT
            sub.TextSize = 12
            sub.TextXAlignment = Enum.TextXAlignment.Right
            sub.TextYAlignment = Enum.TextYAlignment.Center
            sub.LineHeight = 1
            sub.ZIndex = 3
            sub.Parent = row
        end

        row.MouseEnter:Connect(function()
            row.BackgroundColor3 = C.button_hover
        end)
        row.MouseLeave:Connect(function()
            row.BackgroundColor3 = C.suggest_bg
        end)
        row.MouseButton1Down:Connect(function()
            suggest_clicked = true
            spec.onclick()
        end)
    end

    local shown = math.min(#specs, 6)
    suggest_scroll.CanvasSize = UDim2.new(0, 0, 0, #specs * ROW_H)
    suggest_frame.Size = UDim2.new(1, 0, 0, shown * ROW_H + 4)
    suggest_frame.Visible = true
end

local function update_suggestions()
    if not suggest_frame or not inp then return end
    local txt = inp.Text
    if txt == "" then
        rebuild_suggestions({})
        return
    end

    local space = txt:find(" ", 1, true)

    if not space then
        local prefix = txt:lower()
        local names = {}
        for n in pairs(commands) do names[#names + 1] = n end
        table.sort(names)
        local specs = {}
        for _, n in ipairs(names) do
            if n:sub(1, #prefix) == prefix then
                specs[#specs + 1] = {
                    text = n,
                    subtitle = commands[n].description,
                    onclick = function()
                        inp.Text = n .. " "
                        inp:CaptureFocus()
                        task.defer(update_suggestions)
                    end,
                }
            end
        end
        rebuild_suggestions(specs)
        return
    end

    local cmd = txt:sub(1, space - 1):lower()
    local arg = txt:sub(space + 1):lower()

    if cmd == "load" or cmd == "find" or cmd == "loadpath" or cmd == "loadin" then
        if not BC.modules.patch or not BC.modules.patch.search_scripts then
            rebuild_suggestions({})
            return
        end
        local results = BC.modules.patch.search_scripts(arg, 50)
        local specs = {}
        for _, s in ipairs(results) do
            local path = s:GetFullName()
            specs[#specs + 1] = {
                text = path,
                subtitle = s.ClassName,
                onclick = function()
                    inp.Text = ""
                    rebuild_suggestions({})
                    task.defer(function()
                        M.log("> loadpath " .. path, C.accent)
                        if commands["loadpath"] then
                            pcall(commands["loadpath"].handler,
                                {"loadpath", path}, "loadpath " .. path)
                        end
                    end)
                end,
            }
        end
        rebuild_suggestions(specs)
        return
    end

    rebuild_suggestions({})
end

local function submit()
    if not inp then return end
    local txt = inp.Text
    if txt == "" then return end
    M.log("> " .. txt, C.accent)
    local a = {}
    for x in txt:gmatch("%S+") do a[#a + 1] = x end
    if #a > 0 then
        local cmd = commands[a[1]:lower()]
        if cmd then
            local ok, err = pcall(cmd.handler, a, txt)
            if not ok then M.log("[error] " .. tostring(err), C.err) end
        else
            M.log("unknown: " .. a[1], C.err)
        end
    end
    inp.Text = ""
    rebuild_suggestions({})
end

function M.start(bc)
    BC = bc
    gui_root = (gethui and gethui()) or game:GetService("CoreGui")
    local old = gui_root:FindFirstChild("Console")
    if old then old:Destroy() end

    sg = Instance.new("ScreenGui")
    sg.Name = "Console"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent = gui_root

    main = Instance.new("Frame")
    main.Size = UDim2.new(1, 0, 0, 32)
    main.Position = UDim2.new(0, 0, 0, 0)
    main.BackgroundColor3 = C.bar
    main.BorderColor3 = C.border
    main.BorderSizePixel = 2
    main.ClipsDescendants = false
    main.ZIndex = 50
    main.Parent = sg

    inp = Instance.new("TextBox")
    inp.Size = UDim2.new(1, -50, 1, -6)
    inp.Position = UDim2.new(0, 8, 0, 3)
    inp.BackgroundTransparency = 1
    inp.Text = ""
    inp.PlaceholderText = "> command"
    inp.TextColor3 = C.txt
    inp.PlaceholderColor3 = C.hint
    inp.Font = FONT
    inp.TextSize = TSIZE
    inp.TextXAlignment = Enum.TextXAlignment.Left
    inp.TextYAlignment = Enum.TextYAlignment.Center
    inp.ClearTextOnFocus = false
    inp.ZIndex = 51
    inp.Parent = main

    minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 28, 0, 26)
    minBtn.Position = UDim2.new(1, -32, 0, 3)
    minBtn.BackgroundColor3 = C.button
    minBtn.BorderSizePixel = 0
    minBtn.Text = ""
    minBtn.AutoButtonColor = false
    minBtn.ZIndex = 51
    minBtn.Parent = main

    hbar = Instance.new("Frame")
    hbar.AnchorPoint = Vector2.new(0.5, 0.5)
    hbar.Size = UDim2.new(0, 14, 0, 2)
    hbar.Position = UDim2.new(0.5, 0, 0.5, 0)
    hbar.BackgroundColor3 = px(255,255,255)
    hbar.BorderSizePixel = 0
    hbar.ZIndex = 55
    hbar.Parent = minBtn

    vbar = Instance.new("Frame")
    vbar.AnchorPoint = Vector2.new(0.5, 0.5)
    vbar.Size = UDim2.new(0, 2, 0, 14)
    vbar.Position = UDim2.new(0.5, 0, 0.5, 0)
    vbar.BackgroundColor3 = px(255,255,255)
    vbar.BorderSizePixel = 0
    vbar.Visible = false
    vbar.ZIndex = 55
    vbar.Parent = minBtn

    suggest_frame = Instance.new("Frame")
    suggest_frame.Size = UDim2.new(1, 0, 0, 0)
    suggest_frame.Position = UDim2.new(0, 0, 1, 2)
    suggest_frame.BackgroundColor3 = C.suggest_bg
    suggest_frame.BorderColor3 = C.border
    suggest_frame.BorderSizePixel = 2
    suggest_frame.Visible = false
    suggest_frame.ClipsDescendants = true
    suggest_frame.ZIndex = 70
    suggest_frame.Parent = main

    suggest_scroll = Instance.new("ScrollingFrame")
    suggest_scroll.Size = UDim2.new(1, -4, 1, -4)
    suggest_scroll.Position = UDim2.new(0, 2, 0, 2)
    suggest_scroll.BackgroundTransparency = 1
    suggest_scroll.BorderSizePixel = 0
    suggest_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    suggest_scroll.ZIndex = 71
    setup_scroll(suggest_scroll)
    suggest_scroll.Parent = suggest_frame

    local suggest_list = Instance.new("UIListLayout")
    suggest_list.Padding = UDim.new(0, 0)
    suggest_list.SortOrder = Enum.SortOrder.LayoutOrder
    suggest_list.Parent = suggest_scroll

    panel = Instance.new("Frame")
    panel.Size = UDim2.new(1, 0, 0, 200)
    panel.Position = UDim2.new(0, 0, 0, 32)
    panel.BackgroundTransparency = 1
    panel.ClipsDescendants = true
    panel.ZIndex = 40
    panel.Parent = sg

    hintBar = Instance.new("Frame")
    hintBar.Size = UDim2.new(1, 0, 0, 22)
    hintBar.Position = UDim2.new(0, 0, 0, 0)
    hintBar.BackgroundColor3 = C.input
    hintBar.BorderColor3 = C.border
    hintBar.BorderSizePixel = 0
    hintBar.ClipsDescendants = true
    hintBar.ZIndex = 41
    hintBar.Parent = panel

    hl = Instance.new("TextLabel")
    hl.Size = UDim2.new(1, -12, 1, 0)
    hl.Position = UDim2.new(0, 6, 0, 0)
    hl.BackgroundTransparency = 1
    hl.Text = "help load loadpath loadin find scripts held findnum setnum edit apply revert gui src proto close clear"
    hl.TextColor3 = C.hint
    hl.Font = FONT
    hl.TextSize = 12
    hl.TextXAlignment = Enum.TextXAlignment.Left
    hl.TextYAlignment = Enum.TextYAlignment.Center
    hl.LineHeight = 1
    hl.Parent = hintBar

    out = Instance.new("Frame")
    out.Size = UDim2.new(1, 0, 1, -22)
    out.Position = UDim2.new(0, 0, 0, 22)
    out.BackgroundColor3 = C.out
    out.BorderColor3 = C.border
    out.BorderSizePixel = 0
    out.ClipsDescendants = true
    out.ZIndex = 41
    out.Parent = panel

    sb = Instance.new("ScrollingFrame")
    sb.Size = UDim2.new(1, 0, 1, 0)
    sb.BackgroundTransparency = 1
    sb.BorderSizePixel = 0
    sb.CanvasSize = UDim2.new(0, 0, 0, 0)
    sb.AutomaticCanvasSize = Enum.AutomaticSize.Y
    setup_scroll(sb)
    sb.Parent = out

    local ll = Instance.new("UIListLayout")
    ll.Padding = UDim.new(0, 1)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Parent = sb

    local upl = Instance.new("UIPadding")
    upl.PaddingLeft = UDim.new(0, 8)
    upl.PaddingRight = UDim.new(0, 8)
    upl.PaddingTop = UDim.new(0, 4)
    upl.Parent = sb

    drag_begin(main)

    inp:GetPropertyChangedSignal("Text"):Connect(function()
        task.defer(update_suggestions)
    end)
    inp.Focused:Connect(function()
        task.defer(update_suggestions)
    end)
    inp.FocusLost:Connect(function(enter)
        if enter then submit() end
        task.delay(0.4, function()
            if not suggest_clicked then hide_suggestions() end
            suggest_clicked = false
        end)
    end)

    minBtn.MouseButton1Click:Connect(function()
        min = not min
        vbar.Visible = min
        local info = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        t:Create(panel, info, {Size = min and UDim2.new(1, 0, 0, 0) or UDim2.new(1, 0, 0, 200)}):Play()
    end)

    --=========================================================
    -- КОМАНДЫ
    --=========================================================

    M.register("help", function()
        M.log("commands:", C.accent)
        local names = {}
        for n in pairs(commands) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            M.log("  " .. n .. "  " .. commands[n].description, C.txt)
        end
    end, "show this help")

    M.register("clear", function() M.clear() end, "clear output")

    M.register("load", function(a)
        if not a[2] then M.log("usage: load <name>", C.err) return end
        if BC.modules.patch and BC.modules.patch.load_script then
            BC.modules.patch.load_script(a[2])
        end
    end, "load by name")

    M.register("loadpath", function(a)
        if not a[2] then M.log("usage: loadpath <path>", C.err) return end
        if BC.modules.patch and BC.modules.patch.load_path then
            BC.modules.patch.load_path(a[2])
        end
    end, "load by full path")

    M.register("loadin", function(a)
        if not a[2] or not a[3] then M.log("usage: loadin <container> <script>", C.err); return end
        if BC.modules.patch and BC.modules.patch.load_script_in then
            BC.modules.patch.load_script_in(a[2], a[3])
        end
    end, "load script inside container")

    M.register("find", function(a)
        local q = a[2] or ""
        if not BC.modules.patch or not BC.modules.patch.search_scripts then return end
        local results = BC.modules.patch.search_scripts(q, 50)
        M.log("found " .. #results .. " scripts:", C.accent)
        for i, s in ipairs(results) do
            M.log("  [" .. i .. "] " .. s:GetFullName() .. "  (" .. s.ClassName .. ")", C.txt)
        end
        M.log("use: loadpath <full path>", C.hint)
    end, "find scripts by name substring")

    M.register("scripts", function()
        if BC.modules.patch and BC.modules.patch.list_scripts then
            BC.modules.patch.list_scripts()
        end
    end, "list running scripts")

    M.register("held", function()
        if BC.modules.patch and BC.modules.patch.list_held then
            BC.modules.patch.list_held()
        end
    end, "list held tool scripts")

    M.register("gui", function()
        if BC.modules.panel and BC.modules.panel.show then BC.modules.panel.show() end
    end, "open editor window")

    M.register("close", function()
        if BC.modules.panel and BC.modules.panel.hide then BC.modules.panel.hide() end
    end, "hide editor window")

    M.register("apply", function()
        if BC.modules.patch and BC.modules.patch.do_apply then
            BC.modules.patch.do_apply()
        end
    end, "apply changes to live game")

    M.register("revert", function()
        if BC.modules.patch and BC.modules.patch.revert then
            BC.modules.patch.revert()
        end
    end, "revert all hooks")

    M.register("findnum", function(a)
        if BC.modules.patch and BC.modules.patch.findnum_cmd then
            BC.modules.patch.findnum_cmd(a)
        end
    end, "find all LOADN/LOADK with value")

    M.register("setnum", function(a)
        if BC.modules.patch and BC.modules.patch.setnum_cmd then
            BC.modules.patch.setnum_cmd(a)
        end
    end, "setnum <old> <new>")

    M.register("src", function()
        if BC.modules.patch and BC.modules.patch.decompile_full then
            local src, err, kind = BC.modules.patch.decompile_full()
            if not src then
                M.log("decompile failed: " .. tostring(err), C.err)
            else
                M.log("--- SOURCE via " .. tostring(kind) .. " (" .. #src .. " bytes) ---", C.accent)
                for line in src:gmatch("[^\n]+") do M.log(line, C.txt) end
                M.log("--- END ---", C.accent)
            end
        end
    end, "show source from D1")

    M.register("edit", function(a)
        if BC.modules.patch and BC.modules.patch.edit_cmd then BC.modules.patch.edit_cmd(a) end
    end, "edit <loadn|loadb|loadk> <pc> <val>")

    M.register("proto", function(a)
        if BC.modules.patch and BC.modules.patch.switch_proto then BC.modules.patch.switch_proto(a) end
    end, "switch proto")
end

function M.init(bc) BC = bc end
return M
