local M = {}
M.name = "expr"

local BC
local parser, disasm, ssa

local PREC = {
    OR      = 1,
    AND     = 2,
    CMP     = 3,
    CONCAT  = 4,
    ADD     = 5,
    MUL     = 6,
    UNARY   = 7,
    POW     = 8,
    PRIMARY = 9,
}

-- инструкции, чьё значение можно свободно дублировать
local PURE = {
    LOADNIL = true, LOADB = true, LOADN = true, LOADK = true, LOADKX = true,
    MOVE = true, GETGLOBAL = true, GETUPVAL = true, GETIMPORT = true,
    GETTABLE = true, GETTABLEKS = true, GETTABLEN = true,
    ADD = true, SUB = true, MUL = true, DIV = true, IDIV = true, MOD = true, POW = true,
    ADDK = true, SUBK = true, MULK = true, DIVK = true, IDIVK = true, MODK = true, POWK = true,
    SUBRK = true, DIVRK = true,
    AND = true, OR = true, ANDK = true, ORK = true,
    CONCAT = true, NOT = true, MINUS = true, LENGTH = true,
}

-- инструкции, которые безопасно инлайнить (без сайд-эффектов и без многострочности)
local INLINE_SAFE = {}
for k in pairs(PURE) do INLINE_SAFE[k] = true end
INLINE_SAFE.MOVE = true
INLINE_SAFE.GETTABLE = true
INLINE_SAFE.GETTABLEKS = true
INLINE_SAFE.GETTABLEN = true
INLINE_SAFE.GETGLOBAL = true
INLINE_SAFE.GETUPVAL = true
INLINE_SAFE.GETIMPORT = true

local BINOP_PREC = {
    ADD = PREC.ADD, SUB = PREC.ADD,
    MUL = PREC.MUL, DIV = PREC.MUL, IDIV = PREC.MUL, MOD = PREC.MUL,
    POW = PREC.POW,
    CONCAT = PREC.CONCAT,
    AND = PREC.AND, OR = PREC.OR,
}

local CMPOP = {
    JUMPIFEQ = "==", JUMPIFNOTEQ = "~=",
    JUMPIFLE = "<=", JUMPIFLT = "<",
    JUMPIFNOTLE = ">", JUMPIFNOTLT = ">=",
}

local BINOP_SYM = {
    ADD = "+", SUB = "-", MUL = "*", DIV = "/", IDIV = "//", MOD = "%", POW = "^",
    ADDK = "+", SUBK = "-", MULK = "*", DIVK = "/", IDIVK = "//", MODK = "%", POWK = "^",
    AND = "and", OR = "or", ANDK = "and", ORK = "or",
    CONCAT = "..",
}

local function cstr(proto, i)
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

