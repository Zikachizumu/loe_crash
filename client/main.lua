--[[
    loe_crash / client / main.lua

    Araç çarpışması algılama + araçtan anında ragdoll olarak fırlama.
    Yalnızca yerel oyuncunun kendi ped'i yönetilir (NPC'ler hariç); her
    istemci kendi ped'inin sahibi olduğu için OneSync'te sahiplik sorunu yoktur.

    DURUM MAKİNESİ
      OUTSIDE  : araç dışı; düşük frekanslı kontrol
      SAMPLING : desteklenen araçta; her kare fizik örneği ring buffer'a yazılır
      DETECTED : kısa pencerede büyük Δv; velocityAfter için confirmDelayMs beklenir
      EJECTING : koltuktan ayırma + ragdoll aktivasyonunun doğrulanması
      RAGDOLL  : fırlatma velocity'si verildi; araçla çarpışma kısa süre kapalı
      COOLDOWN : aynı çarpışma (sürtünme, zemine çarpma) tekrar tetiklenmesin

    Bütün akış TEK thread'de sıralı yürür: bir çarpışmada ikinci fırlatma veya
    ikinci hasar mümkün değildir.
]]

local P = CrashPhysics
local Dbg = CrashDebug

local STATE = {
    OUTSIDE  = 'OUTSIDE',
    SAMPLING = 'SAMPLING',
    DETECTED = 'DETECTED',
    EJECTING = 'EJECTING',
    RAGDOLL  = 'RAGDOLL',
    COOLDOWN = 'COOLDOWN',
}

local WINDSCREEN_FLAG = 32                -- CPED_CONFIG_FLAG_WillFlyThroughWindscreen
-- IntersectWorld | IntersectVehicles | IntersectObjects: çıkış noktası duvar/direk kadar
-- çarpan aracın içine de düşmesin (kendi aracı ışında yok sayılır)
local TRACE_EXIT_FLAGS = 1 + 2 + 16
local TRACE_OPTIONS = 4                   -- OptionIgnoreNoCollision
local RAGDOLL_TYPE_NORMAL = 0
local APPLY_TYPE_IMPULSE = 1
local LEAVE_FLAG_WARP_OUT = 16            -- TASK_LEAVE_VEHICLE: animasyonsuz, ışınlanarak çıkış (kapı kapalı)
local EJECT_STATE_KEY = 'loeCrashEjecting' -- replike oyuncu state'i: fırlatma sürüyor

local ctx = {
    state = STATE.OUTSIDE,
    ped = 0,
    vehicle = 0,
    seat = nil,
    dimsMin = nil,
    dimsMax = nil,
    nextSeatCheck = 0,
    lastSampleAt = 0,
    candidateAt = 0,
    cooldownUntil = 0,
    windscreenPed = 0,
    windscreenSaved = nil,
    internalBelt = false,
    resetRequested = false,
}

local buffer = P.newBuffer(Config.Sampling.bufferSize)

local excludedModels = {}
for _, name in ipairs(Config.Vehicles.excludedModels or {}) do
    excludedModels[GetHashKey(name)] = true
end

-- BOOL dönen native'ler build'e göre true ya da 1 döndürebiliyor
local function truthy(v) return v == true or v == 1 end

local function setState(state, reason)
    if ctx.state == state then return end
    Dbg.log('durum %s -> %s (%s)', ctx.state, state, reason or '-')
    ctx.state = state
end

-- ------------------------------------------------------------------ koltuk
local SEAT_BONES = {
    [-1] = 'seat_dside_f',
    [0]  = 'seat_pside_f',
    [1]  = 'seat_dside_r',
    [2]  = 'seat_pside_r',
}

local function seatBoneName(seat)
    if SEAT_BONES[seat] then return SEAT_BONES[seat] end
    -- 3+ indeksli koltuklar (otobüs/van): seat_dside_r1, seat_pside_r1, seat_dside_r2 ...
    local row = math.floor((seat - 1) / 2)
    return ('seat_%s_r%d'):format(seat % 2 == 1 and 'dside' or 'pside', row)
end

local function findSeat(veh, ped)
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if GetPedInVehicleSeat(veh, seat) == ped then return seat end
    end
    return nil
end

-- Koltuk bone'u (modelden bağımsız); bone yoksa ped'in kendi konumu
local function getSeatWorldPosition(veh, seat, ped)
    if seat then
        local bone = GetEntityBoneIndexByName(veh, seatBoneName(seat))
        if bone ~= -1 then return GetWorldPositionOfEntityBone(veh, bone) end
    end
    return GetEntityCoords(ped)
