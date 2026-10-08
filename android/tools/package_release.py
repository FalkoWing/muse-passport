#!/usr/bin/env python3
"""Assemble only the explicitly public APK/firmware. Never copy private builds."""
from pathlib import Path
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
VERSION = '1.0.4'
# Version of the Android app in this package. When it is not VERSION the app is
# unchanged, so that release's published APK is packaged again, not a rebuild:
#   gh release download v1.0.2 -p '*.apk' -D android/artifacts
APK_VERSION = '1.0.2'
APK_SHA256 = 'd987c79c743027fbd58e87247aba7a43621759968e9f8f6731c9accd1520ed5d'
BUILD = ROOT / 'esp32/build-muse-folotoy-passport-release'
OUT = ROOT / f'android/artifacts/muse-passport-{VERSION}'
PUBLISHED_APK = OUT.parent / f'Muse-Passport-{APK_VERSION}.apk'
APK = (ROOT / 'android/app/build/outputs/apk/release/app-release.apk'
       if APK_VERSION == VERSION else PUBLISHED_APK)


def configs(path):
    return dict(re.findall(r'^(CONFIG_\w+)="(.*)"$', path.read_text(), re.M))


def main():
    config = configs(BUILD / 'sdkconfig')
    for key in ('CONFIG_GADGET_SDK_TOKEN', 'CONFIG_HOMEHUB_WIFI_SSID',
                'CONFIG_HOMEHUB_WIFI_PASSWORD', 'CONFIG_HOMEHUB_AUTH_TOKEN'):
        if config.get(key, ''):
            raise SystemExit(f'Public configuration must leave {key} empty')
    if APK_VERSION == VERSION:
        metadata = json.loads((APK.parent / 'output-metadata.json').read_text())
        if metadata['elements'][0]['versionName'] != VERSION:
            raise SystemExit('APK version mismatch')
    elif hashlib.sha256(APK.read_bytes()).hexdigest() != APK_SHA256:
        raise SystemExit('APK is not the published release')
    if not (BUILD / 'muse-gadget.bin').stat().st_size < 0x3e0000:
        raise SystemExit('Passport app exceeds its OTA slot')
    if (ROOT / 'esp32/build-muse-folotoy-passport-ble/partition_table/partition-table.bin').exists():
        if (BUILD / 'partition_table/partition-table.bin').read_bytes() != (ROOT / 'esp32/build-muse-folotoy-passport-ble/partition_table/partition-table.bin').read_bytes():
            raise SystemExit('Public/private partition mismatch')
    # Compare actual private build values without logging or packaging them.
    secrets = []
    for private in ('build-muse-folotoy-passport', 'build-muse-folotoy-passport-ble'):
        path = ROOT / 'esp32' / private / 'sdkconfig'
        if path.exists():
            values = configs(path)
            secrets += [v.encode() for k,v in values.items() if
                        k in ('CONFIG_GADGET_SDK_TOKEN', 'CONFIG_HOMEHUB_WIFI_PASSWORD',
                              'CONFIG_HOMEHUB_AUTH_TOKEN') and len(v) >= 8]
    with zipfile.ZipFile(APK) as archive:
        for name in archive.namelist():
            content = archive.read(name)
            if any(secret in content for secret in secrets):
                raise SystemExit('Private value detected in APK; stopped')
    firmware_files = ('bootloader/bootloader.bin', 'partition_table/partition-table.bin',
                      'ota_data_initial.bin', 'muse-gadget.bin', 'flash_args')
    for name in firmware_files:
        content = (BUILD / name).read_bytes()
        if any(secret in content for secret in secrets):
            raise SystemExit('Private value detected in public firmware; stopped')
    # Output is our dedicated generated directory, never a user-selected path.
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    shutil.copy2(APK, OUT / PUBLISHED_APK.name)
    for name in firmware_files:
        dest = OUT / 'firmware' / name
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(BUILD / name, dest)
    shutil.copy2(ROOT / 'README.md', OUT / '使用说明.md')
    shutil.copy2(ROOT / 'android/releases' / f'v{VERSION}.md', OUT / '发行说明.md')
    icon = OUT / 'android/assets/muse-passport-icon.svg'
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'android/assets/muse-passport-icon.svg', icon)
    for notice in ('LICENSE', 'NOTICE', 'THIRD_PARTY.md'):
        shutil.copy2(ROOT / notice, OUT / notice)
    third = OUT / 'THIRD_PARTY'
    third.mkdir()
    for notice in (ROOT / 'android/notices').glob('*'):
        if notice.is_file():
            shutil.copy2(notice,third / notice.name)
    with zipfile.ZipFile(APK) as apk:
        with zipfile.ZipFile(io.BytesIO(apk.read('assets/chaquopy/requirements-common.imy'))) as requirements:
            for name in requirements.namelist():
                if not name.endswith('/') and ('license' in name.lower() or 'notice' in name.lower()):
                    relative=Path(name)
                    if relative.is_absolute() or '..' in relative.parts:
                        raise SystemExit('Invalid license archive path')
                    dest=third / 'python' / relative
                    dest.parent.mkdir(parents=True,exist_ok=True)
                    dest.write_bytes(requirements.read(name))
    shutil.copy2(ROOT / 'esp32/components/passport_bsp/LICENSE', third / 'Passport-BSP-MIT.txt')
    shutil.copy2(ROOT / 'esp32/components/passport_bsp/UPSTREAM.md', third / 'Passport-BSP-UPSTREAM.md')
    shutil.copy2(ROOT / 'esp32/components/muse/fonts/SOURCE_HAN_LICENSE.txt', third / 'Source-Han-OFL.txt')
    (third / 'README.md').write_text('''# Third-party components

Muse Device SDK and the bundled Muse Python Noise/API/protobuf modules: Apache-2.0, see ../LICENSE and source headers.
FoloToy Passport BSP: MIT, see Passport-BSP-MIT.txt and upstream provenance.
Source Han Sans bitmap glyphs: SIL Open Font License 1.1, see Source-Han-OFL.txt.

Android runtime includes Chaquopy 17.0.0 (MIT), OkHttp 4.12.0 / Okio (Apache-2.0), Kotlin standard library (Apache-2.0), CPython 3.13 (PSF), cryptography 42.0.8 (Apache-2.0 OR BSD-3-Clause), and transitive native dependencies including OpenSSL. Their upstream license notices are retained in the packaged dependencies; original license texts in the source/distributions continue to apply.

ESP-IDF 6.0.1 and components carry their own Apache/MIT/BSD notices, including NimBLE, LVGL, FreeRTOS, mbedTLS and cJSON. Refer to the upstream SDK and the dependency lockfile for exact sources. Muse Passport does not replace their licenses.
''')
    files = sorted(p for p in OUT.rglob('*') if p.is_file())
    (OUT / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(OUT).as_posix()}\n' for p in files))
    archive = OUT.parent / f'Muse-Passport-{VERSION}.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as package:
        for p in sorted(OUT.rglob('*')):
            if p.is_file():
                package.write(p, f'{OUT.name}/{p.relative_to(OUT).as_posix()}')
    # Community installers require a single image from 0x0. It deliberately
    # fills the NVS gap with FF: use the four-part package to preserve pairing.
    merged = OUT.parent / f'Muse-Passport-{VERSION}-full.bin'
    subprocess.run([sys.executable, '-m', 'esptool', '--chip', 'esp32c3',
                    'merge-bin', '--output', str(merged), '--flash-mode', 'dio',
                    '--flash-freq', '80m', '--flash-size', '8MB',
                    '0x0', str(BUILD / 'bootloader/bootloader.bin'),
                    '0x10000', str(BUILD / 'partition_table/partition-table.bin'),
                    '0x1d000', str(BUILD / 'ota_data_initial.bin'),
                    '0x20000', str(BUILD / 'muse-gadget.bin')], check=True)
    image = merged.read_bytes()
    if not 0 < len(image) <= 8 * 1024 * 1024:
        raise SystemExit('Merged firmware exceeds hardware Flash')
    if image[0x11000:0x1d000] != b'\xff' * 0xc000:
        raise SystemExit('Merged public image contains unexpected NVS data')
    if any(secret in image for secret in secrets):
        raise SystemExit('Private value detected in merged firmware; stopped')
    if APK != PUBLISHED_APK:
        shutil.copy2(APK, PUBLISHED_APK)
    attachments = (PUBLISHED_APK, archive, merged)
    (OUT.parent / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
        for p in attachments))
    print(f'Prepared {OUT}')
    print(f'Public APK/firmware checked against private configuration; archive: {archive.name}')

if __name__ == '__main__':
    main()
