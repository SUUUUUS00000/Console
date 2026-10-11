local M = {}
M.name = "disasm"

local BC
local parser

local JUMP_OPS = {
    JUMP = true, JUMPBACK = true, JUMPIF = true, JUMPIFNOT = true,
    JUMPIFEQ = true, JUMPIFLE = true, JUMPIFLT = true,
    JUMPIFNOTEQ = true, JUMPIFNOTLE = true, JUMPIFNOTLT = true,
    JUMPX = true, FORNPREP = true, FORNLOOP = true,
    FORGPREP = true, FORGLOOP = true,
    FORGPREP_INEXT = true, FORGPREP_NEXT = true,
    JUMPXEQKNIL = true, JUMPXEQKB = true, JUMPXEQKN = true, JUMPXEQKS = true,
}

function M.jump_target(ins)
    local n = ins.name
    if n == "JUMPX" then
        return ins.word_idx + ins.e + ins.length
    end
    if JUMP_OPS[n] then
        return ins.word_idx + ins.d + ins.length
    end
    if n == "LOADB" and ins.c ~= 0 then
        return ins.word_idx + ins.c + ins.length
    end
    return -1
end

function M.collect_labels(instrs)
    local set = {}
    for _, ins in ipairs(instrs) do
        if JUMP_OPS[ins.name] or (ins.name == "LOADB" and ins.c ~= 0) then
            local t = M.jump_target(ins)
            if t >= 1 then set[t] = true end
        end
    end
    local ordered = {}
    for pc in pairs(set) do ordered[#ordered + 1] = pc end
    table.sort(ordered)
    local named = {}
    for i, pc in ipairs(ordered) do
        named[pc] = "L" .. i
    end
    return named
end

local function const_str(proto, i)
    if not proto or not proto.constants then return "?" end
    local c = proto.constants[i + 1]
    if not c then return "?" end
    if c.kind == 2 then
        local v = c.value
        if type(v) ~= "number" then return "?" end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return tostring(math.floor(v))
        end
        return string.format("%.6g", v)
    end
    if c.kind == 3 then
        return "'" .. tostring(c.value or "") .. "'"
    end
    if c.kind == 9 then
        return tostring(c.value) .. "i"
    end
    return "?"
end

function M.fmt(ins, proto, labels, reg_names)
    local n = ins.name
    local function cstr(i) return const_str(proto, i) end
    local function R(reg)
        if reg_names and reg_names[reg] then return reg_names[reg] end
        return "R" .. reg
    end
    local function L(t)
        if labels and labels[t] then return labels[t] end
        return string.format("%+d", t - ins.word_idx - ins.length)
    end

    if n == "NOP" then return "" end
    if n == "LOADNIL" then return R(ins.a) .. " = nil" end
    if n == "LOADB" then
        if ins.c ~= 0 then
            return R(ins.a) .. " = " .. (ins.b ~= 0 and "true" or "false") .. " ; goto " .. L(M.jump_target(ins))
        end
        return R(ins.a) .. " = " .. (ins.b ~= 0 and "true" or "false")
    end
    if n == "LOADN" then return R(ins.a) .. " = " .. ins.d end
    if n == "LOADK" then return R(ins.a) .. " = " .. cstr(ins.d) end
    if n == "LOADKX" then return R(ins.a) .. " = " .. cstr(ins.aux or 0) end
    if n == "MOVE" then return R(ins.a) .. " = " .. R(ins.b) end
    if n == "GETUPVAL" then return R(ins.a) .. " = upval" .. ins.b end
    if n == "SETUPVAL" then return "upval" .. ins.b .. " = " .. R(ins.a) end
    if n == "GETGLOBAL" then return R(ins.a) .. " = " .. cstr(ins.aux or 0) end
    if n == "SETGLOBAL" then return cstr(ins.aux or 0) .. " = " .. R(ins.a) end
    if n == "GETIMPORT" then return R(ins.a) .. " = " .. cstr(ins.d) end
    if n == "GETTABLE" then return R(ins.a) .. " = " .. R(ins.b) .. "[" .. R(ins.c) .. "]" end
    if n == "SETTABLE" then return R(ins.b) .. "[" .. R(ins.c) .. "] = " .. R(ins.a) end
    if n == "GETTABLEKS" then
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value
        if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
            return R(ins.a) .. " = " .. R(ins.b) .. "." .. kn
        end
        return R(ins.a) .. " = " .. R(ins.b) .. "[" .. cstr(ins.aux or 0) .. "]"
    end
    if n == "SETTABLEKS" then
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value
        if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
            return R(ins.b) .. "." .. kn .. " = " .. R(ins.a)
        end
        return R(ins.b) .. "[" .. cstr(ins.aux or 0) .. "] = " .. R(ins.a)
    end
    if n == "GETTABLEN" then return R(ins.a) .. " = " .. R(ins.b) .. "[" .. (ins.c + 1) .. "]" end
    if n == "SETTABLEN" then return R(ins.b) .. "[" .. (ins.c + 1) .. "] = " .. R(ins.a) end
    if n == "NEWTABLE" then return R(ins.a) .. " = {}" end
    if n == "DUPTABLE" then return R(ins.a) .. " = {dup K" .. ins.d .. "}" end
    if n == "SETLIST" then return R(ins.a) .. "[..] = {" .. R(ins.b) .. "..}" end
    if n == "NEWCLOSURE" then return R(ins.a) .. " = closure(P" .. ins.d .. ")" end
    if n == "DUPCLOSURE" then return R(ins.a) .. " = closure(K" .. ins.d .. ")" end
    if n == "CAPTURE" then return "capture " .. ins.a .. " " .. R(ins.b) end
    if n == "NAMECALL" then
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value or "?"
        return R(ins.a) .. " = " .. R(ins.b) .. ":" .. tostring(kn) .. "(...)"
    end
    if n == "CALL" then
        local nargs = ins.b - 1
        local nres = ins.c - 1
        local args = {}
        for i = 1, nargs do args[#args + 1] = R(ins.a + i) end
        local res = nres == 1 and (R(ins.a) .. " = ") or ""
        return res .. "call(" .. R(ins.a) .. (#args > 0 and (", " .. table.concat(args, ", ")) or "") .. ")"
    end
    if n == "RETURN" then
        local nres = ins.b - 1
        if nres <= 0 then return "return" end
        local vals = {}
        for i = 0, nres - 1 do vals[#vals + 1] = R(ins.a + i) end
        return "return " .. table.concat(vals, ", ")
    end
    if n == "JUMP" then return "goto " .. L(M.jump_target(ins)) end
    if n == "JUMPBACK" then return "back " .. L(M.jump_target(ins)) end
    if n == "JUMPX" then return "gotoX " .. L(M.jump_target(ins)) end
    if n == "JUMPIF" then return "if " .. R(ins.a) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFNOT" then return "if not " .. R(ins.a) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFEQ" then return "if " .. R(ins.a) .. " == " .. R(ins.aux or 0) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFNOTEQ" then return "if " .. R(ins.a) .. " ~= " .. R(ins.aux or 0) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFLE" then return "if " .. R(ins.a) .. " <= " .. R(ins.aux or 0) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFLT" then return "if " .. R(ins.a) .. " < " .. R(ins.aux or 0) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFNOTLE" then return "if " .. R(ins.a) .. " > " .. R(ins.aux or 0) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPIFNOTLT" then return "if " .. R(ins.a) .. " >= " .. R(ins.aux or 0) .. " then goto " .. L(M.jump_target(ins)) end
    if n == "JUMPXEQKNIL" then
        local nf = (ins.aux or 0) >= 0x80000000
        return "if " .. R(ins.a) .. " " .. (nf and "~=" or "==") .. " nil then goto " .. L(M.jump_target(ins))
    end
    if n == "JUMPXEQKB" then
        local v = (ins.aux or 0) % 2
        return "if " .. R(ins.a) .. " == " .. (v == 1 and "true" or "false") .. " then goto " .. L(M.jump_target(ins))
    end
    if n == "JUMPXEQKN" or n == "JUMPXEQKS" then
        local k = (ins.aux or 0) % 0x1000000
        return "if " .. R(ins.a) .. " == " .. cstr(k) .. " then goto " .. L(M.jump_target(ins))
    end
    if n == "ADD" then return R(ins.a) .. " = " .. R(ins.b) .. " + " .. R(ins.c) end
    if n == "SUB" then return R(ins.a) .. " = " .. R(ins.b) .. " - " .. R(ins.c) end
    if n == "MUL" then return R(ins.a) .. " = " .. R(ins.b) .. " * " .. R(ins.c) end
    if n == "DIV" then return R(ins.a) .. " = " .. R(ins.b) .. " / " .. R(ins.c) end
    if n == "IDIV" then return R(ins.a) .. " = " .. R(ins.b) .. " // " .. R(ins.c) end
    if n == "MOD" then return R(ins.a) .. " = " .. R(ins.b) .. " % " .. R(ins.c) end
    if n == "POW" then return R(ins.a) .. " = " .. R(ins.b) .. " ^ " .. R(ins.c) end
    if n == "ADDK" then return R(ins.a) .. " = " .. R(ins.b) .. " + " .. cstr(ins.c) end
    if n == "SUBK" then return R(ins.a) .. " = " .. R(ins.b) .. " - " .. cstr(ins.c) end
    if n == "MULK" then return R(ins.a) .. " = " .. R(ins.b) .. " * " .. cstr(ins.c) end
    if n == "DIVK" then return R(ins.a) .. " = " .. R(ins.b) .. " / " .. cstr(ins.c) end
    if n == "MODK" then return R(ins.a) .. " = " .. R(ins.b) .. " % " .. cstr(ins.c) end
    if n == "POWK" then return R(ins.a) .. " = " .. R(ins.b) .. " ^ " .. cstr(ins.c) end
    if n == "SUBRK" then return R(ins.a) .. " = " .. cstr(ins.b) .. " - " .. R(ins.c) end
    if n == "DIVRK" then return R(ins.a) .. " = " .. cstr(ins.b) .. " / " .. R(ins.c) end
    if n == "AND" then return R(ins.a) .. " = " .. R(ins.b) .. " and " .. R(ins.c) end
    if n == "OR" then return R(ins.a) .. " = " .. R(ins.b) .. " or " .. R(ins.c) end
    if n == "ANDK" then return R(ins.a) .. " = " .. R(ins.b) .. " and " .. cstr(ins.c) end
    if n == "ORK" then return R(ins.a) .. " = " .. R(ins.b) .. " or " .. cstr(ins.c) end
    if n == "CONCAT" then
        local parts = {}
        for i = ins.b, ins.c do parts[#parts + 1] = R(i) end
        return R(ins.a) .. " = " .. table.concat(parts, " .. ")
    end
    if n == "NOT" then return R(ins.a) .. " = not " .. R(ins.b) end
    if n == "MINUS" then return R(ins.a) .. " = -" .. R(ins.b) end
    if n == "LENGTH" then return R(ins.a) .. " = #" .. R(ins.b) end
    if n == "FORNPREP" then return "for " .. R(ins.a + 2) .. "=..,.. do (prep " .. L(M.jump_target(ins)) .. ")" end
    if n == "FORNLOOP" then return "for step " .. L(M.jump_target(ins)) end
    if n == "FORGPREP" then return "for in (prep " .. L(M.jump_target(ins)) .. ")" end
    if n == "FORGLOOP" then
        local cnt = (ins.aux or 0) % 256
        return "for in step " .. L(M.jump_target(ins)) .. " vars=" .. cnt
    end
    if n == "GETVARARGS" then return R(ins.a) .. ".. = ..." end
    if n == "PREPVARARGS" then return "prep varargs " .. ins.a end

    return string.format("%s A=%d B=%d C=%d D=%d", n, ins.a, ins.b, ins.c, ins.d)
end

M.const_str = const_str

function M.init(bc)
    BC = bc
    parser = bc.modules.parser
end

return M
