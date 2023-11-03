#!/bin/bash

set -e

vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/var/lib/vz/snippets/fcos-base-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/geco-pve/coreos

[[ -x /usr/bin/wget ]]&& download_command="wget --quiet --show-progress --output-document"  || download_command="curl --location --output"

# ==================================================================================================================================================================
# functions()
#

setup_fcoreosct()
{
        local CT_VER=0.19.0
        local ARCH=x86_64
        local OS=unknown-linux-gnu # Linux
        local DOWNLOAD_URL=https://github.com/coreos/butane/releases/download

        [[ -x /usr/local/bin/fcos-ct ]]&& [[ "x$(/usr/local/bin/fcos-ct --version | awk '{print $NF}')" == "x${CT_VER}" ]]&& return 0
        echo "\nSetup Fedora CoreOS config transpiler..."
        rm -f /usr/local/bin/fcos-ct
        ${download_command} /usr/local/bin/fcos-ct ${DOWNLOAD_URL}/v${CT_VER}/butane-${ARCH}-${OS}
        chmod 755 /usr/local/bin/fcos-ct
}


setup_yq()
{
        local YQ_VER=4.35.2
        local DOWNLOAD_URL=https://github.com/mikefarah/yq/releases/download

        [[ -x /usr/local/bin/yq ]]&& [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "xv${YQ_VER}" ]]&& return 0
        echo "\nSetup yaml parser tools yq..."
        rm -f /usr/local/bin/yq
        ${download_command} /usr/local/bin/yq ${DOWNLOAD_URL}/v${YQ_VER}/yq_linux_amd64
        chmod 755 /usr/local/bin/yq
}

# ==================================================================================================================================================================
# main()
#

