local M = {}
M.name = "names"

function M.for_proto(proto, instrs)
    local reg_names = {}
    local nparams = proto.numparams or 0
    local maxreg = proto.maxstack or 20
    if maxreg < nparams then maxreg = nparams end
    if maxreg < 1 then maxreg = 1 end

    for i = 0, nparams - 1 do
        reg_names[i] = "arg" .. (i + 1)
    end

    local counter = 1
    for i = nparams, maxreg - 1 do
        reg_names[i] = "v" .. counter
        counter = counter + 1
    end

    return reg_names
end

function M.init(bc)
end

return M