end

-- ------------------------------------------------------------------ filtreler
local function isSupportedVehicle(veh)
    local V = Config.Vehicles
    if not V.classes[GetVehicleClass(veh)] then return false end

    local model = GetEntityModel(veh)
    if excludedModels[model] then return false end
    if V.excludeBikesByModel and (truthy(IsThisModelABike(model)) or truthy(IsThisModelABicycle(model))) then return false end
    if V.excludeQuadbikes and truthy(IsThisModelAQuadbike(model)) then return false end
    return true
end

local function isSeatbeltFastened()
    local S = Config.Seatbelt
    if S.source == 'internal' then return ctx.internalBelt end
    if S.source == 'export' then
        local ok, result = pcall(function()
            return exports[S.export.resource][S.export.method]()
        end)
        return ok and result == true
    end
    return LocalPlayer.state[S.stateBagKey] == true
end

-- Ölü / baygın / ragdoll'u başka bir sistem tarafından kilitli ise sebep döner.
-- Qbox ölüm/bayılma state'lerine YAZILMAZ, yalnızca okunur.
local function getBlockingCondition(ped)
    if truthy(IsEntityDead(ped)) or truthy(IsPedDeadOrDying(ped, true)) or truthy(IsPedFatallyInjured(ped)) then
        return 'oyuncu ölü veya ölmek üzere'
    end
    if LocalPlayer.state.isDead == true then
        return 'LocalPlayer.state.isDead = true'
    end

    local ok, playerData = pcall(function() return exports.qbx_core:GetPlayerData() end)
    if ok and type(playerData) == 'table' and type(playerData.metadata) == 'table' then
        if playerData.metadata.isdead then return 'Qbox metadata.isdead = true' end
        if playerData.metadata.inlaststand then return 'Qbox metadata.inlaststand = true (baygın)' end
    end

    -- CanPedRagdoll burada KULLANILAMAZ: ped koltuktayken oyun ragdoll'u kilitler ve
    -- native her zaman false döner (her çarpışma engelleniyordu). Admin noclip ped'i
    -- dondurup görünmez yapar; engel bu işaretlerden anlaşılır. Ragdoll gerçekten
    -- açılamazsa runEjection'daki aktivasyon doğrulaması fırlatmayı iptal eder.
    if Config.Ragdoll.respectDisabledRagdoll
        and (truthy(IsEntityPositionFrozen(ped)) or not truthy(IsEntityVisible(ped))) then
        return 'ped dondurulmuş veya görünmez (örn. admin noclip)'
    end
    return nil
end

-- ------------------------------------------------------------------ vanilla ön cam fırlatması
local function restoreVanillaEjection()
    if ctx.windscreenPed ~= 0 and ctx.windscreenSaved ~= nil and DoesEntityExist(ctx.windscreenPed) then
        SetPedConfigFlag(ctx.windscreenPed, WINDSCREEN_FLAG, ctx.windscreenSaved)
    end
    ctx.windscreenPed = 0
    ctx.windscreenSaved = nil
end

local function suppressVanillaEjection(ped)
    if not Config.DisableVanillaWindscreenEjection or ctx.windscreenPed == ped then return end
    restoreVanillaEjection()
    ctx.windscreenSaved = truthy(GetPedConfigFlag(ped, WINDSCREEN_FLAG, true))
    ctx.windscreenPed = ped
    SetPedConfigFlag(ped, WINDSCREEN_FLAG, false)
end

-- ------------------------------------------------------------------ güvenli çıkış noktası
local function raycast(from, to, ignoreEntity)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z,
        TRACE_EXIT_FLAGS, ignoreEntity, TRACE_OPTIONS)
    local status, hit, hitPos = GetShapeTestResult(handle)
    return status == 2 and truthy(hit), hitPos
end

