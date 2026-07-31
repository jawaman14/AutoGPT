"""Reagent chemistry helpers, with optional RDKit acceleration."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

# A tiny built-in table so common lab reagents work without RDKit installed.
# Values are g/mol.
_BUILTIN_MOLAR_MASS = {
    "water": 18.015,
    "h2o": 18.015,
    "ethanol": 46.069,
    "methanol": 32.042,
    "acetone": 58.080,
    "acetic acid": 60.052,
    "sodium chloride": 58.443,
    "nacl": 58.443,
    "sodium hydroxide": 39.997,
    "naoh": 39.997,
    "hydrochloric acid": 36.458,
    "hcl": 36.458,
    "sulfuric acid": 98.079,
    "h2so4": 98.079,
    "sodium bicarbonate": 84.007,
    "acetonitrile": 41.053,
    "dmso": 78.129,
    "dcm": 84.933,
    "dichloromethane": 84.933,
    "thf": 72.107,
    "toluene": 92.141,
    "hexane": 86.178,
    "ethyl acetate": 88.106,
}


def rdkit_available() -> bool:
    """Return True if RDKit can be imported."""
    try:
        import rdkit  # noqa: F401

        return True
    except Exception:
        return False


def molar_mass_from_smiles(smiles: str) -> Optional[float]:
    """Compute molar mass (g/mol) from a SMILES string using RDKit.

    Returns ``None`` if RDKit is unavailable or the SMILES cannot be parsed.
    """
    try:
        from rdkit import Chem
        from rdkit.Chem import Descriptors
    except Exception:
        return None
    mol = Chem.MolFromSmiles(smiles)
    if mol is None:
        return None
    return float(Descriptors.MolWt(mol))


def resolve_molar_mass(
    name: str = "",
    smiles: Optional[str] = None,
    explicit: Optional[float] = None,
) -> Optional[float]:
    """Best-effort molar mass: explicit value > SMILES (RDKit) > builtin table."""
    if explicit is not None:
        return explicit
    if smiles:
        mm = molar_mass_from_smiles(smiles)
        if mm is not None:
            return mm
    if name:
        return _BUILTIN_MOLAR_MASS.get(name.strip().lower())
    return None


def moles(volume_ml: float, concentration_mol_per_l: float) -> float:
    """Moles of solute given a volume (mL) and molar concentration (mol/L)."""
    return (volume_ml / 1000.0) * concentration_mol_per_l


@dataclass
class ReagentInfo:
    """Derived chemistry facts about a reagent, computed on demand."""

    name: str
    smiles: Optional[str] = None
    molar_mass: Optional[float] = None

    @classmethod
    def from_reagent(cls, reagent) -> "ReagentInfo":
        """Build from a :class:`labforge.protocol.model.Reagent`."""
        mm = resolve_molar_mass(
            name=getattr(reagent, "name", "") or "",
            smiles=getattr(reagent, "smiles", None),
            explicit=getattr(reagent, "molar_mass", None),
        )
        return cls(
            name=getattr(reagent, "name", "") or getattr(reagent, "id", ""),
            smiles=getattr(reagent, "smiles", None),
            molar_mass=mm,
        )

    def mass_for_volume(
        self, volume_ml: float, concentration_mol_per_l: float
    ) -> Optional[float]:
        """Grams of solute in ``volume_ml`` at the given molar concentration."""
        if self.molar_mass is None:
            return None
        return moles(volume_ml, concentration_mol_per_l) * self.molar_mass
