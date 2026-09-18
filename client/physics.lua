--[[
    loe_crash / client / physics.lua

    SAF MATEMATİK: burada hiçbir oyun native'i çağrılmaz (vector3 kurucusu hariç).
    Ring buffer, çarpışma öncesi/sonrası velocity seçimi, Δv analizi, darbe
    sınıflandırması, fırlatma velocity'si, dönüş impulsları ve hasar kademesi.

    Eksen kuralı (GTA): x = sağ, y = ileri, z = yukarı.
    Hızlar m/s; "Kmh" sonekli alanlar km/sa; "severity" km/sa cinsinden Δv'dir.
]]

CrashPhysics = {}
local P = CrashPhysics

local KMH = 3.6
local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max
local rad, deg, sin, cos, atan = math.rad, math.deg, math.sin, math.cos, math.atan

P.KMH = KMH

-- ------------------------------------------------------------------ vektör
local function v3(x, y, z) return vector3(x + 0.0, y + 0.0, z + 0.0) end
P.v3 = v3

function P.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

function P.cross(a, b)
    return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

function P.add(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
function P.sub(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
function P.scale(a, s) return v3(a.x * s, a.y * s, a.z * s) end
function P.len(a) return sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end

-- Birim vektör + orijinal uzunluk
function P.normalize(a)
    local l = P.len(a)
    if l < 1e-6 then return v3(0, 0, 0), 0.0 end
    return v3(a.x / l, a.y / l, a.z / l), l
end

function P.clampLength(a, maxLen)
    local l = P.len(a)
    if l > maxLen and l > 1e-6 then return P.scale(a, maxLen / l) end
    return a
end

-- z ekseni etrafında (yatay düzlemde) derece cinsinden döndürme
function P.rotateZ(a, degrees)
    local r = rad(degrees)
    local c, s = cos(r), sin(r)
    return v3(a.x * c - a.y * s, a.x * s + a.y * c, a.z)
end

-- Dünya vektörü -> aracın yerel eksenleri (x = sağ, y = ileri, z = yukarı)
function P.toLocal(w, fwd, right, up)
    return v3(P.dot(w, right), P.dot(w, fwd), P.dot(w, up))
end

-- Yerel vektör -> dünya
function P.toWorld(l, fwd, right, up)
    return v3(
        right.x * l.x + fwd.x * l.y + up.x * l.z,
        right.y * l.x + fwd.y * l.y + up.y * l.z,
        right.z * l.x + fwd.z * l.y + up.z * l.z)
end

-- GTA heading'i (0 = kuzey, saat yönünün tersine artar), yalnızca debug çıktısı için
function P.headingOf(v)
    return (deg(atan(-v.x, v.y)) + 360.0) % 360.0
end

-- ------------------------------------------------------------------ ring buffer
-- Sabit kapasite. Slot tabloları BİR KEZ oluşturulur, sonra yalnızca alanları
-- üzerine yazılır: araç içindeyken her kare yeni tablo / çöp üretilmez.
function P.newBuffer(size)
    local slots = {}
    for i = 1, size do
        slots[i] = {
            t = 0,
            vx = 0.0, vy = 0.0, vz = 0.0,      -- dünya velocity (m/s)
            px = 0.0, py = 0.0, pz = 0.0,      -- dünya konumu
            fx = 0.0, fy = 1.0, fz = 0.0,      -- ileri ekseni
            ux = 0.0, uy = 0.0, uz = 1.0,      -- yukarı ekseni (uz = dikliği: 1 düz, 0 yan, -1 ters)
            body = 1000.0,
            engine = 1000.0,
            collided = false,
            inAir = false,
            seat = -2,
        }
    end
    return { slots = slots, size = size, head = 0, count = 0 }
end

function P.bufferReset(buf)
    buf.head = 0
    buf.count = 0
end

-- Yalnızca en yeni örneği tut: reddedilen bir darbenin geçmişi bir sonraki
-- karede aynı darbeyi tekrar aday yapmasın.
function P.bufferKeepNewest(buf)
    if buf.count > 1 then buf.count = 1 end
end

-- Yazılacak slot; kapasite doluysa en eskinin üzerine yazılır
function P.bufferNext(buf)
    buf.head = buf.head % buf.size + 1
    if buf.count < buf.size then buf.count = buf.count + 1 end
    return buf.slots[buf.head]
end

-- age 0 = en yeni örnek
function P.bufferGet(buf, age)
    if age < 0 or age >= buf.count then return nil end
    return buf.slots[(buf.head - 1 - age) % buf.size + 1]
end

local function sampleVelocity(s) return v3(s.vx, s.vy, s.vz) end

local function velocityDiff(a, b)
    local dx, dy, dz = a.vx - b.vx, a.vy - b.vy, a.vz - b.vz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

-- ------------------------------------------------------------------ aday tespiti
-- Son windowMs içinde en yeni örnekle geçmiş örnekler arasındaki en büyük
-- velocity farkı (m/s). Sert fren (~10 m/s²) 80 ms'de ~0.8 m/s değiştirir;
-- gerçek çarpışma aynı sürede 5-25 m/s değiştirir.
function P.maxRecentDelta(buf, windowMs)
    local newest = P.bufferGet(buf, 0)
    if not newest then return 0.0 end

    local best = 0.0
    for age = 1, buf.count - 1 do
        local s = P.bufferGet(buf, age)
        if newest.t - s.t > windowMs then break end
        local d = velocityDiff(newest, s)
        if d > best then best = d end
    end
    return best
end

-- Son windowMs içinde kaporta ve sağlamlığın en büyük düşüşü (puan).
-- Hızı az değiştiren ama aracı hasarlayan darbeler de aday olabilsin.
function P.maxRecentHealthDrop(buf, windowMs)
    local newest = P.bufferGet(buf, 0)
    if not newest then return 0.0, 0.0 end

    local body, engine = 0.0, 0.0
    for age = 1, buf.count - 1 do
        local s = P.bufferGet(buf, age)
        if newest.t - s.t > windowMs then break end
        if s.body - newest.body > body then body = s.body - newest.body end
        if s.engine - newest.engine > engine then engine = s.engine - newest.engine end
    end
    return body, engine
end

-- Kaporta + sağlamlık düşüşünün (puan) hasar yüzdesi.
-- loe_hud ile aynı formül: (motor + gövde) / (2 × maxHealth)
function P.damageDropPct(bodyDrop, engineDrop, T)
    return (bodyDrop + engineDrop) / (2.0 * T.maxHealth) * 100.0
end

function P.damageTriggerMet(bodyDrop, engineDrop, T)
    return P.damageDropPct(bodyDrop, engineDrop, T) >= T.minDropPct
end

-- Aracın açısal hızı (rad/s, dünya ekseni), iki örneğin eksen vektörlerinden.
-- θ açısıyla k ekseni etrafında küçük dönüşte her eksen vektörü için
-- e_eski × e_yeni ≈ θ(k − e(e·k)); üç ortonormal eksen toplanınca 2θk olur.
-- Euler açısı türevinden farklı olarak takla/ters durumda da sarmalanma yapmaz.
function P.angularVelocity(older, newer)
    local dt = (newer.t - older.t) / 1000.0
    if dt <= 0.0 then return v3(0, 0, 0) end

    local fa, ua = v3(older.fx, older.fy, older.fz), v3(older.ux, older.uy, older.uz)
    local fb, ub = v3(newer.fx, newer.fy, newer.fz), v3(newer.ux, newer.uy, newer.uz)
    local ra, rb = P.cross(fa, ua), P.cross(fb, ub)

    local sum = P.add(P.add(P.cross(fa, fb), P.cross(ua, ub)), P.cross(ra, rb))
    return P.scale(sum, 0.5 / dt)
end

-- ------------------------------------------------------------------ sınıflandırma
-- front    : ped aracın önüne doğru atalet taşır (ani yavaşlama)
-- side     : yanal Δv baskın
-- rear     : ped koltuğa bastırılır (arkadan çarpılma veya geri geri duvara çarpma)
-- vertical : dikey Δv baskın (zıplama / iniş / kaldırım)
-- rollover : araç çarpışma penceresinde yan veya ters durumdaydı
function P.classify(an, D, R)
    local rollover = R.enabled and an.minUpright < R.uprightThreshold

    if an.verticalDeltaKmh > an.horizontalDeltaKmh * D.verticalRatio then
        return rollover and 'rollover' or 'vertical'
    end
    if rollover then return 'rollover' end

    if an.relForward < 0.0 and abs(an.relForward) >= abs(an.relRight) then return 'rear' end
    if abs(an.relRight) > abs(an.relForward) then return 'side' end
    return 'front'
end

-- ------------------------------------------------------------------ analiz
-- candidateAt: ani değişimin ilk görüldüğü an. En yeni örnek 'velocityAfter'
-- kabul edilir (confirmDelayMs sonra: GTA çarpışmayı çözmüş olur).
function P.analyze(buf, candidateAt, historyMs, D, R)
    local after = P.bufferGet(buf, 0)
    if not after or buf.count < 3 then return nil end

    local oldest = max(candidateAt - D.preImpactLookbackMs, after.t - historyMs)

    -- velocityBefore: pencerede 'after'dan EN FARKLI hıza sahip örnek.
    -- GTA çarpışma karesinde hızı hemen düşürdüğü için "bir önceki kare"
    -- güvenilir değildir. Farkın beforePickRatio'suna ulaşan EN YENİ örnek
    -- seçilir; böylece virajda da son gerçek hareket yönü kullanılır.
    local maxDiff = -1.0
    for age = 1, buf.count - 1 do
        local s = P.bufferGet(buf, age)
        if s.t < oldest then break end
        if s.t <= candidateAt then
            local d = velocityDiff(s, after)
            if d > maxDiff then maxDiff = d end
        end
    end
    if maxDiff < 0.0 then return nil end

    local before
    for age = 1, buf.count - 1 do
        local s = P.bufferGet(buf, age)
        if s.t < oldest then break end
        if s.t <= candidateAt and velocityDiff(s, after) >= maxDiff * D.beforePickRatio then
            before = s
            break
        end
    end
    if not before then return nil end

    -- Kanıt ve filtre verileri (tek geçiş)
    -- Hasar düşüşü: penceredeki en yüksek değer − 'after'. 'before'dan ölçülmez;
    -- düşük Δv'li darbede 'before' zaten hasar sonrası örnek olabilir.
    -- Reddedilen darbeden sonra buffer tek örneğe indiği için hasar iki kez sayılmaz.
    local collided, airborne = false, before.inAir
    local peakBody, peakEngine, minUpright = after.body, after.engine, before.uz
    local angularRef
    for age = 0, buf.count - 1 do
        local s = P.bufferGet(buf, age)
        if s.t < oldest then break end
        if s.body > peakBody then peakBody = s.body end
        if s.engine > peakEngine then peakEngine = s.engine end
        if s.t >= before.t then
            if s.collided then collided = true end
        elseif s.inAir then
            airborne = true
        end
        if s.uz < minUpright then minUpright = s.uz end
        if not angularRef and s.t <= before.t - D.angularSampleGapMs then angularRef = s end
    end

    local vB, vA = sampleVelocity(before), sampleVelocity(after)
    local dv = P.sub(vA, vB)

    -- Referans eksenler: çarpışma ÖNCESİ araç yönelimi
    local fwd = v3(before.fx, before.fy, before.fz)
    local up = v3(before.ux, before.uy, before.uz)
    local right = P.cross(fwd, up)

    -- Araç Δv kadar değişirken kemersiz ped eski hızını korumaya çalışır;
    -- pedin ARACA GÖRE atalet hareketi = −Δv.
    local rel = P.scale(dv, -1.0)
    local relF, relR, relU = P.dot(rel, fwd), P.dot(rel, right), P.dot(rel, up)

    local speedBefore, speedAfter = P.len(vB), P.len(vA)
    local horizontal = sqrt(relF * relF + relR * relR)

    -- Şiddet: ileri + ağırlıklı yanal + ağırlıklı dikey Δv (km/sa)
    local latW, verW = relR * D.lateralSeverityWeight, relU * D.verticalSeverityWeight
    local severity = sqrt(relF * relF + latW * latW + verW * verW) * KMH

    -- NOT: ring buffer slotları sonradan üzerine yazıldığı için burada
    -- slot referansı değil, gereken değerlerin KOPYASI tutulur.
    local an = {
        position = v3(before.px, before.py, before.pz),
        afterPosition = v3(after.px, after.py, after.pz),
        afterForward = v3(after.fx, after.fy, after.fz),
        afterUp = v3(after.ux, after.uy, after.uz),
        beforeTime = before.t,
        afterTime = after.t,

        velocityBefore = vB,
        velocityAfter = vA,
        deltaVelocity = dv,
        forward = fwd, right = right, up = up,

        relForward = relF, relRight = relR, relUp = relU,
        speedBeforeKmh = speedBefore * KMH,
        speedAfterKmh = speedAfter * KMH,
        speedLossKmh = (speedBefore - speedAfter) * KMH,
        deltaKmh = P.len(dv) * KMH,
        horizontalDeltaKmh = horizontal * KMH,
        lateralDeltaKmh = abs(relR) * KMH,
        verticalDeltaKmh = abs(relU) * KMH,
        severity = severity,
        impactDirection = (P.normalize(rel)),
        impactAngleDeg = deg(atan(relR, relF)),   -- 0 ön, 90 sağ, -90 sol, ±180 arka

        collided = collided,
        bodyDrop = peakBody - after.body,
        engineDrop = peakEngine - after.engine,
        wasAirborne = airborne,
        minUpright = minUpright,
        angularVelocity = angularRef and P.angularVelocity(angularRef, before) or v3(0, 0, 0),
        seatOffset = v3(0, 0, 0),
    }
    an.impactType = P.classify(an, D, R)
    return an
end

-- ------------------------------------------------------------------ karar
-- Kinematik eşikler veya (damageTrigger açıksa) araç hasarı eşiği. (Kemer, ölüm, ragdoll kilidi main.lua'da.)
-- Dönüş: fırlatmaya yetecek bir çarpışma mı?, sebep metni
function P.evaluate(an, D, R)
    if D.requireCollisionEvidence and not an.collided and an.bodyDrop < D.minBodyHealthDrop then
        return false, ('çarpışma kanıtı yok (collided=false, bodyDrop=%.1f): teleport veya script hız değişimi olabilir')
            :format(an.bodyDrop)
    end

    local t = an.impactType

    if t == 'vertical' then
        return false, ('dikey darbe filtrelendi (dikey %.1f > yatay %.1f km/sa): zıplama/iniş/kaldırım')
            :format(an.verticalDeltaKmh, an.horizontalDeltaKmh)
    end

    if t == 'rear' and not D.allowRearEjection then
        return false, 'arkadan darbe / geri geri çarpma: ped koltuğa bastırılır, fırlamaz'
    end

    local T = D.damageTrigger
    if T and T.enabled then
        -- Hasar kendi kanıtı sayılamaz: script SetVehicleBodyHealth ile de düşürebilir
        if D.requireCollisionEvidence and not an.collided and an.deltaKmh < D.candidateDeltaKmh then
            return false, ('hasar modu: çarpışma kanıtı yok (collided=false, Δv=%.1f km/sa): hasar script kaynaklı olabilir')
                :format(an.deltaKmh)
        end
        if an.speedBeforeKmh < T.minSpeedBeforeKmh then
            return false, ('hasar modu: çarpışma öncesi hız düşük (%.1f < %.1f km/sa)'):format(an.speedBeforeKmh, T.minSpeedBeforeKmh)
        end

        local pct = P.damageDropPct(an.bodyDrop, an.engineDrop, T)
        if not P.damageTriggerMet(an.bodyDrop, an.engineDrop, T) then
            return false, ('hasar düşük: -%%%.2f < %%%.2f (kaporta -%.0f, sağlamlık -%.0f)')
                :format(pct, T.minDropPct, an.bodyDrop, an.engineDrop)
        end
        return true, ('hasar eşiği aşıldı (%s): -%%%.2f (kaporta -%.0f, sağlamlık -%.0f)')
            :format(t, pct, an.bodyDrop, an.engineDrop)
    end

    if t == 'rollover' then
        if an.speedBeforeKmh < R.minSpeedBeforeKmh then
            return false, ('takla: çarpışma öncesi hız düşük (%.1f < %.1f km/sa)'):format(an.speedBeforeKmh, R.minSpeedBeforeKmh)
        end
        if an.severity < R.minImpactSeverity then
            return false, ('takla: şiddet düşük (%.1f < %.1f)'):format(an.severity, R.minImpactSeverity)
        end
        return true, 'takla sırasında darbe'
    end

    -- Araç yakın geçmişte havadaysa (zıplama/düşme) yatay eşikler sertleşir:
    -- sert iniş önden çarpma sayılmaz, ama inişte duvara girmek hâlâ sayılır.
    local m = an.wasAirborne and D.landingThresholdMultiplier or 1.0

    if t == 'side' then
        local S = D.side
        if not S.enabled then
            return false, 'yan darbe fırlatması kapalı (Config.Detection.side.enabled)'
        end
        if an.speedBeforeKmh < S.minSpeedBeforeKmh then
            return false, ('yan darbe: çarpışma öncesi hız düşük (%.1f < %.1f km/sa)'):format(an.speedBeforeKmh, S.minSpeedBeforeKmh)
        end
        if an.lateralDeltaKmh < S.minDeltaVelocityKmh * m then
            return false, ('yan darbe: yanal Δv düşük (%.1f < %.1f km/sa)'):format(an.lateralDeltaKmh, S.minDeltaVelocityKmh * m)
        end
        if an.severity < D.minImpactSeverity * m then
            return false, ('yan darbe: şiddet düşük (%.1f < %.1f)'):format(an.severity, D.minImpactSeverity * m)
        end
        return true, 'yan darbe'
    end

    if an.speedBeforeKmh < D.minSpeedBeforeKmh then
        return false, ('çarpışma öncesi hız düşük (%.1f < %.1f km/sa)'):format(an.speedBeforeKmh, D.minSpeedBeforeKmh)
    end
    if an.speedLossKmh < D.minSpeedLossKmh * m then
        return false, ('ani hız kaybı düşük (%.1f < %.1f km/sa)'):format(an.speedLossKmh, D.minSpeedLossKmh * m)
    end
    if an.horizontalDeltaKmh < D.minDeltaVelocityKmh * m then
        return false, ('yatay Δv düşük (%.1f < %.1f km/sa)'):format(an.horizontalDeltaKmh, D.minDeltaVelocityKmh * m)
    end
    if an.severity < D.minImpactSeverity * m then
        return false, ('şiddet düşük (%.1f < %.1f)'):format(an.severity, D.minImpactSeverity * m)
    end
    return true, t == 'rear' and 'arkadan darbe' or 'önden darbe'
end

-- ------------------------------------------------------------------ fırlatma
-- random: 0..1 döndüren fonksiyon (math.random)
function P.computeLaunch(an, L, random)
    -- 1) Koltuğun gerçek dünya hızı: v_merkez + ω × r. Virajda / takla
    --    sırasında dış taraftaki koltuk merkezden daha hızlı hareket eder.
    local occupant = an.velocityBefore
    if L.useAngularVelocity then
        occupant = P.add(occupant, P.scale(P.cross(an.angularVelocity, an.seatOffset), L.angularCarryFactor))
    end

    -- 2) Atalet: çarpışma öncesi dünya hareketinin büyük bölümü korunur.
    --    Heading KULLANILMAZ; drift/çapraz kayma yönü velocity'de zaten var.
    local keep = P.scale(occupant, L.velocityKeepFactor)

    -- Yatay Δv yönü = aracın itildiği yön, yani engelden / çarpan araçtan UZAK taraf
    local awayDir, dvH = P.normalize(v3(an.deltaVelocity.x, an.deltaVelocity.y, 0.0))

    local launch, fallbackDir
    if an.impactType == 'side' or an.impactType == 'rear' then
        -- 3b) Yan / arka darbe: engel kapı veya bagaj kadar yakın; ataletle ona doğru
        --     fırlayan ped araçla engel (veya çarpan araç) arasına sıkışırdı. Ped engelden
        --     uzağa fırlar: öncesi hızın engele doğru bileşeni atılır, paralel bileşeni
        --     (örn. yan sürtünürken ileri hareket) korunur, Δv yönünde itme eklenir.
        local into = -P.dot(keep, awayDir)
        if into > 0.0 then keep = P.add(keep, P.scale(awayDir, into)) end
        launch = P.add(keep, P.scale(awayDir, min(dvH * L.awayPushFactor, L.maxInertiaSpeed)))
        fallbackDir = awayDir
    else
        -- 3a) Ön darbe / takla: sınırlı ek, ileri yönlü ani yavaşlama + yanal Δv
        --     (öncesi eksenlerinde). Arkaya doğru bileşen eklenmez.
        local inertia = P.scale(an.forward, max(an.relForward, 0.0) * L.inertiaFactor)
        local lateral = P.scale(an.right, an.relRight * L.lateralFactor)
        launch = P.add(keep, P.clampLength(P.add(inertia, lateral), L.maxInertiaSpeed))
        fallbackDir = P.scale(awayDir, -1.0)
    end

    -- 4) Her çarpışma birebir aynı görünmesin: küçük yatay sapma ve hız farkı
    launch = P.rotateZ(launch, (random() * 2.0 - 1.0) * L.randomYawDeg)
    launch = P.scale(launch, 1.0 + (random() * 2.0 - 1.0) * L.randomSpeedPct)

    -- 4b) En az yatay hız: duran araca çarpılınca veya düşük hızlı darbede ped
    --     koltuğun üstüne düşmesin, araç kutusundan temiz çıksın
    local hDir, hLen = P.normalize(v3(launch.x, launch.y, 0.0))
    if hLen < L.minHorizontalSpeed then
        if hLen < 0.1 then
            hDir = P.len(fallbackDir) > 0.5 and fallbackDir or (P.normalize(v3(an.forward.x, an.forward.y, 0.0)))
        end
        launch = v3(hDir.x * L.minHorizontalSpeed, hDir.y * L.minHorizontalSpeed, launch.z)
    end

    -- 5) Küçük yukarı bileşen (şiddetle hafifçe artar, tavanlı)
    local upward = min(L.upwardBoost + an.severity * L.upwardPerSeverity, L.maxUpwardSpeed)
    launch = v3(launch.x, launch.y, launch.z + upward)

    -- 6) Toplam tavan: 150 km/sa çarpışmada bile top mermisi etkisi olmaz
    return P.clampLength(launch, L.maxLaunchSpeed)
