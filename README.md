# loe_crash

Fizik tabanlı araç çarpışması ve araçtan fırlama sistemi (FiveM, GTA V Enhanced, Lua 5.4, Qbox uyumlu, OneSync uyumlu).

Karakter koltuktan ağda senkron biçimde ayrılır ve kısa bir ağ devrinden (varsayılan 150 ms) sonra **ragdoll'a** geçer; havada oturma/sürüş pozu korunmaz, diğer oyuncular da fırlamayı anında görür. Fırlama yönü sabit heading'den değil, çarpışma öncesi gerçek dünya velocity'sinden ve çarpışmadaki velocity değişiminden hesaplanır.

- Oyun mantığı yalnızca client'ta. Veritabanı yok. Tek server dosyası `server/debug.lua` (yalnızca `Config.Debug.serverLog` açıkken debug satırlarını sunucu loguna yazar).
- Yalnızca yerel oyuncunun kendi ped'ini yönetir (NPC yok). Her istemci kendi ped'inin sahibi olduğundan network sahiplik sorunu oluşmaz.
- qbx_core zorunlu değil; varsa ölü/baygın bilgisi `exports.qbx_core:GetPlayerData()` ile yalnızca **okunur**.

## Kurulum

`server.cfg` içinde, kemer durumunu yazan `loe_vehicles`'tan sonra:

```
ensure loe_vehicles
ensure loe_crash
```

## Eski sistemle ilişkisi

Önceden fırlatma `loe_vehicles/client/main.lua` içindeki `ejectPed()` ile yapılıyordu. O kod kaldırıldı; `loe_vehicles` artık yalnızca kemeri `LocalPlayer.state.seatbelt`'e yazıyor ve araçtan inince çözüyor. Aynı anda iki eject sistemi çalışmaz. GTA'nın kendi ön camdan uçma mekaniği (ped config flag 32) de araçtayken kapatılır (`Config.DisableVanillaWindscreenEjection`).

## Nasıl çalışır

### Durum makinesi

| Durum | Açıklama |
|---|---|
| `OUTSIDE` | Araç dışı, 500 ms'de bir kontrol |
| `SAMPLING` | Desteklenen araçta, her kare fizik örneği sabit boyutlu ring buffer'a yazılır |
| `DETECTED` | 80 ms içinde ≥15 km/sa velocity değişimi; `confirmDelayMs` kadar beklenir |
| `EJECTING` | Koltuktan ayırma, ragdoll aktivasyonunun doğrulanması |
| `RAGDOLL` | Fırlatma velocity'si verildi, araçla çarpışma kısa süre kapalı |
| `COOLDOWN` | Aynı çarpışma, sürtünme veya yere çarpma tekrar tetiklemez |

Tüm akış tek thread'dedir; bir çarpışmada ikinci fırlatma veya ikinci hasar mümkün değildir. Araç değişince, `playerSpawned` olayında veya ped değişince tüm geçici durum temizlenir.

### Her örnekte tutulanlar

Zaman damgası, dünya velocity'si, konum, aracın ileri ve yukarı eksenleri (rotation/heading bunlardan türetilir), body health, engine health, `HasEntityCollidedWithAnything`, `IsEntityInAir`, koltuk.

### Hesap

- **velocityBefore**: Aday anından önceki 250 ms içinde `velocityAfter`'dan en farklı hıza sahip örnek (farkın %95'ine ulaşan en yenisi). GTA çarpışma karesinde hızı hemen düşürse bile gerçek çarpışma öncesi hız kaybolmaz.
- **velocityAfter**: Adaydan `confirmDelayMs` sonra en yeni örnek.
- **deltaVelocity** = after − before. Kemersiz ped'in araca göre atalet hareketi **−Δv**'dir. Bu, çarpışma öncesi araç eksenlerinde ileri / sağ / yukarı bileşenlere ayrılır.
- **Şiddet** (km/sa) = √(ileri² + (yan × ağırlık)² + (dikey × ağırlık)²).
- **Açısal hız**: İki örneğin eksen vektörlerinden ω ≈ ½·Σ(e_eski × e_yeni)/Δt. Takla sırasında da açı sarmalanması yaşanmaz.

