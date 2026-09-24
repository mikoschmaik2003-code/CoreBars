# CoreBars

## Download und Installation

Die aktuelle Version ist **1.9.7** für **Apple Silicon** und **macOS 13 oder neuer**.
Lade [`CoreBars-1.9.7-Apple-Silicon.dmg`](https://github.com/mikoschmaik2003-code/CoreBars/releases/download/v1.9.7/CoreBars-1.9.7-Apple-Silicon.dmg)
herunter, öffne die DMG und ziehe `CoreBars.app` in `Programme`. Beende vor dem
Ersetzen eine bereits laufende CoreBars-Version. Die Datei
`CoreBars-1.3-Apple-Silicon.dmg` im Repository ist eine ältere Ausgabe.

Diese Version ist **ad hoc signiert, ohne Developer ID und ohne Apple-Beglaubigung**.
Gatekeeper kann den ersten Start deshalb blockieren. Wenn du der Quelle vertraust,
versuche die App zu öffnen und wähle anschließend in **Systemeinstellungen →
Datenschutz & Sicherheit → Dennoch öffnen**. Die Entscheidung liegt bei dir;
[Apple beschreibt den Vorgang](https://support.apple.com/de-de/102445).

CoreBars wurde mit Unterstützung von KI erstellt. Eine Sicherheitsgarantie gibt
es nicht. Die App wurde auf einem M1-Mac gebaut und getestet; andere Apple-Silicon-
Modelle und alle Sensorwerte sind nicht vollständig geprüft. Sie verwendet das
mitgelieferte `macmon` für einige Sensoren. Beim ersten Start aktiviert CoreBars
den Autostart; im Popup lässt er sich wieder abschalten.

Eine kleine native AppKit-Menüleisten-App für Apple Silicon:

- vertikaler Live-Balken je logischem CPU-Kern
- violetter GPU-Auslastungsbalken links vor den CPU-Kernen
- sichtbare Gruppierung in Effizienz- (E) und Performance-Kerne (P)
- getrennte Gesamtlast für CPU P und CPU E
- separater blauer RAM-Balken
- echte durchschnittliche CPU-Temperatur in °C
- Leistungsanzeige in Prozent: nutzt P-/E-Core-Takt aus `macmon`, wenn verfügbar,
  und fällt sonst auf Temperatur + macOS Thermal State zurück
- Speicherdruck als klarer Status mit eigenem Symbol (normal, erhöht, kritisch)
- Swap-Nutzung als Zahlenwert im Popup
- Liste der sechs Apps/Prozesse mit der höchsten aktuellen CPU-Last im Popup
- dezenter Hinweis auf einen Prozess mit mindestens 80 % CPU-Last über 30 Sekunden
- Akku-Drain in Watt, wenn das MacBook nicht am Netzteil hängt
- Netzteilleistung in Watt: grün ab ca. 25 W, gelb bei langsamem Netzteil
- externe Laufwerke links in Blau: freier Speicher in GB plus aktuelle I/O-Auslastung in Mbit/s
- Detailansicht per Klick
- automatischer Autostart über einen benutzereigenen macOS LaunchAgent
  (im Popup abschaltbar)
- kein Dock-Icon

## Bauen

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

Die fertige App liegt anschließend unter `dist/CoreBars.app`.

Das Build-Skript nutzt nur die Apple Command Line Tools und benötigt kein
vollständiges Xcode.

## Temperatursensor

Die Temperaturmessung verwendet das mitgelieferte Open-Source-Programm
[`macmon`](https://github.com/vladkens/macmon) in Version 0.7.2. Es nutzt
Apples IOReport-Schnittstelle ohne Root-Rechte. `macmon` steht unter der
MIT-Lizenz; die Lizenz wird im App-Bundle unter `Resources/macmon-LICENSE`
mitgeliefert.

## Leistungsanzeige

Die Prozentzahl links in der Menüleiste ist kein zweiter CPU-Load-Wert.
Sie soll anzeigen, wie viel Leistungs-Headroom gerade übrig ist:

- bei echter Last nutzt CoreBars den aktuellen P-/E-Cluster-Takt relativ zum
  bekannten Max-Takt
- wenn kein Taktwert verfügbar ist, nutzt CoreBars Temperatur und macOS Thermal
  State (`normal`, `warm`, `heiß`, `kritisch`)
- bei wenig CPU-Last bleibt die Anzeige eher beim verfügbaren Headroom, damit
  niedriger Idle-Takt nicht fälschlich wie Drosselung aussieht

## Speicherdruck und Swap

Der Speicherdruck kommt vom macOS-Kernel. Das Popup zeigt ihn als Text mit
einem eigenen farbigen Symbol. Wenn der Systemwert nicht verfügbar ist, wird
dies ausdrücklich angezeigt. Swap wird darunter als genutzter und gesamter
Wert aus `vm.swapusage` gezeigt.

Ein weiterer Hinweis erscheint im Popup, wenn derselbe Prozess mindestens
30 Sekunden lang 80 % eines CPU-Kerns beansprucht. Er zeigt den Prozess,
seine aktuelle Last und die Dauer. Die Symbole liegen unter `Resources/Assets`
und lassen sich mit `swift scripts/generate-assets.swift Resources/Assets`
neu erzeugen.

## Akku

Wenn das MacBook auf Akku laeuft, zeigt CoreBars den aktuellen Batterie-Drain
als negative Wattzahl. Wenn macOS kurz keinen
Stromwert liefert, bleibt die Anzeige bei `-0.0 W` und nutzt danach den
naechsten Sensorwert oder eine grobe Kapazitaets-Schaetzung.

## Netzteilleistung

Wenn ein Netzteil verbunden ist, zeigt CoreBars neben der Leistungsanzeige die
ausgehandelte Netzteilleistung in Watt. Der Wert kommt bevorzugt aus
`AdapterDetails.Watts`, damit Batterie-Entladung nicht fälschlich als
Ladeleistung angezeigt wird:

- grün: ungefähr volle/ordentliche Ladeleistung ab 25 W
- gelb: langsames Laden unter 25 W
- keine Wattzahl: nicht angeschlossen oder macOS liefert keine Netzteil-Leistung

## Externe Laufwerke

Wenn ein lokales externes Volume unter `/Volumes` eingebunden ist, zeigt CoreBars
ganz links in Blau den freien Speicher des ersten externen Laufwerks, z.B.
`58G`, plus einen kleinen Speicherbelegungsbalken und die aktuelle
Read/Write-Auslastung als Mbit/s.

Im Popup stehen alle externen Laufwerke mit frei/gesamt, Lesen, Schreiben und
Gesamtauslastung. Die Werte kommen aus den IOKit-Statistiken des zugehörigen
Root-Disks, dadurch werden auch reine Lesevorgänge sichtbar.