end

-- Merkez dışı impuls çiftleri: +lever noktasına dir yönünde, −lever noktasına
-- ters yönde aynı büyüklük. Net doğrusal hız değişmez, yalnızca dönme momenti oluşur.
function P.computeSpin(an, launch, L, random)
    local spins = {}

    -- Darbe kaynaklı devrilme: gövdenin üstü fırlama yönünde, altı tersine
    -- itilir -> gövde öne düşer, bacaklar arkadan gelir.
    local dirH, lenH = P.normalize(v3(launch.x, launch.y, 0.0))
    if lenH > 0.5 then
        local speed = min(an.severity * L.spinPerSeverity, L.maxSpinSpeed)
            * (1.0 + (random() * 2.0 - 1.0) * L.spinRandomPct)
        spins[#spins + 1] = { lever = v3(0, 0, 1), dir = dirH, speed = speed }
    end

    -- Aracın açısal hareketinden devralınan dönüş (takla / savrulma).
    -- lever ω eksenine dik; +lever noktasındaki teğetsel yön = eksen × lever.
    local axis, w = P.normalize(an.angularVelocity)
    if w > 0.3 and L.vehicleSpinCarry > 0.0 then
        local lever = P.normalize(P.cross(axis, v3(0, 0, 1)))
        if P.len(lever) < 0.5 then lever = P.normalize(P.cross(axis, an.forward)) end
        if P.len(lever) > 0.5 then
            spins[#spins + 1] = {
                lever = lever,
                dir = P.cross(axis, lever),
                speed = min(w * L.spinLever * L.vehicleSpinCarry, L.maxSpinSpeed),
            }
        end
    end

    return spins
end

-- Koltuk noktasından fırlama yönünde küçük yatay + yukarı ofset
function P.computeExitStart(seatPos, launch, E)
    local dirH = P.normalize(v3(launch.x, launch.y, 0.0))
    return v3(
        seatPos.x + dirH.x * E.forwardOffset,
        seatPos.y + dirH.y * E.forwardOffset,
        seatPos.z + E.upOffset)
end

-- ------------------------------------------------------------------ hasar
-- Fırlatma kuvvetinden bağımsız; yalnızca çarpışma şiddetine bağlı kademe
function P.damageForSeverity(severity, Dm)
    if not Dm.enabled or severity < Dm.minSeverity then return 0 end
    local amount = 0
    for _, tier in ipairs(Dm.tiers) do
        if severity >= tier.minSeverity and tier.damage > amount then amount = tier.damage end
    end
    return min(amount, Dm.maxDamage)
end

