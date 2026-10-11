local M = {}
M.name = "parser"

local BC

local OPNAMES = {
"NOP","BREAK","LOADNIL","LOADB","LOADN","LOADK","MOVE","GETGLOBAL","SETGLOBAL","GETUPVAL","SETUPVAL",
"CLOSEUPVALS","GETIMPORT","GETTABLE","SETTABLE","GETTABLEKS","SETTABLEKS","GETTABLEN","SETTABLEN",
"NEWCLOSURE","NAMECALL","CALL","RETURN","JUMP","JUMPBACK","JUMPIF","JUMPIFNOT","JUMPIFEQ","JUMPIFLE",
"JUMPIFLT","JUMPIFNOTEQ","JUMPIFNOTLE","JUMPIFNOTLT","ADD","SUB","MUL","DIV","MOD","POW","ADDK","SUBK",
"MULK","DIVK","MODK","POWK","AND","OR","ANDK","ORK","CONCAT","NOT","MINUS","LENGTH","NEWTABLE","DUPTABLE",
"SETLIST","FORNPREP","FORNLOOP","FORGLOOP","FORGPREP_INEXT","FASTCALL3","FORGPREP_NEXT","NATIVECALL",
"GETVARARGS","DUPCLOSURE","PREPVARARGS","LOADKX","JUMPX","FASTCALL","COVERAGE","CAPTURE","SUBRK","DIVRK",
"FASTCALL1","FASTCALL2","FASTCALL2K","FORGPREP","JUMPXEQKNIL","JUMPXEQKB","JUMPXEQKN","JUMPXEQKS","IDIV",
"IDIVK","GETUDATAKS","SETUDATAKS","NAMECALLUDATA","NEWCLASSMEMBER","CALLFB","CMPPROTO","FASTPCALL",
"NEWCLASS","CONSTRUCT","FINCONSTRUCT"
}

local NOPS = #OPNAMES

local TWO_WORD = {}
for _, n in ipairs({
"GETGLOBAL","SETGLOBAL","GETIMPORT","GETTABLEKS","SETTABLEKS","NAMECALL",
"JUMPIFEQ","JUMPIFLE","JUMPIFLT","JUMPIFNOTEQ","JUMPIFNOTLE","JUMPIFNOTLT",
"NEWTABLE","SETLIST","FORGLOOP","LOADKX","FASTCALL2","FASTCALL2K","FASTCALL3",
"JUMPXEQKNIL","JUMPXEQKB","JUMPXEQKN","JUMPXEQKS","GETUDATAKS","SETUDATAKS",
"NAMECALLUDATA","NEWCLASSMEMBER","CALLFB","CMPPROTO","NEWCLASS","CONSTRUCT"
}) do
    TWO_WORD[n] = true
end

local JUMPD_OPS = {}
for _, n in ipairs({
"JUMP","JUMPIF","JUMPIFNOT","JUMPIFEQ","JUMPIFLE","JUMPIFLT","JUMPIFNOTEQ",
"JUMPIFNOTLE","JUMPIFNOTLT","FORNPREP","FORNLOOP","FORGPREP","FORGLOOP",
"FORGPREP_INEXT","FORGPREP_NEXT","JUMPBACK",
"JUMPXEQKNIL","JUMPXEQKB","JUMPXEQKN","JUMPXEQKS"
}) do
    JUMPD_OPS[n] = true
end

local OPIDX = {}
for i, n in ipairs(OPNAMES) do OPIDX[n] = i - 1 end

local function s16(v)
    v = v % 0x10000
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end

local function s24(v)
    v = v % 0x1000000
    if v >= 0x800000 then v = v - 0x1000000 end
    return v
end

local function insn_op(w) return w % 256 end
local function insn_a(w) return math.floor(w / 256) % 256 end
local function insn_b(w) return math.floor(w / 65536) % 256 end
local function insn_c(w) return math.floor(w / 16777216) % 256 end
local function insn_d(w) return s16(math.floor(w / 65536) % 65536) end
local function insn_e(w) return s24(math.floor(w / 256) % 16777216) end

local function rd_u8(d, pos)
    if pos < 1 or pos > #d then return nil, pos end
    return string.byte(d, pos), pos + 1
end

local function rd_u32(d, pos)
    if pos < 1 or pos + 3 > #d then return nil, pos end
    local a, b, c, e = string.byte(d, pos, pos + 3)
    return a + b * 256 + c * 65536 + e * 16777216, pos + 4
