#!/usr/bin/env python3
"""The service profile must preserve settings without cloning credentials."""
import importlib.util
import json
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).resolve().parents[1] / 'scripts/prepare_service_profile.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    service = root / 'service'
    service.mkdir()
    source = root / 'claude'
    source.mkdir()
    (service/'configuration.json').write_text(json.dumps({'folder':'/test/project'}))
    (source/'settings.json').write_text('{}')
    (source/'.credentials.json').write_text('{"test-secret":"never-copy"}')
    preferences = root/'preferences.json'
    preferences.write_text(json.dumps({
        'oauthAccount': {'secret':'never-copy'},
        'hasCompletedOnboarding': True,
        'projects': {'/test/project': {'hasTrustDialogAccepted':True, 'lastSessionId':'test-session'}},
    }))
    profile = module.prepare(service, source, preferences)
    assert not (profile/'.credentials.json').exists()
    data = json.loads((profile/'.claude.json').read_text())
    assert 'oauthAccount' not in data
    assert data['projects']['/test/project']['hasTrustDialogAccepted'] is True
    assert (profile/'settings.json').is_symlink()
    assert profile.stat().st_mode & 0o777 == 0o700
    assert (profile/'.claude.json').stat().st_mode & 0o777 == 0o600
    try:
        module.prepare(service, source, preferences)
    except ValueError:
        pass
    else:
        raise AssertionError('Existing profile was overwritten')
    assert json.loads((source/'.credentials.json').read_text())['test-secret'] == 'never-copy'
    print('PASS: credential isolation, settings, private permissions, existing profile preserved')
