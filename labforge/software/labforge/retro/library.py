"""Built-in retrosynthesis examples.

Currently: **L-5-hydroxytryptophan (5-HTP)** — the biosynthetic precursor to
serotonin, sold as a dietary supplement. Three disconnection strategies are
encoded:

1. **Tryptophan synthase β-substitution** (biocatalytic): 5-hydroxyindole +
   L-serine → 5-HTP. This is the route LabForge can actually run (batch or
   flow); the other two are represented for planning/comparison.
2. **Enzymatic aromatic hydroxylation** of L-tryptophan → 5-HTP.
3. **Erlenmeyer–Plöchl azlactone** route from 5-(benzyloxy)indole-3-carbaldehyde
   + hippuric acid, then hydrogenation / hydrolysis / resolution.

Educational reference only. Structures/SMILES are illustrative and the encoded
conditions are not a validated procedure — see ``docs/safety.md``.
"""

from __future__ import annotations

from labforge.retro.model import (
    Disconnection,
    Molecule,
    ModeXDL,
    ReactionStep,
    RetroNode,
    Route,
)
from labforge.synthesis.methods import Mode

# --------------------------------------------------------------- molecules
FIVE_HTP = Molecule(
    "L-5-hydroxytryptophan",
    smiles="NC(Cc1c[nH]c2ccc(O)cc12)C(=O)O",
    cas="4350-09-8",
    note="serotonin precursor; dietary supplement",
)
HYDROXYINDOLE = Molecule("5-hydroxyindole", smiles="Oc1ccc2[nH]ccc2c1", cas="1953-54-4")
L_SERINE = Molecule("L-serine", smiles="NC(CO)C(=O)O", cas="56-45-1")
L_TRYPTOPHAN = Molecule(
    "L-tryptophan", smiles="NC(Cc1c[nH]c2ccccc12)C(=O)O", cas="73-22-3"
)
BNO_ALDEHYDE = Molecule(
    "5-(benzyloxy)indole-3-carbaldehyde", note="benzyl-protected 5-hydroxy aldehyde"
)
HIPPURIC_ACID = Molecule(
    "hippuric acid (N-benzoylglycine)", smiles="OC(=O)CNC(=O)c1ccccc1", cas="495-69-2"
)
AZLACTONE = Molecule(
    "2-phenyl-4-[(5-benzyloxyindol-3-yl)methylene]oxazol-5(4H)-one",
    note="Erlenmeyer azlactone (dehydro amino-acid precursor)",
)


# ---------------------------------------------- executable enzymatic step
def _enzymatic_condensation() -> ReactionStep:
    """5-hydroxyindole + L-serine -> L-5-HTP (tryptophan synthase, PLP)."""
    batch = ModeXDL(
        hardware=[
            '<Component id="reactor" type="reactor"/>',
            '<Component id="product" type="collection"/>',
        ],
        reagents=[
            '<Reagent id="buffer" name="phosphate buffer pH 8 with PLP"/>',
            '<Reagent id="hydroxyindole" name="5-hydroxyindole" smiles="Oc1ccc2[nH]ccc2c1"/>',
            '<Reagent id="serine" name="L-serine" smiles="NC(CO)C(=O)O"/>',
            '<Reagent id="enzyme" name="tryptophan synthase (PLP-dependent)"/>',
        ],
        procedure=[
            '<Comment comment="Biocatalytic 5-HTP (batch): 5-hydroxyindole + L-serine"/>',
            '<Add reagent="buffer" vessel="reactor" volume="20 mL"/>',
            '<Add reagent="serine" vessel="reactor" volume="10 mL" stir="true"/>',
            '<Add reagent="hydroxyindole" vessel="reactor" volume="8 mL" stir="true"/>',
            '<Add reagent="enzyme" vessel="reactor" volume="2 mL"/>',
            '<HeatChill vessel="reactor" temp="45 C" time="4 h" stir="true"/>',
            '<StopStir vessel="reactor"/>',
            '<Transfer from_vessel="reactor" to_vessel="product" volume="all"/>',
        ],
    )
    flow = ModeXDL(
        hardware=[
            '<Component id="flow_reactor" type="flow_reactor"/>',
            '<Component id="product" type="collection"/>',
        ],
        reagents=[
            '<Reagent id="hydroxyindole_feed" name="5-hydroxyindole in buffer/PLP"/>',
            '<Reagent id="serine_feed" name="L-serine in buffer/PLP"/>',
        ],
        procedure=[
            '<Comment comment="Continuous-flow 5-HTP over immobilised tryptophan synthase"/>',
            '<HeatChill vessel="flow_reactor" temp="45 C"/>',
            '<Add reagent="serine_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>',
            '<Add reagent="hydroxyindole_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>',
        ],
    )
    return ReactionStep(
        name="Tryptophan-synthase condensation",
        description="PLP-dependent β-substitution couples L-serine onto 5-hydroxyindole.",
        reactants=[HYDROXYINDOLE, L_SERINE],
        product=FIVE_HTP,
        reaction_class="enzymatic C–C bond formation",
        modes=[Mode.BATCH, Mode.FLOW],
        conditions="tryptophan synthase, PLP cofactor, phosphate buffer pH 8, 45 °C",
        reagents_aux=["tryptophan synthase", "PLP", "phosphate buffer pH 8"],
        executable=True,
        xdl={Mode.BATCH: batch, Mode.FLOW: flow},
    )