### Sınıflandırma

| Tip | Koşul | Sonuç |
|---|---|---|
| `vertical` | dikey Δv > yatay Δv × `verticalRatio` | Fırlamaz (zıplama, iniş, kaldırım) |
| `rollover` | pencerede araç dikliği < `uprightThreshold` | Takla eşikleriyle değerlendirilir |
| `rear` | atalet arkaya doğru (arkadan çarpılma, geri geri çarpma) | `allowRearEjection = true` (varsayılan): fırlar, çarpan araçtan/engelden uzağa |
| `side` | yanal Δv baskın | Yan eşikleri |
| `front` | ileri atalet baskın | Ön eşikleri |

Ayrıca çarpışma kanıtı (collision native **veya** body health düşüşü) yoksa hız değişimi teleport veya script kaynaklı sayılır. Araç son geçmişte havadaysa yatay eşikler `landingThresholdMultiplier` ile sertleşir.

### Hasar tabanlı fırlama (`Detection.damageTrigger`, varsayılan açık)

Açıkken hız/Δv/şiddet ve takla eşikleri devre dışıdır. Hasar %, `loe_hud` araç hasar göstergesiyle aynı formüldür: (**kaporta** `GetVehicleBodyHealth` düşüşü + **sağlamlık** `GetVehicleEngineHealth` düşüşü) / 2000. Tek çarpışmada bu değer `minDropPct` (%1 = toplam 20 puan) kadar düşerse kemersiz karakter fırlar. Birikmiş hasar sayılmaz; yalnızca o çarpışmada kaybedilen miktar ölçülür. HUD değeri yuvarladığı için ekranda görünen 1 puanlık düşüş gerçekte %0.5–1.5 arası olabilir.

- Aday tespiti: ani Δv (`candidateDeltaKmh`) **veya** `preImpactLookbackMs` içinde eşiği aşan hasar düşüşü.
- Ön, yan (sağ/sol), arka ve takla darbelerinin hepsi aynı hasar eşiğiyle fırlatır (`allowRearEjection = true`). Yalnızca `vertical` (zıplama/iniş) filtrelenir; kemer, ölü/baygın ve cooldown kontrolleri değişmez.
- Hasarı script düşürdüyse (collision yok, Δv yok) fırlatma olmaz.
- `minSpeedBeforeKmh`: isteğe bağlı hız şartı.

### Fırlatma velocity'si

```
occupant = velocityBefore + (ω × r_koltuk) × angularCarryFactor
launch   = occupant × velocityKeepFactor
         + clamp(ileri × max(atalet_ileri, 0) × inertiaFactor
                 + sağ × atalet_yan × lateralFactor, maxInertiaSpeed)
launch   = ±randomYawDeg döndür, ±randomSpeedPct ölçekle
launch.z += min(upwardBoost + şiddet × upwardPerSeverity, maxUpwardSpeed)
launch   = clamp(launch, maxLaunchSpeed)
```

**Yan ve arka darbe:** ped engele veya çarpan araca doğru fırlarsa aradaki dar boşlukta sıkışır. Bu darbelerde ped aracın itildiği yöne (yatay Δv, engelden uzağa) `|Δv| × awayPushFactor` hızla fırlar; çarpışma öncesi hızın engele doğru bileşeni atılır, paralel bileşeni korunur. Her darbede yatay hız en az `minHorizontalSpeed` (4 m/s): duran araca çarpılınca da ped araçtan temiz çıkar. Çıkış noktası ışını araçları da kontrol eder (çarpan aracın içine düşmez).

Dönüş için net doğrusal hız üretmeyen merkez dışı impuls çiftleri uygulanır: gövdenin üstü fırlama yönüne itilir (öne takla), ayrıca aracın açısal hızının bir kısmı aktarılır (takla veya savrulma).

