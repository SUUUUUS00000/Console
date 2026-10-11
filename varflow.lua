local M = {}
M.name = "varflow"

function M.classify(proto, instrs)
    local info = {
        nparams = proto.numparams or 0,
        maxstack = proto.maxstack or 0,
        regs = {},
    }

    for i = 0, info.maxstack - 1 do
        local kind = "temp"
        if i < info.nparams then kind = "param" end
        info.regs[i] = { kind = kind, defs = {}, uses = {} }
    end

    for _, ins in ipairs(instrs) do
        local n = ins.name

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
            local r = info.regs[ins.a]
            if r then table.insert(r.defs, ins.word_idx) end
        elseif n == "CALL" or n == "CALLFB" then
            local c = (ins.c or 1) - 1
            if c > 0 then
                for k = 0, c - 1 do
                    local r = info.regs[ins.a + k]
                    if r then table.insert(r.defs, ins.word_idx) end
                end
            end
        elseif n == "NAMECALL" then
            local r1 = info.regs[ins.a]
            if r1 then table.insert(r1.defs, ins.word_idx) end
            local r2 = info.regs[ins.a + 1]
            if r2 then table.insert(r2.defs, ins.word_idx) end
        elseif n == "GETVARARGS" then
            local b = (ins.b or 1) - 1
            if b > 0 then
                for k = 0, b - 1 do
                    local r = info.regs[ins.a + k]
                    if r then table.insert(r.defs, ins.word_idx) end
                end
            end
        end

        local sources = {}
        if n == "MOVE" or n == "NOT" or n == "MINUS" or n == "LENGTH" then
            sources[#sources + 1] = ins.b
        elseif n == "GETTABLE" or n == "SETTABLE" then
            sources[#sources + 1] = ins.b
            sources[#sources + 1] = ins.c
        elseif n == "GETTABLEKS" or n == "GETTABLEN" then
            sources[#sources + 1] = ins.b
        elseif n == "SETTABLEKS" or n == "SETTABLEN" then
            sources[#sources + 1] = ins.a
            sources[#sources + 1] = ins.b
        elseif n == "ADD" or n == "SUB" or n == "MUL" or n == "DIV" or n == "IDIV"
            or n == "MOD" or n == "POW" or n == "AND" or n == "OR" then
            sources[#sources + 1] = ins.b
            sources[#sources + 1] = ins.c
        elseif n == "ADDK" or n == "SUBK" or n == "MULK" or n == "DIVK" or n == "IDIVK"
            or n == "MODK" or n == "POWK" or n == "ANDK" or n == "ORK" then
            sources[#sources + 1] = ins.b
        elseif n == "SUBRK" or n == "DIVRK" then
            sources[#sources + 1] = ins.c
        elseif n == "CONCAT" then
            for k = ins.b, ins.c do sources[#sources + 1] = k end
        elseif n == "RETURN" then
            local b = (ins.b or 1) - 1
            if b > 0 then
                for k = 0, b - 1 do sources[#sources + 1] = ins.a + k end
            end
        elseif n == "JUMPIF" or n == "JUMPIFNOT"
            or n == "JUMPXEQKNIL" or n == "JUMPXEQKB" or n == "JUMPXEQKN" or n == "JUMPXEQKS" then
            sources[#sources + 1] = ins.a
        elseif n == "JUMPIFEQ" or n == "JUMPIFNOTEQ" or n == "JUMPIFLE" or n == "JUMPIFLT"
            or n == "JUMPIFNOTLE" or n == "JUMPIFNOTLT" then
            sources[#sources + 1] = ins.a
            sources[#sources + 1] = ins.aux or 0
        elseif n == "CALL" or n == "CALLFB" then
            sources[#sources + 1] = ins.a
            local b = (ins.b or 1) - 1
            if b > 0 then
                for k = 1, b do sources[#sources + 1] = ins.a + k end
            end
        elseif n == "NAMECALL" then
            sources[#sources + 1] = ins.b
        end

        for _, reg in ipairs(sources) do
            local r = info.regs[reg]
            if r then table.insert(r.uses, ins.word_idx) end
        end
    end

    for reg, r in pairs(info.regs) do
        if r.kind == "temp" and #r.defs >= 2 then
            r.kind = "local_candidate"
        end
    end

    return info
end

function M.init(bc)
end

return M
