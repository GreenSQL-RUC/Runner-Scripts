#!/usr/bin/env bash
#
# node_info.sh - print the identity of this machine as "key: value" lines, for
# summary.txt (run_warm_stepup.sh). Runs from several machines of one model
# (e.g. the two Latitude 7490s) can then be told apart and checked for
# BIOS/microcode/driver differences. query_runner writes the same facts per
# run_id to query_runinfo_<db>.csv.
#
first() { [ -r "$1" ] && head -n1 "$1" 2>/dev/null; }
cpuinfo() { awk -F': *' -v k="$1" '$1 ~ "^"k"[ \t]*$" { print $2; exit }' /proc/cpuinfo; }

turbo=""
if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    turbo="no_turbo=$(first /sys/devices/system/cpu/intel_pstate/no_turbo)"
elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
    turbo="boost=$(first /sys/devices/system/cpu/cpufreq/boost)"
fi
packages=$(cat /sys/devices/system/cpu/cpu*/topology/physical_package_id 2>/dev/null | sort -u | wc -l)

printf '%-20s%s\n' \
    "host:"            "$(hostname -f 2>/dev/null || hostname)" \
    "cpu_model:"       "$(cpuinfo 'model name')" \
    "cpu_packages:"    "$packages" \
    "cpu_count:"       "$(nproc --all)" \
    "microcode:"       "$(cpuinfo microcode)" \
    "bios:"            "$(first /sys/class/dmi/id/bios_vendor) $(first /sys/class/dmi/id/bios_version) ($(first /sys/class/dmi/id/bios_date))" \
    "product:"         "$(first /sys/class/dmi/id/sys_vendor) $(first /sys/class/dmi/id/product_name)" \
    "memory_gb:"       "$(awk '/MemTotal/ { printf "%.0f", $2 / 1048576 }' /proc/meminfo)" \
    "freq_driver:"     "$(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)" \
    "governor:"        "$(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" \
    "turbo:"           "$turbo" \
    "kernel:"          "$(uname -r)" \
    "rapl_zones:"      "$(for z in /sys/class/powercap/intel-rapl:*; do [ -r "$z/name" ] && printf '%s ' "$(cat "$z/name")"; done)"
