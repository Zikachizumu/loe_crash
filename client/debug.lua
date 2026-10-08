--[[
    loe_crash / client / debug.lua

    Kapalıyken: çizim thread'i hiç çalışmaz, log metni hiç üretilmez.
    Açıkken: F8 konsoluna değerlendirme dökümü + ekranda canlı durum satırı +
    son çarpışmanın dünya üzerinde yön çizgileri.
      yeşil   = çarpışma öncesi hareket (velocityBefore)
      kırmızı = velocity değişimi (deltaVelocity)
      mavi    = son fırlatma velocity'si
]]

CrashDebug = { enabled = false }
local D = CrashDebug
local P = CrashPhysics

local last, lastAt = nil, 0
local lastEjected = false
local liveProvider
local drawing = false

-- Config.Debug.serverLog: satırlar biriktirilip 500 ms'de bir sunucuya gönderilir
-- (server/debug.lua sunucu loguna yazar). Çizim thread'i boşaltır.
local SERVER_FLUSH_MS = 500
local SERVER_BATCH_LINES = 40
local serverQueue = {}
local lastFlushAt = 0

local function vecText(v)
    return ('(%.2f, %.2f, %.2f)'):format(v.x, v.y, v.z)
end

local function output(line)
    print('[loe_crash] ' .. line)
    if Config.Debug.serverLog then
        serverQueue[#serverQueue + 1] = line
    end
end

local function flushServerQueue()
    if #serverQueue == 0 then return end
    local now = GetGameTimer()
    if now - lastFlushAt < SERVER_FLUSH_MS then return end
    lastFlushAt = now

    local batch, rest = {}, {}
    for i = 1, #serverQueue do
        if i <= SERVER_BATCH_LINES then batch[#batch + 1] = serverQueue[i] else rest[#rest + 1] = serverQueue[i] end
    end
    serverQueue = rest
    TriggerServerEvent('loe_crash:debugLog', batch)
end

function D.setLiveProvider(fn)
    liveProvider = fn
end

function D.log(fmt, ...)
    if not D.enabled or not Config.Debug.printToConsole then return end
    output(fmt:format(...))
end

function D.report(an, ejected)
    if not D.enabled then return end
    last, lastAt, lastEjected = an, GetGameTimer(), ejected
    if not Config.Debug.printToConsole then return end

    local lines = {
        ('---- çarpışma: tip=%s  sonuç=%s ----'):format(an.impactType, ejected and 'FIRLATILDI' or 'ENGELLENDİ'),
        ('sebep: %s'):format(an.reason or '-'),
        ('velocityBefore=%s |%.1f km/sa|   velocityAfter=%s |%.1f km/sa|')
            :format(vecText(an.velocityBefore), an.speedBeforeKmh, vecText(an.velocityAfter), an.speedAfterKmh),
        ('deltaVelocity=%s |%.1f km/sa|   ani hız kaybı=%.1f km/sa')
            :format(vecText(an.deltaVelocity), an.deltaKmh, an.speedLossKmh),
        ('atalet (araca göre) ileri/sağ/yukarı = %.1f / %.1f / %.1f km/sa   darbe açısı=%.0f°   şiddet=%.1f')
            :format(an.relForward * P.KMH, an.relRight * P.KMH, an.relUp * P.KMH, an.impactAngleDeg, an.severity),
        ('kanıt: collided=%s  bodyDrop=%.1f  engineDrop=%.1f  havadaydı=%s  minUpright=%.2f  |ω|=%.2f rad/s')
            :format(tostring(an.collided), an.bodyDrop, an.engineDrop, tostring(an.wasAirborne), an.minUpright, P.len(an.angularVelocity)),
        ('kemer=%s  hasar=%s  cooldown=%s ms  koltuk=%s')
            :format(tostring(an.belted), tostring(an.damage or 0), tostring(an.cooldownMs or 0), tostring(an.seat)),
    }
    if an.launch then
        lines[#lines + 1] = ('fırlatma velocity=%s |%.1f km/sa|  yön(heading)=%.0f°  başlangıç=%s')
            :format(vecText(an.launch), P.len(an.launch) * P.KMH, P.headingOf(an.launch),
                an.exitStart and vecText(an.exitStart) or '-')
    end
    for i = 1, #lines do
        output(lines[i])
    end
end

-- ------------------------------------------------------------------ çizim
local function drawText(x, y, text, r, g, b)
    SetTextFont(4)
    SetTextScale(0.0, 0.30)
    SetTextColour(r or 255, g or 255, b or 255, 235)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function drawVector(origin, v, scale, r, g, b)
    DrawLine(origin.x, origin.y, origin.z,
        origin.x + v.x * scale, origin.y + v.y * scale, origin.z + v.z * scale,
        r, g, b, 255)
end

local function drawFrame()
    local x, y, step = 0.015, 0.30, 0.021

    if liveProvider then
        local live = liveProvider()
        drawText(x, y, ('crash: %s  hız=%.0f km/sa  kemer=%s  koltuk=%s  cooldown=%d ms')
            :format(live.state, live.speedKmh, tostring(live.belted), tostring(live.seat), math.floor(live.cooldownMs)))
        y = y + step
        drawText(x, y, ('kaporta=%.0f  sağlamlık=%.0f  HUD göstergesi=%%%.0f')
            :format(live.body, live.engine, (live.body + live.engine) / 20.0))
        y = y + step
    end

    if not last or GetGameTimer() - lastAt > Config.Debug.drawDurationMs then return end
    local an = last
    local scale = Config.Debug.lineScale
    local origin = vector3(an.position.x, an.position.y, an.position.z + 1.2)

    drawVector(origin, an.velocityBefore, scale, 0, 255, 0)
    drawVector(origin, an.deltaVelocity, scale, 255, 40, 40)
    if an.launch then
        drawVector(an.exitStart or origin, an.launch, scale, 40, 160, 255)
    end

    local r, g, b = 255, 120, 120
    if lastEjected then r, g, b = 120, 255, 120 end
    drawText(x, y, ('son: %s / %s — %s'):format(an.impactType, lastEjected and 'FIRLATILDI' or 'ENGELLENDİ', an.reason or '-'), r, g, b)
    y = y + step
    drawText(x, y, ('önce %.0f km/sa  sonra %.0f km/sa  Δv %.0f  kayıp %.0f  şiddet %.0f')
        :format(an.speedBeforeKmh, an.speedAfterKmh, an.deltaKmh, an.speedLossKmh, an.severity))
    y = y + step
    drawText(x, y, ('ileri/sağ/yukarı %.0f / %.0f / %.0f  collided=%s  kaporta -%.0f  sağlamlık -%.0f  havada=%s')
        :format(an.relForward * P.KMH, an.relRight * P.KMH, an.relUp * P.KMH,
            tostring(an.collided), an.bodyDrop, an.engineDrop, tostring(an.wasAirborne)))
    y = y + step
    if an.launch then
        drawText(x, y, ('fırlatma %.0f km/sa  yön %.0f°  hasar %s'):format(P.len(an.launch) * P.KMH, P.headingOf(an.launch), tostring(an.damage or 0)))
    end
end

-- ------------------------------------------------------------------ uzak oyuncular
-- Yakındaki diğer oyuncuların klonu için araçta/ragdoll geçişleri ağ zamanıyla (nt)
-- yazılır. Fırlayan oyuncunun 'ayrılma ... nt=' satırıyla karşılaştırılınca klonun
-- koltuktan bu ekranda ne kadar gecikmeyle indiği görülür.
local REMOTE_CHECK_MS = 50
local REMOTE_RANGE = 100.0
local remote = {}
local nextRemoteCheck = 0

local function truthy(v) return v == true or v == 1 end

local function watchRemotePlayers()
    local now = GetGameTimer()
    if not Config.Debug.printToConsole or now < nextRemoteCheck then return end
    nextRemoteCheck = now + REMOTE_CHECK_MS

    local me = PlayerId()
    local myPos = GetEntityCoords(PlayerPedId())
    for _, player in ipairs(GetActivePlayers()) do
        if player ~= me then
            local ped = GetPlayerPed(player)
            local sid = GetPlayerServerId(player)
            if ped ~= 0 and #(GetEntityCoords(ped) - myPos) <= REMOTE_RANGE then
                local inVeh, rag = truthy(IsPedInAnyVehicle(ped, false)), truthy(IsPedRagdoll(ped))
                local s = remote[sid]
                if s and (s.ped ~= ped or s.inVeh ~= inVeh or s.rag ~= rag) then
                    output(('uzak oyuncu %d: araçta=%s ragdoll=%s konum=%s nt=%d')
                        :format(sid, tostring(inVeh), tostring(rag), vecText(GetEntityCoords(ped)), GetNetworkTime()))
                end
                remote[sid] = { ped = ped, inVeh = inVeh, rag = rag }
            else
                remote[sid] = nil
            end
        end
    end
end

function D.setEnabled(on)
    D.enabled = on == true
    print(('[loe_crash] debug %s'):format(D.enabled and 'AÇIK' or 'KAPALI'))

    if D.enabled and not drawing then
        drawing = true
        CreateThread(function()
            while D.enabled do
                drawFrame()
                watchRemotePlayers()
                flushServerQueue()
                Wait(0)
            end
            drawing = false
        end)
    end
end

