# CoreBars Monitor

Eigenständiges macOS-Fenster (kein Menüleisten-Icon) mit zwei umschaltbaren
Ansichten:

- **Dashboard** – Balken pro CPU-Kern, GPU-Auslastung (falls verfügbar),
  RAM-Balken und Netzwerk-Durchsatz, mit kleinen Verlaufskurven.
- **htop-Style** – dunkles, monospaced Layout mit geklammerten
  Kern-Auslastungsbalken oben und einer live sortierten Prozesstabelle
  darunter, angelehnt an `htop`.

Gebaut als Swift Package (kein `.xcodeproj` nötig) mit SwiftUI.

## Voraussetzungen

- macOS 13 (Ventura) oder neuer
- Xcode Command Line Tools oder Xcode installiert
  (`xcode-select --install` falls noch nicht geschehen)

## Bauen & starten

```bash
cd CoreBarsMonitor
swift run
```

Alternativ in Xcode öffnen: Ordner `CoreBarsMonitor` per „File → Open…“
auswählen (Xcode erkennt `Package.swift` automatisch und legt ein Schema
an), dann auf ▶️ klicken.

## Bekannte Einschränkungen

- **GPU-Auslastung** wird über eine inoffizielle IOKit-Statistik
  (`IOAccelerator` → `PerformanceStatistics`) ausgelesen – das ist derselbe
  Trick, den z. B. die Open-Source-App „Stats“ nutzt. Auf manchen
  Mac-Modellen/macOS-Versionen liefert das keinen Wert; die App zeigt dann
  „nicht verfügbar“ statt eines falschen Werts.
- **Netzwerk** zählt nur physische `en*`-Interfaces (WLAN/Ethernet), keine
  virtuellen Interfaces (VPN, Loopback etc.).
- Die Prozessliste holt sich `pcpu`/`pmem` direkt von `ps` (bereits vom
  System berechnet) statt eigene Mach-APIs zu benutzen – robuster und
  deckt sich mit dem, was Activity Monitor/`top` anzeigen.

## Hinweis zur Entstehung

Dieser Code wurde in einer Linux-Cloud-Sandbox ohne Mac/Xcode geschrieben
und konnte dort **nicht kompiliert werden**. Die verwendeten APIs
(`host_processor_info`, `host_statistics64`, `getifaddrs`, IOKit) sind
etabliert und gut dokumentiert, aber falls `swift run` einen
Compile-Fehler wirft: Fehlermeldung kopieren und zurückschicken, dann wird
er gezielt gefixt.
