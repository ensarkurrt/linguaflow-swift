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
`missingKeyTelemetryEnabled: true, appVersion: "1.0.0"` verin. SDK sinyalleri tekilleştirip
partiler; telemetry hatası metin göstermeyi durdurmaz. Bekleyen partiyi `await
client.flushMissingKeys()` ile elle gönderebilirsiniz.