-- Başlangıç noktası duvar/direk içine veya zeminin altına düşmesin.
-- Fırlatma başına yalnızca 2 senkron ışın atılır (her karede değil).
local function adjustExitForWorld(veh, seatPos, start)
    local E = Config.Exit

    local wallHit, wallPos = raycast(seatPos, start, veh)
    if wallHit then
        local dir = P.normalize(P.sub(start, seatPos))
        local safeDistance = math.max(0.0, P.len(P.sub(wallPos, seatPos)) - E.wallMargin)
        start = P.add(seatPos, P.scale(dir, safeDistance))
    end

    local top = P.v3(start.x, start.y, start.z + E.groundProbeUp)
    local bottom = P.v3(start.x, start.y, start.z - E.groundProbeDown)
    local groundHit, groundPos = raycast(top, bottom, veh)
    if groundHit and start.z < groundPos.z + E.groundClearance then
        start = P.v3(start.x, start.y, groundPos.z + E.groundClearance)
    end
    return start
end

-- Sıra önemli olabildiği için (native dokümanı) iki yönde de kapatılır.
-- thisFrameOnly = true: kalıcı değil, her kare çağrıldığı sürece geçerli.
local function disableVehicleCollision(ped, veh)
    if veh ~= 0 and DoesEntityExist(veh) then
        SetEntityNoCollisionEntity(ped, veh, true)
        SetEntityNoCollisionEntity(veh, ped, true)
    end
end

local function isInsideVehicleBox(ped, veh)
    if veh == 0 or not DoesEntityExist(veh) or not ctx.dimsMin then return false end

    local fwd = GetEntityForwardVector(veh)
    local _, _, up, pos = GetEntityMatrix(veh)
    local l = P.toLocal(P.sub(GetEntityCoords(ped), pos), fwd, P.cross(fwd, up), up)
    local mn, mx, m = ctx.dimsMin, ctx.dimsMax, Config.Exit.boxMargin
    return l.x > mn.x - m and l.x < mx.x + m
        and l.y > mn.y - m and l.y < mx.y + m
        and l.z > mn.z - m and l.z < mx.z + m
end

-- ------------------------------------------------------------------ kuvvet / hasar
local function applySpinPair(ped, spin)
    local lever = Config.Launch.spinLever
    local ix, iy, iz = spin.dir.x * spin.speed, spin.dir.y * spin.speed, spin.dir.z * spin.speed
    local ox, oy, oz = spin.lever.x * lever, spin.lever.y * lever, spin.lever.z * lever
    -- APPLY_FORCE_TO_ENTITY(entity, forceType, x, y, z, offX, offY, offZ, nComponent,
    --                       bLocalForce, bLocalOffset, bScaleByMass, bPlayAudio, bScaleByTimeWarp)
    ApplyForceToEntity(ped, APPLY_TYPE_IMPULSE, ix, iy, iz, ox, oy, oz, 0, false, false, true, false, true)
    ApplyForceToEntity(ped, APPLY_TYPE_IMPULSE, -ix, -iy, -iz, -ox, -oy, -oz, 0, false, false, true, false, true)
end

local function applyCrashDamage(ped, severity, belted)
    local amount = P.damageForSeverity(severity, Config.Damage)
    if belted then amount = math.floor(amount * Config.Damage.beltedMultiplier + 0.5) end
    if amount <= 0 or truthy(IsPedDeadOrDying(ped, true)) then return 0 end

    ApplyDamageToPed(ped, amount, Config.Damage.armorFirst)
    return amount
end

-- ------------------------------------------------------------------ durum geçişleri
local function startCooldown(ms, reason)
    ctx.cooldownUntil = GetGameTimer() + ms
    P.bufferReset(buffer)
    setState(STATE.COOLDOWN, reason)
end

local function leaveVehicle()
    restoreVanillaEjection()
    P.bufferReset(buffer)
    ctx.vehicle = 0
    ctx.seat = nil
    ctx.dimsMin, ctx.dimsMax = nil, nil
    if Config.Seatbelt.source == 'internal' and Config.Seatbelt.resetInternalOnExit then
        ctx.internalBelt = false
    end
end

local function enterVehicle(ped, veh, now)
    ctx.vehicle = veh
    ctx.seat = findSeat(veh, ped)
    ctx.nextSeatCheck = now + Config.Sampling.seatRecheckMs
    ctx.dimsMin, ctx.dimsMax = GetModelDimensions(GetEntityModel(veh))
    ctx.lastSampleAt = 0
    ctx.loggedHealth = nil
    P.bufferReset(buffer)
    suppressVanillaEjection(ped)
    setState(STATE.SAMPLING, 'desteklenen araca binildi')
end

