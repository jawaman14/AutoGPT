from playlist_converter.matching import best_match, score_candidate
from playlist_converter.models import SourceTrack, SpotifyCandidate


def make_source(title, artists, duration=200):
    return SourceTrack(
        video_id="vid1", title=title, artists=artists, duration_seconds=duration
    )


def make_candidate(uri, title, artists, duration=200):
    return SpotifyCandidate(
        uri=uri, title=title, artists=artists, album=None, duration_seconds=duration
    )


def test_exact_match_scores_high():
    source = make_source("Yellow", ["Coldplay"])
    candidate = make_candidate("spotify:track:1", "Yellow", ["Coldplay"])
    scored = score_candidate(source, candidate)
    assert scored.score > 90


def test_noisy_youtube_title_still_matches():
    source = make_source("Yellow (Official Video)", ["Coldplay"])
    candidate = make_candidate("spotify:track:1", "Yellow", ["Coldplay"])
    scored = score_candidate(source, candidate)
    assert scored.score > 85


def test_wrong_artist_scores_lower_than_right_artist():
    source = make_source("Yellow", ["Coldplay"])
    right = make_candidate("spotify:track:1", "Yellow", ["Coldplay"])
    wrong = make_candidate("spotify:track:2", "Yellow", ["Some Cover Band"])
    right_score = score_candidate(source, right)
    wrong_score = score_candidate(source, wrong)
    assert right_score.score > wrong_score.score


def test_duration_mismatch_penalizes_score():
    source = make_source("Yellow", ["Coldplay"], duration=200)
    close = make_candidate("spotify:track:1", "Yellow", ["Coldplay"], duration=205)
    far = make_candidate("spotify:track:2", "Yellow", ["Coldplay"], duration=400)
    assert score_candidate(source, close).score > score_candidate(source, far).score


def test_best_match_picks_highest_scoring_candidate():
    source = make_source("Yellow", ["Coldplay"])
    candidates = [
        make_candidate("spotify:track:1", "Yellow (Live)", ["Coldplay Tribute"], duration=260),
        make_candidate("spotify:track:2", "Yellow", ["Coldplay"], duration=200),
    ]
    top, ranked = best_match(source, candidates)
    assert top.candidate.uri == "spotify:track:2"
    assert ranked[0].score >= ranked[1].score


def test_best_match_returns_none_for_no_candidates():
    source = make_source("Yellow", ["Coldplay"])
    top, ranked = best_match(source, [])
    assert top is None
    assert ranked == []
