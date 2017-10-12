#!/bin/bash
# Script informed by the collectd monitoring script for smartmontools (using smartctl)
# by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012
# source at: http://devel.dob.sk/collectd-scripts/

# TODO: This probably needs to be a little more complex.  The raw numbers can have more
#       data in them than you'd think.
#       http://arstechnica.com/civis/viewtopic.php?p=22062211

# NOTES: Added smartmon scrape for SCSI drives, specifically targeting storage nodes where multiple
#        drives are connected using the same SAS Address.  

disks="$(/usr/sbin/smartctl --scan | awk '{print $1 "|" $3}')"

parse_smartctl_attributes_awk="$(cat << 'SMARTCTLAWK'
$1 ~ /^[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
  gsub(/-/, "_");
  printf "%s_value{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $4
  printf "%s_worst{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $5
  printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $6
  printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", $2, labels, $1, $10
}
SMARTCTLAWK
)"

smartmon_attrs="$(cat << 'SMARTMONATTRS'
airflow_temperature_cel
command_timeout
current_pending_sector
end_to_end_error
erase_fail_count
g_sense_error_rate
hardware_ecc_recovered
host_reads_mib
host_reads_32mib
host_writes_mib
host_writes_32mib
load_cycle_count
media_wearout_indicator
nand_writes_1gib
offline_uncorrectable
power_cycle_count
power_on_hours
program_fail_count
raw_read_error_rate
reallocated_sector_ct
reported_uncorrect
sata_downshift_count
spin_retry_count
spin_up_time
start_stop_count
temperature_celsius
total_lbas_read
total_lbas_written
udma_crc_error_count
unsafe_shutdown_count
workld_host_reads_perc
workld_media_wear_indic
workload_minutes
SMARTMONATTRS
)"
smartmon_attrs="$(echo ${smartmon_attrs} | xargs | tr ' ' '|')"

parse_smartctl_attributes() {
  local disk="$1"
  local disk_type="$2"
  local labels="disk=\"${disk}\",type=\"${disk_type}\""
  local vars="$(echo "${smartmon_attrs}" | xargs | tr ' ' '|')"
  sed 's/^ \+//g' \
    | awk -v labels="${labels}" "${parse_smartctl_attributes_awk}" 2>/dev/null \
    | tr A-Z a-z \
    | grep -E "(${smartmon_attrs})"
}

parse_smartctl_scsi_attributes() {
  local disk="$1"
  local disk_type="$2"
  local phy_id="$3"
  local sas_address="$4"
  #local data=$(cat)
  #local phy_id=$(echo "${data}" | awk '/attached phy identifier =/{printf("%s",$5);exit;}')
  local labels="disk=\"${disk}\",type=\"${disk_type}\",phy_id=\"${phy_id}\",sas_address=\"${sas_address}\""
  
  awk -v tag="$labels" '
  /Current Drive Temperature:/{printf("current_drive_temperature_cel_value{"tag"} %s\n",$4);}
  /Drive Trip Temperature:/{printf("drive_trip_temperature_cel_value{"tag"} %s\n",$4);}
  /Specified cycle count over device lifetime:/{printf("specified_start_stop_cycles_lifetime_value{"tag"} %s\n",$7);}
  /Accumulated start-stop cycles:/{printf("accumulated_start_stop_cycles_value{"tag"} %s\n",$4);}
  /Specified load-unload count over device lifetime:/{printf("specified_load_unload_cycles_lifetime_value{"tag"} %s\n",$7);}
  /Accumulated load-unload cycles:/{printf("accumulated_load_unload_cycles_value{"tag"} %s\n",$4);}
  /Elements in grown defect list:/{printf("elements_in_grown_defect_list_value{"tag"} %s\n",$6);}
  '
}

