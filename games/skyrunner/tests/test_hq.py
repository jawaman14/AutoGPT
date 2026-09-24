"""HQ season rules, layers/seat plans, and the strategic simulator."""
import random

import numpy as np

from skyrunner.hq import FRONTS, RunResult, Season, resolve_abstract
from skyrunner.layers import features_for, plan_match
from skyrunner.roles import Role
from skyrunner.sim.strategic import dominance, equilibrium, matrix, play_season, run_matrix


def _season(**rules):
    return Season(random.Random(1), rules)


def test_laundering_is_capped_by_fronts_and_costs_a_fee():
    ss = _season(start_dirty=50_000)
    cap = ss.org.capacity
    assert ss.runner_cmd("launder") is None
    assert ss.org.laundered_tonight == cap
    assert 0.85 * cap <= ss.org.clean < cap  # 10% fee on a laundromat
    assert ss.runner_cmd("launder") is not None  # fronts are full tonight
    assert ss.runner_cmd("buy_front", kind="car_lot") is None
    assert ss.org.capacity == cap + FRONTS["car_lot"][1]


def test_action_points_limit_a_night():
    ss = _season(start_dirty=100_000)
    for _ in range(3):
        assert ss.runner_cmd("loyalty") is None
    assert ss.runner_cmd("loyalty") == "No more moves tonight."
    assert ss.runner_cmd("launder") is None  # free actions still work


def test_burner_phones_blank_the_wiretap():
    ss = _season()
    ss.law.evidence = 30
    ss._begin_planning()
    assert ss.law_cmd("wiretap") is None
    assert ss.runner_cmd("opsec") is None
    ss.start_operation()
    before = ss.law.evidence
    ss.finish_night([])
    assert ss.law.evidence <= before  # decay only, no wiretap gain


def test_wiretap_needs_a_warrant():
    ss = _season()
    assert "warrant" in ss.law_cmd("wiretap")


def test_internal_affairs_finds_bribes_and_turns_them_into_evidence():
    found = 0
    for seed in range(40):
        ss = Season(random.Random(seed), {"start_dirty": 50_000})
        ss.runner_cmd("bribe", who="dispatcher")
        ss.law_cmd("ia_sweep")
        ss.start_operation()
        ss.finish_night([])
        if "dispatcher" not in ss.org.bribes:
            found += 1
            assert ss.law.evidence > 5
    assert 10 <= found <= 30  # about half


def test_bust_builds_evidence_less_with_a_lawyer():
    a, b = _season(), _season()
    b.org.lawyer = True
    for ss in (a, b):
        ss.start_operation()
        ss.finish_night([RunResult("main", "west", detected=True, intercepted=True, busted=True, seized_value=30_000)])
    assert a.law.evidence > b.law.evidence > 0
    assert a.law.bank_k > 0  # seizures fund the task force


def test_win_conditions():
    ss = _season(retire_target=1_000, start_dirty=5_000)
    ss.runner_cmd("launder")
    ss.start_operation()
    ss.finish_night([])
    assert ss.phase == "over" and ss.winner == "runner" and ss.reason == "retired rich"
    ss = _season()
    ss.law.evidence = 120
    ss.start_operation()
    ss.finish_night([])
    assert ss.winner == "law" and ss.reason == "boss indicted"


def test_comeback_event_fires_once_for_the_trailing_law():
    ss = _season(retire_target=30_000, start_dirty=100_000, nights=20)
    for night in range(4):
        ss.runner_cmd("launder")
        ss.start_operation()
        ss.finish_night([])
        if ss.phase == "over":
            break
        ss.next_night()
    assert ss.law.fed_arrived


def test_views_hide_the_other_sides_books():
    ss = _season()
    runner, law = ss.view("runner"), ss.view("law")
    assert "org" in runner and "law" not in runner
    assert runner["evidence"] is None and runner["evidence_rumor"] == "thin"
    assert "law" in law and "org" not in law and law["clean_estimate"] is None


def test_abstract_resolver_respects_counters():
    rng = random.Random(3)
    ss = _season()
    plan = {"runs": 1, "crews": 0, "decoys": 0, "route": "west", "funded": {"heli": 2, "interceptor": 2},
            "cutters": 0, "aerostat": True, "patrol": "west", "tip": True, "leak_patrol": None}
    busts = sum(r.busted for _ in range(300) for r in resolve_abstract(ss, plan, rng))
    plan.update(patrol="sea", tip=False, aerostat=False, funded={"heli": 0, "interceptor": 0})
    busts2 = sum(r.busted for _ in range(300) for r in resolve_abstract(ss, plan, rng))
    assert busts > 3 * busts2


def test_layers_and_seat_plans():
    assert features_for(1) == set()
    assert {"contraband", "interceptors"} <= features_for(2)
    assert "hq" in features_for(5) and "copilot" in features_for(5)
    p = plan_match(2)
    assert p.humans("runner") == [Role.PILOT] and p.humans("law") == [Role.CONTROLLER] and p.layer == 4
    p = plan_match(6)
    assert p.layer == 5 and Role.BOSS in p.humans("runner") and Role.CHIEF in p.humans("law")
    assert len(p.humans("runner")) == len(p.humans("law")) == 3
    p = plan_match(5)
    assert any("full strength" in n for n in p.notes)
    solo = plan_match(1)
    assert solo.humans("runner") == [Role.PILOT] and not solo.humans("law")


def test_equilibrium_solver_on_known_games():
    # matching pennies: 50/50, value 0.5
    p, q, v = equilibrium(np.array([[1.0, 0.0], [0.0, 1.0]]), iters=4000)
    assert abs(v - 0.5) < 0.02 and abs(p[0] - 0.5) < 0.05
    # a dominated row gets no weight
    p, q, v = equilibrium(np.array([[0.7, 0.6], [0.2, 0.1]]), iters=2000)
    assert p[1] < 0.01 and abs(v - 0.6) < 0.01
    notes = dominance(np.array([[0.7, 0.6], [0.2, 0.1]]), ["a", "b"], ["x", "y"])
    assert notes == ["runner 'a' dominates 'b'", "law 'y' dominates 'x'"]


def test_strategic_sim_runs_and_is_roughly_fair():
    r = run_matrix(n=12, workers=1)
    assert all(x["winner"] in ("runner", "law") for x in r)
    _, _, m = matrix(r)
    _, _, v = equilibrium(m)
    assert 0.3 < v < 0.7  # coarse guard; docs/BALANCE.md has the real numbers
    one = play_season("adaptive", "adaptive", 5)
    assert one["nights"] >= 3 and one["history"]
