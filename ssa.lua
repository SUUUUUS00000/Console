local M = {}
M.name = "ssa"

local BC
local parser

-- Классификация версии:
--   param  - параметр функции (R0..numparams-1, def_pc == -1)
--   temp   - один def, один use, оба в одном блоке -> можно инлайнить
--   value  - один def, несколько use, все в одном блоке или приходят из одной ветки
--   mut    - несколько def (переприсваивается) -> точно local
--   phi    - версия на входе в блок с несколькими предшественниками
--   loop   - loop-carried переменная (пишется и читается в цикле)

local function is_jump(name)
    if name == "JUMP" or name == "JUMPBACK" or name == "JUMPX" then return true end
    if name == "JUMPIF" or name == "JUMPIFNOT" then return true end
    if name == "JUMPIFEQ" or name == "JUMPIFNOTEQ" then return true end
    if name == "JUMPIFLE" or name == "JUMPIFLT" then return true end
    if name == "JUMPIFNOTLE" or name == "JUMPIFNOTLT" then return true end
    if name == "JUMPXEQKNIL" or name == "JUMPXEQKB" then return true end
    if name == "JUMPXEQKN" or name == "JUMPXEQKS" then return true end
    return false
end

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
    if ins.name == "JUMPX" then
        return ins.word_idx + ins.e + ins.length
    end
    if is_jump(ins.name) then
        return ins.word_idx + ins.d + ins.length
    end
    if ins.name == "LOADB" and ins.c ~= 0 then
        return ins.word_idx + ins.c + ins.length
    end
    return -1
end

