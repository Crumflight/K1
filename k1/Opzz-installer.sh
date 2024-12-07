#!/bin/sh

# This script sets up a K1 Max printer environment with a BLTouch probe.
# It has been simplified and beacon or other probes references are removed.
# It also adds flexibility to specify a custom Klipper repo and branch via arguments.
#
# Usage examples:
#   ./install.sh --install --klipper-repo "https://github.com/YourUser/YourKlipperFork.git" --klipper-branch "mybranch"
#
# Defaults:
#   klipper_repo="https://github.com/Crumflight/Klipper_kreality.git"
#   klipper_branch uses the default branch from remote if not specified

set -e

# Ensure printer data is present
if [ ! -f /usr/data/printer_data/config/printer.cfg ]; then
  >&2 echo "ERROR: Printer data not setup"
  exit 1
fi

# Check firmware version
ota_version=$(cat /etc/ota_info | grep ota_version | awk -F '=' '{print $2}' | sed 's/^6.//g' | tr -d '.')
if [ -z "$ota_version" ] || [ "$ota_version" -lt 1335 ]; then
  echo "ERROR: Firmware is too old, you must update to at least version 1.3.3.5 of Creality OS"
  echo "https://www.creality.com/pages/download-k1-flagship"
  exit 1
fi

model=k1m  # Hard-coded to K1 Max

# Check for conflicting scripts
if [ -d /usr/data/helper-script ] || [ -f /usr/data/fluidd.sh ] || [ -f /usr/data/mainsail.sh ]; then
    echo "The Guilouz helper and K1_Series_Annex scripts cannot be installed"
    exit 1
fi

# Ensure repository location is correct
if [ "$(dirname $(readlink -f $0))" != "/usr/data/Crumflight/k1" ]; then
  >&2 echo "ERROR: This git repo must be cloned to /usr/data/Crumflight"
  exit 1
fi

update_repo() {
    local repo_dir=$1
    if [ -d "${repo_dir}/.git" ]; then
        cd $repo_dir
        branch_ref=$(git rev-parse --abbrev-ref HEAD)
        if [ -n "$branch_ref" ]; then
            git fetch
            git reset --hard origin/$branch_ref
            sync
        else
            echo "Failed to detect current branch"
            return 1
        fi
    else
        echo "Invalid $repo_dir specified"
        return 1
    fi
    return 0
}

function update_klipper() {
  # Removed beacon and cartographer references
  /usr/share/klippy-env/bin/python3 -m compileall /usr/data/klipper/klippy || return $?
  /usr/data/Crumflight/k1/tools/check-firmware.sh --status
  if [ $? -eq 0 ]; then
      /etc/init.d/S55klipper_service restart
  fi
  return $?
}

# Remove pip cache
rm -rf /root/.cache

# Copy services that we need
cp /usr/data/Crumflight/k1/services/S58factoryreset /etc/init.d || exit $?
cp /usr/data/Crumflight/k1/services/S50dropbear /etc/init.d/ || exit $?
sync

# Replace curl with SSL-capable version
cp /usr/data/Crumflight/k1/tools/curl /usr/bin/curl
sync

CONFIG_HELPER="/usr/data/Crumflight/k1/config-helper.py"

install_config_updater() {
    python3 -c 'from configupdater import ConfigUpdater' 2>/dev/null || {
        echo
        echo "INFO: Installing configupdater python package ..."
        pip3 install configupdater==3.2
        python3 -c 'from configupdater import ConfigUpdater' 2>/dev/null || {
            echo "ERROR: Something bad happened, can't continue"
            exit 1
        }
    }
    if [ -d /usr/data/Crumflight-env/ ]; then
        rm -rf /usr/data/Crumflight-env/
    fi
    sync
}

