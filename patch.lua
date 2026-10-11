local M = {}
M.name = "patch"

local BC
local console, parser, disasm, decompile

local l = game:GetService("Players").LocalPlayer

M.state = {
    script = nil,
    original = nil,
    baseline = nil,
    working = nil,
    parsed = nil,
    instrs = nil,
    proto_idx = 1,
    dirty = false,
    last_src = nil,
    last_source_kind = nil,
    user_src = nil,
}

local active_hooks = {}
local last_applied = nil

local function u32_bytes(v)
    return string.char(
        v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256
    )
end

local function f64_bytes(v)
    local buf = buffer.create(8)
    buffer.writef64(buf, 0, v)
    local parts = {}
    for i = 0, 7 do
        parts[#parts + 1] = string.char(buffer.readu8(buf, i))
    end
    return table.concat(parts)
end

local function patch_word(data, byte_offset, new_word)
    return string.sub(data, 1, byte_offset - 1) .. u32_bytes(new_word) .. string.sub(data, byte_offset + 4)
end

local function edit_loadn_bytes(data, ins, newval)
    if ins.name ~= "LOADN" then return nil, "not LOADN" end
    if newval < -32768 or newval > 32767 then return nil, "out of range" end
    newval = math.floor(newval)
    local nw = parser.OPIDX["LOADN"] + ins.a * 256 + (newval % 0x10000) * 65536
    return patch_word(data, ins.byte_offset, nw)
end

local function edit_loadb_bytes(data, ins, newval)
    if ins.name ~= "LOADB" then return nil, "not LOADB" end
    local v = newval and 1 or 0
    local nw = parser.OPIDX["LOADB"] + ins.a * 256 + v * 65536 + ins.c * 16777216
    return patch_word(data, ins.byte_offset, nw)
end

local function edit_loadk_number_bytes(data, proto, k_index, newval)
    if not proto or not proto.constants then return nil, "no proto" end
    local c = proto.constants[k_index + 1]
    if not c then return nil, "const index out of range" end
    if c.kind ~= 2 then return nil, "not a number constant" end
    if type(newval) ~= "number" then return nil, "value is not a number" end
    local offset = c.offset
    if not offset or offset < 1 or offset + 7 > #data then return nil, "const offset invalid" end
    return string.sub(data, 1, offset - 1) .. f64_bytes(newval) .. string.sub(data, offset + 8)
end

local function reparse()
    local st = M.state
    local parsed = parser.parse(st.working)
    if parsed then
        st.parsed = parsed
        if st.proto_idx > #parsed.protos then st.proto_idx = 1 end
        st.instrs = parser.iter_instrs(parsed.protos[st.proto_idx])
        return true
    end
    return false, parsed
end

local function after_edit(msg)
    local C = console.colors()
    local st = M.state
    st.dirty = (st.working ~= st.baseline)
    local ok, err = reparse()
    if not ok then
        console.log("reparse failed: " .. tostring(err), C.err)
    end
    if BC.modules.panel and BC.modules.panel.render_all then
        BC.modules.panel.render_all()
    end
    if msg then console.log(msg, C.ok) end
end

function M.apply_edit_loadn(ins, v)
    local C = console.colors()
    local st = M.state
    local nb, err = edit_loadn_bytes(st.working, ins, v)
    if not nb then console.log("edit_loadn failed: " .. tostring(err), C.err); return end
    st.working = nb
    after_edit("patched LOADN pc=" .. ins.word_idx .. " -> " .. math.floor(v))
end

function M.apply_edit_loadb(ins, v)
    local C = console.colors()
    local st = M.state
    local nb, err = edit_loadb_bytes(st.working, ins, v)
    if not nb then console.log("edit_loadb failed: " .. tostring(err), C.err); return end
    st.working = nb
    after_edit("patched LOADB pc=" .. ins.word_idx .. " -> " .. (v and 1 or 0))
end

function M.apply_edit_loadk(ins, v)
    local C = console.colors()
    local st = M.state
    local proto = st.parsed.protos[st.proto_idx]
    local nb, err = edit_loadk_number_bytes(st.working, proto, ins.d, v)
    if not nb then console.log("edit_loadk failed: " .. tostring(err), C.err); return end
    st.working = nb
    after_edit("patched LOADK pc=" .. ins.word_idx .. " K" .. ins.d .. " -> " .. tostring(v))
end

local function find_script(name)
    for _, s in ipairs(getrunningscripts and getrunningscripts() or {}) do
        if s.Name == name then return s end
    end
    for _, s in ipairs(getloadedmodules and getloadedmodules() or {}) do
        if s.Name == name then return s end
    end
    for _, s in ipairs(game:GetDescendants()) do
        if (s:IsA("LocalScript") or s:IsA("ModuleScript")) and s.Name == name then
            return s
        end
    end
    return nil
end

function M.load_script(name)
    local C = console.colors()
    local s = find_script(name)
    if not s then console.log("not found: " .. name, C.err); return end
    local bc = getscriptbytecode(s)
    if not bc or #bc == 0 then console.log("empty bytecode", C.err); return end
    local parsed, err = parser.parse(bc)
    if not parsed then
        console.log("parse: " .. tostring(err) .. " (size=" .. #bc .. ")", C.err)
        return
    end
    local st = M.state
    st.script = s
    st.original = bc
    st.baseline = bc
    st.working = bc
    st.parsed = parsed
    st.proto_idx = 1
    st.instrs = parser.iter_instrs(parsed.protos[1])
    st.dirty = false
    st.last_src = nil
    st.last_source_kind = nil
    st.user_src = nil
    if BC.modules.panel and BC.modules.panel.render_all then
        BC.modules.panel.render_all()
    end
    console.log("loaded " .. s:GetFullName() .. " (v" .. parsed.version
        .. ", scheme=" .. (parsed.scheme or "identity")
        .. ", " .. #bc .. "b)", C.ok)
end

function M.list_scripts()
    local C = console.colors()
    console.clear()
    console.log("running scripts:", C.accent)
    for _, s in ipairs(getrunningscripts and getrunningscripts() or {}) do
        console.log("  " .. s:GetFullName(), C.txt)
    end
    console.log("loaded modules:", C.accent)
    for _, s in ipairs(getloadedmodules and getloadedmodules() or {}) do
        console.log("  " .. s:GetFullName(), C.txt)
    end
end

function M.list_held()
    local C = console.colors()
    console.clear()
    local ch = l.Character
    local tool = ch and ch:FindFirstChildOfClass("Tool")
    if tool then
        console.log("held: " .. tool:GetFullName(), C.ok)
        for _, ch2 in ipairs(tool:GetDescendants()) do
            if ch2:IsA("LocalScript") or ch2:IsA("ModuleScript") then
                local bc = getscriptbytecode(ch2)
                console.log("  " .. ch2.Name .. " (" .. (#bc or 0) .. "b)", C.txt)
            end
        end
    else
        console.log("no tool", C.dim)
    end
end

function M.decompile_full()
    local st = M.state
    if st.user_src then
        st.last_src = st.user_src
        st.last_source_kind = "user"
        return st.user_src, nil, "user"
    end
    if not st or not st.working or not st.parsed then
        return nil, "no script loaded"
    end
    if not decompile or not decompile.decompile_best then
        return nil, "no decompiler"
    end
    local src, kind, err = decompile.decompile_best(st.working)
    if not src then return nil, tostring(err) end
    st.last_src = src
    st.last_source_kind = kind
    return src, nil, kind
end

-- Применение
function M.apply_edit(script, new_bytes)
    local C = console.colors()
    local cl = getscriptclosure(script)
    if not cl then return false, "no closure" end

    local src, _, kind = M.decompile_full()
    if not src then
        return false, "decompile failed: " .. tostring(kind)
    end

    console.log("apply: source from " .. tostring(kind) .. " (" .. #src .. "b)", C.dim)

    local fn, load_err = loadstring(src, "@" .. script.Name)

    if not fn then
        local info_ok, info = pcall(debug.getinfo, cl)
        local nups = (info_ok and info and info.nups) or 0
        if nups > 0 then
            local params = {}
            for i = 1, nups do params[#params + 1] = "upval" .. (i - 1) end
            local wrapped = "return function(" .. table.concat(params, ", ") .. ")\n"
                .. src .. "\nend"
            local factory, wrap_err = loadstring(wrapped, "@" .. script.Name .. "_factory")
            if factory then
                local ups = {}
                for i = 1, nups do
                    local _, val = debug.getupvalue(cl, i)
                    ups[i] = val
                end
                local ok_call, made = pcall(factory, table.unpack(ups))
                if ok_call and made then
                    fn = made
                else
                    return false, "factory call failed: " .. tostring(made)
                end
            else
                return false, "compile: " .. tostring(load_err)
                    .. " | factory: " .. tostring(wrap_err)
            end
        end
    end

    if not fn then
        return false, "compile error: " .. tostring(load_err)
    end

    if typeof(hookfunction) ~= "function" then
        return false, "hookfunction unavailable"
    end

    local new_fn = fn
    if typeof(newcclosure) == "function" then
        new_fn = newcclosure(fn)
    end

    local prev = hookfunction(cl, new_fn)
    if not prev then
        return false, "hookfunction returned nil"
    end

    active_hooks[script] = {
        kind = "hookfunction",
        prev = prev,
        script = script,
        src = src,
    }
    return true
end

function M.revert_edit(script)
    local h = active_hooks[script]
    if not h then return false end
    if h.kind == "hookfunction" and typeof(hookfunction) == "function" then
        pcall(hookfunction, h.script, h.prev)
    end
    active_hooks[script] = nil
    return true
end

function M.do_apply()
    local C = console.colors()
    local st = M.state
    if not st.script then console.log("no script", C.err); return end
    if not st.dirty and not st.user_src then
        console.log("nothing to save", C.dim)
        return
    end
    local ok, err = M.apply_edit(st.script, st.working)
    if not ok then console.log("apply failed: " .. tostring(err), C.err); return end
    st.baseline = st.working
    st.dirty = false
    last_applied = st.script
    if BC.modules.panel and BC.modules.panel.render_all then
        BC.modules.panel.render_all()
    end
    console.log("applied: " .. st.script.Name, C.ok)
end

function M.revert()
    local C = console.colors()
    local st = M.state
    if not st.script then return end
    st.user_src = nil
    M.revert_edit(st.script)
    if st.original then
        st.working = st.original
        st.baseline = st.original
        st.dirty = false
        reparse()
        if BC.modules.panel and BC.modules.panel.render_all then
            BC.modules.panel.render_all()
        end
    end
    console.log("reverted", C.warn)
end

--=====================================================================
-- КОМАНДЫ ПОИСКА И ЗАМЕНЫ ПО ЗНАЧЕНИЮ
--=====================================================================

function M.findnum_cmd(a)
    local C = console.colors()
    local st = M.state
    if not st or not st.instrs then console.log("load first", C.err); return end
    local target = tonumber(a[2])
    if not target then console.log("usage: findnum <value>", C.err); return end
    local proto = st.parsed.protos[st.proto_idx]
    console.log("searching for " .. target .. " in proto " .. st.proto_idx, C.accent)

    local found = 0
    for _, ins in ipairs(st.instrs) do
        if ins.name == "LOADN" and ins.d == target then
            found = found + 1
            console.log("  pc=" .. ins.word_idx .. "  LOADN R" .. ins.a .. " = " .. target, C.warn)
        elseif ins.name == "LOADK" then
            local c = proto.constants[ins.d + 1]
            if c and c.kind == 2 and c.value == target then
                found = found + 1
                console.log("  pc=" .. ins.word_idx .. "  LOADK R" .. ins.a .. " = " .. target, C.warn)
            end
        elseif ins.name == "LOADB" and (target == 0 or target == 1) then
            if ins.b == target then
                found = found + 1
                console.log("  pc=" .. ins.word_idx .. "  LOADB R" .. ins.a .. " = " .. target, C.warn)
            end
        end
    end
    console.log("total: " .. found, found > 0 and C.ok or C.dim)
end

function M.setnum_cmd(a)
    local C = console.colors()
    local st = M.state
    if not st or not st.instrs then console.log("load first", C.err); return end
    local old_val = tonumber(a[2])
    local new_val = tonumber(a[3])
    if not old_val or not new_val then
        console.log("usage: setnum <old> <new>", C.err)
        return
    end
    local proto = st.parsed.protos[st.proto_idx]

    local target_ins = nil
    for _, ins in ipairs(st.instrs) do
        if ins.name == "LOADN" and ins.d == old_val then
            target_ins = ins; break
        elseif ins.name == "LOADK" then
            local c = proto.constants[ins.d + 1]
            if c and c.kind == 2 and c.value == old_val then
                target_ins = ins; break
            end
        elseif ins.name == "LOADB" and (old_val == 0 or old_val == 1) then
            if ins.b == old_val then target_ins = ins; break end
        end
    end

    if not target_ins then
        console.log("not found: " .. old_val, C.err)
        return
    end

    console.log("patching pc=" .. target_ins.word_idx .. " " .. target_ins.name
        .. " " .. old_val .. " -> " .. new_val, C.accent)

    if target_ins.name == "LOADN" then
        M.apply_edit_loadn(target_ins, new_val)
    elseif target_ins.name == "LOADK" then
        M.apply_edit_loadk(target_ins, new_val)
    elseif target_ins.name == "LOADB" then
        M.apply_edit_loadb(target_ins, new_val ~= 0)
    end
end

function M.edit_cmd(a)
    local C = console.colors()
    if not a[2] or not a[3] or not a[4] then
        console.log("usage: edit <loadn|loadb|loadk> <pc> <val>", C.err)
        return
    end
    local st = M.state
    if not st.instrs then console.log("load first", C.err); return end
    local field = a[2]:lower()
    local pc = tonumber(a[3])
    local val = tonumber(a[4])
    if not pc or not val then console.log("bad args", C.err); return end
    local ins = nil
    for _, i in ipairs(st.instrs) do
        if i.word_idx == pc then ins = i; break end
    end
    if not ins then console.log("pc not found", C.err); return end
    if field == "loadn" then M.apply_edit_loadn(ins, val)
    elseif field == "loadb" then M.apply_edit_loadb(ins, val ~= 0)
    elseif field == "loadk" then
        if ins.name ~= "LOADK" then console.log("not LOADK", C.err); return end
        M.apply_edit_loadk(ins, val)
    else console.log("unknown field", C.err) end
end

function M.switch_proto(a)
    local C = console.colors()
    local st = M.state
    if not a[2] or not st.parsed then console.log("usage: proto <n>", C.err); return end
    local n = tonumber(a[2])
    if not n or n < 1 or n > #st.parsed.protos then console.log("bad index", C.err); return end
    st.proto_idx = n
    st.instrs = parser.iter_instrs(st.parsed.protos[n])
    if BC.modules.panel and BC.modules.panel.render_all then
        BC.modules.panel.render_all()
    end
    console.log("switched to proto " .. n, C.ok)
end

pcall(function()
    game:GetService("ScriptContext").Error:Connect(function(msg, trace, source)
        if not last_applied then return end
        if source == last_applied then
            warn("[BC] auto-revert:", msg)
            M.revert_edit(last_applied)
            console.log("[BC] auto-revert: " .. tostring(msg), console.colors().err)
            last_applied = nil
        end
    end)
end)

function M.init(bc)
    BC = bc
    console = bc.modules.console
    parser = bc.modules.parser
    disasm = bc.modules.disasm
    decompile = bc.modules.decompile
end

return M