-- Diğer istemciler bu bayrak açıkken klonu ragdoll'a geçene kadar gizler (bkz. "diğer oyuncular")
local function setEjectingState(on)
    if (LocalPlayer.state[EJECT_STATE_KEY] == true) == on then return end
    LocalPlayer.state:set(EJECT_STATE_KEY, on, true)
end

local function resetAll(reason)
    setEjectingState(false)
    leaveVehicle()
    ctx.candidateAt = 0
    ctx.cooldownUntil = 0
    ctx.resetRequested = false
    setState(STATE.OUTSIDE, reason)
end

-- ------------------------------------------------------------------ örnekleme
local function recordSample(veh, now)
    local vel = GetEntityVelocity(veh)
    local fwd = GetEntityForwardVector(veh)
    local _, _, up, pos = GetEntityMatrix(veh)

    -- Teleport: beklenen yol + paydan fazla sıçrama varsa geçmiş geçersizdir
    -- (garaj çıkışı, admin ışınlama vb. sahte Δv üretmesin)
    local prev = P.bufferGet(buffer, 0)
    if prev then
        local dt = (now - prev.t) / 1000.0
        local dx, dy, dz = pos.x - prev.px, pos.y - prev.py, pos.z - prev.pz
        local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
        local expected = math.sqrt(prev.vx * prev.vx + prev.vy * prev.vy + prev.vz * prev.vz) * dt
        if moved > expected + Config.Sampling.teleportMargin then
            P.bufferReset(buffer)
            if ctx.state == STATE.DETECTED then setState(STATE.SAMPLING, 'teleport algılandı') end
            Dbg.log('teleport algılandı (%.1f m), geçmiş silindi', moved)
        end
    end

    local s = P.bufferNext(buffer)
    s.t = now
    s.vx, s.vy, s.vz = vel.x, vel.y, vel.z
    s.px, s.py, s.pz = pos.x, pos.y, pos.z
    s.fx, s.fy, s.fz = fwd.x, fwd.y, fwd.z
    s.ux, s.uy, s.uz = up.x, up.y, up.z
    s.body = GetVehicleBodyHealth(veh)
    s.engine = GetVehicleEngineHealth(veh)
    s.collided = truthy(HasEntityCollidedWithAnything(veh))
    s.inAir = truthy(IsEntityInAir(veh))
    s.seat = ctx.seat or -2
end

-- ------------------------------------------------------------------ fırlatma
local function requestRagdoll(ped)
    local R = Config.Ragdoll
    SetPedToRagdoll(ped, R.minMs, R.maxMs, RAGDOLL_TYPE_NORMAL, false, false, false)
end

-- Ped'i başlangıç noktasında, hızsız tutar. Koltuk bağlantısı hâlâ kopmadıysa
-- SET_ENTITY_COORDS ped'i araçtan warp ederek çıkarır.
local function holdAtStart(ped, start)
    if truthy(IsPedInAnyVehicle(ped, false)) then
        SetEntityCoords(ped, start.x, start.y, start.z, false, false, false, false)
    end
    SetEntityCoordsNoOffset(ped, start.x, start.y, start.z, false, false, false)
    SetEntityVelocity(ped, 0.0, 0.0, 0.0)
end

-- Koltuktan ayırma (Config.Exit.method).
-- 'task' : TaskLeaveVehicle(16) ağda senkron bir araçtan inme görevidir; diğer
--          istemcilerdeki klon da koltuktan iner. Flag 16 animasyon oynatmaz,
--          ped'i ışınlayarak çıkarır. Görev ped'in AI güncellemesinde işlenir;
--          taskExitMaxFrames karede işlenmezse 'clear' ile kesilir.
-- 'clear': ClearPedTasksImmediately yalnızca yerel ped'i koltuktan koparır; klonlar
--          ragdoll bitene kadar koltukta oturur görünür.
-- Dönüş: false = sıfırlama istendi, fırlatma yarıda bırakılmalı
local function detachFromVehicle(ped, veh)
    local E = Config.Exit
    if E.method == 'task' then
        TaskLeaveVehicle(ped, veh, LEAVE_FLAG_WARP_OUT)
        local frames = 0
        while truthy(IsPedInAnyVehicle(ped, false)) and frames < E.taskExitMaxFrames do
            Wait(0)
            if ctx.resetRequested or not DoesEntityExist(ped) then return false end
            frames = frames + 1
            disableVehicleCollision(ped, veh)
        end
        Dbg.log('araçtan inme görevi: %d kare, hâlâ araçta=%s  nt=%d',
            frames, tostring(truthy(IsPedInAnyVehicle(ped, false))), GetNetworkTime())
    end
    if truthy(IsPedInAnyVehicle(ped, false)) then
        ClearPedTasksImmediately(ped)
    end
    return true
