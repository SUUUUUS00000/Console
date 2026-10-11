local M = {}
M.name = "decompile"

local BC
local parser, disasm, ssa, expr, cfgs

local API_URL = "https://obfuscation-tvcs.onrender.com/"

local function is_cond_jump(name)
    if name == "JUMPIF" or name == "JUMPIFNOT" then return true end
    if name == "JUMPIFEQ" or name == "JUMPIFNOTEQ" then return true end
    if name == "JUMPIFLE" or name == "JUMPIFLT" then return true end
    if name == "JUMPIFNOTLE" or name == "JUMPIFNOTLT" then return true end
    if name == "JUMPXEQKNIL" or name == "JUMPXEQKB" then return true end
    if name == "JUMPXEQKN" or name == "JUMPXEQKS" then return true end
    return false
end

local LUA_KEYWORDS = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true,
    ["end"]=true, ["false"]=true, ["for"]=true, ["function"]=true, ["if"]=true,
    ["in"]=true, ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
    ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true, ["until"]=true,
    ["while"]=true, ["continue"]=true,
}

local function is_ident(s)
    if type(s) ~= "string" or s == "" then return false end
    if LUA_KEYWORDS[s] then return false end
    if not s:match("^[%a_][%w_]*$") then return false end
    return true
end

local function safe_str(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("'", "\\'")
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    s = s:gsub("%z", "\\0")
    return "'" .. s .. "'"
end

local function cstr(proto, i)
    if not proto or not proto.constants then return "nil" end
    local c = proto.constants[i + 1]
    if not c then return "nil" end
    if c.kind == 0 then return "nil" end
    if c.kind == 1 then return c.value and "true" or "false" end
    if c.kind == 2 then
        local v = c.value
        if type(v) ~= "number" then return "0" end
        if v ~= v then return "(0/0)" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return tostring(math.floor(v))
        end
        return string.format("%.10g", v)
    end
    if c.kind == 3 then return safe_str(c.value or "") end
    if c.kind == 9 then return tostring(c.value) end
    return "nil"
end

local function member_name(proto, k_idx)
    if not proto or not proto.constants then return nil end
    local c = proto.constants[(k_idx or 0) + 1]
    if c and c.kind == 3 then
        local s = c.value or ""
        if is_ident(s) then return s end
    end
    return nil
end

--=====================================================================
-- ЛОКАЛЬНЫЙ ДЕКОМПИЛЯТОР (fallback)
--=====================================================================

local function decompile_proto(proto_idx, parsed, indent_base, wrap_as_function)
    local proto = parsed.protos[proto_idx]
    if not proto then return {"-- error: proto " .. proto_idx} end
    local instrs = parser.iter_instrs(proto)
    if not instrs or #instrs == 0 then return {} end

    local ssa_data = nil
    if ssa and ssa.build then
        local ok, r = pcall(ssa.build, instrs, proto)
        if ok then ssa_data = r end
    end
    local expr_db = nil
    if expr and expr.build and ssa_data then
        local ok, r = pcall(expr.build, ssa_data, proto, instrs)
        if ok then expr_db = r end
    end
    local cfg = nil
    if cfgs and cfgs.analyze then
        local ok, r = pcall(cfgs.analyze, instrs)
        if ok then cfg = r end
    end

    local out = {}
    local indent = indent_base or 0

    local function pad(n)
        return string.rep("    ", n or indent)
    end

    local function rc(pc, reg)
        if not ssa_data then return "R" .. reg end
        local rad = ssa_data.read_at[pc]
        if not rad then return "R" .. reg end
        local v = rad[reg]
        if not v then return "R" .. reg end
        local e = expr_db and expr_db.get and expr_db.get(v)
        if e then return e.code end
        return ssa_data.name_of[v] or ("R" .. reg)
    end

    local function wc(pc, reg)
        if not ssa_data then return "R" .. reg end
        local wr = ssa_data.write_at[pc]
        if not wr then return "R" .. reg end
        local v = wr[reg]
        if not v then return "R" .. reg end
        return ssa_data.name_of[v] or ("R" .. reg)
    end

    local function build_chain_cond(start_ins)
        local target = disasm.jump_target(start_ins)
        if target < 0 then return nil end
        local parts = {}
        local last_op = nil
        local start_idx = nil
        for idx, ins in ipairs(instrs) do
            if ins.word_idx == start_ins.word_idx then start_idx = idx; break end
        end
        if not start_idx then return nil end
        local i = start_idx
        while i <= #instrs do
            local ins = instrs[i]
            if not is_cond_jump(ins.name) then break end
            if disasm.jump_target(ins) ~= target then break end
            local this_op
            if ins.name == "JUMPIFNOT" or ins.name == "JUMPIFNOTEQ" or ins.name == "JUMPIFNOTLE"
                or ins.name == "JUMPIFNOTLT" or ins.name == "JUMPXEQKNIL" then
                this_op = "or"
            else
                this_op = "and"
            end
            local cnd = ""
            if ins.name == "JUMPIF" then cnd = rc(ins.word_idx, ins.a)
            elseif ins.name == "JUMPIFNOT" then cnd = "not " .. rc(ins.word_idx, ins.a)
            elseif ins.name == "JUMPIFEQ" then cnd = rc(ins.word_idx, ins.a) .. " == " .. rc(ins.word_idx, ins.aux or 0)
            elseif ins.name == "JUMPIFNOTEQ" then cnd = rc(ins.word_idx, ins.a) .. " ~= " .. rc(ins.word_idx, ins.aux or 0)
            elseif ins.name == "JUMPIFLE" then cnd = rc(ins.word_idx, ins.a) .. " <= " .. rc(ins.word_idx, ins.aux or 0)
            elseif ins.name == "JUMPIFLT" then cnd = rc(ins.word_idx, ins.a) .. " < " .. rc(ins.word_idx, ins.aux or 0)
            elseif ins.name == "JUMPIFNOTLE" then cnd = rc(ins.word_idx, ins.a) .. " > " .. rc(ins.word_idx, ins.aux or 0)
            elseif ins.name == "JUMPIFNOTLT" then cnd = rc(ins.word_idx, ins.a) .. " >= " .. rc(ins.word_idx, ins.aux or 0)
            elseif ins.name == "JUMPXEQKNIL" then
                local nf = (ins.aux or 0) >= 0x80000000
                cnd = rc(ins.word_idx, ins.a) .. (nf and " ~= nil" or " == nil")
            elseif ins.name == "JUMPXEQKB" then
                local v = (ins.aux or 0) % 2
                cnd = rc(ins.word_idx, ins.a) .. " == " .. (v == 1 and "true" or "false")
            elseif ins.name == "JUMPXEQKN" or ins.name == "JUMPXEQKS" then
                local k = (ins.aux or 0) % 0x1000000
                cnd = rc(ins.word_idx, ins.a) .. " == " .. cstr(proto, k)
            end
            parts[#parts + 1] = cnd
            last_op = this_op
            i = i + 1
        end
        if #parts == 0 then return nil end
        if #parts == 1 then return parts[1], target end
        return "(" .. table.concat(parts, " " .. last_op .. " ") .. ")", target
    end

    local struct_by_header = {}
    local structs = cfg and cfg.structs or {}
    for _, s in ipairs(structs) do
        if s.header_pc then struct_by_header[s.header_pc] = s end
    end

    local skip_pc = {}
    local idx_at = {}
    for i, ins in ipairs(instrs) do idx_at[ins.word_idx] = i end

    local render_ins

    local function render(start_idx, end_idx, level)
        local result = {}
        local i = start_idx
        while i <= end_idx and i <= #instrs do
            local ins = instrs[i]
            local pc = ins.word_idx

            if skip_pc[pc] then
                i = i + 1
            else
                local s = struct_by_header[pc]
                if s and s.kind == "if" then
                    local cond = build_chain_cond(ins) or "true"
                    table.insert(result, string.rep("    ", level) .. "if " .. cond .. " then")
                    local then_start = idx_at[s.body_start] or (i + 1)
                    local then_end
                    if s.has_else then
                        then_end = (idx_at[s.else_start] or 1) - 1
                    else
                        then_end = (idx_at[s.end_pc] or (#instrs + 1)) - 1
                    end
                    local body = render(then_start, then_end, level + 1)
                    for _, l in ipairs(body) do table.insert(result, l) end
                    if s.has_else then
                        table.insert(result, string.rep("    ", level) .. "else")
                        local else_start = idx_at[s.else_start] or then_end + 1
                        local else_end = (idx_at[s.end_pc] or (#instrs + 1)) - 1
                        local ebody = render(else_start, else_end, level + 1)
                        for _, l in ipairs(ebody) do table.insert(result, l) end
                    end
                    table.insert(result, string.rep("    ", level) .. "end")
                    for j = i, (idx_at[s.end_pc] or i) - 1 do
                        if instrs[j] then skip_pc[instrs[j].word_idx] = true end
                    end
                    i = idx_at[s.end_pc] or (i + 1)
                elseif s and s.kind == "while" then
                    local cond_pc = s.cond_pc or s.body_start
                    local cond_ins = nil
                    for _, x in ipairs(instrs) do
                        if x.word_idx == cond_pc then cond_ins = x; break end
                    end
                    local cond = "true"
                    if cond_ins then
                        if cond_ins.name == "JUMPIFNOT" then
                            cond = rc(cond_pc, cond_ins.a)
                        elseif cond_ins.name == "JUMPIF" then
                            cond = "not " .. rc(cond_pc, cond_ins.a)
                        else
                            cond = build_chain_cond(cond_ins) or "true"
                        end
                    end
                    table.insert(result, string.rep("    ", level) .. "while " .. cond .. " do")
                    local b_start = idx_at[s.body_start] or (i + 1)
                    local b_end = (idx_at[s.end_pc] or (#instrs + 1)) - 1
                    local body = render(b_start, b_end, level + 1)
                    for _, l in ipairs(body) do table.insert(result, l) end
                    table.insert(result, string.rep("    ", level) .. "end")
                    for j = i, (idx_at[s.end_pc] or i) - 1 do
                        if instrs[j] then skip_pc[instrs[j].word_idx] = true end
                    end
                    i = idx_at[s.end_pc] or (i + 1)
                elseif s and s.kind == "repeat" then
                    table.insert(result, string.rep("    ", level) .. "repeat")
                    local b_start = idx_at[s.body_start] or (i + 1)
                    local b_end = (idx_at[s.end_pc] or (#instrs + 1)) - 1
                    local body = render(b_start, b_end, level + 1)
                    for _, l in ipairs(body) do table.insert(result, l) end
                    table.insert(result, string.rep("    ", level) .. "until false")
                    for j = i, (idx_at[s.end_pc] or i) - 1 do
                        if instrs[j] then skip_pc[instrs[j].word_idx] = true end
                    end
                    i = idx_at[s.end_pc] or (i + 1)
                elseif s and s.kind == "fornum" then
                    local a = ins.a
                    local limit = rc(pc, a)
                    local step = rc(pc, a + 1)
                    local start_v = rc(pc, a + 2)
                    local var_name = wc(pc, a + 2) or ("i" .. tostring(pc))
                    local header = string.rep("    ", level) .. "for " .. var_name .. " = " .. start_v .. ", " .. limit
                    if step and step ~= "1" then header = header .. ", " .. step end
                    header = header .. " do"
                    table.insert(result, header)
                    local b_start = idx_at[s.body_start] or (i + 1)
                    local b_end = (idx_at[s.end_pc] or (#instrs + 1)) - 1
                    local body = render(b_start, b_end, level + 1)
                    for _, l in ipairs(body) do table.insert(result, l) end
                    table.insert(result, string.rep("    ", level) .. "end")
                    for j = i, (idx_at[s.end_pc] or i) - 1 do
                        if instrs[j] then skip_pc[instrs[j].word_idx] = true end
                    end
                    i = idx_at[s.end_pc] or (i + 1)
                elseif s and s.kind == "forgen" then
                    local b_start = idx_at[s.body_start] or (i + 1)
                    local b_end = (idx_at[s.end_pc] or (#instrs + 1)) - 1
                    local nvars = 2
                    for _, x in ipairs(instrs) do
                        if x.word_idx == (s.body_end or -1) and x.name == "FORGLOOP" then
                            nvars = (x.aux or 0) % 256
                            if nvars == 0 then nvars = 2 end
                            break
                        end
                    end
                    local var_list = {}
                    for k = 1, nvars do
                        var_list[k] = wc(pc, ins.a + 2 + k) or ("v" .. k)
                    end
                    table.insert(result, string.rep("    ", level) .. "for " .. table.concat(var_list, ", ") .. " in nil do")
                    local body = render(b_start, b_end, level + 1)
                    for _, l in ipairs(body) do table.insert(result, l) end
                    table.insert(result, string.rep("    ", level) .. "end")
                    for j = i, (idx_at[s.end_pc] or i) - 1 do
                        if instrs[j] then skip_pc[instrs[j].word_idx] = true end
                    end
                    i = idx_at[s.end_pc] or (i + 1)
                else
                    local lines = render_ins(ins, level)
                    if lines then
                        for _, l in ipairs(lines) do table.insert(result, l) end
                    end
                    i = i + 1
                end
            end
        end
        return result
    end

    render_ins = function(ins, level)
        local pc = ins.word_idx
        local p = string.rep("    ", level)
        local n = ins.name

        if n == "NOP" or n == "PREPVARARGS" or n == "CAPTURE"
            or n == "CLOSEUPVALS" or n == "COVERAGE" or n == "BREAK" then
            return nil
        end

        if ssa_data then
            local wr = ssa_data.write_at[pc]
            if wr and next(wr) and n ~= "CALL" and n ~= "CALLFB" then
                local all_dead = true
                for _, vid in pairs(wr) do
                    local v = ssa_data.versions[vid]
                    if v and v.kind ~= "dead" then all_dead = false; break end
                end
                if all_dead then return nil end
            end
        end

        if n == "LOADNIL" then return {p .. wc(pc, ins.a) .. " = nil"} end
        if n == "LOADB" then return {p .. wc(pc, ins.a) .. " = " .. (ins.b ~= 0 and "true" or "false")} end
        if n == "LOADN" then return {p .. wc(pc, ins.a) .. " = " .. ins.d} end
        if n == "LOADK" then return {p .. wc(pc, ins.a) .. " = " .. cstr(proto, ins.d)} end
        if n == "LOADKX" then return {p .. wc(pc, ins.a) .. " = " .. cstr(proto, ins.aux or 0)} end
        if n == "MOVE" then return {p .. wc(pc, ins.a) .. " = " .. rc(pc, ins.b)} end
        if n == "GETGLOBAL" then return {p .. wc(pc, ins.a) .. " = " .. cstr(proto, ins.aux or 0)} end
        if n == "GETUPVAL" then return {p .. wc(pc, ins.a) .. " = upval" .. ins.b} end
        if n == "GETIMPORT" then return {p .. wc(pc, ins.a) .. " = " .. cstr(proto, ins.d)} end
        if n == "GETTABLE" then return {p .. wc(pc, ins.a) .. " = " .. rc(pc, ins.b) .. "[" .. rc(pc, ins.c) .. "]"} end
        if n == "GETTABLEKS" then
            local mn = member_name(proto, ins.aux or 0)
            if mn then return {p .. wc(pc, ins.a) .. " = " .. rc(pc, ins.b) .. "." .. mn} end
            return {p .. wc(pc, ins.a) .. " = " .. rc(pc, ins.b) .. "[" .. cstr(proto, ins.aux or 0) .. "]"}
        end
        if n == "GETTABLEN" then return {p .. wc(pc, ins.a) .. " = " .. rc(pc, ins.b) .. "[" .. (ins.c + 1) .. "]"} end
        if n == "NEWTABLE" then return {p .. wc(pc, ins.a) .. " = {}"} end
        if n == "NEWCLOSURE" then
            local child_idx = proto.children[ins.d + 1]
            local child_lines = decompile_proto(child_idx, parsed, 0, true)
            local body_lines = {}
            for _, l in ipairs(child_lines) do table.insert(body_lines, "    " .. l) end
            table.insert(body_lines, p .. "end")
            table.insert(body_lines, 1, p .. wc(pc, ins.a) .. " = function(...)")
            return body_lines
        end
        if n == "DUPCLOSURE" then return {p .. wc(pc, ins.a) .. " = nil --[[ dupclosure ]]"} end
        if n == "SETUPVAL" then return {p .. "upval" .. ins.b .. " = " .. rc(pc, ins.a)} end
        if n == "SETGLOBAL" then return {p .. cstr(proto, ins.aux or 0) .. " = " .. rc(pc, ins.a)} end
        if n == "SETTABLE" then return {p .. rc(pc, ins.b) .. "[" .. rc(pc, ins.c) .. "] = " .. rc(pc, ins.a)} end
        if n == "SETTABLEKS" then
            local mn = member_name(proto, ins.aux or 0)
            if mn then return {p .. rc(pc, ins.b) .. "." .. mn .. " = " .. rc(pc, ins.a)} end
            return {p .. rc(pc, ins.b) .. "[" .. cstr(proto, ins.aux or 0) .. "] = " .. rc(pc, ins.a)}
        end
        if n == "SETTABLEN" then return {p .. rc(pc, ins.b) .. "[" .. (ins.c + 1) .. "] = " .. rc(pc, ins.a)} end
        if n == "SETLIST" then return nil end

        if n == "CALL" or n == "CALLFB" then
            local nres = ins.c - 1
            local nargs = ins.b - 1
            local args = {}
            for k = 1, nargs do
                local a = rc(pc, ins.a + k)
                args[#args + 1] = a or "nil"
            end

            local fn_ver = ssa_data and ssa_data.read_at and ssa_data.read_at[pc]
            fn_ver = fn_ver and fn_ver[ins.a]
            local namcall_ins = nil
            if fn_ver and ssa_data.versions[fn_ver] then
                local d_pc = ssa_data.versions[fn_ver].def_pc
                if d_pc and d_pc >= 0 then
                    for _, x in ipairs(instrs) do
                        if x.word_idx == d_pc and x.name == "NAMECALL" then namcall_ins = x; break end
                    end
                end
            end

            local call_expr
            if namcall_ins then
                local self_expr = rc(namcall_ins.word_idx, namcall_ins.b) or "nil"
                local mn = member_name(proto, namcall_ins.aux or 0) or cstr(proto, namcall_ins.aux or 0)
                local real_args = {}
                for k = 2, nargs do
                    real_args[#real_args + 1] = args[k] or "nil"
                end
                call_expr = self_expr .. ":" .. mn .. "(" .. table.concat(real_args, ", ") .. ")"
            else
                local fn = rc(pc, ins.a) or "nil"
                call_expr = fn .. "(" .. table.concat(args, ", ") .. ")"
            end

            if nres == 0 then
                return {p .. call_expr}
            elseif nres == 1 then
                local wr2 = ssa_data and ssa_data.write_at[pc]
                local vid = wr2 and wr2[ins.a]
                if vid and expr_db and expr_db.inlineable and expr_db.inlineable[vid] then
                    return nil
                end
                return {p .. wc(pc, ins.a) .. " = " .. call_expr}
            else
                local names = {}
                for k = 0, nres - 1 do names[#names + 1] = wc(pc, ins.a + k) end
                return {p .. table.concat(names, ", ") .. " = " .. call_expr}
            end
        end

        if n == "RETURN" then
            local nres = ins.b - 1
            if nres <= 0 then return {p .. "return"} end
            local vals = {}
            for k = 0, nres - 1 do vals[#vals + 1] = rc(pc, ins.a + k) or "nil" end
            return {p .. "return " .. table.concat(vals, ", ")}
        end

        if n == "JUMP" or n == "JUMPBACK" or n == "JUMPX" then return nil end
        if is_cond_jump(n) then
            local cnd = build_chain_cond(ins) or "false"
            return {p .. "-- if " .. cnd .. " then ... end"}
        end
        if n == "GETVARARGS" then return {p .. wc(pc, ins.a) .. " = ..."} end
        if n == "FORNPREP" or n == "FORNLOOP" or n == "FORGPREP" or n == "FORGLOOP" then return nil end

        return nil
    end

    local body = render(1, #instrs, indent)

    if wrap_as_function then
        local params = {}
        for k = 1, (proto.numparams or 0) do params[#params + 1] = "arg" .. k end
        if proto.is_vararg then params[#params + 1] = "..." end
        local head = "function(" .. table.concat(params, ", ") .. ")"
        local wrapped = {head}
        for _, l in ipairs(body) do table.insert(wrapped, "    " .. l) end
        table.insert(wrapped, "end")
        return wrapped
    end

    return body
end

function M.full_script_local(parsed)
    if not parsed or not parsed.protos then return nil, "no parsed data" end
    local body = decompile_proto(1, parsed, 0, false)
    return table.concat(body, "\n"), nil
end

function M.from_proto(proto, instrs, ssa_data, expr_db, cfg)
    local fake_parsed = { protos = {proto}, strings = {} }
    local saved_iter = parser.iter_instrs
    parser.iter_instrs = function() return instrs end
    local result = decompile_proto(1, fake_parsed, 0, false)
    parser.iter_instrs = saved_iter
    return table.concat(result, "\n")
end

--=====================================================================
-- D1 API (MEGGD)
--=====================================================================

function M.api_decompile(bytecode_str)
    if type(bytecode_str) ~= "string" or #bytecode_str == 0 then
        return nil, "empty bytecode"
    end
    if typeof(request) ~= "function" then
        return nil, "request unavailable"
    end

    local parts = {}
    for i = 1, #bytecode_str do
        parts[#parts + 1] = string.format("%02X", string.byte(bytecode_str, i))
    end
    local hex = table.concat(parts, " ")

    local HttpService = game:GetService("HttpService")
    local body_ok, body = pcall(function()
        return HttpService:JSONEncode({code = hex})
    end)
    if not body_ok then return nil, "json encode failed: " .. tostring(body) end

    local ok, res = pcall(request, {
        Url = API_URL,
        Method = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body = body,
    })
    if not ok then return nil, "request failed: " .. tostring(res) end
    if type(res) ~= "table" then return nil, "bad response type" end
    if res.StatusCode ~= 200 then
        return nil, "status " .. tostring(res.StatusCode) .. ": " .. tostring(res.Body)
    end

    local dec_ok, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)
    if not dec_ok then return nil, "json decode failed: " .. tostring(data) end
    if type(data) ~= "table" or not data.result then
        return nil, "no result field in response"
    end
    return data.result
end

-- Оркестратор: сначала D1, потом локальный
function M.decompile_best(bytecode_str, parsed)
    local api_src, api_err = M.api_decompile(bytecode_str)
    if api_src and #api_src > 0 then
        return api_src, "d1"
    end
    local local_src, local_err = M.full_script_local(parsed)
    if local_src then
        return local_src, "local", api_err
    end
    return nil, nil, "d1: " .. tostring(api_err) .. " | local: " .. tostring(local_err)
end

function M.init(bc)
    BC = bc
    parser = bc.modules.parser
    disasm = bc.modules.disasm
    ssa = bc.modules.ssa
    expr = bc.modules.expr
    cfgs = bc.modules.cfgs
end

return M
