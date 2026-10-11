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
    original_src = nil,
}

local active_hooks = {}
local last_applied = nil
local script_cache = nil
local script_cache_time = 0

local function u32_bytes(v)
    return string.char(
        v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
    )
end

local function f64_bytes(v)
    local buf = buffer.create(8)
    buffer.writef64(buf, 0, v)
    local parts = {}
    for i = 0, 7 do parts[#parts + 1] = string.char(buffer.readu8(buf, i)) end
    return table.concat(parts)
end

local function patch_word(data, byte_offset, new_word)
    return data:sub(1, byte_offset - 1) .. u32_bytes(new_word) .. data:sub(byte_offset + 4)
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
    return data:sub(1, offset - 1) .. f64_bytes(newval) .. data:sub(offset + 8)
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
    if not ok then console.log("reparse failed: " .. tostring(err), C.err) end
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

-- =================== ПОИСК СКРИПТОВ ===================

local function collect_all_scripts()
    local list = {}
    for _, s in ipairs(game:GetDescendants()) do
        if s:IsA("LocalScript") or s:IsA("ModuleScript") or s:IsA("Script") then
            list[#list + 1] = s
        end
    end
    return list
end

function M.get_all_scripts(force)
    local now = tick()
    if force or not script_cache or (now - script_cache_time) > 3 then
        script_cache = collect_all_scripts()
        script_cache_time = now
    end
    return script_cache
end

function M.search_scripts(query, limit)
    limit = limit or 50
    query = (query or ""):lower()
    local results = {}
    for _, s in ipairs(M.get_all_scripts()) do
        local path = s:GetFullName()
        if query == "" or path:lower():find(query, 1, true) then
            results[#results + 1] = s
            if #results >= limit then break end
        end
    end
    return results
end

-- =================== ЗАГРУЗКА ===================

function M._load_instance(s)
    local C = console.colors()
    if not s then console.log("nil instance", C.err); return end
    if not (s:IsA("LocalScript") or s:IsA("ModuleScript") or s:IsA("Script")) then
        console.log("not a script: " .. s:GetFullName(), C.err); return
    end
    local bc = getscriptbytecode(s)
    if not bc or #bc == 0 then
        console.log("empty bytecode: " .. s:GetFullName(), C.err); return
    end
    local parsed, err = parser.parse(bc)
    if not parsed then
        console.log("parse: " .. tostring(err) .. " (size=" .. #bc .. ")", C.err); return
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
    st.original_src = nil
    if BC.modules.panel and BC.modules.panel.render_all then
        BC.modules.panel.render_all()
    end
    console.log("loaded " .. s:GetFullName() .. " (v" .. parsed.version
        .. ", scheme=" .. (parsed.scheme or "identity") .. ", " .. #bc .. "b)", C.ok)
end

function M.load_script(name)
    local C = console.colors()
    local s = nil
    for _, c in ipairs(getrunningscripts and getrunningscripts() or {}) do
        if c.Name == name then s = c; break end
    end
    if not s then
        for _, c in ipairs(getloadedmodules and getloadedmodules() or {}) do
            if c.Name == name then s = c; break end
        end
    end
    if not s then
        for _, c in ipairs(M.get_all_scripts()) do
            if c.Name == name then s = c; break end
        end
    end
    if not s then console.log("not found: " .. name, C.err); return end
    M._load_instance(s)
end

function M.load_path(path)
    local C = console.colors()
    if not path or path == "" then console.log("empty path", C.err); return end
    local parts = {}
    for part in path:gmatch("[^%.]+") do parts[#parts + 1] = part end
    if #parts == 0 then console.log("empty path", C.err); return end
    local idx = 1
    local current = game
    if parts[1] == "game" then idx = 2 end
    for i = idx, #parts do
        local nxt = current:FindFirstChild(parts[i])
        if not nxt then
            console.log("not found: " .. parts[i] .. " at " .. current:GetFullName(), C.err); return
        end
        current = nxt
    end
    M._load_instance(current)
end

function M.load_script_in(container_name, script_name)
    local C = console.colors()
    local container = nil
    for _, obj in ipairs(game:GetDescendants()) do
        if obj.Name == container_name then container = obj; break end
    end
    if not container then console.log("container not found", C.err); return end
    local s = container:FindFirstChild(script_name, true)
    if not s then console.log("not found: " .. script_name, C.err); return end
    M._load_instance(s)
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

-- =================== ДЕКОМПИЛЯЦИЯ ===================

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
    if not st.original_src then st.original_src = src end
    return src, nil, kind
end

-- =================== АНАЛИЗ ИЗМЕНЕНИЙ ===================

local function extract_literals(src)
    local list = {}
    local pattern = "'[^']*'|\"[^\"]*\"|%f[%w_]%d+%.?%d*%f[%W_]|%f[%w_]true%f[%W_]|%f[%w_]false%f[%W_]"
    for tok in src:gmatch(pattern) do
        list[#list + 1] = tok
    end
    return list
end

local function diff_literals(old_src, new_src)
    local old_lits = extract_literals(old_src)
    local new_lits = extract_literals(new_src)
    local changes = {}
    local n = math.min(#old_lits, #new_lits)
    for i = 1, n do
        if old_lits[i] ~= new_lits[i] then
            changes[#changes + 1] = {
                index = i,
                old_lit = old_lits[i],
                new_lit = new_lits[i],
            }
        end
    end
    if #old_lits ~= #new_lits then
        changes.structural = true
    end
    return changes
end

local function parse_literal(tok)
    if not tok or tok == "" then return nil end
    local s = tok:match("^'(.+)'$") or tok:match('^"(.+)"$')
    if s then return "string", s end
    if tok == "true" then return "boolean", true end
    if tok == "false" then return "boolean", false end
    local n = tonumber(tok)
    if n then return "number", n end
    return nil
end

local function patch_constant_all(fns, old_val, new_val)
    if typeof(debug.getconstants) ~= "function" then return 0 end
    if typeof(debug.setconstant) ~= "function" then return 0 end
    local total = 0
    for _, fn in ipairs(fns) do
        if typeof(islclosure) == "function" and not islclosure(fn) then
        else
            local ok, consts = pcall(debug.getconstants, fn)
            if ok and consts then
                for idx, val in pairs(consts) do
                    if val == old_val then
                        local ok_set = pcall(debug.setconstant, fn, idx, new_val)
                        if ok_set then total = total + 1 end
                    end
                end
            end
        end
    end
    return total
end

local function patch_upvalue_all(fns, old_val, new_val)
    if typeof(debug.getupvalues) ~= "function" then return 0 end
    if typeof(debug.setupvalue) ~= "function" then return 0 end
    local total = 0
    for _, fn in ipairs(fns) do
        if typeof(islclosure) == "function" and not islclosure(fn) then
        else
            local ok, ups = pcall(debug.getupvalues, fn)
            if ok and ups then
                for idx, val in pairs(ups) do
                    if val == old_val then
                        local ok_set = pcall(debug.setupvalue, fn, idx, new_val)
                        if ok_set then total = total + 1 end
                    end
                end
            end
        end
    end
    return total
end

local function collect_all_functions(root_fn)
    local fns = {root_fn}
    if typeof(debug.getprotos) ~= "function" then return fns end
    local ok, protos = pcall(debug.getprotos, root_fn)
    if not ok or not protos then return fns end
    for i = 1, #protos do
        local ok2, actives = pcall(debug.getproto, root_fn, i, true)
        if ok2 and actives and #actives > 0 then
            for _, f in ipairs(actives) do
                if type(f) == "function" then fns[#fns + 1] = f end
            end
        end
    end
    return fns
end

-- =================== СТРАТЕГИИ ПРИМЕНЕНИЯ ===================

local function strategy_debug(root_fn, changes)
    local C = console.colors()
    if #changes == 0 then return false, "no literal changes" end

    local fns = collect_all_functions(root_fn)
    console.log("  strategy A: inspecting " .. #fns .. " functions", C.dim)

    local applied = 0
    for _, ch in ipairs(changes) do
        local ok_old, old_kind, old_val = pcall(parse_literal, ch.old_lit)
        local ok_new, new_kind, new_val = pcall(parse_literal, ch.new_lit)
        if ok_old and ok_new and old_kind and new_kind then
            if old_kind == new_kind then
                local n = patch_constant_all(fns, old_val, new_val)
                if n > 0 then
                    applied = applied + n
                    console.log("    setconstant " .. tostring(old_val) .. " -> " ..
                        tostring(new_val) .. " (" .. n .. " place(s))", C.dim)
                else
                    local m = patch_upvalue_all(fns, old_val, new_val)
                    if m > 0 then
                        applied = applied + m
                        console.log("    setupvalue " .. tostring(old_val) .. " -> " ..
                            tostring(new_val) .. " (" .. m .. " place(s))", C.dim)
                    end
                end
            end
        end
    end

    if applied > 0 then
        return true, applied
    end
    return false, "no constants or upvalues matched"
end

local function strategy_hookproto(script, root_fn, new_fn)
    local C = console.colors()
    if typeof(hookproto) ~= "function" then return false, "no hookproto" end

    local ok_old, old_protos = pcall(debug.getprotos, root_fn)
    if not ok_old or not old_protos or #old_protos == 0 then
        return false, "no old protos"
    end

    local new_fns = collect_all_functions(new_fn)
    if #new_fns <= 1 then
        pcall(new_fn)
        new_fns = collect_all_functions(new_fn)
    end

    if #old_protos > (#new_fns - 1) then
        return false, "not enough new functions"
    end

    local saved = {}
    local applied = 0

    for i = 1, #old_protos do
        local old_proto = old_protos[i]
        local new_fn_i = new_fns[i + 1]
        if new_fn_i then
            if typeof(isprotohooked) == "function" then
                local ok_h, hooked = pcall(isprotohooked, old_proto)
                if ok_h and hooked then
                    pcall(restoreproto, old_proto)
                end
            end
            local ok_apply, err = pcall(hookproto, old_proto, new_fn_i)
            if ok_apply then
                saved[#saved + 1] = old_proto
                applied = applied + 1
                console.log("    hookproto[" .. i .. "] OK", C.dim)
            else
                console.log("    hookproto[" .. i .. "] failed: " .. tostring(err), C.err)
            end
        end
    end

    if applied == 0 then return false, "no protos hooked" end

    active_hooks[script] = {
        kind = "hookproto",
        protos = saved,
        script = script,
    }
    return true, applied
end

local function strategy_hookfunction(script, root_fn, new_fn)
    local C = console.colors()
    if typeof(hookfunction) ~= "function" then return false, "no hookfunction" end

    local final_fn = new_fn
    if typeof(newcclosure) == "function" then
        pcall(function() final_fn = newcclosure(new_fn) end)
    end

    local prev = hookfunction(root_fn, final_fn)
    if not prev then return false, "hookfunction returned nil" end

    -- перезапуск скрипта с защитой
    local spawn_ok, spawn_err = pcall(function()
        local co = coroutine.create(root_fn)
        local ok_run, run_err = coroutine.resume(co)
        if not ok_run then
            error(run_err)
        end
        task.wait(0.05)
        if coroutine.status(co) == "dead" then
            return
        end
    end)
    if not spawn_ok then
        pcall(hookfunction, root_fn, prev)
        active_hooks[script] = nil
        return false, "runtime error after hook: " .. tostring(spawn_err)
    end

    active_hooks[script] = {
        kind = "hookfunction",
        prev = prev,
        script = script,
    }
    return true
end

-- =================== ГЛАВНАЯ ФУНКЦИЯ ===================

function M.apply_edit(script, new_bytes)
    local C = console.colors()
    local st = M.state

    local root_fn = getscriptclosure(script)
    if not root_fn then return false, "no closure" end

    local src = M.decompile_full()
    if not src then
        return false, "decompile failed"
    end

    local new_fn, load_err = loadstring(src, "@" .. script.Name)

    if not new_fn then
        local info_ok, info = pcall(debug.getinfo, root_fn)
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
                    local _, val = debug.getupvalue(root_fn, i)
                    ups[i] = val
                end
                local ok_call, made = pcall(factory, table.unpack(ups))
                if ok_call and made then
                    new_fn = made
                else
                    return false, "factory failed: " .. tostring(made)
                end
            else
                return false, "compile: " .. tostring(load_err)
                    .. " | factory: " .. tostring(wrap_err)
            end
        end
    end

    if not new_fn then
        return false, "compile error: " .. tostring(load_err)
    end

    local changes = {}
    if st.original_src and st.user_src then
        changes = diff_literals(st.original_src, st.user_src)
    end

    console.log("apply: " .. #changes .. " literal change(s) detected", C.dim)

    if #changes > 0 and not changes.structural then
        local ok_a, info_a = strategy_debug(root_fn, changes)
        if ok_a then
            console.log("apply: strategy A applied " .. tostring(info_a) .. " change(s)", C.ok)
            last_applied = script
            return true
        else
            console.log("apply: strategy A failed: " .. tostring(info_a), C.dim)
        end
    end

    local ok_b, info_b = strategy_hookproto(script, root_fn, new_fn)
    if ok_b then
        console.log("apply: strategy B (hookproto) applied " .. tostring(info_b) .. " protos", C.ok)
        last_applied = script
        return true
    else
        console.log("apply: strategy B failed: " .. tostring(info_b), C.dim)
    end

    local ok_c, err_c = strategy_hookfunction(script, root_fn, new_fn)
    if ok_c then
        console.log("apply: strategy C (hookfunction + respawn)", C.ok)
        last_applied = script
        return true
    end

    return false, "all strategies failed: " .. tostring(err_c)
end

function M.revert_edit(script)
    local h = active_hooks[script]
    if not h then return false end

    if h.kind == "hookfunction" and typeof(hookfunction) == "function" then
        pcall(hookfunction, h.script, h.prev)
    elseif h.kind == "hookproto" and typeof(restoreproto) == "function" then
        for _, proto in ipairs(h.protos or {}) do
            pcall(restoreproto, proto)
        end
    end

    active_hooks[script] = nil
    return true
end

function M.do_apply()
    local C = console.colors()
    local st = M.state
    if not st.script then console.log("no script", C.err); return end
    if not st.dirty and not st.user_src then
        console.log("nothing to save", C.dim); return
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
    st.original_src = nil
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

-- =================== КОМАНДЫ ===================

function M.findnum_cmd(a)
    local C = console.colors()
    local st = M.state
    if not st or not st.instrs then console.log("load first", C.err); return end
    local target = tonumber(a[2])
    if not target then console.log("usage: findnum <value>", C.err); return end
    local proto = st.parsed.protos[st.proto_idx]
    console.log("searching for " .. target, C.accent)
    local found = 0
    for _, ins in ipairs(st.instrs) do
        if ins.name == "LOADN" and ins.d == target then
            found = found + 1
            console.log("  pc=" .. ins.word_idx .. " LOADN R" .. ins.a .. " = " .. target, C.warn)
        elseif ins.name == "LOADK" then
            local c = proto.constants[ins.d + 1]
            if c and c.kind == 2 and c.value == target then
                found = found + 1
                console.log("  pc=" .. ins.word_idx .. " LOADK R" .. ins.a .. " = " .. target, C.warn)
            end
        end
    end
    console.log("total: " .. found, found > 0 and C.ok or C.dim)
end

function M.setnum_cmd(a)
    local C = console.colors()
    local st = M.state
    if not st or not st.instrs then console.log("load first", C.err); return end
    local old_val, new_val = tonumber(a[2]), tonumber(a[3])
    if not old_val or not new_val then
        console.log("usage: setnum <old> <new>", C.err); return
    end
    local proto = st.parsed.protos[st.proto_idx]
    local target = nil
    for _, ins in ipairs(st.instrs) do
        if ins.name == "LOADN" and ins.d == old_val then target = ins; break end
        if ins.name == "LOADK" then
            local c = proto.constants[ins.d + 1]
            if c and c.kind == 2 and c.value == old_val then target = ins; break end
        end
    end
    if not target then console.log("not found: " .. old_val, C.err); return end
    if target.name == "LOADN" then
        M.apply_edit_loadn(target, new_val)
    else
        M.apply_edit_loadk(target, new_val)
    end
end

function M.edit_cmd(a)
    local C = console.colors()
    if not a[2] or not a[3] or not a[4] then
        console.log("usage: edit <loadn|loadb|loadk> <pc> <val>", C.err); return
    end
    local st = M.state
    if not st.instrs then console.log("load first", C.err); return end
    local field = a[2]:lower()
    local pc, val = tonumber(a[3]), tonumber(a[4])
    if not pc or not val then console.log("bad args", C.err); return end
    local ins = nil
    for _, i in ipairs(st.instrs) do
        if i.word_idx == pc then ins = i; break end
    end
    if not ins then console.log("pc not found", C.err); return end
    if field == "loadn" then M.apply_edit_loadn(ins, val)
    elseif field == "loadb" then M.apply_edit_loadb(ins, val ~= 0)
    elseif field == "loadk" then M.apply_edit_loadk(ins, val)
    else console.log("unknown", C.err) end
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