### Araçtan ayırma sırası

1. Fizik verisi zaten analiz tablosunda.
2. `TaskLeaveVehicle(ped, veh, 16)` (`Config.Exit.method = 'task'`): ağda senkron araçtan inme görevi, flag 16 animasyon oynatmaz, ped'i ışınlayarak çıkarır. Görev `taskExitMaxFrames` karede işlenmezse `ClearPedTasksImmediately` ile kesilir.
3. Bağlantı hâlâ kopmadıysa `SetEntityCoords` ped'i araçtan warp eder.
4. Başlangıç noktası: koltuk bone'u (`seat_dside_f`, `seat_pside_f`, ...) + yukarı 0.45 m + fırlama yönünde 0.20 m. Bir ışın duvar/direk içine düşmeyi, bir ışın zeminin altına düşmeyi engeller (fırlatma başına 2 ışın).
5. **Ağ devri** (`networkHandoffMs`, 150 ms): ped araç dışında, ragdoll'suz ve fırlatma velocity'siyle hareket eder. Diğer istemcilerdeki klon bu sürede koltuktan iner.
6. `SetPedToRagdoll` istenir ve `IsPedRagdoll` ile **doğrulanır** (en fazla 10 kare, her kare tekrar denenir). Aktivasyon anındaki hız ragdoll gövdesine aktarılır, dönüş impulsları verilir, hasar bir kez uygulanır.
7. Ped araç kutusundan çıkana kadar (150 ms – 1200 ms) araçla çarpışması kapalı tutulur, koltuğa geri yapışmaz.
8. Havadayken ragdoll erken biterse yeniden başlatılır. Yere inip ragdoll bitince GTA'nın normal kalkma davranışı devralır.

## Diğer oyuncuların görmesi

Ped koltuktan yalnızca yerel olarak koparılıp (`ClearPedTasksImmediately`) aynı karede ragdoll'a geçerse diğer istemcilerdeki klon bunu almaz: ragdoll süresince koltukta oturur görünür (üstündeki oyuncu etiketi de araçta kalır), ragdoll bitince kapı yanına iner ve oyuncu yürüyene kadar orada durur, sonra gerçek yerine ışınlanır.

Bu yüzden çıkış ağda senkron `TaskLeaveVehicle(16)` ile yapılır ve ragdoll'dan önce kısa bir ağ devri bırakılır. Klon koltuktan inip ardından gerçek ped'in ragdoll'unu izler; ayrı bir kopya veya sunucu event'i yoktur, herkes aynı ped'i görür.

Diğer oyuncular hâlâ koltukta görüyorsa:

1. İki oyuncuda da `Config.Debug.commandEnabled = true` ve `serverLog = true` yapın, `/crashdebug` açın.
2. Fırlayan oyuncunun `ayrılma: ... nt=` satırı ile izleyen oyuncunun `uzak oyuncu <id>: araçta=false ... nt=` satırındaki `nt` (ağ zamanı, ms) farkı klonun koltuktan ne kadar gecikmeyle indiğini gösterir.
3. Fark ragdoll süresi kadarsa (birkaç saniye) `networkHandoffMs` değerini 250-300 yapın.

## Emniyet kemeri

Varsayılan: `Config.Seatbelt.source = 'statebag'`, `stateBagKey = 'seatbelt'`. `loe_vehicles` kemeri `LocalPlayer.state.seatbelt`'e yazıyor, `loe_hud` de aynı değeri okuyor.

Başka bir kemer sistemine bağlamak için:

- **Export ile okuma**: `source = 'export'`, `export = { resource = 'kaynak_adi', method = 'IsSeatbeltOn' }`. Fonksiyon `true/false` döndürmeli.
- **Durumu bu resource'a gönderme**: `source = 'internal'`, diğer script `exports.loe_crash:SetSeatbeltState(true)` çağırır.
- Tamamen kapatmak için `enabled = false` (kemer yok sayılır).

Diğer export'lar: `IsSeatbeltFastened()`, `IsEjecting()`, `GetCrashState()`.

