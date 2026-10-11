local M = {}
M.name = "cfgs"

local BC
local disasm

local COND_OPS = {
    JUMPIF = true, JUMPIFNOT = true,
    JUMPIFEQ = true, JUMPIFNOTEQ = true,
    JUMPIFLE = true, JUMPIFLT = true,
    JUMPIFNOTLE = true, JUMPIFNOTLT = true,
    JUMPXEQKNIL = true, JUMPXEQKB = true,
    JUMPXEQKN = true, JUMPXEQKS = true,
}

local function find_prev_before(instrs, pc)
    for _, other in ipairs(instrs) do
        if other.word_idx + other.length == pc then
            return other
        end
    end
    return nil
end

local function find_ins_at(instrs, pc)
    for _, other in ipairs(instrs) do
        if other.word_idx == pc then return other end
    end
    return nil
end

function M.analyze(instrs)
    if not instrs or #instrs == 0 then
        return { labels = {}, ends = {}, indents = {} }
    end

    local structs = {}

    -- 1. while: JUMPBACK
    for _, ins in ipairs(instrs) do
        if ins.name == "JUMPBACK" then
            local top = disasm.jump_target(ins)
            if top > 0 and top < ins.word_idx then
                structs[#structs+1] = {
                    kind = "while",
                    header_pc = top,
                    body_start = top,
                    body_end = ins.word_idx,
                    end_pc = ins.word_idx + ins.length,
                    ranges = { { top, ins.word_idx + ins.length } },
                }
            end
        end
    end

    -- 2. repeat: условный обратный переход
    for _, ins in ipairs(instrs) do
        if ins.name == "JUMPIF" or ins.name == "JUMPIFNOT" then
            local t = disasm.jump_target(ins)
            if t > 0 and t < ins.word_idx then
                structs[#structs+1] = {
                    kind = "repeat",
                    header_pc = t,
                    body_start = t,
                    body_end = ins.word_idx,
                    end_pc = ins.word_idx + ins.length,
                    ranges = { { t, ins.word_idx + ins.length } },
                }
            end
        end
    end

    -- 3. if / if-else: условный переход вперёд
    for _, ins in ipairs(instrs) do
        if COND_OPS[ins.name] then
            local t = disasm.jump_target(ins)
            if t > ins.word_idx then
                local cond_end = ins.word_idx + ins.length
                local prev = find_prev_before(instrs, t)
                local has_else = false
                local else_start = t
                local end_pc = t
                if prev and prev.name == "JUMP" then
                    local jt = disasm.jump_target(prev)
                    if jt > t then
                        has_else = true
                        else_start = t
                        end_pc = jt
                    end
                end
                local ranges
                if has_else then
                    ranges = {
                        { cond_end, else_start },
                        { else_start, end_pc },
                    }
                else
                    ranges = { { cond_end, t } }
                end
                structs[#structs+1] = {
                    kind = "if",
                    header_pc = ins.word_idx,
                    body_start = cond_end,
                    body_end = has_else and else_start or t,
                    else_start = has_else and else_start or nil,
                    has_else = has_else,
                    end_pc = end_pc,
                    ranges = ranges,
                }
            end
        end
    end

    -- 4. numeric for: FORNPREP ... FORNLOOP
    for _, ins in ipairs(instrs) do
        if ins.name == "FORNPREP" then
            local body_start = ins.word_idx + ins.length
            for _, loop_ins in ipairs(instrs) do
                if loop_ins.name == "FORNLOOP" and disasm.jump_target(loop_ins) == body_start then
                    structs[#structs+1] = {
                        kind = "fornum",
                        header_pc = ins.word_idx,
                        body_start = body_start,
                        body_end = loop_ins.word_idx,
                        end_pc = loop_ins.word_idx + loop_ins.length,
                        ranges = { { body_start, loop_ins.word_idx + loop_ins.length } },
                    }
                    break
                end
            end
        end
    end

    -- 5. generic for: FORGPREP ... FORGLOOP
    for _, ins in ipairs(instrs) do
        if ins.name == "FORGPREP" or ins.name == "FORGPREP_INEXT" or ins.name == "FORGPREP_NEXT" then
            local check_pc = disasm.jump_target(ins)
            local forgloop = find_ins_at(instrs, check_pc)
            if forgloop and forgloop.name == "FORGLOOP" then
                local body_start = ins.word_idx + ins.length
                structs[#structs+1] = {
                    kind = "forgen",
                    header_pc = ins.word_idx,
                    body_start = body_start,
                    body_end = check_pc,
                    end_pc = check_pc + forgloop.length,
                    ranges = { { body_start, check_pc + forgloop.length } },
                }
            end
        end
    end

    -- Сортировка: внешние первыми (start asc, end desc)
    table.sort(structs, function(a, b)
        if a.header_pc ~= b.header_pc then return a.header_pc < b.header_pc end
        return a.end_pc > b.end_pc
    end)

    -- Назначение имён
    local counters = { if_ = 0, else_ = 0, while_ = 0, repeat_ = 0, for_ = 0, end_ = 0 }
    local labels = {}
    local ends = {}

    for _, s in ipairs(structs) do
        if s.kind == "if" then
            counters.if_ = counters.if_ + 1
            s.header_label = "if_" .. counters.if_
            labels[s.header_pc] = s.header_label
            if s.has_else then
                counters.else_ = counters.else_ + 1
                s.else_label = "else_" .. counters.else_
                labels[s.else_start] = s.else_label
            end
            counters.end_ = counters.end_ + 1
            s.end_label = "end_" .. counters.end_
        elseif s.kind == "while" then
            counters.while_ = counters.while_ + 1
            s.header_label = "while_" .. counters.while_
            labels[s.header_pc] = s.header_label
            counters.end_ = counters.end_ + 1
            s.end_label = "end_" .. counters.end_
        elseif s.kind == "repeat" then
            counters.repeat_ = counters.repeat_ + 1
            s.header_label = "repeat_" .. counters.repeat_
            labels[s.header_pc] = s.header_label
            counters.end_ = counters.end_ + 1
            s.end_label = "end_" .. counters.end_
        elseif s.kind == "fornum" or s.kind == "forgen" then
            counters.for_ = counters.for_ + 1
            s.header_label = "for_" .. counters.for_
            labels[s.header_pc] = s.header_label
            counters.end_ = counters.end_ + 1
            s.end_label = "end_" .. counters.end_
        end
    end

    -- Метки конца: собираем по pc, вставляем в начало (внутренние первыми)
    for _, s in ipairs(structs) do
        if s.end_label then
            ends[s.end_pc] = ends[s.end_pc] or {}
            table.insert(ends[s.end_pc], 1, s.end_label)
        end
    end

    -- Отступы: считаем, сколько блоков содержат pc
    local indents = {}
    for _, ins in ipairs(instrs) do
        local pc = ins.word_idx
        local level = 0
        for _, s in ipairs(structs) do
            local contains = false
            for _, r in ipairs(s.ranges) do
                if r[1] <= pc and pc < r[2] then
                    contains = true
                    break
                end
            end
            if contains then level = level + 1 end
        end
        indents[pc] = level
    end

    return {
        structs = structs,
        labels = labels,
        ends = ends,
        indents = indents,
    }
end

function M.init(bc)
    BC = bc
    disasm = bc.modules.disasm
end

return M