# --------------------------------------------- planning-only chemical steps
def _aromatic_hydroxylation() -> ReactionStep:
    return ReactionStep(
        name="Enzymatic 5-hydroxylation",
        description="Regioselective aromatic hydroxylation of L-tryptophan at C5.",
        reactants=[L_TRYPTOPHAN],
        product=FIVE_HTP,
        reaction_class="enzymatic aromatic hydroxylation",
        modes=[Mode.BATCH],
        conditions="tryptophan hydroxylase / engineered whole cells, O2, cofactor recycling",
    )


def _azlactone_finish() -> ReactionStep:
    return ReactionStep(
        name="Azlactone reduction / hydrolysis / resolution",
        description=(
            "Hydrogenate the dehydro amino-acid, remove the benzyl group, "
            "hydrolyse the oxazolone, then resolve to L-5-HTP."
        ),
        reactants=[AZLACTONE],
        product=FIVE_HTP,
        reaction_class="hydrogenation + hydrolysis + resolution",
        modes=[Mode.BATCH, Mode.FLOW],  # continuous hydrogenation is flow-amenable
        conditions="H2 / Pd-C (or continuous H2), then acid/base hydrolysis; enzymatic resolution",
    )


def _erlenmeyer_condensation() -> ReactionStep:
    return ReactionStep(
        name="Erlenmeyer–Plöchl condensation",
        description="Azlactone formation from the aldehyde and hippuric acid.",
        reactants=[BNO_ALDEHYDE, HIPPURIC_ACID],
        product=AZLACTONE,
        reaction_class="aldol-type condensation (azlactone)",
        modes=[Mode.BATCH],
        conditions="Ac2O, NaOAc, reflux",
    )


# ------------------------------------------------------------- the tree
def five_htp_tree() -> RetroNode:
    """Return the full retrosynthetic tree for L-5-HTP."""
    azlactone_node = RetroNode(
        AZLACTONE,
        disconnections=[
            Disconnection(
                name="Erlenmeyer azlactone",
                description="Disconnect the exocyclic C=C: aldehyde + hippuric acid.",
                reaction_class="azlactone condensation",
                forward=_erlenmeyer_condensation(),
                precursors=[RetroNode(BNO_ALDEHYDE), RetroNode(HIPPURIC_ACID)],
            )
        ],
    )
    return RetroNode(
        FIVE_HTP,
        disconnections=[
            Disconnection(
                name="Tryptophan-synthase β-substitution",
                description="Biocatalytic C–C coupling of L-serine to 5-hydroxyindole.",
                reaction_class="enzymatic condensation",
                forward=_enzymatic_condensation(),
                precursors=[RetroNode(HYDROXYINDOLE), RetroNode(L_SERINE)],
            ),
            Disconnection(
                name="Aromatic hydroxylation",
                description="Install the 5-OH enzymatically on L-tryptophan.",
                reaction_class="enzymatic hydroxylation",
                forward=_aromatic_hydroxylation(),
                precursors=[RetroNode(L_TRYPTOPHAN)],
            ),
            Disconnection(
                name="Azlactone (Erlenmeyer) route",
                description="Classic chemical route via a dehydro amino-acid azlactone.",
                reaction_class="chemical, multi-step",
                forward=_azlactone_finish(),
                precursors=[azlactone_node],
            ),
        ],
    )


def enzymatic_route() -> Route:
    """The single-step, LabForge-executable biocatalytic route to 5-HTP."""
    return Route(target=FIVE_HTP, steps=[_enzymatic_condensation()], name="enzymatic")


# name -> tree builder
LIBRARY = {"5htp": five_htp_tree}


def get(name: str) -> RetroNode:
    key = name.lower().replace("-", "").replace("_", "")
    if key in ("5htp", "5hydroxytryptophan", "5ht", "fivehtp"):
        return five_htp_tree()
    if key in LIBRARY:
        return LIBRARY[key]()
    raise KeyError(f"unknown target '{name}'. Known: {', '.join(LIBRARY)}")