-- Возвращает {code=..., prec=N} для значения, определяемого в ins.
-- Если значение невыразимо — nil.
local function render_def(ins, proto, expr_of, ssa_data, get_read, depth)
    if depth > 8 then return nil end

    local n = ins.name

    if n == "LOADNIL" then
        return {code = "nil", prec = PREC.PRIMARY}
    end
    if n == "LOADB" then
        return {code = (ins.b ~= 0) and "true" or "false", prec = PREC.PRIMARY}
    end
    if n == "LOADN" then
        return {code = tostring(ins.d), prec = PREC.PRIMARY}
    end
    if n == "LOADK" then
        return {code = cstr(proto, ins.d), prec = PREC.PRIMARY}
    end
    if n == "LOADKX" then
        return {code = cstr(proto, ins.aux or 0), prec = PREC.PRIMARY}
    end
    if n == "GETGLOBAL" then
        return {code = cstr(proto, ins.aux or 0), prec = PREC.PRIMARY}
    end
    if n == "GETIMPORT" then
        return {code = cstr(proto, ins.d), prec = PREC.PRIMARY}
    end
    if n == "GETUPVAL" then
        return {code = "upval" .. ins.b, prec = PREC.PRIMARY}
    end
    if n == "MOVE" then
        return get_read(ins.b, depth + 1)
    end
    if n == "GETTABLE" then
        local t = get_read(ins.b, depth + 1)
        local k = get_read(ins.c, depth + 1)
        if not t or not k then return nil end
        return {code = t.code .. "[" .. k.code .. "]", prec = PREC.PRIMARY}
    end
    if n == "GETTABLEKS" then
        local t = get_read(ins.b, depth + 1)
        if not t then return nil end
        local c = proto and proto.constants and proto.constants[(ins.aux or 0) + 1]
        local kn = c and c.value
        if type(kn) == "string" and kn:match("^[%a_][%w_]*$") then
            return {code = t.code .. "." .. kn, prec = PREC.PRIMARY}
        end
        return {code = t.code .. "[" .. cstr(proto, ins.aux or 0) .. "]", prec = PREC.PRIMARY}
    end
    if n == "GETTABLEN" then
        local t = get_read(ins.b, depth + 1)
        if not t then return nil end
        return {code = t.code .. "[" .. (ins.c + 1) .. "]", prec = PREC.PRIMARY}
    end

    if n == "NOT" then
        local a = get_read(ins.b, depth + 1)
        if not a then return nil end
        local code = a.code
        if a.prec < PREC.UNARY then code = "(" .. code .. ")" end
        return {code = "not " .. code, prec = PREC.UNARY}
    end
    if n == "MINUS" then
        local a = get_read(ins.b, depth + 1)
        if not a then return nil end
        local code = a.code
        if a.prec < PREC.UNARY then code = "(" .. code .. ")" end
        return {code = "-" .. code, prec = PREC.UNARY}
    end
    if n == "LENGTH" then
        local a = get_read(ins.b, depth + 1)
        if not a then return nil end
        local code = a.code
        if a.prec < PREC.UNARY then code = "(" .. code .. ")" end
        return {code = "#" .. code, prec = PREC.UNARY}
    end

    if n == "ADD" or n == "SUB" or n == "MUL" or n == "DIV" or n == "IDIV"
        or n == "MOD" or n == "POW" or n == "AND" or n == "OR" then
        local a = get_read(ins.b, depth + 1)
        local b = get_read(ins.c, depth + 1)
        if not a or not b then return nil end
        local prec = BINOP_PREC[n] or PREC.ADD
        local sym = BINOP_SYM[n] or "?"
        local right_assoc = (n == "POW" or n == "CONCAT")
        local left_min = right_assoc and (prec + 1) or prec
        local right_min = right_assoc and prec or (prec + 1)
        local lcode = a.code
        local rcode = b.code
        if a.prec < left_min then lcode = "(" .. lcode .. ")" end
        if b.prec < right_min then rcode = "(" .. rcode .. ")" end
        return {code = lcode .. " " .. sym .. " " .. rcode, prec = prec}
    end

    if n == "ADDK" or n == "SUBK" or n == "MULK" or n == "DIVK" or n == "IDIVK"
        or n == "MODK" or n == "POWK" or n == "ANDK" or n == "ORK" then
        local a = get_read(ins.b, depth + 1)
        if not a then return nil end
        local prec = BINOP_PREC[n] or PREC.ADD
        local sym = BINOP_SYM[n] or "?"
        local kcode = cstr(proto, ins.c)
        local right_assoc = (n == "POWK")
        local left_min = right_assoc and (prec + 1) or prec
        local right_min = right_assoc and prec or (prec + 1)
        local lcode = a.code
        if a.prec < left_min then lcode = "(" .. lcode .. ")" end
        return {code = lcode .. " " .. sym .. " " .. kcode, prec = prec}
    end

    if n == "SUBRK" or n == "DIVRK" then
        local b = get_read(ins.c, depth + 1)
        if not b then return nil end
        local prec = n == "SUBRK" and PREC.ADD or PREC.MUL
        local sym = n == "SUBRK" and "-" or "/"
        local kcode = cstr(proto, ins.b)
        local rcode = b.code
        if b.prec < (prec + 1) then rcode = "(" .. rcode .. ")" end
        return {code = kcode .. " " .. sym .. " " .. rcode, prec = prec}
    end

    if n == "CONCAT" then
        local parts = {}
        for i = ins.b, ins.c do
            local r = get_read(i, depth + 1)
            if not r then return nil end
            local rc = r.code
            if r.prec < PREC.CONCAT + 1 then rc = "(" .. rc .. ")" end
            parts[#parts + 1] = rc
        end
        return {code = table.concat(parts, " .. "), prec = PREC.CONCAT}
    end

    return nil
end

function M.build(ssa_data, proto, instrs)
    if not ssa_data or not ssa_data.versions then
        return {expr_of = {}, get = function(_, _) return nil end}
    end

    local ins_at = {}
    for _, ins in ipairs(instrs) do ins_at[ins.word_idx] = ins end

    -- Считаем, сколько раз используется каждая версия
    local use_count = {}
    for id, v in pairs(ssa_data.versions) do
        use_count[id] = #v.uses
    end

    -- Определяем inlineable
    local inlineable = {}
    for id, v in pairs(ssa_data.versions) do
        local ok = false
        if v.kind == "param" then
            ok = true
        elseif v.kind == "temp" or v.kind == "value" then
            if v.def_pc and v.def_pc >= 0 then
                local def_ins = ins_at[v.def_pc]
                if def_ins and INLINE_SAFE[def_ins.name] then
                    if use_count[id] <= 1 then
                        ok = true
                    elseif use_count[id] == 2 and PURE[def_ins.name] then
                        ok = true
                    end
                end
            end
        end
        inlineable[id] = ok
    end

    local expr_of = {}
    local in_progress = {}

    local function get_read(reg, depth, read_version)
        if read_version == nil then return nil end
        local v = ssa_data.versions[read_version]
        if not v then return nil end
        if v.kind == "param" then
            return {code = "arg" .. (v.reg + 1), prec = PREC.PRIMARY}
        end
        if not inlineable[read_version] then
            return {code = ssa_data.name_of[read_version] or ("t" .. read_version), prec = PREC.PRIMARY}
        end
        if expr_of[read_version] then return expr_of[read_version] end
        if in_progress[read_version] then
            return {code = ssa_data.name_of[read_version] or ("t" .. read_version), prec = PREC.PRIMARY}
        end
        if not v.def_pc or v.def_pc < 0 then
            return {code = ssa_data.name_of[read_version] or ("t" .. read_version), prec = PREC.PRIMARY}
        end
        local def_ins = ins_at[v.def_pc]
        if not def_ins then
            return {code = ssa_data.name_of[read_version] or ("t" .. read_version), prec = PREC.PRIMARY}
        end
        in_progress[read_version] = true
        local res = render_def(def_ins, proto, expr_of, ssa_data, function(r, d)
            -- для рекурсивного вызова get_read нужен контекст ssa_data
            local rid = nil
            -- Для текущей инструкции используем её read_at напрямую
            -- Так как get_read вызывается только из render_def по конкретному def_ins,
            -- то rid = ssa_data.read_at[def_ins.word_idx][r]
            local rad = ssa_data.read_at[def_ins.word_idx]
            if rad then rid = rad[r] end
            return get_read(r, d, rid)
        end, depth or 0)
        in_progress[read_version] = nil
        if res then expr_of[read_version] = res end
        return res or {code = ssa_data.name_of[read_version] or ("t" .. read_version), prec = PREC.PRIMARY}
    end

    -- Проходим по всем версиям и вычисляем выражения
    for id, v in pairs(ssa_data.versions) do
        if inlineable[id] and v.def_pc and v.def_pc >= 0 then
            local def_ins = ins_at[v.def_pc]
            if def_ins then
                local res = render_def(def_ins, proto, expr_of, ssa_data, function(r, d)
                    local rad = ssa_data.read_at[def_ins.word_idx]
                    local rid = rad and rad[r]
                    return get_read(r, d, rid)
                end, 0)
                if res then expr_of[id] = res end
            end
        end
    end

    return {
        expr_of = expr_of,
        inlineable = inlineable,
        get = function(id)
            if not id then return nil end
            return expr_of[id]
        end
    }
end

function M.init(bc)
    BC = bc
    parser = bc.modules.parser
    disasm = bc.modules.disasm
    ssa = bc.modules.ssa
end

return M