end

local function runEjection(ped, veh, an)
    local E, R = Config.Exit, Config.Ragdoll
    local launch = an.launch
    setState(STATE.EJECTING, an.reason)

    -- 1) Fizik verisi 'an' içinde (velocityBefore/After, Δv, ω, koltuk ofseti).
    --    Çıkış noktası: koltuk bone'u + fırlama yönünde küçük ofset, dünya kontrollü.
    local seatPos = getSeatWorldPosition(veh, ctx.seat, ped)
    local start = adjustExitForWorld(veh, seatPos, P.computeExitStart(seatPos, launch, E))
    an.exitStart = start

    -- 2) Koltuktan ayırma, güvenli başlangıç noktası
    disableVehicleCollision(ped, veh)
    if not detachFromVehicle(ped, veh) then return end
    holdAtStart(ped, start)

    -- 3) AĞ DEVRİ: ped araçtan ayrıldığı karede ragdoll'a geçerse diğer istemcilerdeki
    --    klon ragdoll bitene kadar koltukta kalır, sonra kapı yanına iner ve ped yürüyene
    --    kadar orada durur. Ragdoll'dan önce networkHandoffMs boyunca ped araç dışında,
    --    ragdoll'suz ve fırlatma hızıyla hareket eder; klonlar bu sürede koltuktan iner
    --    ve ardından gerçek ragdoll'u izler.
    --    0 = eski davranış: ped teyide kadar hızsız tutulur, velocity ragdoll'dan sonra
    --    verilir (ragdoll'suz hız verilen oturan ped donuk pozla uçardı).
    local handoff = E.networkHandoffMs > 0
    if handoff then
        SetEntityVelocity(ped, launch.x, launch.y, launch.z)
        local handoffUntil = GetGameTimer() + E.networkHandoffMs
        while GetGameTimer() < handoffUntil do
            Wait(0)
            if ctx.resetRequested or not DoesEntityExist(ped) then return end
            disableVehicleCollision(ped, veh)
        end
    end

    -- 4) Ragdoll iste ve GERÇEKTEN aktif olduğunu doğrula. Ağ devrinde ped hareketine
    --    devam eder; aktivasyon anındaki hızı ragdoll gövdesine aktarılır.
    local carry = handoff and GetEntityVelocity(ped) or launch
    requestRagdoll(ped)
    local active = truthy(IsPedRagdoll(ped))
    local frames = 0
    while not active and frames < R.activationMaxFrames do
        Wait(0)
        if ctx.resetRequested or not DoesEntityExist(ped) then return end
        frames = frames + 1
        disableVehicleCollision(ped, veh)
        active = truthy(IsPedRagdoll(ped))
        if not active then
            if handoff then carry = GetEntityVelocity(ped) else holdAtStart(ped, start) end
            requestRagdoll(ped)
        end
    end

    Dbg.log('ayrılma: araçta=%s  ragdoll aktif=%s  (%d kare)  ağ devri=%d ms  nt=%d',
        tostring(truthy(IsPedInAnyVehicle(ped, false))), tostring(active), frames, E.networkHandoffMs, GetNetworkTime())

    if not active then
        an.reason = ('ragdoll %d karede aktive edilemedi, fırlatma iptal'):format(R.activationMaxFrames)
        Dbg.report(an, false)
        startCooldown(Config.Detection.cooldownMs, an.reason)
        return
    end

    -- 5) Ragdoll aktif: velocity gövdeye verilir
    SetEntityVelocity(ped, carry.x, carry.y, carry.z)

    -- 6) Doğal takla/dönüş için sınırlı merkez dışı impuls çiftleri
    local spins = P.computeSpin(an, launch, Config.Launch, math.random)
    for i = 1, #spins do
        applySpinPair(ped, spins[i])
    end

    -- Hasar: çarpışma başına TEK kez, ragdoll başladıktan sonra
    -- (koltukta ölen ped araçta oturur kalırdı)
    an.damage = applyCrashDamage(ped, an.severity, false)
    Dbg.report(an, true)

    -- 7) Ragdoll'u koru; ped araç kutusundan çıkana kadar araçla çarpışmayı kapat
    setState(STATE.RAGDOLL, 'fırlatıldı')
    local launchedAt = GetGameTimer()
    while true do
        Wait(0)
        if ctx.resetRequested or not DoesEntityExist(ped) then return end

        local elapsed = GetGameTimer() - launchedAt
        if elapsed < E.maxNoCollisionMs and (elapsed < E.minNoCollisionMs or isInsideVehicleBox(ped, veh)) then
            disableVehicleCollision(ped, veh)
        end

        if truthy(IsPedDeadOrDying(ped, true)) then break end

        if not truthy(IsPedRagdoll(ped)) then
            if R.keepWhileAirborne and elapsed < R.maxMs and truthy(IsEntityInAir(ped)) then
                -- Havadayken ragdoll erken biterse ayakta/oturur poza dönmesin
                requestRagdoll(ped)
            elseif elapsed >= E.minNoCollisionMs then
                -- 8) Yerde ve ragdoll bitti: GTA'nın normal kalkma davranışı devralır
                break
            end
        end

        if elapsed > R.maxMs + R.watchExtraMs then break end
    end

    startCooldown(Config.Detection.cooldownMs, 'fırlatma tamamlandı')
