#!/usr/bin/env python3
"""Create one durable, private community release key. Never replace a key."""
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / '.private'
PROPS = PRIVATE / 'signing.properties'
KEY = PRIVATE / 'muse-passport-release.jks'


def main():
    if PROPS.exists() and KEY.exists():
        print('Existing Muse Passport release key retained.')
        return
    if PROPS.exists() or KEY.exists():
        raise SystemExit('Incomplete signing setup; restore the missing file before proceeding.')
    PRIVATE.mkdir(mode=0o700, exist_ok=True)
    PRIVATE.chmod(0o700)
    java_home = Path(os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'))
    keytool = str(java_home / 'bin/keytool') if (java_home / 'bin/keytool').exists() else 'keytool'
    password = secrets.token_urlsafe(32)
    env = dict(os.environ, MUSE_PASSPORT_KEY_PASSWORD=password)
    subprocess.run([keytool, '-genkeypair', '-keystore', str(KEY), '-storetype', 'PKCS12',
        '-alias', 'muse-passport', '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
        '-dname', 'CN=Muse Passport Community', '-storepass:env', 'MUSE_PASSPORT_KEY_PASSWORD',
        '-keypass:env', 'MUSE_PASSPORT_KEY_PASSWORD'], env=env, check=True, capture_output=True)
    KEY.chmod(0o600)
    fd = os.open(PROPS, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        file.write('storeFile=.private/muse-passport-release.jks\nkeyAlias=muse-passport\n')
        file.write('storePassword=' + password + '\nkeyPassword=' + password + '\n')
    print('Release key created in android/.private/. Keep an encrypted backup of both files; never publish them.')


if __name__ == '__main__':
    main()
