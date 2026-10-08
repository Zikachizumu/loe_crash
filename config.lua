Config = {}

-- Ana anahtar. false iken örnekleme yapılmaz, thread saniyede bir uyanır.
Config.Enabled = true

-- GTA'nın kendi "ön camdan uçma" mekaniği (ped config flag 32,
-- CPED_CONFIG_FLAG_WillFlyThroughWindscreen). Açık kalırsa bu resource ile
-- aynı anda İKİNCİ bir fırlatma sistemi çalışabilir. true: oyuncu desteklenen
-- bir araçtayken flag kapatılır, araçtan çıkınca / resource durunca eski
-- değerine döndürülür.
Config.DisableVanillaWindscreenEjection = true

-- ------------------------------------------------------------------ DİĞER OYUNCULARIN EKRANI
-- Fırlayan oyuncunun klonu diğer ekranlarda koltuktan inince GTA onu kapı yanına ayakta
-- koyar ve ragdoll bilgisi gelene kadar (~Exit.networkHandoffMs) orada tutar.
-- hideRemoteUntilRagdoll: bu ayakta pozda klon yalnızca izleyen ekranda görünmez tutulur,
-- ragdoll'a geçince görünür (koltuktayken gizlenmez). Fırlayan oyuncu bunu replike oyuncu
-- state'iyle (loeCrashEjecting) bildirir; sunucu tarafı kod gerekmez.
Config.Sync = {
    hideRemoteUntilRagdoll = true,
    hideMaxMs              = 1500,   -- bayraktan itibaren; klon bu sürede ragdoll'a geçmezse yine de gösterilir
}

-- ------------------------------------------------------------------ DEBUG
Config.Debug = {
    enabled        = false,        -- resource açılırken debug açık mı
    commandEnabled = false,        -- /crashdebug kaydedilsin mi (YALNIZCA geliştirme ortamı)
    commandName    = 'crashdebug',
    printToConsole = true,         -- her değerlendirmeyi F8 konsoluna yaz
    serverLog      = false,        -- debug satırlarını sunucu konsoluna/data/logs dosyasına da gönder (YALNIZCA geliştirme)
    drawDurationMs = 8000,         -- son çarpışmanın çizgi/yazısı ekranda kalma süresi
    lineScale      = 0.12,         -- çizgi uzunluğu: 1 m/s = bu kadar metre
}

