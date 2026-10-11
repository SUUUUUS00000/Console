local M = {}
M.name = "decompile"

local BC
local parser, disasm, ssa, expr, cfgs

local function is_cond_jump(name)
    if name == "JUMPIF" or name == "JUMPIFNOT" then return true end
    if name == "JUMPIFEQ" or name == "JUMPIFNOTEQ" then return true end
    if name == "JUMPIFLE" or name == "JUMPIFLT" then return true end
    if name == "JUMPIFNOTLE" or name == "JUMPIFNOTLT" then return true end
    if name == "JUMPXEQKNIL" or name == "JUMPXEQKB" then return true end
    if name == "JUMPXEQKN" or name == "JUMPXEQKS" then return true end
    return false
end

local function jump_target(ins)
    return disasm.jump_target(ins)
end

-- Возвращает expr-строку или nil
local function get_code(expr_db, ssa_data, reg, read_at_pc)
    if not ssa_data or not read_at_pc then return nil end
    local v = read_at_pc[reg]
    if not v then return nil end
    local e = expr_db and expr_db.get and expr_db.get(v)
    if e then return e.code end
    if ssa_data.name_of[v] then return ssa_data.name_of[v] end
    return nil
end

local function assign_to(ssa_data, ins, reg)
    local wr = ssa_data.write_at[ins.word_idx]
    local v = wr and wr[reg]
    if v and ssa_data.name_of[v] then return ssa_data.name_of[v] end
    return "R" .. reg
end