end

-- ------------------------------------------------------------------ çarpışma teyidi
local function confirmCrash(ped, veh)
    local an = P.analyze(buffer, ctx.candidateAt, Config.Sampling.historyMs, Config.Detection, Config.Rollover)
    if not an then
        P.bufferKeepNewest(buffer)
        setState(STATE.SAMPLING, 'analiz için yeterli örnek yok')
        return
    end

    an.seat = ctx.seat
    an.belted = Config.Seatbelt.enabled and isSeatbeltFastened() or false
    an.damage = 0
    an.cooldownMs = 0

    -- ω × r için koltuğun araç merkezine göre ofseti: şu anki eksenlerde
    -- yerele çevrilip çarpışma ÖNCESİ eksenlerle dünyaya geri çevrilir.
    local seatPos = getSeatWorldPosition(veh, ctx.seat, ped)
    local afterRight = P.cross(an.afterForward, an.afterUp)
    local seatLocal = P.toLocal(P.sub(seatPos, an.afterPosition), an.afterForward, afterRight, an.afterUp)
    an.seatOffset = P.toWorld(seatLocal, an.forward, an.right, an.up)

    local isCrash, reason = P.evaluate(an, Config.Detection, Config.Rollover)
    an.reason = reason

    if not isCrash then
        Dbg.report(an, false)
        P.bufferKeepNewest(buffer)
        setState(STATE.SAMPLING, reason)
        return
    end

    local blocker = getBlockingCondition(ped)
    if blocker then
        an.reason = blocker
        an.cooldownMs = Config.Detection.beltedCooldownMs
        Dbg.report(an, false)
        startCooldown(an.cooldownMs, blocker)
        return
    end

    if an.belted then
        an.damage = applyCrashDamage(ped, an.severity, true)
        an.reason = 'emniyet kemeri takılı: fırlatma engellendi'
        an.cooldownMs = Config.Detection.beltedCooldownMs
        Dbg.report(an, false)
        startCooldown(an.cooldownMs, 'kemerli çarpışma')
        return
    end

    an.launch = P.computeLaunch(an, Config.Launch, math.random)
    an.cooldownMs = Config.Detection.cooldownMs

    -- Bayrak ayrılmadan ÖNCE açılır ki klon koltuktan inmeden diğer istemcilere ulaşsın;
    -- ragdoll'dan hemen sonra değil, fırlatma bitince kapanır (klonun ragdoll'u gecikmeli gelir)
    setEjectingState(true)
    runEjection(ped, veh, an)
    setEjectingState(false)
end