-- Какие регистры читает инструкция
local function read_regs(ins)
    local n = ins.name
    local r = {}
    if n == "MOVE" or n == "NOT" or n == "MINUS" or n == "LENGTH" then
        r[#r+1] = ins.b
    elseif n == "GETTABLE" then
        r[#r+1] = ins.b
        r[#r+1] = ins.c
    elseif n == "SETTABLE" then
        r[#r+1] = ins.a
        r[#r+1] = ins.b
        r[#r+1] = ins.c
    elseif n == "GETTABLEKS" or n == "GETTABLEN" or n == "GETUDATAKS" then
        r[#r+1] = ins.b
    elseif n == "SETTABLEKS" or n == "SETTABLEN" or n == "SETUDATAKS" then
        r[#r+1] = ins.a
        r[#r+1] = ins.b
    elseif n == "ADD" or n == "SUB" or n == "MUL" or n == "DIV" or n == "IDIV"
        or n == "MOD" or n == "POW" or n == "AND" or n == "OR" then
        r[#r+1] = ins.b
        r[#r+1] = ins.c
    elseif n == "ADDK" or n == "SUBK" or n == "MULK" or n == "DIVK" or n == "IDIVK"
        or n == "MODK" or n == "POWK" or n == "ANDK" or n == "ORK" then
        r[#r+1] = ins.b
    elseif n == "SUBRK" or n == "DIVRK" then
        r[#r+1] = ins.c
    elseif n == "CONCAT" then
        for k = ins.b, ins.c do r[#r+1] = k end
    elseif n == "RETURN" then
        local b = (ins.b or 1) - 1
        if b > 0 then
            for k = 0, b - 1 do r[#r+1] = ins.a + k end
        end
    elseif n == "JUMPIF" or n == "JUMPIFNOT"
        or n == "JUMPXEQKNIL" or n == "JUMPXEQKB" or n == "JUMPXEQKN" or n == "JUMPXEQKS" then
        r[#r+1] = ins.a
    elseif n == "JUMPIFEQ" or n == "JUMPIFNOTEQ" or n == "JUMPIFLE" or n == "JUMPIFLT"
        or n == "JUMPIFNOTLE" or n == "JUMPIFNOTLT" then
        r[#r+1] = ins.a
        r[#r+1] = ins.aux or 0
    elseif n == "CALL" or n == "CALLFB" then
        r[#r+1] = ins.a
        local b = (ins.b or 1) - 1
        if b > 0 then
            for k = 1, b do r[#r+1] = ins.a + k end
        end
    elseif n == "NAMECALL" then
        r[#r+1] = ins.b
    elseif n == "SETUPVAL" or n == "SETGLOBAL" then
        r[#r+1] = ins.a
    elseif n == "SETLIST" then
        local c = (ins.c or 1) - 1
        for k = 0, c - 1 do r[#r+1] = ins.b + k end
    elseif n == "FORNPREP" or n == "FORNLOOP" then
        r[#r+1] = ins.a
        r[#r+1] = ins.a + 1
        r[#r+1] = ins.a + 2
    elseif n == "FORGPREP" or n == "FORGPREP_INEXT" or n == "FORGPREP_NEXT" then
        r[#r+1] = ins.a
        r[#r+1] = ins.a + 1
        r[#r+1] = ins.a + 2
    elseif n == "FORGLOOP" then
        r[#r+1] = ins.a
        r[#r+1] = ins.a + 1
        r[#r+1] = ins.a + 2
    end
    return r
end

-- Какие регистры пишет инструкция
local function write_regs(ins)
    local n = ins.name
    local r = {}
    if n == "LOADNIL" or n == "LOADB" or n == "LOADN" or n == "LOADK" or n == "LOADKX"
        or n == "MOVE" or n == "GETGLOBAL" or n == "GETUPVAL" or n == "GETIMPORT"
        or n == "GETTABLE" or n == "GETTABLEKS" or n == "GETTABLEN" or n == "GETUDATAKS"
        or n == "NEWTABLE" or n == "DUPTABLE" or n == "NEWCLOSURE" or n == "DUPCLOSURE"
        or n == "ADD" or n == "SUB" or n == "MUL" or n == "DIV" or n == "IDIV" or n == "MOD"
        or n == "POW" or n == "ADDK" or n == "SUBK" or n == "MULK" or n == "DIVK"
        or n == "IDIVK" or n == "MODK" or n == "POWK" or n == "SUBRK" or n == "DIVRK"
        or n == "AND" or n == "OR" or n == "ANDK" or n == "ORK"
        or n == "CONCAT" or n == "NOT" or n == "MINUS" or n == "LENGTH"
        or n == "NEWCLASS" then
        r[#r+1] = ins.a
    elseif n == "CALL" or n == "CALLFB" then
        local c = (ins.c or 1) - 1
        if c < 0 then
            r[#r+1] = ins.a
        elseif c > 0 then
            for k = 0, c - 1 do r[#r+1] = ins.a + k end
        end
    elseif n == "NAMECALL" then
        r[#r+1] = ins.a
        r[#r+1] = ins.a + 1
    elseif n == "GETVARARGS" then
        local b = (ins.b or 1) - 1
        if b < 0 then
            r[#r+1] = ins.a
        elseif b > 0 then
            for k = 0, b - 1 do r[#r+1] = ins.a + k end
        end
    elseif n == "FORNPREP" then
        r[#r+1] = ins.a + 2
    elseif n == "FORNLOOP" then
        r[#r+1] = ins.a + 2
    elseif n == "FORGLOOP" then
        r[#r+1] = ins.a + 2
        local cnt = (ins.aux or 0) % 256
        for k = 3, 3 + cnt - 1 do r[#r+1] = ins.a + k end
    end
    return r
end

local function analyze_blocks(instrs)
    local index = {}
    for i, ins in ipairs(instrs) do
        index[ins.word_idx] = i
    end

    local leaders = {}
    if #instrs > 0 then
        leaders[1] = true
    end

    for i, ins in ipairs(instrs) do
        if ins.name == "JUMP" or ins.name == "JUMPBACK" or ins.name == "JUMPX" then
            local t = jump_target(ins)
            if index[t] then leaders[index[t]] = true end
            if index[i + 1] then leaders[i + 1] = true end
        elseif is_cond_jump(ins.name) then
            local t = jump_target(ins)
            if index[t] then leaders[index[t]] = true end
            if index[i + 1] then leaders[i + 1] = true end
        elseif ins.name == "LOADB" and ins.c ~= 0 then
            local t = jump_target(ins)
            if index[t] then leaders[index[t]] = true end
            if index[i + 1] then leaders[i + 1] = true end
        elseif ins.name == "FORNPREP" or ins.name == "FORGPREP"
            or ins.name == "FORGPREP_INEXT" or ins.name == "FORGPREP_NEXT" then
            local t = jump_target(ins)
            if index[t] then leaders[index[t]] = true end
            if index[i + 1] then leaders[i + 1] = true end
        elseif ins.name == "FORNLOOP" or ins.name == "FORGLOOP" then
            local t = jump_target(ins)
            if index[t] then leaders[index[t]] = true end
            if index[i + 1] then leaders[i + 1] = true end
        end
    end

    local blocks = {}
    local block_of = {}
    local cur = nil
    for i, ins in ipairs(instrs) do
        if leaders[i] then
            cur = { start_idx = i, end_idx = i, start_pc = ins.word_idx, instrs = {} }
            blocks[#blocks + 1] = cur
        end
        if cur then
            cur.instrs[#cur.instrs + 1] = ins
            cur.end_idx = i
            block_of[i] = #blocks
        end
    end

    -- предшественники (по индексу в instrs, с учётом jumps)
    local preds = {}
    for bi, b in ipairs(blocks) do
        preds[bi] = {}
    end
    for i, ins in ipairs(instrs) do
        local bi = block_of[i]
        if ins.name == "JUMP" or ins.name == "JUMPBACK" or ins.name == "JUMPX" then
            local t = jump_target(ins)
            if index[t] then
                table.insert(preds[block_of[index[t]]], bi)
            end
        elseif is_cond_jump(ins.name) then
            local t = jump_target(ins)
            if index[t] then table.insert(preds[block_of[index[t]]], bi) end
            if index[i + 1] then table.insert(preds[block_of[i + 1]], bi) end
        elseif ins.name == "LOADB" and ins.c ~= 0 then
            local t = jump_target(ins)
            if index[t] then table.insert(preds[block_of[index[t]]], bi) end
            if index[i + 1] then table.insert(preds[block_of[i + 1]], bi) end
        elseif ins.name == "FORNPREP" or ins.name == "FORGPREP"
            or ins.name == "FORGPREP_INEXT" or ins.name == "FORGPREP_NEXT" then
            local t = jump_target(ins)
            if index[t] then table.insert(preds[block_of[index[t]]], bi) end
            if index[i + 1] then table.insert(preds[block_of[i + 1]], bi) end
        elseif ins.name == "FORNLOOP" or ins.name == "FORGLOOP" then
            local t = jump_target(ins)
            if index[t] then table.insert(preds[block_of[index[t]]], bi) end
            if index[i + 1] then table.insert(preds[block_of[i + 1]], bi) end
        else
            if index[i + 1] then
                table.insert(preds[block_of[i + 1]], bi)
            end
        end
    end

    return blocks, block_of, preds
end

function M.build(instrs, proto)
    if not instrs or #instrs == 0 then
        return { versions = {}, read_at = {}, write_at = {}, name_of = {} }
    end

    local blocks, block_of, preds = analyze_blocks(instrs)

    local versions = {}
    local version_count = 0
    local name_of = {}
    local read_at = {}
    local write_at = {}
    local reg_ver = {}   -- reg -> version_id

    local function new_version(reg, def_pc, kind)
        version_count = version_count + 1
        versions[version_count] = {
            id = version_count,
            reg = reg,
            def_pc = def_pc,
            uses = {},
            kind = kind or "value",
        }
        name_of[version_count] = nil
        return version_count
    end

    -- параметры
    local nparams = proto.numparams or 0
    for i = 0, nparams - 1 do
        local v = new_version(i, -1, "param")
        reg_ver[i] = v
        name_of[v] = "arg" .. (i + 1)
    end

    local function ensure_reg_ver(reg)
        if not reg_ver[reg] then
            local v = new_version(reg, -1, "value")
            reg_ver[reg] = v
        end
        return reg_ver[reg]
    end

    -- отслеживаем "входные версии" для каждого блока
    local block_entry = {}
    local block_exit = {}
    block_entry[1] = {}
    for r, v in pairs(reg_ver) do block_entry[1][r] = v end

    -- проверка: блок является целью обратного перехода (loop body)?
    local loop_of = {}
    for i, ins in ipairs(instrs) do
        if ins.name == "JUMPBACK" or (is_cond_jump(ins.name)) then
            local t = jump_target(ins)
            if t > 0 and t < ins.word_idx then
                -- этот jump идёт назад
                -- все блоки между target и jump — внутри цикла
                for bi, b in ipairs(blocks) do
                    if b.start_pc >= t and b.start_pc <= ins.word_idx then
                        loop_of[bi] = true
                    end
                end
            end
        end
    end

    -- Проход по блокам в порядке pc
    for bi, b in ipairs(blocks) do
        -- если в блок ведут несколько предшественников с разными версиями — phi
        local entry = block_entry[bi]
        if not entry then
            -- вычисляем entry как объединение exit предшественников
            entry = {}
            for r, v in pairs(reg_ver) do entry[r] = v end
            local ps = preds[bi] or {}
            for _, pi in ipairs(ps) do
                local pe = block_exit[pi]
                if pe then
                    for r, pv in pairs(pe) do
                        if entry[r] == nil then
                            entry[r] = pv
                        elseif entry[r] ~= pv then
                            -- конфликт: создаём phi
                            local phi_id = new_version(r, -1, "phi")
                            entry[r] = phi_id
                        end
                    end
                end
            end
            block_entry[bi] = entry
        end

        -- обновляем reg_ver из entry
        for r, v in pairs(entry) do
            if reg_ver[r] == nil then
                reg_ver[r] = v
            end
        end

        -- обработка инструкций блока
        for _, ins in ipairs(b.instrs) do
            local pc = ins.word_idx
            read_at[pc] = {}
            write_at[pc] = {}

            -- регистры, читаемые
            local rr = read_regs(ins)
            for _, r in ipairs(rr) do
                local v = reg_ver[r]
                if not v then v = ensure_reg_ver(r) end
                read_at[pc][r] = v
                table.insert(versions[v].uses, pc)
            end

            -- регистры, записываемые
            local wr = write_regs(ins)
            for _, r in ipairs(wr) do
                -- если регистр loop-carried, не создаём новую версию
                local is_loop = false
                if loop_of[bi] then
                    -- проверяем, читается ли r раньше в том же цикле
                    if reg_ver[r] and versions[reg_ver[r]].def_pc >= 0 then
                        local prev_v = reg_ver[r]
                        local prev_def_pc = versions[prev_v].def_pc
                        -- если prev version определена внутри этого же цикла — loop-carried
                        for bj, b2 in pairs(loop_of) do
                            local bb = blocks[bj]
                            if bb and prev_def_pc >= bb.start_pc and prev_def_pc <= bb.end_pc then
                                is_loop = true
                                break
                            end
                        end
                    end
                end

                if is_loop and reg_ver[r] then
                    -- переиспользуем существующую версию
                    write_at[pc][r] = reg_ver[r]
                    versions[reg_ver[r]].kind = "mut"
                else
                    local v = new_version(r, pc, "value")
                    reg_ver[r] = v
                    write_at[pc][r] = v
                end
            end
        end

        -- сохраняем выходные версии
        block_exit[bi] = {}
        for r, v in pairs(reg_ver) do
            block_exit[bi][r] = v
        end
    end

    -- финальная классификация
    for id, v in pairs(versions) do
        if v.kind == "value" then
            local def_block = block_of[v.def_pc and 1 or 1]
            local all_uses_same_block = true
            for _, u in ipairs(v.uses) do
                local ui = nil
                for i, ins in ipairs(instrs) do
                    if ins.word_idx == u then ui = i break end
                end
                if ui then
                    local def_i = nil
                    for i, ins in ipairs(instrs) do
                        if ins.word_idx == v.def_pc then def_i = i break end
                    end
                    if def_i and block_of[ui] ~= block_of[def_i] then
                        all_uses_same_block = false
                        break
                    end
                end
            end

            if #v.uses == 0 then
                v.kind = "dead"
            elseif #v.uses == 1 and all_uses_same_block then
                v.kind = "temp"
            elseif all_uses_same_block then
                v.kind = "value"
            else
                v.kind = "value"
            end
        end
    end

    -- имена для временных и значений: t1, t2, ...
    local counter = 0
    for id = 1, version_count do
        if not name_of[id] then
            counter = counter + 1
            name_of[id] = "t" .. counter
        end
    end

    return {
        versions = versions,
        read_at = read_at,
        write_at = write_at,
        name_of = name_of,
        blocks = blocks,
        block_of = block_of,
        preds = preds,
        loop_of = loop_of,
    }
end

function M.name_for(ssa, version_id)
    if not version_id then return "?" end
    return ssa.name_of[version_id] or ("t" .. version_id)
end

function M.init(bc)
    BC = bc
    parser = bc.modules.parser
end

return M