## Önemli config değerleri

| Ayar | Varsayılan | Anlamı |
|---|---|---|
| `Detection.damageTrigger.enabled` | true | Hasar tabanlı fırlama (açıkken aşağıdaki hız eşikleri kullanılmaz) |
| `Detection.damageTrigger.minDropPct` | 1 | Tek çarpışmada HUD hasar % düşüşü (kaporta + sağlamlık ortalaması) |
| `Detection.minSpeedBeforeKmh` | 60 | Önden fırlama için çarpışma öncesi min hız |
| `Detection.minSpeedLossKmh` | 35 | Ani hız kaybı (\|önce\| − \|sonra\|) |
| `Detection.minDeltaVelocityKmh` | 40 | Yatay \|Δv\| |
| `Detection.minImpactSeverity` | 40 | Toplam şiddet |
| `Detection.side.*` | 40 / 40 | Yan darbe min hız / yanal Δv |
| `Detection.confirmDelayMs` | 60 | velocityAfter için bekleme |
| `Detection.cooldownMs` | 3000 | Fırlatma sonrası tekrar tetiklenmeme süresi |
| `Exit.method` | `'task'` | Koltuktan ayırma: `'task'` ağda senkron, `'clear'` yalnızca yerel |
| `Exit.networkHandoffMs` | 150 | Ragdoll öncesi ağ devri; diğer oyuncular hâlâ koltukta görüyorsa 250-300 |
| `Launch.velocityKeepFactor` | 0.85 | Çarpışma öncesi hızın korunan payı |
| `Launch.inertiaFactor` | 0.15 | İleri Δv eki |
| `Launch.lateralFactor` | 0.45 | Yanal Δv eki |
| `Launch.maxLaunchSpeed` | 24 m/s | Toplam fırlatma tavanı (~86 km/sa) |
| `Launch.upwardBoost` | 1.0 m/s | Küçük yukarı bileşen |
| `Launch.spinPerSeverity` | 0.035 | Takla miktarı |
| `Ragdoll.minMs / maxMs` | 2500 / 6000 | Ragdoll süresi |
| `Damage.tiers` | 45→8 … 140→50 | Şiddete göre can kaybı |
| `Rollover.enabled` | true | Takla sırasında fırlama |

Tüm değerlerin açıklaması `config.lua` içindedir.

## Debug

Geliştirme ortamında `Config.Debug.commandEnabled = true` yapın ve oyunda `/crashdebug` yazın. Production'da `enabled = false`, `commandEnabled = false` kalmalı; kapalıyken çizim thread'i çalışmaz, log metni üretilmez.

FiveM for GTAV Enhanced istemcisi F8 çıktısını diske yazmaz. Test sonuçlarını sunucu logunda (`data/logs`) görmek için ayrıca `serverLog = true` yapın; debug satırları `server/debug.lua` üzerinden sunucu konsoluna yazılır. `serverLog = false` iken sunucu event'i hiç kaydedilmez.

Not: `CanPedRagdoll` ped koltuktayken oyun tarafından her zaman `false` döner, bu yüzden engel kontrolünde kullanılmaz. `respectDisabledRagdoll` dondurulmuş/görünmez ped'i (admin noclip) engeller.

- F8 konsolu: `velocityBefore`, `velocityAfter`, `deltaVelocity`, önce/sonra hız, hız kaybı, araca göre atalet bileşenleri, şiddet, kanıt, kemer, hasar, cooldown, fırlatma velocity'si ve yönü, **fırlatmanın neden gerçekleştiği veya engellendiği**.
- Ekran: canlı durum satırı ve son çarpışmanın özeti.
- Dünya çizgileri: **yeşil** çarpışma öncesi hareket, **kırmızı** Δv, **mavi** fırlatma.

## Test adımları

Testleri debug açıkken yapın ve her testte F8'deki `sebep:` satırını kontrol edin. Hız sabitlemeyi (cruise) kapalı tutun.