parse_smartctl_info() {
  local -i smart_available=0 smart_enabled=0 smart_healthy=0
  local disk="$1" disk_type="$2" phy_id="$3" sas_address="$4"
  #local data=$(cat)
  #local phy_id=$(echo "${data}" | awk '/attached phy identifier =/{printf("%s",$5);exit;}')

  while read line ; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g')"
    case "${info_type}" in
      Model_Family) model_family="${info_value}" ;;
      Device_Model) device_model="${info_value}" ;;
      Serial_Number|Serial_number) serial_number="${info_value}" ;;
      Firmware_Version) fw_version="${info_value}" ;;
      Vendor) vendor="${info_value}" ;;
      Product) product="${info_value}" ;;
      Revision) revision="${info_value}" ;;
      Logical_Unit_id) lun_id="${info_value}" ;;
    esac
    if [[ "${info_type}" == 'SMART_support_is' ]] ; then
      case "${info_value:0:7}" in
        Enabled) smart_enabled=1 ;;
        Availab) smart_available=1 ;;
        Unavail) smart_available=0 ;;
      esac
    fi
    if [[ "${info_type}" == 'SMART_overall-health_self-assessment_test_result' ]] ; then
      case "${info_value:0:6}" in
        PASSED) smart_healthy=1 ;;
      esac
    elif [[ "${info_type}" == 'SMART_Health_Status' ]] ; then
      case "${info_value:0:2}" in
        OK) smart_healthy=1 ;;
      esac
    fi
  done
  if [[ -n "${vendor}" ]] ; then
    echo "device_info{disk=\"${disk}\",type=\"${disk_type}\",vendor=\"${vendor}\",product=\"${product}\",revision=\"${revision}\",serial_number=\"${serial_number}\",lun_id=\"${lun_id}\"} 1"
  else
    echo "device_info{disk=\"${disk}\",type=\"${disk_type}\",model_family=\"${model_family}\",device_model=\"${device_model}\",serial_number=\"${serial_number}\",firmware_version=\"${fw_version}\"} 1"
  fi
  echo "device_smart_available{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_available}"
  echo "device_smart_enabled{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_enabled}"

  echo "device_smart_healthy{disk=\"${disk}\",type=\"${disk_type}\",phy_id=\"${phy_id}\",sas_address=\"${sas_address}\"} ${smart_healthy}"
  #if [ ${type} = "scsi" ]; then
  #  echo "device_smart_healthy{disk=\"${disk}\",type=\"${disk_type}\",phy_id=\"${phy_id}\",sas_address=\"${sas_address}\"} ${smart_healthy}"
  #else
  #  echo "device_smart_healthy{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_healthy}"
  #fi
}

#parse_smartctl_sas_info() {
#  awk '/attached phy identifier =/{printf("%s",$5);exit;}'
#}

parse_smartctl_sas_info() {
  # Extract SAS info from Protocol Specific port log page for SAS SSP
  # exit after 1st match
  local data=$(cat)
  # Attached Physical Identifier
  local phy_id="$(echo "${data}" | awk '/attached phy identifier =/{printf("%s",$5);exit;}')"
  # Attached SAS Address  
  local sas_address="$(echo "${data}" | awk '/attached SAS address =/{printf("%s",$5);exit;}')"
  # return values
  echo "${phy_id} ${sas_address}"
}


output_format_awk="$(cat << 'OUTPUTAWK'
BEGIN { v = "" }
v != $1 {
  print "# HELP smartmon_" $1 " SMART metric " $1;
  print "# TYPE smartmon_" $1 " gauge";
  v = $1
}
{print "smartmon_" $0}
OUTPUTAWK
)"

format_output() {
  sort \
  | awk -F'{' "${output_format_awk}"
}

smartctl_version="$(/usr/sbin/smartctl -V | head -n1  | awk '$1 == "smartctl" {print $2}')"

echo "smartctl_version{version=\"${smartctl_version}\"} 1" | format_output

if [[ "$(expr "${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]] ; then
  exit
fi

device_list="$(/usr/sbin/smartctl --scan-open | awk '{print $1 "|" $3}')"

for device in ${device_list}; do
  disk="$(echo ${device} | cut -f1 -d'|')"
  type="$(echo ${device} | cut -f2 -d'|')"
  echo "smartctl_run{disk=\"${disk}\",type=\"${type}\"}" $(TZ=UTC date '+%s')
  # Get the SMART information and health
  #/usr/sbin/smartctl -i -H -d "${type}" "${disk}" | parse_smartctl_info "${disk}" "${type}"
  # Get the SMART attributes
  if [ ${type} = "scsi" ]; then
    read phy_id sas_address <<< "$(/usr/sbin/smartctl -x -d "${type}" "${disk}" | parse_smartctl_sas_info)"
    /usr/sbin/smartctl -i -H -d "${type}" "${disk}" | parse_smartctl_info "${disk}" "${type}" "${phy_id}" "${sas_address}"
    /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk}" "${type}" "${phy_id}" "${sas_address}"
  else
    /usr/sbin/smartctl -i -H -d "${type}" "${disk}" | parse_smartctl_info "${disk}" "${type}"
    /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}"
  fi
done | format_output
