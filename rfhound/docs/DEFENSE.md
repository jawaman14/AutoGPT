# Defensive module — detect attacks & harden devices

The `rfhound defense` commands are the "build protections" half of RFHound. They
help you **detect** RF attacks and **assess and harden** your own devices. They
are receive-and-analyse only, except the resilience harness, which reuses the
separate, safety-gated *replay-of-your-own-capture* path.

> **By design, RFHound ships no jammer/DoS transmitter, no RollJam
> capture-and-replay attack, and no brute-force code generator.** These are RF
> denial-of-service and access-control-defeating attack primitives; they are out
> of scope regardless of environment. Crucially, a defence program does not need
> them — everything you need to *detect* and *harden against* those attacks is
> here. See [`LEGAL.md`](LEGAL.md).

## 1. Jamming / interference detection — `defense monitor`

Learns a baseline noise floor for a band, then alarms when the floor rises
(classic jamming) or when expected signals disappear (desense). This is the
actual capability a defender needs to *detect* an RF DoS attack.

```bash
rfhound defense monitor 433 435 --threshold 10 --samples 20
rfhound defense monitor 433 435 --simulate      # models a jammer switching on
```

Deploy it as a continuous watch on a band your devices rely on (garage/gate
receivers, sensors) and route alarms to your monitoring stack.

## 2. Replay-attack detection — `defense replay-check`

Analyses a stream of observed transmissions and flags replay signatures:
identical payloads on a device that should roll its code, or the same fixed code
repeated faster than a human could press a button.

Input file: one observation per line, `timestamp payload`:

```
1712000000.0 a1b2c3
1712000000.4 a1b2c3
1712000000.7 a1b2c3
```

```bash
rfhound defense replay-check --file observations.txt
rfhound defense replay-check --file observations.txt --fixed   # fixed-code device
rfhound defense replay-check --simulate
```

Pair it with a decoder (e.g. pipe `rtl_433 -F json` payloads into this format) to
get runtime replay alerts.

## 3. Rolling-code posture assessment — `defense rolling-assess`

Capture a handful of presses of the **same button** on a device you're
authorized to assess, then classify it: fixed vs rolling, whether a "rolling"
code looks like a thinly-masked counter, and a 0–100 resilience score with
concrete hardening recommendations. Passive analysis — it reports weaknesses and
produces no attack.

Input file: one captured payload (hex or bits) per line.

```bash
rfhound defense rolling-assess --file captures.txt
rfhound defense rolling-assess --simulate --kind fixed     # demo: weak device
rfhound defense rolling-assess --simulate --kind rolling   # demo: strong device
```

## 4. Lab resilience harness — `defense resilience`

Structures a resilience test of **your own** device and turns the result into a
hardening report. The active step (transmitting) is the *separate, gated* replay
of a capture you made, inside your RF enclosure:

```bash
# 1) capture your device (your own remote), inside the tent
rfhound capture 433.92 5 --name myfob

# 2) enable gated transmit for the band, then replay your capture at your device
rfhound tx enable --allow 433.0-434.8
rfhound replay <captures>/myfob.sigmf-data --authorized

# 3) tell the harness what happened, get a hardening report
rfhound defense resilience --device myfob --payloads captures.txt \
    --replayed --actuated true
```

If the device actuates on a replayed capture, it doesn't enforce freshness and is
replay-vulnerable; the report recommends an authenticated rolling counter /
challenge-response and runtime replay + RollJam detection.

```bash
rfhound defense resilience --device demo --simulate    # end-to-end demo
```

## Turning findings into protections

| Finding | Hardening action |
|---|---|
| Fixed code / replay-vulnerable | Move to authenticated rolling code or challenge-response; receiver rejects reused codes |
| "Rolling" code is really a counter | Use a cryptographic hop with good avalanche; validate a forward-only window |
| Jamming detected | Alarm + fail-safe behaviour; diversity/redundancy; detect jam-then-press (RollJam) |
| Replays seen in the wild | Rate-limit, nonce/timestamp validation, alerting |