| # | Senaryo | Beklenen |
|---|---|---|
| 1 | 30 km/sa önden çarpma | `ENGELLENDİ – çarpışma öncesi hız düşük` |
| 2 | 80 km/sa direğe önden | Öne doğru, ağ devrinden sonra ragdoll |
| 3 | 120 km/sa duvar | Fırlatma ≤ 86 km/sa (tavan) |
| 4 | Hareket hâlinde sağdan güçlü darbe | `tip=side`, sağa savrulma |
| 5 | Virajda çapraz çarpışma | Mavi çizgi yeşil (gerçek hareket) yönünde, heading'de değil |
| 6 | Kaldırımdan inme | Aday oluşmaz veya `dikey darbe filtrelendi` |
| 7 | Zıplayıp dört teker iniş | `dikey darbe filtrelendi` |
| 8 | Takla | `tip=rollover`, ragdoll çıkışı |
| 9 | Kemer takılı çarpışma | `emniyet kemeri takılı: fırlatma engellendi` |
| 10 | Kemersiz aynı çarpışma | Fırlama |
| 11 | Yolcu koltuğunda çarpışma | Sürücüyle aynı; `koltuk=0` |
| 12 | Çarpışmadan hemen sonra ikinci temas | Tek rapor, tek hasar (cooldown) |
| 13 | Normal şekilde inme | Hiçbir rapor yok |
| 14 | Ölü/baygınken çarpışma | `oyuncu ölü` veya `Qbox metadata...`, hata yok |

Kırılabilen direkler (lamba direkleri) aracı tam durdurmayabilir; hız kaybı 35 km/sa altında kalırsa fırlama olmaz. Bu beklenen davranıştır, debug'da `ani hız kaybı düşük` yazar.

## Ayar rehberi

**Daha ağır / daha az fırlama**
- `minSpeedBeforeKmh` 70-80, `minSpeedLossKmh` 45, `minImpactSeverity` 50
- `velocityKeepFactor` 0.75, `maxLaunchSpeed` 18
- `spinPerSeverity` 0.02

**Daha hafif / daha kolay fırlama**
- `minSpeedBeforeKmh` 50, `minSpeedLossKmh` 25, `minDeltaVelocityKmh` 30
- `upwardBoost` 1.5, `maxLaunchSpeed` 28

**Daha gerçekçi**
- `velocityKeepFactor` 0.95 ve `inertiaFactor` 0.05: ped neredeyse tam olarak çarpışma öncesi hızla devam eder (fiziksel atalet)
- `lateralFactor` 0.3, `randomYawDeg` 2
- Takla hiç görünmüyorsa `spinPerSeverity` ve `maxSpinSpeed` artırın; aşırı dönüyorsa azaltın
- Ped araca takılıyorsa `Exit.upOffset` 0.55, `maxNoCollisionMs` 1500

## Bilinen sınırlar

- Başka bir oyuncunun kullandığı araçta **yolcuyken**, aracın velocity'si network üzerinden gelir ve yumuşatılmış olabilir. Tespit çalışır, ancak eşiklere daha geç ulaşılabilir.
- Duran araca yandan çarpılması varsayılan olarak fırlatmaz (`side.minSpeedBeforeKmh = 40`). Gerçekte de bu durumda yolcu genellikle araç içinde kalır. İstenirse 0 yapılabilir.
- Dönüş impulslarının görsel etkisi ped modeline göre değişebilir; değerler oyunda ayarlanmak üzere muhafazakâr seçildi.
- Ağ devri süresince (varsayılan 150 ms) ped ragdoll'suz düşme pozundadır; bu, diğer oyuncuların fırlamayı anında görmesi için verilen bedeldir. `networkHandoffMs = 0` ilk karede ragdoll'a döner ama klonlar ragdoll bitene kadar koltukta kalır.
- Uzak oyuncuların ragdoll'u GTA'nın ağ yumuşatmasıyla gösterilir; uzuv pozları birebir aynı olmayabilir, gövde konumu aynıdır.

