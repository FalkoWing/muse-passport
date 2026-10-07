#!/usr/bin/env bash
# Local build/configuration helper. Never selects or flashes a port implicitly.
set -eo pipefail
action=${1:-build}
case "$action" in
    build|ble-build|release-build|menuconfig|size|monitor|merge-bin) ;;
    *) echo "Usage: $0 build|ble-build|menuconfig|size|merge-bin|monitor [PORT]" >&2; exit 2 ;;
esac
root=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v idf.py >/dev/null 2>&1; then
    task_idf_export=${IDF_EXPORT:-$HOME/esp/esp-idf-v6.0.1/export.sh}
    [ -f "$task_idf_export" ] || { echo "Activate ESP-IDF v6.0.1 or set IDF_EXPORT" >&2; exit 1; }
    # export.sh otherwise selects the shell's Python, which may differ from
    # the Python used to install IDF. Prefer an existing IDF 6.0 environment.
    if [ -n "${IDF_PYTHON_ENV_PATH:-}" ]; then
        export PATH="$IDF_PYTHON_ENV_PATH/bin:$PATH"
    else
        for task_python in "${IDF_TOOLS_PATH:-$HOME/.espressif}"/python_env/idf6.0_py*/bin/python3; do
            if [ -x "$task_python" ]; then
                export PATH="$(dirname "$task_python"):$PATH"
                break
            fi
        done
    fi
    . "$task_idf_export" >/dev/null
fi
[ "$(idf.py --version)" = "ESP-IDF v6.0.1" ] || {
    echo "Passport needs ESP-IDF v6.0.1; activate that version first" >&2; exit 1;
}
cd "$root"
task_build=build-muse-folotoy-passport
task_defaults='sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-folotoy-passport'
if [ "$action" = ble-build ] || [ "$action" = release-build ]; then
    task_public_release=false
    [ "$action" != release-build ] || task_public_release=true
    task_build=build-muse-folotoy-passport-ble
    task_defaults+=';devices/sdkconfig.muse-passport-ble'
    if "$task_public_release"; then
        task_build=build-muse-folotoy-passport-release
        mkdir -p "$task_build"
        # This configuration is independent of private development builds.
        python3 - "$task_build/sdkconfig" <<'PYPUBLIC'
import pathlib, re, sys
p=pathlib.Path(sys.argv[1])
s=p.read_text() if p.exists() else ''
if not re.search(r'^CONFIG_GADGET_SDK_TOKEN=""$',s,re.M):
    s=re.sub(r'^CONFIG_GADGET_SDK_TOKEN=.*$', '', s, flags=re.M)
    p.write_text(s+'\nCONFIG_GADGET_SDK_TOKEN=""\n')
PYPUBLIC
    fi
    if ! "$task_public_release" && [ ! -f "$task_build/sdkconfig" ] && [ -f build-muse-folotoy-passport/sdkconfig ]; then
        mkdir -p "$task_build"
        cp build-muse-folotoy-passport/sdkconfig "$task_build/sdkconfig"
        chmod 600 "$task_build/sdkconfig"
        python3 - "$task_build/sdkconfig" <<'PYCONFIG'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text().replace('# CONFIG_MUSE_PHONE_BRIDGE is not set', '')
s += '\nCONFIG_MUSE_PHONE_BRIDGE=y\nCONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=247\n'
p.write_text(s)
PYCONFIG
    fi
    action=build
fi
task_idf_args=(-B "$task_build" -DIDF_TARGET=esp32c3 -DPROJECT_VER=1.0.3
    -DSDKCONFIG="$task_build/sdkconfig"
    "-DSDKCONFIG_DEFAULTS=$task_defaults")
if [ "$action" = monitor ]; then
    [ -n "${2:-}" ] || { echo "monitor needs an explicit USB port" >&2; exit 2; }
    task_idf_args+=(-p "$2")
fi
exec idf.py "${task_idf_args[@]}" "$action"
