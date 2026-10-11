local M = {}
M.name = "names"

-- Возвращает карту reg -> display_name для прототипа.
-- Без отладочной информации единственная надёжная разметка:
--   регистры 0..numparams-1 - параметры   -> arg1, arg2, arg3
--   остальные                - временные  -> v1, v2, v3, ...
-- Имена стабильны: один регистр всегда получает одно и то же имя внутри функции.

function M.for_proto(proto, instrs)
    local names = {}
    local nparams = proto.numparams or 0
    local maxreg = proto.maxstack or 20
    if maxreg < nparams then maxreg = nparams end
    if maxreg < 1 then maxreg = 1 end

    for i = 0, nparams - 1 do
        names[i] = "arg" .. (i + 1)
    end

    local counter = 1
    for i = nparams, maxreg - 1 do
        names[i] = "v" .. counter
        counter = counter + 1
    end

    return names
end

-- Быстрая проверка: используется ли имя регистра где-либо в списке инструкций.
-- Нужно, чтобы не плодить vN для регистров, которых реально нет.
function M.used_regs(instrs)
    local used = {}
    for _, ins in ipairs(instrs) do
        local n = ins.name
        -- приёмник
        if n == "CALL" or n == "CALLFB" then
            local c = (ins.c or 1) - 1
            if c > 0 then
                for k = 0, c - 1 do used[ins.a + k] = true end
            end
        elseif n == "GETVARARGS" then
            local b = (ins.b or 1) - 1
            if b > 0 then
                for k = 0, b - 1 do used[ins.a + k] = true end
            end
        elseif n == "NAMECALL" then
            used[ins.a] = true
            used[ins.a + 1] = true
        elseif n == "FORNLOOP" or n == "FORNPREP" then
            for k = 0, 2 do used[ins.a + k] = true end
        elseif n == "FORGLOOP" then
            local cnt = (ins.aux or 0) % 256
            for k = 0, 2 do used[ins.a + k] = true end
            for k = 3, 3 + cnt do used[ins.a + k] = true end
        elseif n == "FORGPREP" or n == "FORGPREP_INEXT" or n == "FORGPREP_NEXT" then
            for k = 0, 2 do used[ins.a + k] = true end
        elseif n == "NEWTABLE" or n == "DUPTABLE" or n == "NEWCLOSURE" or n == "DUPCLOSURE"
            or n == "LOADNIL" or n == "LOADB" or n == "LOADN" or n == "LOADK" or n == "LOADKX"
            or n == "MOVE" or n == "GETGLOBAL" or n == "GETUPVAL" or n == "GETIMPORT"
            or n == "GETTABLE" or n == "GETTABLEKS" or n == "GETTABLEN" or n == "GETUDATAKS"
            or n == "ADD" or n == "SUB" or n == "MUL" or n == "DIV" or n == "IDIV" or n == "MOD"
            or n == "POW" or n == "ADDK" or n == "SUBK" or n == "MULK" or n == "DIVK"
            or n == "IDIVK" or n == "MODK" or n == "POWK" or n == "SUBRK" or n == "DIVRK"
            or n == "AND" or n == "OR" or n == "ANDK" or n == "ORK"
            or n == "CONCAT" or n == "NOT" or n == "MINUS" or n == "LENGTH" then
            used[ins.a] = true
        end
        -- источники
        if n == "MOVE" or n == "NOT" or n == "MINUS" or n == "LENGTH" then
            used[ins.b] = true
        elseif n == "GETTABLE" or n == "SETTABLE" then
            used[ins.b] = true
            used[ins.c] = true
        elseif n == "GETTABLEKS" or n == "GETTABLEN" then
            used[ins.b] = true
        elseif n == "SETTABLEKS" or n == "SETTABLEN" then
            used[ins.a] = true
            used[ins.b] = true
        elseif n == "ADD" or n == "SUB" or n == "MUL" or n == "DIV" or n == "IDIV"
            or n == "MOD" or n == "POW" or n == "AND" or n == "OR" then
            used[ins.b] = true
            used[ins.c] = true
        elseif n == "ADDK" or n == "SUBK" or n == "MULK" or n == "DIVK" or n == "IDIVK"
            or n == "MODK" or n == "POWK" or n == "ANDK" or n == "ORK" then
            used[ins.b] = true
        elseif n == "SUBRK" or n == "DIVRK" then
            used[ins.c] = true
        elseif n == "CONCAT" then
            for k = ins.b, ins.c do used[k] = true end
        elseif n == "RETURN" then
            local b = (ins.b or 1) - 1
            if b > 0 then
                for k = 0, b - 1 do used[ins.a + k] = true end
            end
        elseif n == "JUMPIF" or n == "JUMPIFNOT"
            or n == "JUMPXEQKNIL" or n == "JUMPXEQKB" or n == "JUMPXEQKN" or n == "JUMPXEQKS" then
            used[ins.a] = true
        elseif n == "JUMPIFEQ" or n == "JUMPIFNOTEQ" or n == "JUMPIFLE" or n == "JUMPIFLT"
            or n == "JUMPIFNOTLE" or n == "JUMPIFNOTLT" then
            used[ins.a] = true
            used[ins.aux or 0] = true
        elseif n == "CALL" or n == "CALLFB" then
            used[ins.a] = true
            local b = (ins.b or 1) - 1
            if b > 0 then
                for k = 1, b do used[ins.a + k] = true end
            end
        elseif n == "NAMECALL" then
            used[ins.b] = true
        end
    end
    return used
end

function M.init(bc)
    -- без зависимостей
end

return M
