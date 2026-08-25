#!/data/data/com.termux/files/usr/bin/env bash

adb tcpip 35555 && sleep 4

adb shell dumpsys deviceidle disable
adb shell dumpsys deviceidle whitelist +com.termux

adb shell am set-standby-bucket com.termux active

adb shell settings put global settings_enable_monitor_phantom_procs false
adb shell settings put global power_manager_constants "sustained_performance_mode=1"
adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"

# adb devices -l

# scp *.jar termux:Everest/plugins
# cp target/CoreProtect-24.0.jar ~/Projects/Everest/plugins/CoreProtect-24.0.jar
# scp target/CoreProtect-24.0.jar termux:Everest/plugins/CoreProtect-24.0.jar

# ssh-copy-id -i ~/.ssh/id_ed25519 termux
# ssh-add ~/.ssh/id_ed25519
# ssh-add -l
