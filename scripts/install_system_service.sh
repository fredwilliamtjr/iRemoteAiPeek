#!/bin/bash
# Instala apenas o supervisor; o menu em /Applications continua independente.
# Uso (depois de --write-service-config, como usuário):
# sudo scripts/install_system_service.sh fred /caminho/dist/iRemoteAiPeek.app
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Execute com privilégios de administrador.' >&2; exit 1; }
SERVICE_USER=${1:?Informe o usuário dono do Remote Control}
SOURCE_APP=${2:?Informe o aplicativo compilado}
SERVICE_UID=$(id -u "$SERVICE_USER")
[[ $SERVICE_UID != 0 ]] || { echo 'O Remote Control não pode rodar como root.' >&2; exit 1; }
SERVICE_HOME=$(dscl . -read "/Users/$SERVICE_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
[[ -d "$SERVICE_HOME" && -x "$SOURCE_APP/Contents/MacOS/iRemoteAiPeek" ]] || exit 1
codesign --verify --deep --strict "$SOURCE_APP"
SERVICE_ROOT='/Library/Application Support/iRemoteAiPeek'
LABEL="com.smartfull.iremoteaipeek.service.$SERVICE_UID"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATE_ROOT="$SERVICE_HOME/Library/Application Support/iRemoteAiPeek"
[[ -f "$STATE_ROOT/configuration.json" ]] || { echo 'Execute --write-service-config como usuário antes de instalar.' >&2; exit 1; }
if [[ -e "$SERVICE_ROOT" ]]; then
    [[ ! -L "$SERVICE_ROOT" && $(stat -f %u "$SERVICE_ROOT") == 0 ]] || exit 1
else
    install -d -o root -g wheel -m 755 "$SERVICE_ROOT"
fi
STAGED_APP=$(mktemp -d "$SERVICE_ROOT/stage.XXXXXX")
trap 'rmdir "$STAGED_APP" 2>/dev/null || true' EXIT
ditto "$SOURCE_APP" "$STAGED_APP/iRemoteAiPeek.app"
chown -R root:wheel "$STAGED_APP/iRemoteAiPeek.app"
chmod -R go-w "$STAGED_APP/iRemoteAiPeek.app"
codesign --verify --deep --strict "$STAGED_APP/iRemoteAiPeek.app"
# Não encerrar silenciosamente uma instalação já carregada.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo 'O serviço já está carregado. Pare-o explicitamente antes de atualizar.' >&2
    exit 1
fi
if [[ -e "$SERVICE_ROOT/iRemoteAiPeek.app" ]]; then
    BACKUP_DIR=$(mktemp -d "$SERVICE_ROOT/previous.XXXXXX")
    mv "$SERVICE_ROOT/iRemoteAiPeek.app" "$BACKUP_DIR/iRemoteAiPeek.app"
fi
mv "$STAGED_APP/iRemoteAiPeek.app" "$SERVICE_ROOT/iRemoteAiPeek.app"
/usr/bin/python3 - "$PLIST" "$LABEL" "$SERVICE_USER" "$SERVICE_HOME" "$SERVICE_ROOT" <<'PY'
import os,plistlib,sys,uuid
from pathlib import Path
plist,label,user,home,root=sys.argv[1:]
data={
 'Label':label,
 'ProgramArguments':[root+'/iRemoteAiPeek.app/Contents/MacOS/iRemoteAiPeek','--service'],
 'AssociatedBundleIdentifiers':['com.smartfull.iremoteaipeek'],
 'UserName':user,'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,
 'SessionCreate':True,'ProcessType':'Background','ExitTimeOut':15,'Umask':0o077,
 'WorkingDirectory':home,
 'EnvironmentVariables':{'HOME':home,'USER':user,'LOGNAME':user,
     'PATH':home+'/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
     'LANG':'en_US.UTF-8','TERM':'xterm-256color'},
 'StandardOutPath':home+'/Library/Application Support/iRemoteAiPeek/service.stdout.log',
 'StandardErrorPath':home+'/Library/Application Support/iRemoteAiPeek/service.stderr.log',
}
profile=Path(home)/'Library/Application Support/iRemoteAiPeek/claude-profile'
if profile.is_dir():
 data['EnvironmentVariables']['CLAUDE_CONFIG_DIR']=str(profile)
p=Path(plist)
if p.exists():
 backup=p.with_name(p.name+'.previous.'+uuid.uuid4().hex)
 p.rename(backup)
p.write_bytes(plistlib.dumps(data))
os.chmod(p,0o644)
os.chown(p,0,0)
PY
plutil -lint "$PLIST"
launchctl enable "system/$LABEL"
launchctl bootstrap system "$PLIST"
launchctl print "system/$LABEL" | /usr/bin/egrep 'state =|program =|pid ='
echo 'Supervisor instalado. O menu deve usar a mesma versão do aplicativo.'
