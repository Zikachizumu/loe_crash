--[[
    loe_crash / client / sync.lua

    Fırlamanın DİĞER oyuncuların ekranında anında görünmesi.

    SORUN: Fırlayan istemci kendi ped'ini ClearPedTasksImmediately + warp ile
    koltuktan ayırır ve aynı karede ragdoll'a geçirir. Diğer istemcilerdeki klon
    ped senkronize bir "araçtan in" görevi almaz; ragdoll süresince koltukta
    oturur görünür, ragdoll bitince düştüğü yere ışınlanır.

    ÇÖZÜM: Fırlayan istemci başlangıç noktası + fırlatma velocity'si + dönüş
    impulslarını sunucu üzerinden yakındaki oyunculara gönderir. İzleyici
    istemcide klon hâlâ koltuktaysa gerçek klon YEREL olarak gizlenir ve ağa
    kaydedilmeyen bir kopyası aynı başlangıç koşullarıyla fırlatılır. Gerçek klon
    araçtan ayrıldığı anda kopya silinir, gerçek ped tekrar görünür.

    Ortak yardımcılar (ragdoll isteği, impuls çifti, araç çarpışması, araç kutusu)
    burada tanımlıdır; main.lua da bunları kullanır.
]]

CrashSync = {}
local S = CrashSync
local P = CrashPhysics
local Dbg = CrashDebug

local RAGDOLL_TYPE_NORMAL = 0
local APPLY_TYPE_IMPULSE = 1
local MAX_SPINS = 2

-- BOOL dönen native'ler build'e göre true ya da 1 döndürebiliyor
local function truthy(v) return v == true or v == 1 end

-- ------------------------------------------------------------------ ortak yardımcılar
function S.requestRagdoll(ped)
    local R = Config.Ragdoll
    SetPedToRagdoll(ped, R.minMs, R.maxMs, RAGDOLL_TYPE_NORMAL, false, false, false)
end

function S.applySpinPair(ped, spin)
    local lever = Config.Launch.spinLever
    local ix, iy, iz = spin.dir.x * spin.speed, spin.dir.y * spin.speed, spin.dir.z * spin.speed
    local ox, oy, oz = spin.lever.x * lever, spin.lever.y * lever, spin.lever.z * lever
    -- APPLY_FORCE_TO_ENTITY(entity, forceType, x, y, z, offX, offY, offZ, nComponent,
    --                       bLocalForce, bLocalOffset, bScaleByMass, bPlayAudio, bScaleByTimeWarp)
    ApplyForceToEntity(ped, APPLY_TYPE_IMPULSE, ix, iy, iz, ox, oy, oz, 0, false, false, true, false, true)
    ApplyForceToEntity(ped, APPLY_TYPE_IMPULSE, -ix, -iy, -iz, -ox, -oy, -oz, 0, false, false, true, false, true)
end

-- Sıra önemli olabildiği için (native dokümanı) iki yönde de kapatılır.
-- thisFrameOnly = true: kalıcı değil, her kare çağrıldığı sürece geçerli.
function S.disableVehicleCollision(ped, veh)
    if veh ~= 0 and DoesEntityExist(veh) then
        SetEntityNoCollisionEntity(ped, veh, true)
        SetEntityNoCollisionEntity(veh, ped, true)
    end
end

function S.isInsideVehicleBox(ped, veh, dimsMin, dimsMax)
    if veh == 0 or not DoesEntityExist(veh) or not dimsMin then return false end

    local fwd = GetEntityForwardVector(veh)
    local _, _, up, pos = GetEntityMatrix(veh)
    local l = P.toLocal(P.sub(GetEntityCoords(ped), pos), fwd, P.cross(fwd, up), up)
    local mn, mx, m = dimsMin, dimsMax, Config.Exit.boxMargin
    return l.x > mn.x - m and l.x < mx.x + m
        and l.y > mn.y - m and l.y < mx.y + m
        and l.z > mn.z - m and l.z < mx.z + m
end

