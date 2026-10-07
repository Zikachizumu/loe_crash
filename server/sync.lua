--[[
    loe_crash / server / sync.lua

    Fırlayan oyuncunun başlangıç noktası + fırlatma velocity'sini yakındaki
    oyunculara iletir (client/sync.lua). Oyun mantığı yok, veritabanı yok.
    Gönderen kimliği istemciden alınmaz, `source`'tur: oyuncu yalnızca kendi
    fırlamasını bildirebilir. Değer sınırları alıcı istemcide de doğrulanır.
]]

if not Config.Sync.enabled then return end

local MIN_INTERVAL_MS = 1000      -- oyuncu başına (istemci cooldown'u 3000 ms)
local MAX_START_DISTANCE = 30.0   -- başlangıç noktası oyuncunun sunucudaki konumundan bu kadar uzak olamaz
local MAX_SPINS = 2

local lastAt = {}

local function isVec(v) return type(v) == 'vector3' end

RegisterNetEvent('loe_crash:ejected', function(data)
    local src = tonumber(source)
    if not src or type(data) ~= 'table' or not isVec(data.start) or not isVec(data.launch) then return end
    if data.spins ~= nil and (type(data.spins) ~= 'table' or #data.spins > MAX_SPINS) then return end

    local now = GetGameTimer()
    if lastAt[src] and now - lastAt[src] < MIN_INTERVAL_MS then return end
    lastAt[src] = now

    local payload = { start = data.start, launch = data.launch, spins = data.spins or {} }

    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then
        -- OneSync kapalı: sunucu konumu bilmez; herkese gönderilir, istemciler mesafeyi kendisi filtreler
        TriggerClientEvent('loe_crash:remoteEjected', -1, src, payload)
        return
    end

    local origin = GetEntityCoords(ped)
    if #(origin - data.start) > MAX_START_DISTANCE then return end

    local range = Config.Sync.range
    for _, id in ipairs(GetPlayers()) do
        local target = tonumber(id)
        if target and target ~= src then
            local other = GetPlayerPed(target)
            if other ~= 0 and #(GetEntityCoords(other) - origin) <= range then
                TriggerClientEvent('loe_crash:remoteEjected', target, src, payload)
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    lastAt[tonumber(source)] = nil
end)
