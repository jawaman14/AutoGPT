# RFHound 🐕‍🦺📡

**A friendly, powerful, receive-first HackRF reconnaissance & RF situational-awareness toolkit.**

> ℹ️ **This repository is a pointer.** RFHound is developed as a standalone
> project. The full, actively-maintained source, issues, and releases live at:
>
> ## → **https://github.com/jawaman14/rfhound**
>
> This branch previously held an early RFHound prototype nested inside an
> AutoGPT fork; this README now carries RFHound information and directs people
> to the canonical repo above for everything.

---

## What RFHound is

RFHound is an **orchestration layer** for RF situational awareness. It doesn't
re-implement DSP — it drives the best existing tools (`hackrf_sweep`,
`hackrf_transfer`, `rtl_433`, `dump1090`, `multimon-ng`, `AIS-catcher`, and
more) behind one guided, approachable interface, and ships a **frequency
knowledge base** so you always know what you're looking at.

> ⚠️ **Receive-first.** Transmit is disabled by default and gated behind explicit
> authorization and a frequency allow-list. RFHound deliberately contains **no
> jamming, denial-of-service, deauth, or brute-force** capability.

## Highlights

- **Two frequency helpers** — `rfhound at 433.92` (what's here + every tool for
  it) and `rfhound tune adsb` (what frequency do I need?).
- **Passive multi-source scanning** — HackRF spectrum sweep/recon plus the host's
  Wi-Fi and Bluetooth adapters (`sources --scan`, run in parallel), with RSSI.
- **RSSI locating** — `hunt` foxhunts a target hotter/colder; multi-node RSSI +
  TDOA feed `sigint locate` for a fix (GeoJSON/KML export).
- **Defensive detection** — jamming/interference, RollJam, ADS-B/AIS spoofing,
  rogue base stations (`defense imsi-detect`), frequency-hopping, drones.
- **Presence / geofence** — watch a Wi-Fi/BLE identifier or a specific aircraft
  (ICAO) / vessel (MMSI) and alert on appear/disappear/near.
- **Contacts map** — decoded ADS-B/AIS plotted by position with RSSI.
- **Web dashboard + REST API** — receive-and-analyse only (no transmit endpoint),
  token-gated, with a Prometheus `/metrics` endpoint.
- **Mods** — add your own bands, decoder recipes, detectors, and **pure-Python
  decode/demod functions** without touching the core.

## Get RFHound

```bash
git clone https://github.com/jawaman14/rfhound
cd rfhound
pip install -e .
rfhound                       # guided menu
rfhound --simulate recon      # full offline demo, no hardware needed
rfhound web --open            # browser dashboard + REST API
```

## License

MIT — see [`LICENSE`](LICENSE).
