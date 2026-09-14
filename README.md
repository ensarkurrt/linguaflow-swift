# iOS için LinguaFlow

iOS 15+ Swift Package; actor-isolated remote delivery, kalıcı locale tercihi, release-aware disk
cache, bundled JSON fallback, tenant overlay, ICU argümanları, App Attest ve CLI-generated typed
key'leri içerir.

```swift
let config = try LinguaFlowConfig(branchKey: "br_live_…", overlay: "acme")
let client = LinguaFlowClient(
  config: config,
  integrityProvider: AppAttestProvider(environment: .production)
)
try await client.initialize()

titleLabel.text = try await client.text(Lf.Home.greeting(name: "Ada"))
try await client.selectLocale("tr") // nil cihaz dili çözümüne döner
```

Paketi Swift Package Manager ile ekleyin ve CLI'ın indirdiği `linguaflow/<locale>.json` dosyalarını
uygulama bundle'ına dahil edin. Kaynak önceliği remote, release ile eşleşen disk cache ve app bundle
şeklindedir. Branch politikası gerektirmiyorsa `AppAttestProvider` opsiyoneldir.

Eksik anahtar raporlaması için branch politikasını açın ve config'e
`missingKeyTelemetryEnabled: true` verin. SDK sürüm adı ve build numarasını varsayılan olarak ana
uygulamanın `Bundle.main` bilgisinden okur; `appVersion` yalnız test veya özel sürüm etiketi için
opsiyonel override'dır. SDK sinyalleri tekilleştirip partiler; telemetry hatası metin göstermeyi
durdurmaz. Bekleyen partiyi `await client.flushMissingKeys()` ile elle gönderebilirsiniz.

`AppAttestProvider` yapılandırıldığında SDK ayrıca bundle indirme/parse, Delivery API ve ICU
sonuçlarını toplu runtime telemetrisi olarak gönderir. Bu sinyaller otomatik rollout sağlık
kapılarında kullanılır; gönderim hataları çeviri akışını kesmez.