if [[ "${phase}" == "pre-start" ]]
then
	echo -n "Fedora CoreOS: Preparing...                              "

	setup_fcoreosct
	setup_yq
    echo " "
	YQ="/usr/local/bin/yq --exit-status"

	instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} '.instance-id')"
	args_found="$(qm config ${vmid} | /usr/local/bin/yq '.args')"
	# same cloudinit config ?
	[[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]] && [[  ${args_found} -eq null ]] && {
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
	}

	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]]&& {
		exit 0 # already done
	}

	mkdir -p ${COREOS_FILES_PATH} || exit 1

	# check config
	ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}' 2> /dev/null)"
	cipasswd="$(qm cloudinit dump ${vmid} user | ${YQ} '.password' 2> /dev/null)" || true # can be empty
	cissh="$(qm cloudinit dump ${vmid} user | ${YQ} '.ssh_authorized_keys | ... style = "double" | . style = "flow" ' 2> /dev/null)"
	[[ "x${cipasswd}" != "x" ]]&& VALIDCONFIG=true
	${VALIDCONFIG:-false} || [[ "x${cissh}" == "x" ]]|| VALIDCONFIG=true
	${VALIDCONFIG:-false} || {
		echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
		exit 1
	}

	#checking base block
	[[ -e "${COREOS_TMPLT}" ]]&& {
		echo -n "Fedora CoreOS: Generate block based on template...       "
		cat "${COREOS_TMPLT}" > ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "[done]"
	} || {
	echo -n "Fedora CoreOS: basic template not found,"
	echo -n  "				creating default                          [done]"
	echo -e "# This file is managed by Geco-iT hook-script. Do not edit.\n" > ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".variant = \"fcos\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".version = \"1.5.0\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	}

	echo -n  "Fedora CoreOS: Generate yaml users block...               "
	${YQ} -i ".passwd.users.[0].name = \"${ciuser:-admin}\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".passwd.users.[0].gecos = \"Geco-iT CoreOS Administrator\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".passwd.users.[0].password_hash = \"${cipasswd}\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".passwd.users.[0].groups = [\"sudo\",\"docker\",\"adm,wheel\",\"systemd-journal\"] " ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".passwd.users.[0].ssh_authorized_keys = ${cissh}" ${COREOS_FILES_PATH}/${vmid}.yaml # much simple
#	cissh_length="$(qm cloudinit dump ${vmid} user | ${YQ} '.ssh_authorized_keys | length' 2> /dev/null)"
#	for (( i=0; i < ${cissh_length}; i++ )) # can set multiple ssh keys
#	do
#	ssh_keys="$(qm cloudinit dump ${vmid} user | ${YQ} .ssh_authorized_keys[${i}])"
#	${YQ} -i ".passwd.users.[0].ssh_authorized_keys[${i}] = \"${ssh_keys}\"" ${COREOS_FILES_PATH}/${vmid}.yaml
#	done
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml hostname block...           "
	hostname="$(qm cloudinit dump ${vmid} user | ${YQ} '.hostname' 2> /dev/null)"
	key_index=0
	${YQ} -i ".storage.files[${key_index}].path = \"/etc/hostname\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".storage.files[${key_index}].mode = 0644" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".storage.files[${key_index}].overwrite = true" ${COREOS_FILES_PATH}/${vmid}.yaml
	${YQ} -i ".storage.files[${key_index}].contents.inline = \"${hostname,,}\"" ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"
set -x
	echo -n "Fedora CoreOS: Generate yaml network block...            "
	netcards="$(qm cloudinit dump ${vmid} network | ${YQ} '.config[] | select(.type == "physical").name' 2> /dev/null | wc -l)"
	nameservers="$(qm cloudinit dump ${vmid} network | ${YQ} '.config[] | select(.type == "nameserver").address[]' | paste -s -d ";" -)"
	searchdomain="$(qm cloudinit dump ${vmid} network | ${YQ} '.config[] | select(.type == "nameserver").search[]' | paste -s -d ";" -)"
	key_index=1
	[[ ${netcards} -eq null ]] && ${YQ} -i 'delpaths([["storage","files", 1]])' ${COREOS_FILES_PATH}/${vmid}.yaml # remove networks default block
	for (( i=O; i<${netcards}; i++ ))
	do
		index=$(( ${key_index} + ${i} ))
		macaddr="" ipv4="" netmask4="" gateway4="" ipv6="" gateway6=""  # reset on each run
		macaddr="$(qm cloudinit dump ${vmid} network | ${YQ} .config[${i}].mac_address 2> /dev/null)"
		# ipv4:
		ipv4="$(qm cloudinit dump ${vmid} network | ${YQ} .config[${i}].subnets[0].address 2> /dev/null)" && {
		netmask4="$(qm cloudinit dump ${vmid} network | ${YQ} .config[${i}].subnets[0].netmask 2> /dev/null)"
		gateway4="$(qm cloudinit dump ${vmid} network | ${YQ} .config[${i}].subnets[0].gateway 2> /dev/null)" || true # can be empty
		outputv4="
method=manual
addresses=${ipv4}/${netmask4}
gateway=${gateway4}
dns=${nameservers}
dns-search=${searchdomain}
"
		}	
		# ipv6:
		ipv6="$(qm cloudinit dump ${vmid} network | ${YQ} .config[${i}].subnets[1].address 2> /dev/null)" && {
		gateway6="$(qm cloudinit dump ${vmid} network | ${YQ} .config[${i}].subnets[1].gateway 2> /dev/null)" || true # can be empty
		outputv6="
method=manual
addresses=${ipv6}
gateway=${gateway6}
"
		}
		[[ "${ipv4}" -eq null && "${ipv6}" -eq null ]] && continue			# if ipv4 and ipv6 not set will skip	
		[[ ${index} -gt 1 ]] && ${YQ} -i '.storage.files = (.storage.files | .[0:'${index}'] + [ null ] + .['${index}':]) ' ${COREOS_FILES_PATH}/${vmid}.yaml # appending network block after previous network
		${YQ} -i ".storage.files[${index}].path = \"/etc/NetworkManager/system-connections/net${i}.nmconnection\"" ${COREOS_FILES_PATH}/${vmid}.yaml
		${YQ} -i ".storage.files[${index}].mode = 0600" ${COREOS_FILES_PATH}/${vmid}.yaml
		${YQ} -i ".storage.files[${index}].overwrite = true" ${COREOS_FILES_PATH}/${vmid}.yaml
		output="
[connection]
type=ethernet
id=net${i}
#interface-name=eth${i}
[ethernet]
mac-address=${macaddr}

[ipv4]${outputv4}
[ipv6]${outputv6}
"		${YQ} -i '.storage.files['${index}'].contents.inline =  strenv(output) ' ${COREOS_FILES_PATH}/${vmid}.yaml
	done
	echo "[done]"

	echo -n "Fedora CoreOS: Generate ignition config...               "
	/usr/local/bin/fcos-ct 	--pretty --strict \
				--output ${COREOS_FILES_PATH}/${vmid}.ign \
				${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
	[[ $? -eq 0 ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[done]"

	# save cloudinit instanceid
	echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id

	# check vm config (no args on first boot)
	qm config ${vmid} --current | grep -q ^args || {
		echo -n "Fedora CoreOS: set args com.coreos/config on VM${vmid}... "
		rm -f /var/lock/qemu-server/lock-${vmid}.conf
		pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
			echo "[failed]"
			exit 1
		}
		touch /var/lock/qemu-server/lock-${vmid}.conf
		#echo -n "Fedora CoreOS: Cloud Init Success, rebooting to main os  "
		#qm reset ${vmid} -skiplock true
		# hack for reload new ignition file
		echo -n "WARNING: New generated Fedora CoreOS ignition settings, we must restart vm..."
		qm stop ${vmid} && sleep 2 && qm start ${vmid} &
		exit 0
	}
fi

exit 0