-- ------------------------------------------------------------------ ÖRNEKLEME
Config.Sampling = {
    intervalMs     = 0,     -- araç içinde örnekleme aralığı (0 = her kare; çarpışma karesini kaçırmamak için önerilen)
    historyMs      = 300,   -- analizin geriye bakabileceği en uzun süre
    bufferSize     = 64,    -- SABİT ring buffer kapasitesi; historyMs'i en yüksek FPS'te kapsamalı (64 kare ≈ 210 FPS'te 300 ms)
    outsideIdleMs  = 500,   -- araç dışındayken kontrol aralığı
    seatRecheckMs  = 500,   -- koltuk değişimi (shuffle) kontrol aralığı
    teleportMargin = 4.0,   -- iki örnek arasında beklenen yoldan bu kadar metre fazla sıçrama = teleport, geçmiş silinir
}

-- ------------------------------------------------------------------ ÇARPIŞMA ALGILAMA
Config.Detection = {
    -- Aday: kısa pencerede bu kadar velocity değişimi olunca çarpışma şüphesi başlar
    candidateDeltaKmh   = 15.0,
    candidateWindowMs   = 80,
    confirmDelayMs      = 60,     -- adaydan sonra velocityAfter için bekleme (GTA darbeyi çözsün)
    preImpactLookbackMs = 250,    -- velocityBefore bu pencerede aranır (historyMs'den küçük olmalı)
    beforePickRatio     = 0.95,   -- en farklı hızın bu oranına ulaşan EN YENİ örnek velocityBefore olur
    angularSampleGapMs  = 50,     -- açısal hız için kullanılan iki örnek arası süre

    -- Önden darbe eşikleri (hepsi aynı anda sağlanmalı)
    minSpeedBeforeKmh   = 60.0,   -- çarpışma öncesi minimum hız
    minSpeedLossKmh     = 35.0,   -- ani hız kaybı: |vÖnce| − |vSonra|
    minDeltaVelocityKmh = 40.0,   -- yatay |Δv|
    minImpactSeverity   = 40.0,   -- toplam şiddet (ileri + ağırlıklı yanal/dikey Δv, km/sa)

    -- Yanal Δv baskın darbeler
    side = {
        enabled             = true,
        minSpeedBeforeKmh   = 40.0,
        minDeltaVelocityKmh = 40.0,   -- yanal |Δv|
    },

    -- HASAR TABANLI FIRLAMA. enabled = true iken yukarıdaki hız/Δv/şiddet eşikleri
    -- ve takla eşikleri KULLANILMAZ; karar tek çarpışmadaki araç hasarına göre verilir.
    -- Hasar %, loe_hud araç hasar göstergesiyle AYNI formül:
    -- (kaporta düşüşü + sağlamlık düşüşü) / (2 × maxHealth) × 100
    -- Kaporta = GetVehicleBodyHealth, Sağlamlık = GetVehicleEngineHealth (ikisi de 0-1000).
    -- %1 = toplam 20 puan (örn. yalnızca kaporta -20, ya da kaporta -12 + motor -8).
    -- loe_vehicles Config.EngineDamage.syncBodyAndEngine açıkken kaporta ve motor aynı
    -- değerdir: ortak -10 (kaporta -10 + motor -10) = %1 (HUD'da görünen düşüşle aynı).
    -- Birikmiş hasar sayılmaz, yalnızca O çarpışmada kaybedilen miktar.
    -- Dikey darbe ve arkadan darbe filtreleri geçerlidir.
    damageTrigger = {
        enabled           = true,
        maxHealth         = 1000.0,
        minDropPct        = 1.0,     -- tek çarpışmada HUD hasar %'sindeki düşüş
        minSpeedBeforeKmh = 0.0,     -- 0 = hız şartı yok (duran araca çarpılınca da fırlar)
    },

    -- Arkadan çarpılma / geri geri çarpma. true: fırlatır (ped öne, çarpan araçtan/engelden
    -- uzağa fırlar; hasar modunda hasar eşiği, kapalıyken önden eşikleri kullanılır).
    allowRearEjection = true,

    -- Şiddet formülündeki ağırlıklar
    lateralSeverityWeight  = 1.0,
    verticalSeverityWeight = 0.35,

    -- Dikey filtre: |dikey Δv| > |yatay Δv| × verticalRatio ise darbe dikey sayılır (zıplama/iniş/kaldırım)
    verticalRatio = 0.9,
    -- Araç son geçmişte havadaysa yatay eşikler bu katsayıyla sertleşir (sert iniş ≠ önden çarpma)
    landingThresholdMultiplier = 1.5,

    -- Çarpışma kanıtı: HasEntityCollidedWithAnything VEYA body health düşüşü yoksa
    -- hız değişimi teleport / script kaynaklı sayılır ve fırlatma olmaz.
    -- Hasar modunda: collided VEYA candidateDeltaKmh kadar Δv yoksa hasar script kaynaklı sayılır.
    requireCollisionEvidence = true,
    minBodyHealthDrop        = 4.0,

    cooldownMs        = 3000,   -- fırlatma sonrası (ped yere çarparken / araç sürüklenirken tekrar tetiklenmez)
    beltedCooldownMs  = 1500,   -- kemerli veya engellenmiş çarpışma sonrası
}

-- ------------------------------------------------------------------ TAKLA
Config.Rollover = {
    enabled           = true,
    uprightThreshold  = 0.35,   -- çarpışma penceresinde aracın dikliği (yukarı ekseninin z'si) bunun altına indiyse takla sayılır
    minSpeedBeforeKmh = 40.0,
    minImpactSeverity = 20.0,
}

-- ------------------------------------------------------------------ FIRLATMA FİZİĞİ
Config.Launch = {
    velocityKeepFactor = 0.85,    -- çarpışma öncesi dünya velocity'sinin korunan payı
    inertiaFactor      = 0.15,    -- ileri yönlü ani Δv'nin eklenen payı
    lateralFactor      = 0.45,    -- yanal Δv'nin eklenen payı
    maxInertiaSpeed    = 8.0,     -- m/s — inertia + yanal ekin (yan/arka darbede itmenin) üst sınırı

    -- Yan ve arka darbe: ped engele / çarpan araca doğru değil, ondan UZAĞA (aracın
    -- itildiği yön) fırlar; çarpışma öncesi hızın engele doğru bileşeni atılır.
    awayPushFactor     = 0.6,     -- yatay |Δv|'nin itme hızına dönüşen payı
    minHorizontalSpeed = 4.0,     -- m/s — her darbede en az yatay fırlama hızı (duran araçta da temiz çıkış)

    upwardBoost        = 1.0,     -- m/s — sabit küçük yukarı bileşen
    upwardPerSeverity  = 0.012,   -- m/s — şiddetin (km/sa) her birimi için ek yukarı hız
    maxUpwardSpeed     = 3.5,     -- m/s

    maxLaunchSpeed     = 24.0,    -- m/s (~86 km/sa) toplam fırlatma velocity tavanı

    useAngularVelocity = true,    -- aracın dönüşünden gelen teğetsel hızı ekle (ω × r)
    angularCarryFactor = 1.0,

    randomYawDeg       = 3.0,     -- ± derece yatay sapma
    randomSpeedPct     = 0.04,    -- ± hız farkı (0.04 = %4)

    -- Dönüş (takla) için merkez dışı impuls çiftleri
    spinPerSeverity    = 0.035,   -- m/s — şiddetin (km/sa) her birimi için teğetsel hız
    maxSpinSpeed       = 4.5,     -- m/s
    spinLever          = 0.45,    -- metre — impulsların merkeze uzaklığı
    spinRandomPct      = 0.25,
    vehicleSpinCarry   = 0.35,    -- aracın açısal hızının pede aktarılan payı (takla/savrulma)
}

-- ------------------------------------------------------------------ ARAÇTAN AYRILMA
Config.Exit = {
    -- Koltuktan ayırma yöntemi:
    --   'clear' : ClearPedTasksImmediately — aynı karede, animasyonsuz. (önerilen)
    --   'task'  : TaskLeaveVehicle flag 16 — çarpışma anındaki hızda testte 5 karede
    --             işlenmedi ve 'clear'e düştü; ped bu sürede koltukta bekler.
    method            = 'clear',
    taskExitMaxFrames = 5,     -- 'task': görev bu kadar karede işlenmezse 'clear' ile kesilir

    -- Ağ devri (ms): ragdoll'dan önce ped araç dışında, ragdoll'suz ve fırlatma hızıyla
    -- hareket eder. Diğer istemcilerdeki klon ancak ped araç dışında VE ragdoll'suzken
    -- koltuktan iner; 0 = ilk karede ragdoll, klon ragdoll bitene kadar koltukta kalır.
    -- Diğer oyuncular hâlâ koltukta görüyorsa 250-300 deneyin.
    networkHandoffMs  = 150,

    upOffset         = 0.45,   -- koltuk noktasından yukarı (m)
    forwardOffset    = 0.20,   -- fırlama yönünde yatay (m) — görünür teleport olmasın diye küçük
    wallMargin       = 0.35,   -- başlangıç noktası duvar/direk içindeyse bu kadar geri çekilir
    groundClearance  = 0.40,   -- pelvisin zeminden minimum yüksekliği
    groundProbeUp    = 0.60,   -- zemin ışını başlangıcı (başlangıç noktasının üstü)
    groundProbeDown  = 2.50,   -- zemin ışını bitişi (başlangıç noktasının altı)
    minNoCollisionMs = 150,    -- ped-araç çarpışması en az bu kadar kapalı (koltuğa geri yapışmasın)
    maxNoCollisionMs = 1200,   -- ped araç kutusundan çıkamadıysa bile en fazla bu kadar
    boxMargin        = 0.35,   -- araç sınır kutusu payı
}

-- ------------------------------------------------------------------ RAGDOLL
Config.Ragdoll = {
    minMs               = 2500,   -- SET_PED_TO_RAGDOLL minTime (tip 0)
    maxMs               = 6000,   -- SET_PED_TO_RAGDOLL maxTime
    activationMaxFrames = 10,     -- ragdoll teyit edilemezse kaç kare daha denensin
    keepWhileAirborne   = true,   -- havadayken ragdoll erken biterse yeniden başlat
    respectDisabledRagdoll = true, -- ped dondurulmuş/görünmezse (örn. admin noclip) fırlatma yapılmaz
    watchExtraMs        = 2000,   -- maxMs sonrasında izlemeyi bırakmak için ek güvenlik süresi
}

-- ------------------------------------------------------------------ HASAR
-- Fırlatma kuvvetinden bağımsız, çarpışma şiddetine (km/sa Δv) bağlı.
-- ApplyDamageToPed kullanılır: can doğrudan set edilmez, oyunun hasar/ölüm akışı işler.
Config.Damage = {
    enabled          = true,
    minSeverity      = 45.0,      -- bunun altında hasar yok
    tiers = {                     -- şiddet >= minSeverity → damage (oyuncu canı 200, 100 altı ölüm)
        { minSeverity = 45.0,  damage = 8  },
        { minSeverity = 70.0,  damage = 18 },
        { minSeverity = 100.0, damage = 32 },
        { minSeverity = 140.0, damage = 50 },
    },
    maxDamage        = 60,
    beltedMultiplier = 0.0,       -- kemer takılıyken hasar çarpanı (0 = hasar yok)
    armorFirst       = false,     -- true: önce zırhtan düşer
}

-- ------------------------------------------------------------------ EMNİYET KEMERİ
-- source:
--   'statebag' : LocalPlayer.state[stateBagKey]. loe_vehicles kemeri
--                LocalPlayer.state.seatbelt'e yazıyor (loe_hud da aynısını okuyor).
--   'export'   : exports[export.resource][export.method]() → boolean döndüren başka bir kemer sistemi
--   'internal' : bu resource'un kendi durumu; başka script exports.loe_crash:SetSeatbeltState(bool) çağırır
Config.Seatbelt = {
    enabled     = true,      -- false: kemer hiç kontrol edilmez, şartlar sağlanırsa herkes fırlar
    source      = 'statebag',
    stateBagKey = 'seatbelt',
    export      = { resource = '', method = '' },
    resetInternalOnExit = true,   -- 'internal' kaynakta araçtan inince kemer çözülür
}

-- ------------------------------------------------------------------ ARAÇ FİLTRELERİ
-- GTA araç sınıfları: 0 Compacts, 1 Sedans, 2 SUVs, 3 Coupes, 4 Muscle,
-- 5 Sports Classics, 6 Sports, 7 Super, 8 Motorcycles, 9 Off-road,
-- 10 Industrial, 11 Utility, 12 Vans, 13 Cycles, 14 Boats, 15 Helicopters,
-- 16 Planes, 17 Service, 18 Emergency, 19 Military, 20 Commercial,
-- 21 Trains, 22 Open Wheel
Config.Vehicles = {
    classes = {
        [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = true, [7] = true, [8] = false, [9] = true, [10] = true, [11] = true,
        [12] = true, [13] = false, [14] = false, [15] = false, [16] = false,
        [17] = true, [18] = true, [19] = true, [20] = true, [21] = false, [22] = true,
    },
    -- Sınıfı yanlış girilmiş addon motosiklet/bisikletleri model tipinden de ele
    -- (GTA'nın kendi düşme davranışıyla çakışmasın)
    excludeBikesByModel = true,
    excludeQuadbikes    = true,
    excludedModels      = {},   -- örn. { 'monster', 'rhino' }
}

