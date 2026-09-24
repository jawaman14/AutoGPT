"""Headless simulation and balance tooling.

  feasibility  - can every aircraft get into and out of every strip, at what load?
                 (the pilot bot flies the real JSBSim model)
  tactical     - bot runs against the AI task force, many seeds: detection,
                 intercept, bust, crash and delivery rates per route and tactic
  strategic    - whole seasons of the HQ layer, thousands of them, using rates
                 calibrated by the tactical sim; policy-vs-policy win matrix
  report       - turns results into docs/BALANCE.md

Run `python -m skyrunner.sim --help`.
"""