-- ------------------------------------------------------------------ ana döngü
-- Dönüş: bir sonraki Wait süresi (ms)
local function update()
    if not Config.Enabled then
        if ctx.state ~= STATE.OUTSIDE then resetAll('Config.Enabled = false') end
        return 1000
    end

    local ped = PlayerPedId()
    if ped ~= ctx.ped or ctx.resetRequested then
        resetAll(ped ~= ctx.ped and 'ped değişti (respawn/model)' or 'yeniden doğma')
        ctx.ped = ped
    end

    local now = GetGameTimer()
    local veh = GetVehiclePedIsIn(ped, false)

    if ctx.state == STATE.COOLDOWN then
        if veh == 0 and ctx.vehicle ~= 0 then leaveVehicle() end
        if now < ctx.cooldownUntil then return 100 end
        setState(STATE.OUTSIDE, 'cooldown bitti')
    end

    if ctx.state == STATE.OUTSIDE then
        if veh ~= 0 and isSupportedVehicle(veh) then
            enterVehicle(ped, veh, now)
            return 0
        end
        if Dbg.enabled and veh ~= 0 and ctx.unsupportedLogged ~= veh then
            ctx.unsupportedLogged = veh
            Dbg.log('araç desteklenmiyor, algılama yok (sınıf %d, Config.Vehicles)', GetVehicleClass(veh))
        end
        if ctx.vehicle ~= 0 then leaveVehicle() end
        return Config.Sampling.outsideIdleMs
    end

    -- SAMPLING / DETECTED
    if veh == 0 or veh ~= ctx.vehicle then
        leaveVehicle()
        setState(STATE.OUTSIDE, veh == 0 and 'araçtan inildi' or 'araç değişti')
        return 0
    end

    if ctx.seat == nil or now >= ctx.nextSeatCheck then
        ctx.seat = findSeat(veh, ped)
        ctx.nextSeatCheck = now + Config.Sampling.seatRecheckMs
        if ctx.seat == nil then
            -- Biniş/iniş animasyonu sürüyor: koltukta değilken algılama yapılmaz
            P.bufferReset(buffer)
            if ctx.state == STATE.DETECTED then setState(STATE.SAMPLING, 'koltukta değil') end
            return 100
        end
    end

    local interval = Config.Sampling.intervalMs
    if interval <= 0 or now - ctx.lastSampleAt >= interval then
        recordSample(veh, now)
        ctx.lastSampleAt = now
    end

    -- Debug: aday olsun olmasın her hasar düşüşü loglanır (algılama hiç tetiklenmiyor mu?)
    if Dbg.enabled then
        local body, engine = GetVehicleBodyHealth(veh), GetVehicleEngineHealth(veh)
        local total = body + engine
        if not ctx.loggedHealth or total > ctx.loggedHealth then
            ctx.loggedHealth = total
        elseif ctx.loggedHealth - total >= 2.0 then
            Dbg.log('araç hasarı: kaporta=%.0f sağlamlık=%.0f (HUD %%%.0f, düşüş %.0f puan)  durum=%s  kemer=%s  hız=%.0f km/sa',
                body, engine, total / 20.0, ctx.loggedHealth - total, ctx.state, tostring(isSeatbeltFastened()),
                GetEntitySpeed(veh) * P.KMH)
            ctx.loggedHealth = total
        end
    end

    if ctx.state == STATE.SAMPLING then
        local D = Config.Detection
        local delta = P.maxRecentDelta(buffer, D.candidateWindowMs) * P.KMH
        if delta >= D.candidateDeltaKmh then
            ctx.candidateAt = now
            setState(STATE.DETECTED, ('ani velocity değişimi %.1f km/sa'):format(delta))
        elseif D.damageTrigger.enabled then
            -- Hasar birkaç temas karesine yayılabilir: analizin geriye baktığı pencere kullanılır.
            -- Reddedilen darbeden sonra buffer tek örneğe indiği için aynı hasar tekrar sayılmaz.
            local bodyDrop, engineDrop = P.maxRecentHealthDrop(buffer, D.preImpactLookbackMs)
            if P.damageTriggerMet(bodyDrop, engineDrop, D.damageTrigger) then
                ctx.candidateAt = now
                setState(STATE.DETECTED, ('ani hasar: kaporta -%.0f, sağlamlık -%.0f'):format(bodyDrop, engineDrop))
            end
        end
    elseif ctx.state == STATE.DETECTED and now - ctx.candidateAt >= Config.Detection.confirmDelayMs then
        confirmCrash(ped, veh)
    end

    return interval > 0 and interval or 0
end

CreateThread(function()
    math.randomseed(GetGameTimer())
    while true do
        -- Tek bir hata algılama thread'ini kalıcı olarak öldürmesin
        local ok, result = pcall(update)
        if ok then
            Wait(result)
        else
            print(('[loe_crash] HATA: %s'):format(tostring(result)))
            Dbg.log('HATA: %s', tostring(result))
            resetAll('hata sonrası sıfırlama')
            Wait(1000)
        end
    end
end)