disable_creality_services() {
    if [ ! -L /etc/boot-display/part0 ]; then
      rm -rf /overlay/upper/etc/boot-display/*
      rm -rf /overlay/upper/etc/logo/*
      rm -f /overlay/upper/etc/init.d/S12boot_display
      rm -f /overlay/upper/etc/init.d/S11jpeg_display_shell
      mount -o remount /
    fi

    if [ -f /etc/init.d/S99start_app ]; then
        echo
        echo "INFO: Disabling creality services ..."

        [ -f /etc/init.d/S99start_app ] && /etc/init.d/S99start_app stop && rm /etc/init.d/S99start_app
        [ -f /etc/init.d/S70cx_ai_middleware ] && /etc/init.d/S70cx_ai_middleware stop && rm /etc/init.d/S70cx_ai_middleware
        [ -f /etc/init.d/S97webrtc ] && /etc/init.d/S97webrtc stop && rm /etc/init.d/S97webrtc
        [ -f /etc/init.d/S99mdns ] && /etc/init.d/S99mdns stop && rm /etc/init.d/S99mdns
        [ -f /etc/init.d/S96wipe_data ] && {
            wipe_data_pid=$(ps -ef | grep wipe_data | grep -v "grep" | awk '{print $1}')
            [ -n "$wipe_data_pid" ] && kill -9 $wipe_data_pid
            rm /etc/init.d/S96wipe_data
        }
        [ -f /etc/init.d/S55klipper_service ] && /etc/init.d/S55klipper_service stop
        [ -f /etc/init.d/S57klipper_mcu ] && /etc/init.d/S57klipper_mcu stop && rm /etc/init.d/S57klipper_mcu

        # kill log_main if running
        log_main_pid=$(ps -ef | grep log_main | grep -v "grep" | awk '{print $1}')
        [ -n "$log_main_pid" ] && kill -9 $log_main_pid
    fi
    sync
}

install_boot_display() {
  grep -q "boot-display" /usr/data/Crumflight.done && return 0

  echo
  echo "INFO: Installing custom boot display ..."

  rm -rf /etc/boot-display/part0
  cp /usr/data/Crumflight/k1/boot-display.conf /etc/boot-display/
  cp /usr/data/Crumflight/k1/services/S11jpeg_display_shell /etc/init.d/
  mkdir -p /usr/data/boot-display
  tar -zxf "/usr/data/Crumflight/k1/boot-display.tar.gz" -C /usr/data/boot-display
  ln -s /usr/data/boot-display/part0 /etc/boot-display/
  echo "boot-display" >> /usr/data/Crumflight.done
  sync
  return 1
}

install_webcam() {
    local mode=$1
    grep -q "webcam" /usr/data/Crumflight.done && return 0

    if [ "$mode" != "update" ] || [ ! -f /opt/bin/mjpg_streamer ]; then
        echo
        echo "INFO: Installing mjpg streamer ..."
        /opt/bin/opkg install mjpg-streamer mjpg-streamer-input-http mjpg-streamer-input-uvc mjpg-streamer-output-http mjpg-streamer-www || exit $?
    fi

    echo
    echo "INFO: Updating webcam config ..."
    [ -f /opt/etc/init.d/S96mjpg-streamer ] && rm /opt/etc/init.d/S96mjpg-streamer
    pidof cam_app &>/dev/null && killall -TERM cam_app
    pidof mjpg_streamer &>/dev/null && killall -TERM mjpg_streamer

    [ -f /etc/init.d/S50webcam ] && /etc/init.d/S50webcam stop
    [ -f /usr/bin/auto_uvc.sh ] && rm /usr/bin/auto_uvc.sh

    cp /usr/data/Crumflight/k1/files/auto_uvc.sh /usr/bin/
    chmod 777 /usr/bin/auto_uvc.sh

    cp /usr/data/Crumflight/k1/services/S50webcam /etc/init.d/
    /etc/init.d/S50webcam start

    [ -f /usr/data/Crumflight.ipaddress ] && rm /usr/data/Crumflight.ipaddress
    cp /usr/data/Crumflight/k1/webcam.conf /usr/data/printer_data/config/ || exit $?

    echo "webcam" >> /usr/data/Crumflight.done
    sync
    return 1
}

install_moonraker() {
    local mode=$1
    grep -q "moonraker" /usr/data/Crumflight.done && return 0

    echo
    if [ "$mode" != "update" ] && [ -d /usr/data/moonraker ]; then
        [ -f /etc/init.d/S56moonraker_service ] && /etc/init.d/S56moonraker_service stop
        if [ -d /usr/data/printer_data/database/ ]; then
            [ -f /usr/data/moonraker-database.tar.gz ] && rm /usr/data/moonraker-database.tar.gz
            echo "INFO: Backing up moonraker database ..."
            cd /usr/data/printer_data/
            tar -zcf /usr/data/moonraker-database.tar.gz database/
            cd
        fi
        rm -rf /usr/data/moonraker
    fi

    if [ "$mode" != "update" ] && [ -d /usr/data/moonraker-env ]; then
        rm -rf /usr/data/moonraker-env
    fi

    if [ ! -d /usr/data/moonraker/.git ]; then
        echo "INFO: Installing moonraker ..."
        [ -d /usr/data/moonraker ] && rm -rf /usr/data/moonraker
        [ -d /usr/data/moonraker-env ] && rm -rf /usr/data/moonraker-env

        git clone https://github.com/Arksine/moonraker /usr/data/moonraker || exit $?

        if [ -f /usr/data/moonraker-database.tar.gz ]; then
            echo
            echo "INFO: Restoring moonraker database ..."
            cd /usr/data/printer_data/
            tar -zxf /usr/data/moonraker-database.tar.gz
            rm /usr/data/moonraker-database.tar.gz
            cd
        fi
    fi

    if [ ! -f /usr/data/moonraker-timelapse/component/timelapse.py ]; then
        [ -d /usr/data/moonraker-timelapse ] && rm -rf /usr/data/moonraker-timelapse
        git clone https://github.com/mainsail-crew/moonraker-timelapse.git /usr/data/moonraker-timelapse/ || exit $?
    fi

    if [ ! -d /usr/data/moonraker-env ]; then
        tar -zxf /usr/data/Crumflight/k1/moonraker-env.tar.gz -C /usr/data/ || exit $?
    fi

    if [ "$mode" != "update" ] || [ ! -f /opt/bin/ffmpeg ]; then
        echo "INFO: Upgrading ffmpeg for moonraker timelapse ..."
        /opt/bin/opkg install ffmpeg || exit $?
    fi

    echo "INFO: Updating moonraker config ..."
    [ ! -f /usr/data/printer_data/moonraker.secrets ] && cp /usr/data/Crumflight/k1/moonraker.secrets /usr/data/printer_data/
    ln -sf /usr/data/Crumflight/k1/tools/supervisorctl /usr/bin/ || exit $?
    cp /usr/data/Crumflight/k1/services/S56moonraker_service /etc/init.d/ || exit $?
    cp /usr/data/Crumflight/k1/moonraker.conf /usr/data/printer_data/config/ || exit $?
    ln -sf /usr/data/Crumflight/k1/moonraker.asvc /usr/data/printer_data/ || exit $?
    ln -sf /usr/data/moonraker-timelapse/component/timelapse.py /usr/data/moonraker/moonraker/components/ || exit $?

    if ! grep -q "moonraker/components/timelapse.py" "/usr/data/moonraker/.git/info/exclude"; then
        echo "moonraker/components/timelapse.py" >> "/usr/data/moonraker/.git/info/exclude"
    fi
    ln -sf /usr/data/moonraker-timelapse/klipper_macro/timelapse.cfg /usr/data/printer_data/config/ || exit $?
    cp /usr/data/Crumflight/k1/timelapse.conf /usr/data/printer_data/config/ || exit $?

    [ ! -f /usr/data/printer_data/config/notifier.conf ] && cp /usr/data/Crumflight/k1/notifier.conf /usr/data/printer_data/config/

    echo "moonraker" >> /usr/data/Crumflight.done
    sync
    return 1
}

install_nginx() {
    local mode=$1
    grep -q "nginx" /usr/data/Crumflight.done && return 0

    default_ui=fluidd
    if [ -f /usr/data/nginx/nginx/sites/mainsail ]; then
      grep "#listen" /usr/data/nginx/nginx/sites/mainsail > /dev/null
      [ $? -ne 0 ] && default_ui=mainsail
    fi

    if [ "$mode" != "update" ] && [ -d /usr/data/nginx ]; then
        [ -f /etc/init.d/S50nginx_service ] && /etc/init.d/S50nginx_service stop
        rm -rf /usr.data/nginx
    fi

    if [ ! -d /usr.data/nginx ]; then
        echo
        echo "INFO: Installing nginx ..."
        tar -zxf /usr.data/Crumflight/k1/nginx.tar.gz -C /usr.data/ || exit $?
    fi

    echo "INFO: Updating nginx config ..."
    cp /usr.data/Crumflight/k1/nginx.conf /usr.data/nginx/nginx/ || exit $?
    mkdir -p /usr.data/nginx/nginx/sites/
    cp /usr.data/Crumflight/k1/nginx/fluidd /usr.data/nginx/nginx/sites/ || exit $?
    cp /usr.data/Crumflight/k1/nginx/mainsail /usr.data/nginx/nginx/sites/ || exit $?

    if [ "$default_ui" = "mainsail" ]; then
      echo "INFO: Restoring mainsail as default UI"
      sed -i 's/.*listen 80 default_server;/    #listen 80 default_server;/g' /usr.data/nginx/nginx/sites/fluidd
      sed -i 's/.*#listen 80 default_server;/    listen 80 default_server;/g' /usr.data/nginx/nginx/sites/mainsail
    fi

    cp /usr.data/Crumflight/k1/services/S50nginx_service /etc/init.d/ || exit $?

    echo "nginx" >> /usr.data/Crumflight.done
    sync
    return 1
}

install_fluidd() {
    local mode=$1
    grep -q "fluidd" /usr.data/Crumflight.done && return 0

    if [ "$mode" != "update" ] && [ -d /usr.data/fluidd ]; then
        rm -rf /usr.data/fluidd
    fi
    if [ "$mode" != "update" ] && [ -d /usr.data/fluidd-config ]; then
        rm -rf /usr.data/fluidd-config
    fi

    if [ ! -d /usr.data/fluidd ]; then
        echo
        echo "INFO: Installing fluidd ..."
        mkdir -p /usr.data/fluidd || exit $?
        curl -L "https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip" -o /usr.data/fluidd.zip || exit $?
        unzip -qd /usr.data/fluidd /usr.data/fluidd.zip || exit $?
        rm /usr.data/fluidd.zip
    fi

    if [ ! -d /usr.data/fluidd-config ]; then
        git clone https://github.com/fluidd-core/fluidd-config.git /usr.data/fluidd-config || exit $?
    fi

    echo "INFO: Updating fluidd config ..."
    [ -f /usr.data/printer_data/config/fluidd.cfg ] && rm /usr.data/printer_data/config/fluidd.cfg
    ln -sf /usr.data/fluidd-config/client.cfg /usr.data/printer_data/config/fluidd.cfg
    ln -sf /usr.data/printer_data/ /root

    $CONFIG_HELPER --remove-section "pause_resume" || true
    $CONFIG_HELPER --remove-section "display_status" || true
    $CONFIG_HELPER --remove-section "virtual_sdcard" || true

    $CONFIG_HELPER --add-include "fluidd.cfg" || exit $?

    echo "fluidd" >> /usr.data/Crumflight.done
    sync
    return 1
}

install_mainsail() {
    local mode=$1
    grep -q "mainsail" /usr.data/Crumflight.done && return 0

    if [ "$mode" != "update" ] && [ -d /usr.data/mainsail ]; then
        rm -rf /usr.data/mainsail
    fi

    if [ ! -d /usr.data/mainsail ]; then
        echo
        echo "INFO: Installing mainsail ..."
        mkdir -p /usr.data/mainsail || exit $?
        curl -L "https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip" -o /usr.data/mainsail.zip || exit $?
        unzip -qd /usr.data/mainsail /usr.data/mainsail.zip || exit $?
        rm /usr.data/mainsail.zip
    fi

    echo "mainsail" >> /usr.data/Crumflight.done
    sync
    return 1
}

install_kamp() {
    local mode=$1
    grep -q "KAMP" /usr.data/Crumflight.done && return 0

    if [ "$mode" != "update" ] && [ -d /usr.data/KAMP ]; then
        rm -rf /usr.data/KAMP
    fi

    if [ ! -d /usr.data/KAMP/.git ]; then
        echo
        echo "INFO: Installing KAMP ..."
        [ -d /usr.data/KAMP ] && rm -rf /usr.data/KAMP
        git clone https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging.git /usr.data/KAMP || exit $?
    fi

    echo "INFO: Updating KAMP config ..."
    ln -sf /usr.data/KAMP/Configuration /usr.data/printer_data/config/KAMP || exit $?
    cp /usr.data/KAMP/Configuration/KAMP_Settings.cfg /usr.data/printer_data/config/ || exit $?
    $CONFIG_HELPER --add-include "KAMP_Settings.cfg" || exit $?

    sed -i 's:#\[include ./KAMP/Line_Purge.cfg\]:\[include ./KAMP/Line_Purge.cfg\]:g' /usr.data/printer_data/config/KAMP_Settings.cfg
    sed -i 's:#\[include ./KAMP/Smart_Park.cfg\]:\[include ./KAMP/Smart_Park.cfg\]:g' /usr.data/printer_data/config/KAMP_Settings.cfg

    cp /usr.data/printer_data/config/KAMP_Settings.cfg /usr.data/Crumflight-backups/

    echo "KAMP" >> /usr.data/Crumflight.done
    sync
    return 1
}

install_klipper() {
    local mode=$1
    grep -q "klipper" /usr.data/Crumflight.done && return 0

    echo "INFO: Installing/updating Klipper ..."
    # Use variables (possibly overridden by arguments)
    [ -z "$klipper_repo_url" ] && klipper_repo_url="https://github.com/Crumflight/Klipper_kreality.git"
    # If no branch specified, we just use the default branch from the repository
    # klipper_branch can be empty meaning default branch

    if [ "$mode" != "update" ] && [ -d /usr.data/klipper ]; then
        [ -f /etc/init.d/S55klipper_service ] && /etc/init.d/S55klipper_service stop
        rm -rf /usr.data/klipper
        [ -f /usr.data/Crumflight.klipper ] && rm /usr.data/Crumflight.klipper
    fi

    if [ ! -d /usr.data/klipper/.git ]; then
        echo "INFO: Cloning Klipper from $klipper_repo_url ..."
        git clone "$klipper_repo_url" /usr.data/klipper || exit $?
        if [ -n "$klipper_branch" ]; then
            cd /usr.data/klipper
            git checkout "$klipper_branch" || exit $?
            cd -
        fi
    else
        cd /usr.data/klipper
        # If branch specified, attempt to switch
        if [ -n "$klipper_branch" ]; then
            git fetch
            git checkout "$klipper_branch"
            git pull
        else
            # Just update current branch
            git fetch
            git pull
        fi
        cd -
    fi

    /usr/share/klippy-env/bin/python3 -m compileall /usr.data/klipper/klippy || exit $?

    [ -e /usr/share/klipper ] && rm -rf /usr/share/klipper
    ln -sf /usr.data/klipper /usr/share/
    [ -e /root/klipper ] && rm -rf /root/klipper
    ln -sf /usr.data/klipper /root

    cp /usr.data/Crumflight/k1/services/S55klipper_service /etc/init.d/ || exit $?
    cp /usr.data/Crumflight/k1/services/S13mcu_update /etc/init.d/ || exit $?

    cp /usr.data/Crumflight/k1/sensorless.cfg /usr.data/printer_data/config/ || exit $?
    cp /usr.data/Crumflight/k1/useful_macros.cfg /usr.data/printer_data/config/ || exit $?
    $CONFIG_HELPER --add-include "useful_macros.cfg" || exit $?

    $CONFIG_HELPER --remove-section "mcu rpi"
    $CONFIG_HELPER --remove-section "bl24c16f"
    $CONFIG_HELPER --remove-section "prtouch_v2"
    $CONFIG_HELPER --remove-section "mcu leveling_mcu"
    $CONFIG_HELPER --remove-section-entry "printer" "square_corner_max_velocity"
    $CONFIG_HELPER --remove-section-entry "printer" "max_accel_to_decel"

    $CONFIG_HELPER --remove-section-entry "tmc2209 stepper_x" "hold_current"
    $CONFIG_HELPER --remove-section-entry "tmc2209 stepper_y" "hold_current"

    $CONFIG_HELPER --remove-include "printer_params.cfg"
    $CONFIG_HELPER --remove-include "gcode_macro.cfg"
    $CONFIG_HELPER --remove-include "custom_gcode.cfg"

    [ -f /usr.data/printer_data/config/custom_gcode.cfg ] && rm /usr.data/printer_data/config/custom_gcode.cfg
    [ -f /usr.data/printer_data/config/gcode_macro.cfg ] && rm /usr.data/printer_data/config/gcode_macro.cfg
    [ -f /usr.data/printer_data/config/printer_params.cfg ] && rm /usr.data/printer_data/config/printer_params.cfg
    [ -f /usr.data/printer_data/config/factory_printer.cfg ] && rm /usr.data/printer_data/config/factory_printer.cfg

    cp /usr.data/Crumflight/k1/start_end.cfg /usr.data/printer_data/config/ || exit $?
    $CONFIG_HELPER --add-include "start_end.cfg" || exit $?

    cp /usr.data/Crumflight/k1/fan_control.cfg /usr.data/printer_data/config || exit $?
    $CONFIG_HELPER --add-include "fan_control.cfg" || exit $?

    $CONFIG_HELPER --remove-section "output_pin fan0"
    $CONFIG_HELPER --remove-section "output_pin fan1"
    $CONFIG_HELPER --remove-section "output_pin fan2"
    $CONFIG_HELPER --remove-section "output_pin PA0"
    $CONFIG_HELPER --remove-section "output_pin PB2"
    $CONFIG_HELPER --remove-section "output_pin PB10"
    $CONFIG_HELPER --remove-section "output_pin PC8"
    $CONFIG_HELPER --remove-section "output_pin PC9"
    $CONFIG_HELPER --remove-section "duplicate_pin_override"
    $CONFIG_HELPER --remove-section "static_digital_output my_fan_output_pins"
    $CONFIG_HELPER --remove-section "heater_fan hotend_fan"
    $CONFIG_HELPER --remove-section "temperature_sensor mcu_temp"
    $CONFIG_HELPER --remove-section "temperature_sensor chamber_temp"
    $CONFIG_HELPER --remove-section "temperature_fan chamber_fan"
    $CONFIG_HELPER --remove-section "temperature_fan mcu_fan"
    $CONFIG_HELPER --remove-section "multi_pin heater_fans"
    $CONFIG_HELPER --remove-section "idle_timeout"

    echo "klipper" >> /usr.data/Crumflight.done
    sync
    return 1
}

install_guppyscreen() {
    local mode=$1
    grep -q "guppyscreen" /usr.data/Crumflight.done && return 0

    if [ "$mode" != "update" ] && [ -d /usr.data/guppyscreen ]; then
        [ -f /etc/init.d/S99guppyscreen ] && /etc/init.d/S99guppyscreen stop
        killall -q guppyscreen || true
        rm -rf /usr.data/guppyscreen
    fi

    if [ ! -d /usr.data/guppyscreen ]; then
        echo
        echo "INFO: Installing guppyscreen ..."
        curl -L "https://github.com/ballaswag/guppyscreen/releases/latest/download/guppyscreen.tar.gz" -o /usr.data/guppyscreen.tar.gz || exit $?
        tar xf /usr.data/guppyscreen.tar.gz -C /usr.data/ || exit $?
        rm /usr.data/guppyscreen.tar.gz
    fi

    echo "INFO: Updating guppyscreen config ..."
    cp /usr.data/Crumflight/k1/services/S99guppyscreen /etc/init.d/ || exit $?
    cp /usr.data/Crumflight/k1/guppyconfig.json /usr.data/guppyscreen || exit $?

    cp /usr.data/Crumflight/k1/guppyscreen.cfg /usr.data/printer_data/config/ || exit $?
    $CONFIG_HELPER --remove-include "GuppyScreen/*.cfg" || true
    $CONFIG_HELPER --add-include "guppyscreen.cfg" || exit $?

    echo "guppyscreen" >> /usr.data/Crumflight.done
    sync
    return 1
}

setup_bltouch() {
    grep -q "bltouch-probe" /usr.data/Crumflight.done && return 0
    echo
    echo "INFO: Setting up BLTouch ..."

    $CONFIG_HELPER --remove-section "bed_mesh" || true
    $CONFIG_HELPER --remove-section-entry "stepper_z" "position_endstop" || true
    $CONFIG_HELPER --replace-section-entry "stepper_z" "endstop_pin" "probe:z_virtual_endstop" || true

    # Overwrite with BLTouch config
    [ -f /usr.data/printer_data/config/bltouch.cfg ] && rm /usr.data/printer_data/config/bltouch.cfg
    $CONFIG_HELPER --remove-include "bltouch.cfg" || true
    $CONFIG_HELPER --overrides "/usr.data/Crumflight/k1/bltouch.cfg" || exit $?

    cp /usr.data/Crumflight/k1/bltouch_macro.cfg /usr.data/printer_data/config/ || exit $?
    $CONFIG_HELPER --add-include "bltouch_macro.cfg" || exit $?

    cp /usr.data/Crumflight/k1/bltouch-${model}.cfg /usr.data/printer_data/config/ || exit $?
    $CONFIG_HELPER --add-include "bltouch-${model}.cfg" || exit $?

    position_max=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max")
    position_max=$((position_max-17))
    $CONFIG_HELPER --replace-section-entry "stepper_y" "position_max" "$position_max" || exit $?

    echo "bltouch-probe" >> /usr.data/Crumflight.done
    sync
    return 1
}

install_entware() {
    local mode=$1
    grep -q "entware" /usr.data/Crumflight.done && return 0
    echo
    /usr/data/Crumflight/k1/entware-install.sh "$mode" || exit $?
    echo "entware" >> /usr.data/Crumflight.done
    sync
}

apply_overrides() {
    grep -q "overrides" /usr.data/Crumflight.done && return 0
    /usr/data/Crumflight/k1/apply-overrides.sh
    retval=$?
    echo "overrides" >> /usr.data/Crumflight.done
    sync
    return $retval
}

restart_moonraker() {
    echo
    echo "INFO: Restarting Moonraker ..."
    /etc/init.d/S56moonraker_service restart

    echo "INFO: Waiting for Moonraker to start..."
    timeout=480
    start_time=$(date +%s)

    while true; do
      KLIPPER_PATH=$(curl -s localhost:7125/printer/info | jq -r .result.klipper_path 2>/dev/null || true)
      if [ "$KLIPPER_PATH" = "/usr/share/klipper" ] || [ "$KLIPPER_PATH" = "/usr/data/klipper" ]; then
          echo "INFO: Moonraker started and reporting Klipper path: $KLIPPER_PATH"
          break
      fi
      current_time=$(date +%s)
      elapsed_time=$((current_time - start_time))
      if [ $elapsed_time -ge $timeout ]; then
          echo "ERROR: Timeout while waiting for Moonraker to start."
          exit 1
      fi
      [ $((elapsed_time % 10)) -eq 0 ] && echo "INFO: Still waiting for Moonraker... Elapsed: ${elapsed_time}s"
      sleep 1
    done
}

# Move backups
mkdir -p /usr.data/printer_data/config/backups/
mv /usr.data/printer_data/config/*.bkp /usr.data/printer_data/config/backups/ 2>/dev/null || true

mkdir -p /usr.data/Crumflight-backups
if [ ! -f /usr.data/Crumflight.done ] && [ ! -f /usr.data/Crumflight-backups/printer.factory.cfg ]; then
    if ! grep -q "# Modified by Simple AF " /usr.data/printer_data/config/printer.cfg; then
        cp /usr.data/printer_data/config/printer.cfg /usr.data/Crumflight-backups/printer.factory.cfg
    else
      echo "ERROR: No pristine factory printer.cfg available"
    fi
fi

# Default mode and client
client=cli
mode=install
skip_overrides=false

# Additional variables for repo and branch
klipper_repo_url=""
klipper_branch=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --install|--update|--reinstall|--clean-install|--clean-reinstall|--clean-update)
            mode=$(echo $1 | sed 's/--//g')
            if echo $mode | grep -q "clean-"; then
                skip_overrides=true
                mode=$(echo $mode | sed 's/clean-//g')
            fi
            shift
            ;;
        --client)
            shift
            client=$1
            shift
            ;;
        --klipper-repo)
            shift
            klipper_repo_url=$1
            shift
            ;;
        --klipper-branch)
            shift
            klipper_branch=$1
            shift
            ;;
        *)
            break
            ;;
    esac
done

echo
echo "INFO: Mode is $mode"
echo "INFO: Probe is BLTouch"
[ -n "$klipper_repo_url" ] && echo "INFO: Custom Klipper repo: $klipper_repo_url"
[ -n "$klipper_branch" ] && echo "INFO: Klipper branch: $klipper_branch"

disable_creality_services
install_config_updater

# Remove old addons
for dir in addons SimpleAddon; do
  [ -d /usr.data/printer_data/config/$dir ] && rm -rf /usr.data/printer_data/config/$dir
done
for file in save-zoffset.cfg eddycalibrate.cfg quickstart.cfg cartographer_calibrate.cfg btteddy_calibrate.cfg; do
  $CONFIG_HELPER --remove-include "SimpleAddon/$file" || true
done
sync

if [ -f /usr.data/Crumflight-backups/printer.Crumflight.cfg ]; then
    mv /usr.data/Crumflight-backups/printer.Crumflight.cfg /usr.data/Crumflight-backups/printer.cfg
fi

if [ "$mode" = "reinstall" ] || [ "$mode" = "update" ]; then
    if [ "$skip_overrides" != "true" ] && [ -f /usr.data/Crumflight-backups/printer.cfg ]; then
        echo
        /usr.data/Crumflight/k1/config-overrides.sh
    fi

    [ -f /usr.data/Crumflight.done ] && rm /usr.data/Crumflight.done

    if [ -f /usr.data/Crumflight-backups/printer.factory.cfg ]; then
        cp /usr.data/Crumflight-backups/printer.factory.cfg /usr.data/printer_data/config/printer.cfg
        DATE_TIME=$(date +"%Y-%m-%d %H:%M:%S")
        sed -i "1s/^/# Modified by Simple AF ${DATE_TIME}\n/" /usr.data/printer_data/config/printer.cfg

        for file in printer.cfg moonraker.conf; do
            [ -f /usr.data/Crumflight-backups/$file ] && rm /usr.data/Crumflight-backups/$file
        done
    elif [ "$mode" = "update" ]; then
        echo "ERROR: Update mode not possible without a pristine factory printer.cfg"
        exit 1
    fi
fi
sync

cp /usr.data/Crumflight/k1/services/S96ipaddress /etc/init.d/
ln -sf /var/log/messages /usr.data/printer_data/logs/

touch /usr.data/Crumflight.done
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
cp /usr.data/printer_data/config/printer.cfg /usr.data/printer_data/config/backups/printer-${TIMESTAMP}.cfg
sync

install_entware $mode
install_webcam $mode
install_boot_display

moonraker_restart_needed=$(install_moonraker $mode; echo $?)
nginx_restart_needed=$(install_nginx $mode; echo $?)
fluidd_restart_needed=$(install_fluidd $mode; echo $?)
mainsail_restart_needed=$(install_mainsail $mode; echo $?)
kamp_restart_needed=$(install_kamp $mode; echo $?)
klipper_restart_needed=$(install_klipper $mode; echo $?)
guppyscreen_restart_needed=$(install_guppyscreen $mode; echo $?)
probe_restart_needed=$(setup_bltouch; echo $?)

if [ -f /usr.data/Crumflight-backups/printer.factory.cfg ]; then
    for file in printer.cfg start_end.cfg fan_control.cfg useful_macros.cfg moonraker.conf sensorless.cfg bltouch_macro.cfg bltouch.cfg bltouch-${model}.cfg; do
        [ -f /usr.data/printer_data/config/$file ] && cp /usr.data/printer_data/config/$file /usr.data/Crumflight-backups/
    done
    [ -f /usr.data/guppyscreen/guppyconfig.json ] && cp /usr.data/guppyscreen/guppyconfig.json /usr.data/Crumflight-backups/
fi

apply_overrides_status=0
if [ "$skip_overrides" != "true" ]; then
    apply_overrides
    apply_overrides_status=$?
fi

/usr.data/Crumflight/k1/update-ip-address.sh
update_ip_address_status=$?

if [ $apply_overrides_status -ne 0 ] || [ $moonraker_restart_needed -ne 0 ] || [ $update_ip_address_status -ne 0 ]; then
    [ "$client" = "cli" ] && restart_moonraker || echo "WARNING: Moonraker restart required"
fi

if [ $moonraker_restart_needed -ne 0 ] || [ $nginx_restart_needed -ne 0 ] || [ $fluidd_restart_needed -ne 0 ] || [ $mainsail_restart_needed -ne 0 ]; then
    if [ "$client" = "cli" ]; then
        echo
        echo "INFO: Restarting Nginx ..."
        /etc/init.d/S50nginx_service restart
    else
        echo "WARNING: NGINX restart required"
    fi
fi

if [ $apply_overrides_status -ne 0 ] || [ $klipper_restart_needed -ne 0 ] || [ $guppyscreen_restart_needed -ne 0 ] || [ $probe_restart_needed -ne 0 ] || [ $kamp_restart_needed -ne 0 ]; then
    if [ "$client" = "cli" ]; then
        echo
        echo "INFO: Restarting Klipper ..."
        /etc/init.d/S55klipper_service restart
    else
        echo "WARNING: Klipper restart required"
    fi
fi

if [ $apply_overrides_status -ne 0 ] || [ $guppyscreen_restart_needed -ne 0 ]; then
    if [ "$client" = "cli" ]; then
        echo
        echo "INFO: Restarting Guppyscreen ..."
        /etc/init.d/S99guppyscreen restart
    else
        echo "WARNING: Guppyscreen restart required"
    fi
fi

echo
/usr.data/Crumflight/k1/tools/check-firmware.sh

exit 0
