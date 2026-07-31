# Usage guide

## Install RFHound

```bash
cd rfhound
pip install -e .           # gives you the `rfhound` command + rich
```

RFHound itself only needs Python 3.9+ and (optionally) `rich`. Everything else is
an **external SDR tool** it drives on demand — install only what you need.

## Install the SDR tools RFHound can drive

Run `rfhound doctor` at any time to see what's present and get install hints.

```bash
# HackRF host tools (hackrf_info, hackrf_sweep, hackrf_transfer)
sudo apt install hackrf            # Debian/Ubuntu
brew install hackrf                # macOS

# ISM decoder (build with SoapySDR for HackRF input)
sudo apt install rtl-433

# Pager / APRS decoder
sudo apt install multimon-ng

# ADS-B (dump1090-fa), AIS-catcher, acarsdec, dumpvdl2 — build from source:
#   https://github.com/flightaware/dump1090
#   https://github.com/jvde-github/AIS-catcher
#   https://github.com/TLeconte/acarsdec
#   https://github.com/szpajder/dumpvdl2

# SoapySDR HackRF driver (needed by rtl_433 -d driver=hackrf, AIS-catcher, etc.)
sudo apt install soapysdr-module-hackrf
```

### HackRF permissions on Linux

If `hackrf_info` says the device is busy or permission-denied, install udev rules
and add yourself to `plugdev`:

```bash
sudo usermod -aG plugdev "$USER"    # then log out/in
# The hackrf package usually installs /etc/udev/rules.d rules automatically.
```

## Core workflows

### 1. What's around me? (recon)

```bash
rfhound recon                        # survey high-value bands
rfhound recon --category ism         # just the ISM bands
rfhound recon --report site.html     # write an HTML report
rfhound recon --simulate             # no hardware needed
```

### 2. Look at a slice of spectrum (sweep)

```bash
rfhound sweep 433 435                # spectrogram + peak table
rfhound sweep 100 1000 --bin 250     # wide sweep, coarser bins
rfhound sweep 862 928 --snr 8        # lower threshold = more sensitive
```

### 3. Browse the knowledge base (bands)

```bash
rfhound bands                        # everything
rfhound bands --category aviation
rfhound bands --tag tpms -v          # with descriptions
rfhound bands --search pager
```

### 4. Decode a protocol (decode)

```bash
rfhound decode list                  # recipes + which tools are ready
rfhound decode run rtl433            # 433 MHz ISM devices
rfhound decode run adsb              # aircraft at 1090 MHz
rfhound decode run rtl433 --freq 868.3 --seconds 60
rfhound decode run adsb --dry-run    # print the command, run nothing
```

#### Pagers / APRS need an FM front-end

`multimon-ng` consumes demodulated audio on stdin. With a HackRF the canonical
pipeline is (RFHound prints the `multimon-ng` half; wire up the front-end
yourself so the choice is deliberate):

```bash
# Example using rtl_fm-style demod via SoapySDR + sox, piped into multimon-ng:
hackrf_transfer -r - -f 929000000 -s 2000000 \
  | csdr convert_u8_f | csdr fmdemod_quadri_cf | csdr fractional_decimator_ff ... \
  | multimon-ng -a POCSAG1200 -f alpha -
```

### 5. Capture IQ for deep analysis (capture)

```bash
rfhound capture 433.92 10            # 10 s at 433.92 MHz
rfhound capture 1090 5 --rate 4000000 --note "ADS-B sample"
```

This writes a `.sigmf-data` file plus a `.sigmf-meta` sidecar. Open it in
**Universal Radio Hacker**, **inspectrum**, or **GNU Radio** to reverse the
protocol, then hand results back to RFHound recipes.

### 6. Authorized replay (transmit — gated)

**Read [`LEGAL.md`](LEGAL.md) first.** Transmit is off by default.

```bash
# One-time: declare the ranges you are authorized to transmit in.
rfhound tx enable --allow 433.0-434.8 --jurisdiction "EU"

# Replay a signal YOU captured, for authorized testing of YOUR device:
rfhound replay capture_433MHz.sigmf-data --authorized --dry-run   # preview
rfhound replay capture_433MHz.sigmf-data --authorized             # transmit

rfhound tx status         # review settings
rfhound tx disable        # turn transmit back off
```

RFHound refuses to transmit outside your declared allow-list, outside the HackRF
hardware range, or without the per-command `--authorized` flag.

## The guided menu

Prefer clicking to typing? Just run:

```bash
rfhound
```

…for an interactive menu covering recon, sweep, the knowledge base, and decoders.
It auto-detects whether a HackRF is attached and drops into `--simulate` if not.

## Configuration

```bash
rfhound config show        # current settings
rfhound config init        # write ~/.config/rfhound/config.json
rfhound config path        # where the config lives
```

Editable settings include RX gains (`lna_gain`, `vga_gain`, `amp_enable`),
`sample_rate`, `output_dir`, and the transmit safety block.