end

local function rd_var(d, pos)
    local r, s = 0, 1
    while true do
        if pos > #d then return nil, pos end
        local b = string.byte(d, pos)
        pos = pos + 1
        r = r + (b % 128) * s
        s = s * 128
        if b < 128 then break end
        if s > 2 ^ 53 then return nil, pos end
    end
    return r, pos
end

local function rd_double(d, pos)
    if pos < 1 or pos + 7 > #d then return nil, pos end
    local buf = buffer.fromstring(d)
    local v = buffer.readf64(buf, pos - 1)
    return v, pos + 8
end

--========= OPCODE SCHEME DETECTION =========

local function proto_ok(proto, dec)
    local code = proto.code_words
    local n = #code
    if n == 0 then return true end
    local i = 1
    local last_op = nil
    while i <= n do
        local w = code[i]
        local enc = w % 256
        local real = dec[enc]
        if real == nil or real >= NOPS then return false end
        local name = OPNAMES[real + 1]
        if not name then return false end
        local two = TWO_WORD[name]
        local ln = two and 2 or 1
        if i + ln - 1 > n then return false end
        last_op = real
        if JUMPD_OPS[name] then
            local d = s16(math.floor(w / 65536) % 65536)
            local t = i + d + ln
            if t < 1 or t > n + 1 then return false end
        elseif name == "JUMPX" then
            local e = s24(math.floor(w / 256) % 16777216)
            local t = i + e + 1
            if t < 1 or t > n + 1 then return false end
        end
        i = i + ln
    end
    if i ~= n + 1 then return false end
    if last_op and last_op ~= 22 then return false end
    return true
end