-- Главная функция: собирает исходник из instrs + анализа
function M.from_proto(proto, instrs, ssa_data, expr_db, cfg)
    if not instrs or #instrs == 0 then return "-- empty" end
    if not ssa_data then return "-- no ssa data" end
    if not cfg then return "-- no cfg data" end

    local out = {}
    local labels = cfg.labels or {}
    local ends = cfg.ends or {}
    local indents = cfg.indents or {}
    local skip = {}
    local structs = cfg.structs or {}

    -- строим карту: pc -> struct header / end
    local header_kind = {}
    local end_of_struct = {}
    for _, s in ipairs(structs) do
        if s.header_label and s.header_pc then
            header_kind[s.header_pc] = s
        end
        if s.end_label and s.end_pc then
            end_of_struct[s.end_pc] = end_of_struct[s.end_pc] or {}
            table.insert(end_of_struct[s.end_pc], s)
        end
    end

    local function fmt_cond(ins)
        local cond_str = ""
        -- формируем условие из инструкции
        local n = ins.name
        local function rcode(reg)
            return get_code(expr_db, ssa_data, reg, ssa_data.read_at[ins.word_idx]) or ("R" .. reg)
        end
        if n == "JUMPIF" then
            return rcode(ins.a)
        elseif n == "JUMPIFNOT" then
            return "not " .. rcode(ins.a)
        elseif n == "JUMPIFEQ" then
            return rcode(ins.a) .. " == " .. rcode(ins.aux or 0)
        elseif n == "JUMPIFNOTEQ" then
            return rcode(ins.a) .. " ~= " .. rcode(ins.aux or 0)
        elseif n == "JUMPIFLE" then
            return rcode(ins.a) .. " <= " .. rcode(ins.aux or 0)
        elseif n == "JUMPIFLT" then
            return rcode(ins.a) .. " < " .. rcode(ins.aux or 0)
        elseif n == "JUMPIFNOTLE" then
            return rcode(ins.a) .. " > " .. rcode(ins.aux or 0)
        elseif n == "JUMPIFNOTLT" then
            return rcode(ins.a) .. " >= " .. rcode(ins.aux or 0)
        elseif n == "JUMPXEQKNIL" then
            local nf = (ins.aux or 0) >= 0x80000000
            return rcode(ins.a) .. (nf and " ~= nil" or " == nil")
        elseif n == "JUMPXEQKB" then
            local v = (ins.aux or 0) % 2
            return rcode(ins.a) .. " == " .. (v == 1 and "true" or "false")
        elseif n == "JUMPXEQKN" or n == "JUMPXEQKS" then
            local k = (ins.aux or 0) % 0x1000000
            return rcode(ins.a) .. " == " .. disasm.const_str(proto, k)
        end
        return "true"
    end

    local function fmt_ins(ins)
        local pc = ins.word_idx
        local indent = indents[pc] or 0
        local pad = string.rep("    ", indent)

        -- если это метка, которая уже обработана как структура — пропускаем
        if skip[pc] then return nil end

        -- начало структуры
        local s = header_kind[pc]
        if s then
            if s.kind == "if" then
                -- условие — инструкция pc
                local cond = fmt_cond(ins)
                skip[pc] = true
                local body = { pad .. "if " .. cond .. " then" }
                -- отмечаем, что это if, для правильного закрытия
                s._opened = true
                return body
            elseif s.kind == "while" then
                -- while header: смотрим, какая инструкция первой в теле
                -- реальное условие проверяется в теле; упрощённо выведем комментарий
                skip[pc] = true
                return { pad .. "while true do -- [header]" }
            elseif s.kind == "fornum" then
                skip[pc] = true
                return { pad .. "for ... do -- [fornum]" }
            elseif s.kind == "forgen" then
                skip[pc] = true
                return { pad .. "for ... in ... do -- [forgen]" }
            elseif s.kind == "repeat" then
                skip[pc] = true
                return { pad .. "repeat" }
            end
        end

        -- конец структуры
        if ends[pc] then
            local enders = end_of_struct[pc] or {}
            local lines = {}
            for _, e in ipairs(enders) do
                if e.kind == "if" then
                    table.insert(lines, string.rep("    ", (indents[pc] or 1) - 1) .. "end")
                elseif e.kind == "while" then
                    table.insert(lines, string.rep("    ", (indents[pc] or 1) - 1) .. "end")
                elseif e.kind == "fornum" or e.kind == "forgen" then
                    table.insert(lines, string.rep("    ", (indents[pc] or 1) - 1) .. "end")
                elseif e.kind == "repeat" then
                    table.insert(lines, string.rep("    ", (indents[pc] or 1) - 1) .. "until true")
                end
            end
            return lines
        end

        -- обычные инструкции: попробуем вывести как выражение/присваивание
        local n = ins.name
        local function rc(reg)
            return get_code(expr_db, ssa_data, reg, ssa_data.read_at[pc]) or ("R" .. reg)
        end
        local function wc(reg)
            return assign_to(ssa_data, ins, reg)
        end
        local function cstr(i)
            return disasm.const_str(proto, i)
        end

        if n == "NOP" or n == "PREPVARARGS" or n == "CAPTURE"
            or n == "CLOSEUPVALS" or n == "COVERAGE" or n == "BREAK" then
            return nil
        end

        -- если все writes мертвы — пропускаем
        local wr = ssa_data.write_at[pc]
        if wr and next(wr) then
            local all_dead = true
            for _, vid in pairs(wr) do
                local v = ssa_data.versions[vid]
                if v and v.kind ~= "dead" then all_dead = false; break end
            end
            -- не пропускаем CALL/присваивания с побочками
            if all_dead and n ~= "CALL" and n ~= "CALLFB" then
                return nil
            end
        end

        if n == "LOADNIL" then return { pad .. wc(ins.a) .. " = nil" } end
        if n == "LOADB" then return { pad .. wc(ins.a) .. " = " .. (ins.b ~= 0 and "true" or "false") } end
        if n == "LOADN" then return { pad .. wc(ins.a) .. " = " .. ins.d } end
        if n == "LOADK" then return { pad .. wc(ins.a) .. " = " .. cstr(ins.d) } end
        if n == "LOADKX" then return { pad .. wc(ins.a) .. " = " .. cstr(ins.aux or 0) } end
        if n == "MOVE" then return { pad .. wc(ins.a) .. " = " .. rc(ins.b) } end
        if n == "GETGLOBAL" then return { pad .. wc(ins.a) .. " = " .. cstr(ins.aux or 0) } end
        if n == "GETUPVAL" then return { pad .. wc(ins.a) .. " = upval" .. ins.b } end
        if n == "GETIMPORT" then return { pad .. wc(ins.a) .. " = " .. cstr(ins.d) } end
        if n == "GETTABLE" then return { pad .. wc(ins.a) .. " = " .. rc(ins.b) .. "[" .. rc(ins.c) .. "]" } end
        if n == "GETTABLEKS" then
            local c = proto.constants and proto.constants[(ins.aux or 0) + 1]
            local kn = c and c.value
            if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
                return { pad .. wc(ins.a) .. " = " .. rc(ins.b) .. "." .. kn }
            end
            return { pad .. wc(ins.a) .. " = " .. rc(ins.b) .. "[" .. cstr(ins.aux or 0) .. "]" }
        end
        if n == "GETTABLEN" then return { pad .. wc(ins.a) .. " = " .. rc(ins.b) .. "[" .. (ins.c + 1) .. "]" } end
        if n == "NEWTABLE" then return { pad .. wc(ins.a) .. " = {}" } end
        if n == "NEWCLOSURE" then return { pad .. wc(ins.a) .. " = function() ... end -- P" .. ins.d } end
        if n == "SETUPVAL" then return { pad .. "upval" .. ins.b .. " = " .. rc(ins.a) } end
        if n == "SETGLOBAL" then return { pad .. cstr(ins.aux or 0) .. " = " .. rc(ins.a) } end
        if n == "SETTABLE" then return { pad .. rc(ins.b) .. "[" .. rc(ins.c) .. "] = " .. rc(ins.a) } end
        if n == "SETTABLEKS" then
            local c = proto.constants and proto.constants[(ins.aux or 0) + 1]
            local kn = c and c.value
            if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
                return { pad .. rc(ins.b) .. "." .. kn .. " = " .. rc(ins.a) }
            end
            return { pad .. rc(ins.b) .. "[" .. cstr(ins.aux or 0) .. "] = " .. rc(ins.a) }
        end
        if n == "SETTABLEN" then return { pad .. rc(ins.b) .. "[" .. (ins.c + 1) .. "] = " .. rc(ins.a) } end

        if n == "CALL" or n == "CALLFB" then
            local nres = ins.c - 1
            local nargs = ins.b - 1
            local args = {}
            for i = 1, nargs do args[#args + 1] = rc(ins.a + i) end
            local fname = rc(ins.a)
            local call = fname .. "(" .. table.concat(args, ", ") .. ")"
            if nres == 0 then
                return { pad .. call }
            elseif nres == 1 then
                local wr2 = ssa_data.write_at[pc]
                local vid = wr2 and wr2[ins.a]
                if vid and expr_db and expr_db.inlineable and expr_db.inlineable[vid] then
                    return nil
                end
                return { pad .. wc(ins.a) .. " = " .. call }
            else
                local names = {}
                for i = 0, nres - 1 do names[#names + 1] = wc(ins.a + i) end
                return { pad .. table.concat(names, ", ") .. " = " .. call }
            end
        end

        if n == "RETURN" then
            local nres = ins.b - 1
            if nres <= 0 then return { pad .. "return" } end
            local vals = {}
            for i = 0, nres - 1 do vals[#vals + 1] = rc(ins.a + i) end
            return { pad .. "return " .. table.concat(vals, ", ") }
        end

        if n == "JUMP" then return nil end
        if n == "JUMPBACK" then return nil end
        if is_cond_jump(n) then
            -- остаточный условный переход — выведем как комментарий с условием
            return { pad .. "-- if " .. fmt_cond(ins) .. " then ... end" }
        end

        if n == "FORNPREP" then return { pad .. "for prep -> " .. tostring(jump_target(ins)) } end
        if n == "FORNLOOP" then return { pad .. "for loop -> " .. tostring(jump_target(ins)) } end
        if n == "FORGPREP" then return { pad .. "forgen prep" } end
        if n == "FORGLOOP" then return { pad .. "forgen loop" } end
        if n == "GETVARARGS" then return { pad .. wc(ins.a) .. " = ..." } end
        if n == "DUPTABLE" then return { pad .. wc(ins.a) .. " = {--[[ dup K" .. ins.d .. " ]]}" } end
        if n == "DUPCLOSURE" then return { pad .. wc(ins.a) .. " = function() ... end" } end

        return { pad .. "-- " .. n .. " " .. tostring(ins.a) }
    end

    for _, ins in ipairs(instrs) do
        local lines = fmt_ins(ins)
        if lines then
            for _, l in ipairs(lines) do
                table.insert(out, l)
            end
        end
    end

    return table.concat(out, "\n")
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
