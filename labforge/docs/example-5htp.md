# Worked example: 5-hydroxytryptophan (5-HTP), batch and flow

This ties the whole suite together: take a target molecule, do a
**retrosynthesis**, pick a route, and run it in both **batch** and **flow** — end
to end in simulation.

> **5-HTP** (L-5-hydroxytryptophan) is the biosynthetic precursor to serotonin
> and a common dietary supplement (extracted commercially from *Griffonia
> simplicifolia* seeds). This example is **educational**: the structures/SMILES
> are illustrative and the encoded conditions are **not** a validated procedure.
> Read [`safety.md`](safety.md) before attempting any chemistry.

Run it all:

```bash
python examples/retro_5htp.py
# or piecewise:
labforge retro 5htp
labforge retro 5htp --emit-xdl --mode flow
labforge simulate examples/protocols/5htp_flow.xdl  --graph examples/graphs/5htp_flow_rig.json
labforge simulate examples/protocols/5htp_batch.xdl --graph examples/graphs/5htp_batch_rig.json
```

## 1. Retrosynthesis

`labforge retro 5htp` encodes three disconnection strategies for 5-HTP:

```
* L-5-hydroxytryptophan
  => [Tryptophan-synthase β-substitution; enzymatic; batch/flow]
       - 5-hydroxyindole   (starting material)
       - L-serine          (starting material)
  => [Aromatic hydroxylation; enzymatic; batch]
       - L-tryptophan      (starting material)
  => [Azlactone (Erlenmeyer) route; chemical, multi-step; batch/flow]
       * azlactone
         => [Erlenmeyer condensation] 5-(benzyloxy)indole-3-carbaldehyde + hippuric acid
```

1. **Tryptophan-synthase β-substitution** (biocatalytic): the PLP-dependent
   enzyme couples L-serine directly onto 5-hydroxyindole. One clean C–C bond,
   aqueous buffer, mild temperature. **This is the route LabForge runs.**
2. **Enzymatic aromatic hydroxylation** of L-tryptophan (tryptophan hydroxylase
   / engineered cells). Represented for comparison; needs O₂ + cofactor
   recycling, outside LabForge's pump/stir/heat rig class.
3. **Erlenmeyer–Plöchl azlactone** route: classic chemical synthesis via a
   dehydro-amino-acid, then hydrogenation / hydrolysis / resolution. Also
   planning-only here (H₂ hydrogenation, filtration, chiral resolution).

Routes 2 and 3 are marked *planning-only*; asking LabForge to emit XDL for them
raises a clear error rather than pretending it can run them.

## 2. Choosing batch vs flow for the enzymatic route

The tryptophan-synthase condensation suits **both** modes:

- **Batch** — run it as a stirred, buffered enzyme incubation: charge buffer,
  serine, 5-hydroxyindole and enzyme; hold at 45 °C with stirring; collect.
  Simple, tolerant, good when the enzyme is free in solution.
- **Flow** — immobilise the enzyme in a packed bed and pump the two feeds
  through it at a controlled rate. Precise residence time, small inventory,
  easy to run continuously. See [`batch-vs-flow.md`](batch-vs-flow.md).

## 3. The generated procedures

`examples/retro_5htp.py` generates the XDL from the library
(`labforge.retro.library`) and writes it to `examples/protocols/`. (A test keeps
the committed files in sync with the library.)

### Batch (`5htp_batch.xdl`, rig `5htp_batch_rig.json`)

```xml
<Add reagent="buffer" vessel="reactor" volume="20 mL"/>
<Add reagent="serine" vessel="reactor" volume="10 mL" stir="true"/>
<Add reagent="hydroxyindole" vessel="reactor" volume="8 mL" stir="true"/>
<Add reagent="enzyme" vessel="reactor" volume="2 mL"/>
<HeatChill vessel="reactor" temp="45 C" time="4 h" stir="true"/>
<StopStir vessel="reactor"/>
<Transfer from_vessel="reactor" to_vessel="product" volume="all"/>
```

Simulated result: reactor charged to 40 mL, held at 45 °C, drained to `product`
(40 mL collected).

### Flow (`5htp_flow.xdl`, rig `5htp_flow_rig.json`)

```xml
<HeatChill vessel="flow_reactor" temp="45 C"/>
<Add reagent="serine_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
<Add reagent="hydroxyindole_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
```

The `flow_reactor` is a pass-through (10 mL holdup, outlet `product`), so it
never accumulates; the 20 mL of combined feed is collected downstream. The
compiler reports residence time — 10 mL ÷ 0.5 mL/min combined = **20 min** at
45 °C.

## 4. What this demonstrates

- A retrosynthesis that distinguishes **what LabForge can run** from what it can
  only plan.
- The **same reaction** expressed as batch and as flow, from one library
  definition.
- First-class **flow** primitives: flow rate, pass-through reactor, residence
  time — all validated in simulation with zero hardware.
