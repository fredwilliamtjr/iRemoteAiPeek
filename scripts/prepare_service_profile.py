#!/usr/bin/env python3
"""Prepare an independent Claude login without copying any existing credentials."""
import argparse
import json
import os
from pathlib import Path


def prepare(service_root, claude_root, preferences):
    if service_root.is_symlink():
        raise ValueError('A pasta de serviço não pode ser um link simbólico')
    profile = service_root / 'claude-profile'
    if profile.exists() or profile.is_symlink():
        raise ValueError('O perfil já existe; seus dados serão preservados')
    config = json.loads((service_root / 'configuration.json').read_text())
    source = json.loads(preferences.read_text()) if preferences.exists() else {}
    profile.mkdir(mode=0o700, parents=True)
    # Compartilha configurações e históricos existentes. OAuth/Keychain e
    # arquivos de sessão/bridge ficam independentes; não há cópia de tokens.
    for name in ['CLAUDE.md', 'settings.json', 'agents', 'skills', 'commands',
                 'plugins', 'rules', 'hooks', 'projects']:
        target = claude_root / name
        if target.exists():
            (profile / name).symlink_to(target, target_is_directory=target.is_dir())
    data = {k: source[k] for k in ['hasCompletedOnboarding', 'theme'] if k in source}
    folder = config.get('folder')
    if folder and folder in source.get('projects', {}):
        keys = ['allowedTools', 'mcpContextUris', 'enabledMcpjsonServers',
                'disabledMcpjsonServers', 'hasTrustDialogAccepted',
                'hasClaudeMdExternalIncludesApproved',
                'hasClaudeMdExternalIncludesWarningShown', 'lastSessionId']
        project = source['projects'][folder]
        data['projects'] = {folder: {k: project[k] for k in keys if k in project}}
    p = profile / '.claude.json'
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n')
    p.chmod(0o600)
    print('Perfil independente preparado (sem copiar credenciais):', profile)
    return profile


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    home = Path.home()
    parser.add_argument('--service-dir', type=Path, default=home/'Library/Application Support/iRemoteAiPeek')
    parser.add_argument('--claude-dir', type=Path, default=home/'.claude')
    parser.add_argument('--preferences-file', type=Path, default=home/'.claude.json')
    args = parser.parse_args()
    prepare(args.service_dir, args.claude_dir, args.preferences_file)