local function build_candidates()
    local list = {}
    do
        local t = {}
        for x = 0, 255 do t[x] = x end
        list[#list+1] = {name = "identity", dec = t}
    end
    local tried = { [1] = true, [203] = true, [227] = true }
    local order = {227, 203, 37}
    for _, k in ipairs(order) do
        local t = {}
        for x = 0, 255 do t[x] = (x * k) % 256 end
        list[#list+1] = {name = "mul " .. k, dec = t}
    end
    for k = 1, 255, 2 do
        if not tried[k] then
            local t = {}
            for x = 0, 255 do t[x] = (x * k) % 256 end
            list[#list+1] = {name = "mul " .. k, dec = t}
        end
    end
    for k = 1, 255 do
        local t = {}
        for x = 0, 255 do t[x] = bit32.bxor(x, k) end
        list[#list+1] = {name = "xor " .. k, dec = t}
    end
    return list
end

local function detect_scheme(protos)
    local cands = build_candidates()
    for _, c in ipairs(cands) do
        local ok_all = true
        for _, p in ipairs(protos) do
            if not proto_ok(p, c.dec) then
                ok_all = false
                break
            end
        end
        if ok_all then return c end
    end
    return nil
end

local function apply_scheme(protos, scheme)
    for _, p in ipairs(protos) do
        local code = p.code_words
        local i = 1
        while i <= #code do
            local w = code[i]
            local enc = w % 256
            local real = scheme.dec[enc]
            local hi = math.floor(w / 256) * 256
            code[i] = hi + real
            local name = OPNAMES[real + 1]
            local two = name and TWO_WORD[name]
            i = i + (two and 2 or 1)
        end
    end
end

--========= PARSER =========

local function parse_impl(data)
    local pos = 1
    local version = rd_u8(data, pos)
    if not version then return nil, "empty data" end
    pos = pos + 1
    if version == 0 then return nil, "compile error" end
    if version < 3 or (version > 14 and version ~= 100) then
        return nil, "unsupported version " .. version
    end

    local typesversion = 0
    if version >= 4 then
        typesversion = rd_u8(data, pos)
        if not typesversion then return nil, "eof@typesversion" end
        pos = pos + 1
    end

    local sc
    sc, pos = rd_var(data, pos)
    if not sc then return nil, "eof@strcount" end
    local strings = {}
    for i = 1, sc do
        local len
        len, pos = rd_var(data, pos)
        if not len then return nil, "eof@strlen" end
        if pos + len - 1 > #data then return nil, "eof@strdata" end
        strings[i] = string.sub(data, pos, pos + len - 1)
        pos = pos + len
    end

    if typesversion == 3 then
        while true do
            local idx = rd_u8(data, pos)
            if not idx then return nil, "eof@udatamap" end
            pos = pos + 1
            if idx == 0 then break end
            local _
            _, pos = rd_var(data, pos)
            if not pos then return nil, "eof@udatamap2" end
        end
    end

    local pcount
    pcount, pos = rd_var(data, pos)
    if not pcount then return nil, "eof@protocount" end
    local protos = {}

    for i = 1, pcount do
        local proto_size = 0
        if version >= 12 then
            proto_size, pos = rd_var(data, pos)
            if not proto_size then return nil, "eof@protosize" end
        end
        local proto_start = pos

        local pr = {}
        pr.maxstack, pos = rd_u8(data, pos)
        if not pr.maxstack then return nil, "eof@maxstack" end
        pr.numparams, pos = rd_u8(data, pos)
        pr.nups, pos = rd_u8(data, pos)
        pr.is_vararg, pos = rd_u8(data, pos)

        if version >= 4 then
            pr.flags, pos = rd_u8(data, pos)
            if not pr.flags then return nil, "eof@flags" end
            local ts
            ts, pos = rd_var(data, pos)
            if not ts then return nil, "eof@typesize" end
            pos = pos + ts
        end

        local sizecode
        sizecode, pos = rd_var(data, pos)
        if not sizecode then return nil, "eof@sizecode" end
        pr.code_offset = pos
        pr.sizecode = sizecode
        pr.code_words = {}
        for j = 1, sizecode do
            pr.code_words[j], pos = rd_u32(data, pos)
            if not pr.code_words[j] then return nil, "eof@code" end
        end

        local sizek
        sizek, pos = rd_var(data, pos)
        if not sizek then return nil, "eof@sizek" end
        pr.constants = {}
        for j = 1, sizek do
            local kind = rd_u8(data, pos)
            if not kind then return nil, "eof@constkind" end
            pos = pos + 1
            local c = {kind = kind, offset = pos}
            if kind == 0 then
            elseif kind == 1 then
                c.value = rd_u8(data, pos) ~= 0
                pos = pos + 1
            elseif kind == 2 then
                c.value, pos = rd_double(data, pos)
                if c.value == nil then return nil, "eof@dbl" end
            elseif kind == 3 then
                local si
                si, pos = rd_var(data, pos)
                if not si then return nil, "eof@cstr" end
                c.value = si > 0 and strings[si] or nil
            elseif kind == 4 then
                c.import_ids, pos = rd_u32(data, pos)
                if not c.import_ids then return nil, "eof@import" end
            elseif kind == 5 then
                local n
                n, pos = rd_var(data, pos)
                if not n then return nil, "eof@tbln" end
                for _ = 1, n do
                    local _, np = rd_var(data, pos)
                    if not np then return nil, "eof@tblk" end
                    pos = np
                end
            elseif kind == 6 then
                local _, np = rd_var(data, pos)
                if not np then return nil, "eof@closure" end
                pos = np
            elseif kind == 7 then
                pos = pos + 16
            elseif kind == 8 then
                local n
                n, pos = rd_var(data, pos)
                if not n then return nil, "eof@twcn" end
                for _ = 1, n do
                    local _, np = rd_var(data, pos)
                    if not np then return nil, "eof@twck" end
                    pos = np
                    local _, np2 = rd_u32(data, pos)
                    if not np2 then return nil, "eof@twcv" end
                    pos = np2
                end
            elseif kind == 9 then
                local neg = rd_u8(data, pos)
                if not neg then return nil, "eof@intneg" end
                pos = pos + 1
                c.value, pos = rd_var(data, pos)
                if c.value == nil then return nil, "eof@intval" end
                if neg ~= 0 then c.value = -c.value end
            elseif kind == 10 then
                local _, np = rd_var(data, pos)
                if not np then return nil, "eof@clsn" end
                pos = np
                local np2, nm
                np2, pos = rd_var(data, pos)
                nm, pos = rd_var(data, pos)
                if not np2 or not nm then return nil, "eof@clsc" end
                for _ = 1, np2 + nm do
                    local _, np3 = rd_var(data, pos)
                    if not np3 then return nil, "eof@clsm" end
                    pos = np3
                end
            elseif kind == 11 then
                pos = pos + 32
            else
                return nil, "unknown const kind " .. kind
            end
            if pos - 1 > #data then return nil, "eof@constend" end
            pr.constants[j] = c
        end

        local sizep
        sizep, pos = rd_var(data, pos)
        if not sizep then return nil, "eof@sizep" end
        pr.children = {}
        for j = 1, sizep do
            pr.children[j], pos = rd_var(data, pos)
            if not pr.children[j] then return nil, "eof@child" end
        end

        pr.linedefined, pos = rd_var(data, pos)
        if not pr.linedefined then return nil, "eof@linedef" end
        local dn
        dn, pos = rd_var(data, pos)
        if not dn then return nil, "eof@debugname" end
        pr.debugname = dn > 0 and strings[dn] or nil

        local lf = rd_u8(data, pos)
        if not lf then return nil, "eof@lineflag" end
        pos = pos + 1
        if lf ~= 0 then
            local lg = rd_u8(data, pos)
            if not lg then return nil, "eof@linegap" end
            pos = pos + 1
            local intervals = sizecode > 0 and (math.floor((sizecode - 1) / 2 ^ lg) + 1) or 1
            pos = pos + sizecode + intervals * 4
        end

        local df = rd_u8(data, pos)
        if not df then return nil, "eof@debugflag" end
        pos = pos + 1
        if df ~= 0 then
            local slv
            slv, pos = rd_var(data, pos)
            if not slv then return nil, "eof@locvars" end
            pr.locvars = {}
            for j = 1, slv do
                local ni, sp, ep
                ni, pos = rd_var(data, pos)
                sp, pos = rd_var(data, pos)
                ep, pos = rd_var(data, pos)
                if not ni or not sp or not ep then return nil, "eof@locvar" end
                local reg = rd_u8(data, pos)
                if not reg then return nil, "eof@locvarreg" end
                pos = pos + 1
                pr.locvars[j] = {name = ni > 0 and strings[ni] or nil, startpc = sp, endpc = ep, reg = reg}
            end
            local suv
            suv, pos = rd_var(data, pos)
            if not suv then return nil, "eof@upvals" end
            pr.upvalues = {}
            for j = 1, suv do
                local ni
                ni, pos = rd_var(data, pos)
                if not ni then return nil, "eof@upval" end
                pr.upvalues[j] = ni > 0 and strings[ni] or nil
            end
        end

        if version >= 11 then
            local fbs
            fbs, pos = rd_var(data, pos)
            if not fbs then return nil, "eof@fbcount" end
            for _ = 1, fbs do
                pos = pos + 1
                local _, np = rd_var(data, pos)
                if not np then return nil, "eof@fb" end
                pos = np
            end
        end

        if version >= 12 then
            if pr.flags and bit32 and bit32.band(pr.flags, 8) ~= 0 then
                local _, np = rd_var(data, pos)
                if not np then return nil, "eof@cost" end
                pos = np
            end
            if proto_size > 0 then pos = proto_start + proto_size end
        end

        protos[i] = pr
    end

    local main_idx
    main_idx, pos = rd_var(data, pos)
    if not main_idx then return nil, "eof@main" end

    local result = {
        version = version,
        typesversion = typesversion,
        strings = strings,
        protos = protos,
        main = main_idx,
        scheme = "identity"
    }

    local scheme = detect_scheme(protos)
    if scheme and scheme.name ~= "identity" then
        apply_scheme(protos, scheme)
        result.scheme = scheme.name
    end

    return result
end

function M.parse(data)
    local ok, result, err = pcall(parse_impl, data)
    if not ok then return nil, "parse crash: " .. tostring(result) end
    if not result then return nil, err or "unknown error" end
    return result
end

function M.iter_instrs(pr)
    local list = {}
    local i = 1
    while i <= pr.sizecode do
        local wv = pr.code_words[i]
        if wv == nil then break end
        local op = insn_op(wv)
        local nm = OPNAMES[op + 1] or ("OP_" .. op)
        local two = TWO_WORD[nm] or false
        list[#list + 1] = {
            word_idx = i,
            word = wv,
            op = op,
            name = nm,
            a = insn_a(wv),
            b = insn_b(wv),
            c = insn_c(wv),
            d = insn_d(wv),
            e = insn_e(wv),
            aux = two and pr.code_words[i + 1] or nil,
            byte_offset = pr.code_offset + (i - 1) * 4,
            length = two and 2 or 1,
        }
        i = i + (two and 2 or 1)
    end
    return list
end

M.OPNAMES = OPNAMES
M.OPIDX = OPIDX
M.TWO_WORD = TWO_WORD

function M.init(bc)
    BC = bc
end

return M
