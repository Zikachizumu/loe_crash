--[[
    loe_crash / server / debug.lua

    YALNIZCA GELİŞTİRME: Config.Debug.serverLog açıkken istemcinin debug
    satırlarını sunucu konsoluna (ve data/logs dosyasına) yazar. FiveM for
    GTAV Enhanced istemcisi F8 çıktısını diske yazmadığı için test sonuçları
    buradan okunur. Kapalıyken event hiç kaydedilmez.
]]

if not Config.Debug.serverLog then return end

local MAX_LINES = 40
local MAX_LEN = 400
local MIN_INTERVAL_MS = 250

local lastAt = {}

RegisterNetEvent('loe_crash:debugLog', function(lines)
    local src = source
    if type(lines) ~= 'table' then return end

    local now = GetGameTimer()
    if lastAt[src] and now - lastAt[src] < MIN_INTERVAL_MS then return end
    lastAt[src] = now

    for i = 1, math.min(#lines, MAX_LINES) do
        local line = lines[i]
        if type(line) == 'string' then
            print(('[loe_crash][%d] %s'):format(src, line:sub(1, MAX_LEN)))
        end
    end
end)

AddEventHandler('playerDropped', function()
    lastAt[source] = nil
end)

