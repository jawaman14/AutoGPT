"""Optional cheminformatics helpers (molar mass, stoichiometry).

Everything here degrades gracefully when RDKit is not installed: explicit
values from the XDL file are always honoured, and only *derived* quantities
(e.g. molar mass from a SMILES string) require RDKit.
"""

from labforge.chemistry.reagents import (  # noqa: F401
    ReagentInfo,
    molar_mass_from_smiles,
    moles,
    rdkit_available,
)

__all__ = ["ReagentInfo", "molar_mass_from_smiles", "moles", "rdkit_available"]
