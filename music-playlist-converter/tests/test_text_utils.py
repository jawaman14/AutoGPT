from playlist_converter.text_utils import extract_featured_artists, normalize, strip_noise


def test_strip_noise_removes_official_video_tag():
    assert strip_noise("Bohemian Rhapsody (Official Video)") == "Bohemian Rhapsody"


def test_strip_noise_removes_feat_credit():
    assert strip_noise("Blinding Lights (feat. Someone)") == "Blinding Lights"


def test_strip_noise_removes_remaster_tag():
    assert strip_noise("Come Together (2019 Remaster)") == "Come Together"


def test_strip_noise_leaves_clean_titles_untouched():
    assert strip_noise("Yellow") == "Yellow"


def test_normalize_lowercases_and_strips_punctuation():
    assert normalize("Don't Stop Me Now!") == "dont stop me now"


def test_normalize_collapses_whitespace():
    assert normalize("A   B\tC") == "a b c"


def test_extract_featured_artists():
    assert extract_featured_artists("Song (feat. Alice & Bob)") == ["Alice", "Bob"]


def test_extract_featured_artists_none():
    assert extract_featured_artists("Song") == []