-- spawnmanager (server.cfg'de ensure) yeniden doğuşta bunu tetikler
AddEventHandler('playerSpawned', function()
    ctx.resetRequested = true
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    restoreVanillaEjection()
    setEjectingState(false)
end)

-- ------------------------------------------------------------------ diğer oyuncular
-- Fırlayan oyuncunun klonu bu ekranda ağ gecikmesi kadar koltukta oturur, sonra GTA onu
-- araçtan indirip kapı yanına AYAKTA koyar ve ragdoll bilgisi gelene kadar (~ağ devri)
-- orada tutar. Bu ayakta poz gösterilmez: oyuncunun EJECT_STATE_KEY bayrağı açıkken klon,
-- araç dışına çıktığı kareden ragdoll'a geçene kadar yalnızca bu istemcide görünmez
-- tutulur. Koltuktayken GİZLENMEZ: bayrak klon inmeden ~100 ms önce gelir, o süreyi
-- de gizlemek karakteri gereksiz yere kaybettirir (gecikme hissi).
local hidingRemote = {}

local function hideRemoteUntilRagdoll(serverId)
    if hidingRemote[serverId] then return end
    hidingRemote[serverId] = true

    CreateThread(function()
        local hideUntil = GetGameTimer() + Config.Sync.hideMaxMs
        local hiddenAt
        while GetGameTimer() < hideUntil do
            local player = GetPlayerFromServerId(serverId)
            if player == -1 then break end
            local ped = GetPlayerPed(player)
            if ped == 0 or not DoesEntityExist(ped) then break end
            if not truthy(IsPedInAnyVehicle(ped, false)) then
                if truthy(IsPedRagdoll(ped)) then break end
                hiddenAt = hiddenAt or GetGameTimer()
                SetEntityLocallyInvisible(ped)   -- her kare çağrılmalı; yalnızca bu kare, yalnızca bu istemci
            end
            Wait(0)
            -- Handler değer bag'e uygulanmadan çağrılır: bayrak ilk kareden sonra okunur
            -- (fırlatma ragdoll teyit edilemeden iptal olduysa kapanmıştır)
            if Player(serverId).state[EJECT_STATE_KEY] ~= true then break end
        end
        Dbg.log('uzak oyuncu %d: gizleme bitti, görünmez kalma %d ms  nt=%d',
            serverId, hiddenAt and (GetGameTimer() - hiddenAt) or 0, GetNetworkTime())
        hidingRemote[serverId] = nil
    end)
end

AddStateBagChangeHandler(EJECT_STATE_KEY, nil, function(bagName, _, value)
    if value ~= true or not Config.Sync.hideRemoteUntilRagdoll then return end
    local serverId = tonumber(bagName:match('^player:(%d+)$'))
    if not serverId or serverId == GetPlayerServerId(PlayerId()) then return end
    Dbg.log('uzak oyuncu %d: fırlatma bayrağı geldi  nt=%d', serverId, GetNetworkTime())
    hideRemoteUntilRagdoll(serverId)
end)

-- ------------------------------------------------------------------ exports (başka kemer sistemleri için)
-- Config.Seatbelt.source = 'internal' iken: exports.loe_crash:SetSeatbeltState(true/false)
exports('SetSeatbeltState', function(state)
    ctx.internalBelt = state == true
end)

exports('IsSeatbeltFastened', function()
    return isSeatbeltFastened()
end)

exports('IsEjecting', function()
    return ctx.state == STATE.EJECTING or ctx.state == STATE.RAGDOLL
end)

exports('GetCrashState', function()
    return ctx.state
end)

-- ------------------------------------------------------------------ debug
Dbg.setLiveProvider(function()
    local veh = ctx.vehicle
    local valid = veh ~= 0 and DoesEntityExist(veh)
    return {
        state = ctx.state,
        speedKmh = valid and GetEntitySpeed(veh) * P.KMH or 0.0,
        body = valid and GetVehicleBodyHealth(veh) or 0.0,
        engine = valid and GetVehicleEngineHealth(veh) or 0.0,
        belted = isSeatbeltFastened(),
        seat = ctx.seat,
        cooldownMs = math.max(0, ctx.cooldownUntil - GetGameTimer()),
    }
end)

if Config.Debug.commandEnabled then
    RegisterCommand(Config.Debug.commandName, function()
        Dbg.setEnabled(not Dbg.enabled)
    end, false)
end

if Config.Debug.enabled then
    Dbg.setEnabled(true)
end

