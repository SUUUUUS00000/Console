local M = {}
M.name = "decompile"

local API_URL = "https://obfuscation-tvcs.onrender.com/decompile"

local function bytes_to_hex(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X", string.byte(data, i))
    end
    return table.concat(parts, " ")
end

function M.api_decompile(bytecode_str)
    if type(bytecode_str) ~= "string" or #bytecode_str == 0 then
        return nil, "empty bytecode"
    end
    if typeof(request) ~= "function" then
        return nil, "request unavailable"
    end

    local HttpService = game:GetService("HttpService")
    local body_ok, body = pcall(function()
        return HttpService:JSONEncode({code = bytes_to_hex(bytecode_str)})
    end)
    if not body_ok then return nil, "json encode failed: " .. tostring(body) end

    local ok, res = pcall(request, {
        Url = API_URL,
        Method = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body = body,
    })
    if not ok then return nil, "request failed: " .. tostring(res) end
    if type(res) ~= "table" then return nil, "bad response type" end
    if res.StatusCode ~= 200 then
        return nil, "status " .. tostring(res.StatusCode) .. ": " .. tostring(res.Body)
    end

    local dec_ok, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)
    if not dec_ok then return nil, "json decode failed: " .. tostring(data) end
    if type(data) ~= "table" then return nil, "bad json" end
    if not data.result then return nil, "no result field" end
    return data.result
end

function M.decompile_best(bytecode_str)
    local src, err = M.api_decompile(bytecode_str)
    if src and type(src) == "string" and #src > 0 then
        return src, "d1", nil
    end
    return nil, nil, "d1: " .. tostring(err)
end

function M.init(bc)
end

return M
