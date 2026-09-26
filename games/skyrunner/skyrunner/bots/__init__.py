"""AI players for every seat.

They exist for three reasons: to fill seats nobody is sitting in, to give solo
players opponents, and to play thousands of matches headless so the rules can
be balanced on data instead of hunches (see `skyrunner.sim`).

  pilot.PilotBot     flies the real JSBSim aircraft: takeoff, low-level
                     terrain following, airdrops, approaches and landings
  hq.RunnerBoss      runs the trafficking organisation between nights
  hq.TaskForceChief  runs the task force's budget, informants and cases
"""
