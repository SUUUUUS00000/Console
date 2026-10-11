local M = {}
M.name = "ssa"

local BC
local parser

local function is_unconditional_jump(name)
    return name == "JUMP" or name == "JUMPBACK" or name == "JUMPX"
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
    if is_unconditional_jump(ins.name) or is_cond_jump(ins.name) then
        return ins.word_idx + ins.d + ins.length
    end
    if ins.name == "LOADB" and ins.c ~= 0 then
        return ins.word_idx + ins.c + ins.length
    end
    if ins.name == "FORNPREP" or ins.name == "FORGPREP"
        or ins.name == "FORGPREP_INEXT" or ins.name == "FORGPREP_NEXT" then
        return ins.word_idx + ins.d + ins.length
    end
    if ins.name == "FORNLOOP" or ins.name == "FORGLOOP" then
        return ins.word_idx + ins.d + ins.length
    end
    return -1
end

local function is_branching(name)
    return is_unconditional_jump(name) or is_cond_jump(name)
        or name == "FORNPREP" or name == "FORNLOOP"
        or name == "FORGPREP" or name == "FORGLOOP"
        or name == "FORGPREP_INEXT" or name == "FORGPREP_NEXT"
        or (name == "LOADB")
end

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
        if c > 0 then
            for k = 0, c - 1 do r[#r+1] = ins.b + k end
        end
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
    elseif n == "FORNPREP" or n == "FORNLOOP" then
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
    if #instrs > 0 then leaders[1] = true end

    for i, ins in ipairs(instrs) do
        if is_branching(ins.name) then
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

    local preds = {}
    for bi = 1, #blocks do preds[bi] = {} end
    for i, ins in ipairs(instrs) do
        local bi = block_of[i]
        if is_unconditional_jump(ins.name) then
            local t = jump_target(ins)
            if index[t] then table.insert(preds[block_of[index[t]]], bi) end
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
    local index = {}
    for i, ins in ipairs(instrs) do index[ins.word_idx] = i end

    local versions = {}
    local version_count = 0
    local name_of = {}
    local read_at = {}
    local write_at = {}
    local reg_ver = {}

    local function new_version(reg, def_pc, kind)
        version_count = version_count + 1
        versions[version_count] = {
            id = version_count,
            reg = reg,
            def_pc = def_pc,
            uses = {},
            kind = kind or "value",
        }
        return version_count
    end

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

    -- loop detection: блоки внутри обратного перехода
    local loop_of = {}
    for i, ins in ipairs(instrs) do
        if is_unconditional_jump(ins.name) or is_cond_jump(ins.name) then
            local t = jump_target(ins)
            if t > 0 and t < ins.word_idx then
                for bi, b in ipairs(blocks) do
                    if b.start_pc >= t and b.start_pc <= ins.word_idx then
                        loop_of[bi] = true
                    end
                end
            end
        end
    end

    local block_entry = {}
    local block_exit = {}
    block_entry[1] = {}
    for r, v in pairs(reg_ver) do block_entry[1][r] = v end

    for bi, b in ipairs(blocks) do
        local entry = block_entry[bi]
        if not entry then
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
                            -- создаём phi
                            local phi_id = new_version(r, -1, "phi")
                            name_of[phi_id] = "phi" .. phi_id
                            entry[r] = phi_id
                            -- подтягиваем phi в предшественников, чтобы они использовали ту же версию
                            reg_ver[r] = phi_id
                        end
                    end
                end
            end
            block_entry[bi] = entry
        end

        for r, v in pairs(entry) do
            if reg_ver[r] == nil then reg_ver[r] = v end
        end

        for _, ins in ipairs(b.instrs) do
            local pc = ins.word_idx
            read_at[pc] = {}
            write_at[pc] = {}

            local rr = read_regs(ins)
            for _, r in ipairs(rr) do
                local v = reg_ver[r]
                if not v then v = ensure_reg_ver(r) end
                read_at[pc][r] = v
                table.insert(versions[v].uses, pc)
            end

            local wr = write_regs(ins)
            for _, r in ipairs(wr) do
                local is_loop = false
                if loop_of[bi] and reg_ver[r] then
                    local prev_v = reg_ver[r]
                    local prev_def_pc = versions[prev_v].def_pc
                    if prev_def_pc and prev_def_pc >= 0 then
                        for bj in pairs(loop_of) do
                            local bb = blocks[bj]
                            if bb and prev_def_pc >= bb.start_pc and prev_def_pc <= bb.end_pc then
                                is_loop = true
                                break
                            end
                        end
                    end
                end

                if is_loop and reg_ver[r] then
                    write_at[pc][r] = reg_ver[r]
                    versions[reg_ver[r]].kind = "mut"
                else
                    local v = new_version(r, pc, "value")
                    reg_ver[r] = v
                    write_at[pc][r] = v
                end
            end
        end

        block_exit[bi] = {}
        for r, v in pairs(reg_ver) do
            block_exit[bi][r] = v
        end
    end

    -- финальная классификация
    for id, v in pairs(versions) do
        if v.kind == "value" or v.kind == "phi" then
            if #v.uses == 0 then
                if v.kind ~= "phi" then v.kind = "dead" end
            elseif #v.uses == 1 then
                local def_i = v.def_pc >= 0 and index[v.def_pc] or nil
                local use_i = index[v.uses[1]]
                if def_i and use_i and block_of[def_i] == block_of[use_i] then
                    v.kind = "temp"
                end
            end
        end
    end

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

M.name_for = function(ssa, version_id)
    if not version_id then return "?" end
    return ssa.name_of[version_id] or ("t" .. version_id)
end

function M.init(bc)
    BC = bc
    parser = bc.modules.parser
end

return M
