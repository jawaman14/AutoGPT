import pytest

from skyrunner.campaign import CHAPTERS, Campaign
from skyrunner.controls import InputFrame
from skyrunner.game import Session
from skyrunner.roles import Mode


@pytest.fixture()
def sess(world, jsbsim_root):
    return Session(world=world, jsbsim_root=jsbsim_root, seed=11, mode=Mode.CAMPAIGN)


def test_chapter_one_is_legal_only(sess):
    Campaign().attach(sess)
    assert "contraband" not in sess.features and not sess.police.features
    for board in sess.boards.values():
        assert not any(j.hot for j in board)


def test_objectives_advance_chapters(sess):
    camp = Campaign()
    camp.attach(sess)
    sess.bus.emit("job_delivered", sess.time, pay=5200, hot=False)
    sess.bus.emit("landed", sess.time, code="EGL")
    sess.update(1 / 60, InputFrame())
    assert camp.index == 1 and camp.chapter.title == "A Favor for Manny"
    here = sess.location
    assert any(j.hot and "Manny" in j.title for j in sess.boards[here])
    assert "contraband" in sess.features


def test_wanted_spoils_the_clean_run(sess):
    camp = Campaign(index=1)
    camp.attach(sess)
    job = next(j for j in sess.boards[sess.location] if j.hot)
    sess.accept_job(job)
    sess.police.wanted = 1
    sess.update(1 / 60, InputFrame())
    sess.bus.emit("job_delivered", sess.time, pay=4500, hot=True)
    assert camp.progress.get("hot_clean", 0) == 0


def test_kickers_puts_rosa_aboard(sess):
    camp = Campaign(index=2)
    camp.attach(sess)
    assert sess.copilot == "ai" and sess.loadout.copilot_aboard
    assert any(j.is_airdrop for j in sess.boards[sess.location])


def test_long_legs_starts_offshore_with_ferry_fuel(sess):
    camp = Campaign(index=3)
    camp.attach(sess)
    assert sess.phase == "flying"
    assert sess.loadout.ferry_fuel_lb() > 100
    assert sess.active_jobs and sess.active_jobs[0].is_airdrop
    for _ in range(60 * 3):
        sess.update(1 / 60, InputFrame())
    assert sess.phase == "flying"
    # the AI co-pilot starts pumping once the wings have room
    sess.fm.fdm["propulsion/tank[0]/contents-lbs"] = 20
    sess.fm.fdm["propulsion/tank[1]/contents-lbs"] = 20
    for _ in range(60 * 5):
        sess.update(1 / 60, InputFrame())
    assert sess.pumping


def test_save_roundtrip():
    c = Campaign(2, {"kicked": 3})
    d = Campaign.from_dict(c.to_dict())
    assert d.index == 2 and d.progress == {"kicked": 3}
    assert CHAPTERS[3].playable and not CHAPTERS[4].playable