-- ------------------------------------------------------------------ gönderme (fırlayan istemci)
function S.broadcastEjection(start, launch, spins)
    if not Config.Sync.enabled then return end
    local list = {}
    for i = 1, math.min(#spins, MAX_SPINS) do
        list[i] = { lever = spins[i].lever, dir = spins[i].dir, speed = spins[i].speed }
    end
    TriggerServerEvent('loe_crash:ejected', { start = start, launch = launch, spins = list })
end

-- ------------------------------------------------------------------ alma (izleyici istemci)
local function validVec(v, maxLen)
    if type(v) ~= 'vector3' then return false end
    local l = P.len(v)
    return l == l and l <= maxLen   -- l == l: NaN değil
end

-- Ağdan gelen veri doğrulanır ve config tavanlarıyla sınırlanır
local function sanitize(data)
    if type(data) ~= 'table'
        or not validVec(data.start, 100000.0)
        or not validVec(data.launch, Config.Launch.maxLaunchSpeed + 1.0) then
        return nil
    end
    local spins = {}
    if type(data.spins) == 'table' then
        for i = 1, math.min(#data.spins, MAX_SPINS) do
            local s = data.spins[i]
            if type(s) == 'table' and validVec(s.lever, 1.01) and validVec(s.dir, 1.01)
                and type(s.speed) == 'number' and s.speed >= 0.0 and s.speed <= Config.Launch.maxSpinSpeed then
                spins[#spins + 1] = { lever = s.lever, dir = s.dir, speed = s.speed }
            end
        end
    end
    return { start = data.start, launch = data.launch, spins = spins }
end

local function stillSeated(realPed, veh)
    return DoesEntityExist(realPed) and GetVehiclePedIsIn(realPed, false) == veh
end

-- Her kare çağrılmalı: yalnızca bu istemcide, yalnızca bu kare için gizler
local function hideReal(realPed)
    if DoesEntityExist(realPed) then SetEntityLocallyInvisible(realPed) end
end

local function runGhost(ghost, realPed, veh, data)
    local E, R = Config.Exit, Config.Ragdoll
    local dimsMin, dimsMax = GetModelDimensions(GetEntityModel(veh))
    local start = data.start

    SetEntityInvincible(ghost, true)
    SetBlockingOfNonTemporaryEvents(ghost, true)
    SetPedCanRagdoll(ghost, true)
    SetEntityVisible(ghost, false, false)

    local function hold()
        S.disableVehicleCollision(ghost, veh)
        SetEntityCoordsNoOffset(ghost, start.x, start.y, start.z, false, false, false)
        SetEntityVelocity(ghost, 0.0, 0.0, 0.0)
    end

    -- Fırlayan istemciyle aynı sıra: hızsız başlangıç noktası, ragdoll teyidi, sonra velocity
    hideReal(realPed)
    hold()
    S.requestRagdoll(ghost)
    local frames = 0
    while not truthy(IsPedRagdoll(ghost)) do
        if frames >= R.activationMaxFrames or not stillSeated(realPed, veh) then return end
        Wait(0)
        frames = frames + 1
        hideReal(realPed)
        hold()
        S.requestRagdoll(ghost)
    end

    SetEntityVisible(ghost, true, false)
    SetEntityVelocity(ghost, data.launch.x, data.launch.y, data.launch.z)
    for i = 1, #data.spins do
        S.applySpinPair(ghost, data.spins[i])
    end

    -- Gerçek klon koltukta kaldığı sürece kopya gösterilir
    local launchedAt = GetGameTimer()
    while stillSeated(realPed, veh) and DoesEntityExist(ghost) do
        hideReal(realPed)

        local elapsed = GetGameTimer() - launchedAt
        if elapsed > R.maxMs + R.watchExtraMs then return end

        if elapsed < E.maxNoCollisionMs
            and (elapsed < E.minNoCollisionMs or S.isInsideVehicleBox(ghost, veh, dimsMin, dimsMax)) then
            S.disableVehicleCollision(ghost, veh)
        end

        if R.keepWhileAirborne and elapsed < R.maxMs
            and not truthy(IsPedRagdoll(ghost)) and truthy(IsEntityInAir(ghost)) then
            S.requestRagdoll(ghost)
        end
        Wait(0)
    end
end

local function playGhost(realPed, veh, data)
    -- isNetwork = false: kopya yalnızca bu istemcide var, sunucuya/başkalarına gitmez
    local ghost = ClonePed(realPed, false, false, true)
    if not ghost or ghost == 0 or not DoesEntityExist(ghost) then return end
    SetEntityAsMissionEntity(ghost, true, true)

    local ok, err = pcall(runGhost, ghost, realPed, veh, data)
    if DoesEntityExist(ghost) then DeleteEntity(ghost) end
    if not ok then
        print(('[loe_crash] HATA (uzak fırlatma): %s'):format(tostring(err)))
    end
end

local playing = {}   -- serverId -> true (aynı oyuncu için tek kopya)

RegisterNetEvent('loe_crash:remoteEjected', function(serverId, data)
    if not Config.Sync.enabled or type(serverId) ~= 'number' or playing[serverId] then return end

    local payload = sanitize(data)
    if not payload then return end

    local player = GetPlayerFromServerId(serverId)
    if player == -1 or player == PlayerId() then return end

    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) then return end
    if #(GetEntityCoords(PlayerPedId()) - payload.start) > Config.Sync.range then return end

    -- Klon koltuktan zaten ayrıldıysa ağ senkronu yetmiştir, kopya gerekmez
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return end

    playing[serverId] = true
    Dbg.log('uzak fırlatma: oyuncu %d hâlâ koltukta görünüyor, yerel kopya fırlatılıyor', serverId)
    CreateThread(function()
        playGhost(ped, veh, payload)
        playing[serverId] = nil
    end)
end)
