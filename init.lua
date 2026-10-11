-- BC Editor loader v0.1.0
-- Замени USERNAME/REPO на свои

local BASE = "https://raw.githubusercontent.com/USERNAME/REPO/main/"

local MODULES = {
    "console",
    "parser",
    "disasm",
    "patch",
    "panel",
}

local BC = { version = "0.1.0", modules = {}, base = BASE }

print("[BC] loading from " .. BASE)

for i, name in ipairs(MODULES) do
    local url = BASE .. name .. ".lua"
    local ok, src = pcall(game.HttpGet, game, url, true)
    if not ok then
        print(("[%d/%d] %s REQUEST FAILED: %s"):format(i, #MODULES, name, tostring(src)))
        return
    end
    if type(src) ~= "string" or #src == 0 then
        print(("[%d/%d] %s EMPTY RESPONSE"):format(i, #MODULES, name))
        return
    end
    if src:sub(1, 1) == "<" then
        print(("[%d/%d] %s GOT HTML (проверь raw-URL)"):format(i, #MODULES, name))
        return
    end
    local fn, err = loadstring(src, "@" .. name)
    if not fn then
        print(("[%d/%d] %s COMPILE ERROR: %s"):format(i, #MODULES, name, tostring(err)))
        return
    end
    local ok2, mod = pcall(fn)
    if not ok2 then
        print(("[%d/%d] %s RUNTIME ERROR: %s"):format(i, #MODULES, name, tostring(mod)))
        return
    end
    if type(mod) ~= "table" then
        print(("[%d/%d] %s NO RETURN TABLE"):format(i, #MODULES, name))
        return
    end
    BC.modules[name] = mod
    print(("[%d/%d] %s OK"):format(i, #MODULES, name))
end

-- Связываем модули
for _, name in ipairs(MODULES) do
    local mod = BC.modules[name]
    if mod and type(mod.init) == "function" then
        local ok, err = pcall(mod.init, BC)
        if not ok then
            print("[BC] " .. name .. ".init FAILED: " .. tostring(err))
            return
        end
    end
end

-- Стартуем GUI
if BC.modules.console and BC.modules.console.start then
    BC.modules.console.start(BC)
end
if BC.modules.panel and BC.modules.panel.start then
    BC.modules.panel.start()
end

print("[BC] ready v" .. BC.version)
