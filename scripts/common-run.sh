#!/usr/bin/env bash

announce_startup() (
	local postfix_account opendkim_account

	DISTRO="unknown"
	[ -f /etc/lsb-release ] && . /etc/lsb-release
	[ -f /etc/os-release ] && . /etc/os-release
	if [ -f /etc/alpine-release ]; then
		DISTRO="alpine"
	else
		DISTRO="${ID}"
	fi
	echo -e "${gray}${emphasis}★★★★★ ${reset}${lightblue}POSTFIX STARTING UP${reset} ${gray}(${reset}${emphasis}${DISTRO}${reset}${gray})${emphasis} ★★★★★${reset}"

	postfix_account="$(cat /etc/passwd | grep -E "^postfix" | cut -f3-4 -d:)"
	opendkim_account="$(cat /etc/passwd | grep -E "^opendkim" | cut -f3-4 -d:)"

	notice "System accounts: ${emphasis}postfix${reset}=${orange_emphasis}${postfix_account}${reset}, ${emphasis}opendkim${reset}=${orange_emphasis}${opendkim_account}${reset}. Careful when switching distros."
)

setup_timezone() {
	if [[ ! -z "$TZ" ]]; then
		TZ_FILE="$(zone_info_dir)/$TZ"
		if [ -f "$TZ_FILE" ]; then
			notice "Setting container timezone to: ${emphasis}$TZ${reset}"
			ln -snf "$TZ_FILE" /etc/localtime
			echo "$TZ" > /etc/timezone
		else
			warn "Cannot set timezone to: ${emphasis}$TZ${reset} -- this timezone does not exist."
		fi
	else
		info "Not setting any timezone for the container"
	fi
}

check_environment_sane() (
	if touch /tmp/test; then
		debug "/tmp writable."
		rm /tmp/test
	else
		error "Could not write to /tmp. Please mount it to an empty dir if the image is read-only."
		exit
	fi

)

rsyslog_log_format() {
	local log_format="${LOG_FORMAT}"
	if [[ -z "${log_format}" ]]; then
		log_format="plain"
	fi
	info "Using ${emphasis}${log_format}${reset} log format for rsyslog."
	sed -i -E "s/<log-format>/${log_format}/" /etc/rsyslog.conf
}

logrotate_remove_duplicate_mail_log() {
	if egrep -q '^/var/log/mail.log' /etc/logrotate.d/logrotate.conf; then
		info "Removing /var/log/mail.log from /etc/logrotate.d/rsyslog"
		sed -i -E '/^\/var\/log\/mail.log/d' /etc/logrotate.d/rsyslog
	fi
}

anon_email_log() {
	local anon_email="${ANONYMIZE_EMAILS}"
	if [[ "${anon_email}" == "true" || "${anon_email}" == "1" || "${anon_email}" == "yes" || "${anon_email}" == "y" ]]; then
		anon_email="default"
	fi
	if [[ -n "${anon_email}" && "${anon_email}" != "0" ]]; then
		notice "Using ${emphasis}${anon_email}${reset} filter for email anonymization."
		sed -i -E "s/<anon-email-format>/${anon_email}/" /etc/rsyslog.conf
		sed -i -E '
		/^\s*#\s*<email-anonymizer>\s*$/,/^\s*#\s*<\/email-anonymizer>\s*$/{
			/^\s*#\s*<email-anonymizer>\s*$/n
			/^\s*#\s*<\/email-anonymizer>\s*$/! {
			s/(\s*)#(.*)$/\1\2/g
			}
		}
		' /etc/rsyslog.conf
	else
		notice "Emails in the logs will not be anonymized. Set ${emphasis}ANONYMIZE_EMAILS${reset} to enable this feature."
	fi
}

setup_conf() {
	local srcfile
	local dstfile
	local base

	# Make sure the /etc/postfix directory exists
	mkdir -p /etc/postfix
	# Make sure all the neccesary files (and directories) exist
	if [[ -d "/etc/postfix.template/" ]]; then
		for srcfile in /etc/postfix.template/*; do
			base="$(basename $srcfile)"
			dstfile="/etc/postfix/$base"

			if [[ ! -e "$dstfile" ]]; then
				debug "Creating ${emphasis}$dstfile${reset}."
				cp -r "$srcfile" "$dstfile"
			fi
		done
	fi
}

reown_folders() {
	mkdir -p /var/spool/postfix/pid /var/spool/postfix/dev /var/spool/postfix/private /var/spool/postfix/public 
	if [[ "${SKIP_ROOT_SPOOL_CHOWN}" == "1" ]]; then
		warn "${emphasis}SKIP_ROOT_SPOOL_CHOWN${reset} is set. Script will not chown ${emphasis}/var/spool/postfix/${reset}. Make sure you know what you're doing."
	else
		debug "Reowning ${emphasis}root: /var/spool/postfix/${reset}"
		if ! chown root: /var/spool/postfix/; then
			warn "Cannot reown ${emphasis}root:${reset} for ${emphasis}/var/spool/postfix/${reset}. Your installation might be broken."
		fi

		debug "Reowning ${emphasis}root: /var/spool/postfix/pid/${reset}"
		if ! chown root: /var/spool/postfix/pid; then
			warn "Cannot reown ${emphasis}root:${reset} for ${emphasis}/var/spool/postfix/pid/${reset}. Your installation might be broken."
		fi
	fi

	debug "Reowning ${emphasis}postfix:postdrop /var/spool/postfix/private/${reset}"
	if ! chown -R postfix:postdrop /var/spool/postfix/private; then
		warn "Cannot reown ${emphasis}postfix:postdrop${reset} for ${emphasis}/var/spool/postfix/private${reset}. Your installation might be broken."
	fi
	debug "Reowning ${emphasis}postfix:postdrop /var/spool/postfix/public/${reset}"
	if ! chown -R postfix:postdrop /var/spool/postfix/public; then
		warn "Cannot reown ${emphasis}postfix:postdrop${reset} for ${emphasis}/var/spool/postfix/public${reset}. Your installation might be broken."
	fi

	do_postconf -e "manpage_directory=/usr/share/man"

	# postfix set-permissions complains if documentation files do not exist
	postfix -c /etc/postfix/ set-permissions > /dev/null 2>&1 || true
}

postfix_enable_chroot() {
	# Fix Kubernetes not mounting NSS configuration (https://github.com/kubernetes/kubernetes/issues/71082)
	if [[ ! -e /etc/nsswitch.conf ]]; then
		notice "Creating file ${emphasis}/etc/nsswitch.conf${reset}. See https://github.com/kubernetes/kubernetes/issues/71082"
		if ! echo 'hosts: files dns' > /etc/nsswitch.conf; then
			warn "Could not write ${emphasis}/etc/nsswitch.conf${reset}. Postfix will still start, but check https://github.com/kubernetes/kubernetes/issues/71082 for more info."
		fi
	fi

	# Adapted from example Linux chroot in Postfix sources examples/chroot-setup/LINUX2
	info "Preparing files for Postfix chroot:"

	if [[ -z "${POSTFIXD_DIR}" ]]; then
		POSTFIXD_DIR=/var/spool/postfix
	fi
	if [[ -z "${POSTFIXD_ETC}" ]]; then
		POSTFIXD_ETC="${POSTFIXD_DIR}/etc"
	fi

	local zoneinfo="$(zone_info_dir)"
	if [[ -z "${POSTFIX_ZIF}" ]]; then
		POSTFIXD_ZIF="${POSTFIXD_DIR}${zoneinfo}"
	fi
	(
		umask 022
		[[ ! -d "$POSTFIXD_ZIF" ]]  && mkdir -pv                  $POSTFIXD_ZIF  || true
		[[ ! -d "$POSTFIXD_DIR" ]]  && mkdir -pv                  $POSTFIXD_DIR  || true
		[[ ! -d "$POSTFIXD_ETC" ]]  && mkdir -pv                  $POSTFIXD_ETC  || true
		if [[ -h /etc/localtime ]]; then
			# Assume it links to ZoneInfo or something that is accessible from chroot
			echo "Copying ${zoneinfo} -> ${POSTFIXD_ZIF}"
			cp -fPpr ${zoneinfo}/* ${POSTFIXD_ZIF}/
			cp -fPpv /etc/localtime "$POSTFIXD_ETC/"
		fi
		[[ -e /etc/localtime ]]     && cp -fpv /etc/localtime     $POSTFIXD_ETC  || true
		[[ -e /etc/nsswitch.conf ]] && cp -fpv /etc/nsswitch.conf $POSTFIXD_ETC  || true
		[[ -e /etc/resolv.conf ]]   && cp -fpv /etc/resolv.conf   $POSTFIXD_ETC  || true
		[[ -e /etc/services ]]      && cp -fpv /etc/services      $POSTFIXD_ETC  || true
		[[ -e /etc/host.conf ]]     && cp -fpv /etc/host.conf     $POSTFIXD_ETC  || true
		[[ -e /etc/hosts ]]         && cp -fpv /etc/hosts         $POSTFIXD_ETC  || true
		[[ -e /etc/passwd ]]        && cp -fpv /etc/passwd        $POSTFIXD_ETC  || true
	) | sed 's/^/        /g'
}

postfix_upgrade_default_database_type() {
	# Debian (and Ubuntu?) defalt to "hash:" and "btree:" database types. These have been removed from Alpine due to
	# licence issues. To ensure compatiblity across images of this service across different distributions, we just
	# select "lmdb:" as the default database type -- this should be supported in every distro.
	local default_database_type="$(get_postconf "default_database_type")"	

	if [[ "${default_database_type}" != "lmdb" ]]; then
		notice "Switching ${emphasis}default_database_type${reset} to ${emphasis}lmdb${reset} to ensure cross-distro compatibility."
		do_postconf -e "default_database_type=lmdb"
	fi
}

postfix_upgrade_conf() {
	local maincf=/etc/postfix/main.cf
	local line
	local entry
	local filename
	local OLD_IFS
	
	# Check for any references to the old "hash:" and "btree:" databases and replace them with "lmdb:"
	if cat "$maincf" | egrep -v "^#" | egrep -q "(hash|btree):"; then
		warn "Detected old hash: and btree: references in the config file, which are not supported anymore. Upgrading to lmdb:"
		sed -i -E 's/(hash|btree):/lmdb:/g' "$maincf"
		OLD_IFS="$IFS"
		IFS=$'\n'
		# Recreate aliases
		for line in $(cat "$maincf" | egrep 'lmdb:[^,]+' | sort | uniq); do
			entry="$(echo "$line" | egrep -o 'lmdb:[^,]+')"
			filename="$(echo "$entry" | cut -d: -f2)"
			if [[ -f "$filename" ]]; then
				if echo "$line" | egrep -q '[ \t]*alias.*'; then
					debug "Creating new postalias for ${emphasis}$entry${reset}."
					postalias $entry
				else
					debug "Creating new postmap for ${emphasis}$entry${reset}."
					postmap $entry
				fi
			fi
		done
		IFS="$OLD_IFS"
	else
		debug "No upgrade of hashes needed needed."
	fi
}

postfix_upgrade_daemon_directory() {
	local dir_debian="/usr/lib/postfix/sbin" # Debian, Ubuntu
	local dir_alpine="/usr/libexec/postfix"  # Alpine


	# Some people will keep the configuration of postfix on an external drive, although this is not strictly necessary by this
	# image. And when they switch between different distributions (Alpine -> Debian and vice versa), the image will fail with the
	# old configuration. This is a quick and dirty check to solve this issue so we don't get issues like these:
	# https://github.com/bokysan/docker-postfix/issues/147
	local daemon_directory="$(get_postconf "daemon_directory")"

	if [[ "${daemon_directory}" == "${dir_debian}" ]] && [[ ! -d "${dir_debian}" ]] && [[ -d "${dir_alpine}" ]]; then
		warn "You're switching from Debian/Ubuntu distribution to Alpine. Changing ${emphasis}daemon_directory = ${dir_alpine}${reset}, otherwise this image will not run.\r\n        To avoid these warnings in the future, it is suggested ${emphasis}NOT${reset} to link ${emphasis}/etc/postfix${reset} to a volume, and let this image manage it itself."
		do_postconf -e "daemon_directory=${dir_alpine}"
		daemon_directory="${dir_alpine}"
	elif [[ "${daemon_directory}" == "${dir_alpine}" ]] && [[ ! -d "${dir_alpine}" ]] && [[ -d "${dir_debian}" ]]; then
		warn "You're switching from Alpine to Debian/Ubuntu distribution. Changing ${emphasis}daemon_directory = ${dir_debian}${reset}, otherwise this image will not run.\r\n        To avoid these warnings in the future, it is suggested ${emphasis}NOT${reset} to link ${emphasis}/etc/postfix${reset} to a volume, and let this image manage it itself."
		do_postconf -e "daemon_directory=${dir_debian}"
		daemon_directory="${dir_debian}"
	fi

	if [[ ! -d "${daemon_directory}" ]]; then
		error "Your ${emphasis}daemon_directory${reset} is set to ${emphasis}${daemon_directory}${reset} but it does not exist. Postfix startup will most likely fail."
	else
		# Ensure that daemon_directory is owned by root
		chown root:root "${daemon_directory}"
	fi
}

postfix_disable_utf8() {
	local smtputf8_enable="$(get_postconf "smtputf8_enable")"

	if [[ -f /etc/alpine-release ]] && [[ "${smtputf8_enable}" == "yes" ]]; then
		debug "Running on Alpine. Setting ${emphasis}smtputf8_enable${reset}=${emphasis}no${reset}, as Alpine does not have proper libraries to handle UTF-8"
		do_postconf -e smtputf8_enable=no
	elif [[ ! -f /etc/alpine-release ]] && [[ "${smtputf8_enable}" == "no" ]]; then
		debug "Running on non-Alpine system. Setting ${emphasis}smtputf8_enable${reset}=${emphasis}yes${reset}."
		do_postconf -e smtputf8_enable=yes
	fi
}

postfix_create_aliases() {
	touch /etc/postfix/aliases
	postalias /etc/postfix/aliases
}

postfix_disable_local_mail_delivery() {
	do_postconf -e mydestination=
}

postfix_disable_domain_relays() {
	do_postconf -e relay_domains=
}

postfix_increase_header_size_limit() {
	do_postconf -e "header_size_limit=4096000"
}

postfix_restrict_message_size() {
	if [[ -n "${MESSAGE_SIZE_LIMIT}" ]]; then
		deprecated "${emphasis}MESSAGE_SIZE_LIMIT${reset} variable is deprecated. Please use ${emphasis}POSTFIX_message_size_limit${reset} instead."
		POSTFIX_message_size_limit="${MESSAGE_SIZE_LIMIT}"
	fi

	if [[ -n "${POSTFIX_message_size_limit}" ]]; then
		notice "Restricting message_size_limit to: ${emphasis}${POSTFIX_message_size_limit} bytes${reset}"
	else
		info "Using ${emphasis}unlimited${reset} message size."
		POSTFIX_message_size_limit=0
	fi
}

postfix_reject_invalid_helos() {
	do_postconf -e smtpd_delay_reject=yes
	do_postconf -e smtpd_helo_required=yes
	# Fast reject -- reject straight away when the client is connecting
	do_postconf -e "smtpd_client_restrictions=permit_mynetworks,permit_sasl_authenticated,reject"
	# Reject / accept on EHLO / HELO command
	do_postconf -e "smtpd_helo_restrictions=permit_mynetworks,reject_invalid_helo_hostname,permit"
	# Delayed reject -- reject on MAIL FROM command. Not strictly neccessary to have both, but doesn't hurt
	do_postconf -e "smtpd_sender_restrictions=permit_mynetworks,reject"
}

postfix_set_hostname() {
    local ip
    local hostname
	do_postconf -# myhostname
	if [[ -z "$POSTFIX_myhostname" ]] && [[ "${AUTOSET_HOSTNAME}" == "1" ]]; then
		warn "Both ${emphasis}POSTFIX_myhostname${reset} and ${emphasis}AUTOSET_HOSTNAME${reset} are set. ${emphasis}POSTFIX_myhostname${reset} will take precedence and ${emphasis}AUTOSET_HOSTNAME${reset} will be ignored."
	fi

	if [[ -z "$POSTFIX_myhostname" ]]; then
		POSTFIX_myhostname="${HOSTNAME}"
	elif [[ "${AUTOSET_HOSTNAME}" == "1" ]]; then
		ip=$(get_public_ip)
		hostname=$(dig +short -x $IP)
		# Remove the trailing dot
		hostname="${hostname%.}"
		notice "Automatically setting Postfix hostname to ${emphasis}${hostname}${reset} based on your public IP address ${emphasis}${ip}${reset}..."
		POSTFIX_myhostname="${hostname}"
	fi
}

postfix_set_relay_tls_level() {
	if [ ! -z "$RELAYHOST_TLS_LEVEL" ]; then
		deprecated "${emphasis}RELAYHOST_TLS_LEVEL${reset} variable is deprecated. Please use ${emphasis}POSTFIX_smtp_tls_security_level${reset} instead."
		POSTFIX_smtp_tls_security_level="$RELAYHOST_TLS_LEVEL"
	fi

	if [ -z "$POSTFIX_smtp_tls_security_level" ]; then
		info "Setting smtp_tls_security_level: ${emphasis}may${reset}"
		POSTFIX_smtp_tls_security_level="may"
	fi
}

postfix_setup_relayhost() {
	if [ ! -z "$RELAYHOST" ]; then
		noticen "Forwarding all emails to ${emphasis}$RELAYHOST${reset}"
		do_postconf -e "relayhost=$RELAYHOST"
		# Alternately, this could be a folder, like this:
		# smtp_tls_CApath
		do_postconf -e "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt"

		file_env 'RELAYHOST_PASSWORD'

		# Allow to overwrite RELAYHOST in the sasl_passwd file with SASL_RELAYHOST variable if specified
		if [ -z "$SASL_RELAYHOST" ]; then
			SASL_RELAYHOST=$RELAYHOST
		fi

		if [ -n "$RELAYHOST_USERNAME" ] && [ -n "$RELAYHOST_PASSWORD" ]; then
			echo -e " using username ${emphasis}$RELAYHOST_USERNAME${reset} and password ${emphasis}(redacted)${reset}."
			if [[ -f /etc/postfix/sasl_passwd ]]; then
				if ! grep -q -F "$SASL_RELAYHOST $RELAYHOST_USERNAME:$RELAYHOST_PASSWORD" /etc/postfix/sasl_passwd; then
					sed -i -e "/^$SASL_RELAYHOST .*$/d" /etc/postfix/sasl_passwd
					echo "$SASL_RELAYHOST $RELAYHOST_USERNAME:$RELAYHOST_PASSWORD" >> /etc/postfix/sasl_passwd
				fi
			else
				echo "$SASL_RELAYHOST $RELAYHOST_USERNAME:$RELAYHOST_PASSWORD" >> /etc/postfix/sasl_passwd
			fi
			postmap lmdb:/etc/postfix/sasl_passwd
			chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.lmdb
			chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.lmdb

			do_postconf -e "smtp_sasl_auth_enable=yes"
			do_postconf -e "smtp_sasl_password_maps=lmdb:/etc/postfix/sasl_passwd"
			do_postconf -e "smtp_sasl_security_options=noanonymous"
			do_postconf -e "smtp_sasl_tls_security_options=noanonymous"
		else
			echo -e " without any authentication. ${emphasis}Make sure your server is configured to accept emails coming from this IP.${reset}"
		fi
	else
		notice "Postfix is configured to deliver messages directly (without relaying). ${emphasis}Make sure your DNS is setup properly!${reset} If unsure, read the docs."
		do_postconf -# relayhost
		do_postconf -# smtp_sasl_auth_enable
		do_postconf -# smtp_sasl_password_maps
		do_postconf -# smtp_sasl_security_options
	fi
}

postfix_setup_xoauth2_pre_setup() {
	file_env 'XOAUTH2_CLIENT_ID'
	file_env 'XOAUTH2_SECRET'
	if [ -n "$XOAUTH2_CLIENT_ID" ] || [ -n "$XOAUTH2_SECRET" ]; then
		cat <<EOF > /etc/sasl-xoauth2.conf
{
  "client_id": "${XOAUTH2_CLIENT_ID}",
  "client_secret": "${XOAUTH2_SECRET}",
  "log_to_syslog_on_failure": "${XOAUTH2_SYSLOG_ON_FAILURE:-no}",
  "log_full_trace_on_failure": "${XOAUTH2_FULL_TRACE:-no}",
  "token_endpoint": "${XOAUTH2_TOKEN_ENDPOINT:-https://accounts.google.com/o/oauth2/token}"
}
EOF

		if [ -z "$RELAYHOST" ] || [ -z "${RELAYHOST_USERNAME}" ]; then
			error "You need to specify RELAYHOST and RELAYHOST_USERNAME otherwise Postfix will not run!"
			exit 1
		fi

		# Note that this is not an error. sasl-xoauth2 expect the password to be stored
		# in a file, which is referenced by the smtp_sasl_password_maps file.
		export RELAYHOST_PASSWORD_FILENAME=""
		export RELAYHOST_PASSWORD="/var/spool/postfix/xoauth2-tokens/${RELAYHOST_USERNAME}"

		if [ ! -d "/var/spool/postfix/xoauth2-tokens" ]; then
			mkdir -p "/var/spool/postfix/xoauth2-tokens"
		fi

		if [ ! -f "/var/spool/postfix/xoauth2-tokens/${RELAYHOST_USERNAME}" ] && [ -n "$XOAUTH2_INITIAL_ACCESS_TOKEN" ] && [ -n "$XOAUTH2_INITIAL_REFRESH_TOKEN" ]; then
			cat <<EOF > "/var/spool/postfix/xoauth2-tokens/${RELAYHOST_USERNAME}"
{
	"access_token" : "${XOAUTH2_INITIAL_ACCESS_TOKEN}",
	"refresh_token" : "${XOAUTH2_INITIAL_REFRESH_TOKEN}",
	"expiry" : "0"
}
EOF
		fi
		chown -R postfix:root "/var/spool/postfix/xoauth2-tokens"
	fi
}

postfix_setup_xoauth2_post_setup() {
	local other_plugins
	local plugin_viewer="pluginviewer"
	if [ -n "$XOAUTH2_CLIENT_ID" ] || [ -n "$XOAUTH2_SECRET" ]; then
		do_postconf -e 'smtp_sasl_security_options='
		do_postconf -e 'smtp_sasl_mechanism_filter=xoauth2'
		do_postconf -e 'smtp_tls_session_cache_database=lmdb:${data_directory}/smtp_scache'
	else
		# So, this fix should solve the issue #106, when password in the 'smtp_sasl_password_maps' was
		# read as file instead of the actual password. It turns out that the culprit is the sasl-xoauth2
		# plugin, which expect the filename in place of the password. And as the plugin injects itself
		# automatically in the list of SASL login mechanisms, it tries to read the password as a file and --
		# naturally -- fails.
		# 
		# The fix is therefore simple: If we're not using OAuth2, we remove the plugin from the list and
		# keep all the plugins installed.

		if hash saslpluginviewer > /dev/null 2>&1; then
			# Ubuntu/Debian have renamed pluginviewer to saslpluginviewer so this fails with those distros.
			plugin_viewer="saslpluginviewer"
		fi
		other_plugins="$(${plugin_viewer} -c | grep Plugin | cut -d\  -f2 | cut -c2- | rev | cut -c2- | rev | grep -v EXTERNAL | grep -v sasl-xoauth2 | tr '\n' ',' | rev | cut -c2- | rev | convert_plugin_names_to_filter_names)"
		do_postconf -e "smtp_sasl_mechanism_filter=${other_plugins}"
	fi
}

postfix_setup_smtpd_sasl_auth() {
	local first_bad_user bad_users mydomain message
	local _user _pwd
	if [ ! -z "$SMTPD_SASL_USERS" ]; then
		info "Enable smtpd sasl auth."
		do_postconf -e "smtpd_sasl_auth_enable=yes"
		do_postconf -e "broken_sasl_auth_clients=yes"
		
		[ ! -d /etc/postfix/sasl ] && mkdir /etc/postfix/sasl
		cat > /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5 NTLM
EOF
		[[ ! -d /etc/sasl2 ]] && mkdir /etc/sasl2
		ln -s -f /etc/postfix/sasl/smtpd.conf /etc/sasl2/

		bad_users=""
		mydomain="$(postconf -h mydomain)"
		# sasldb2
		echo $SMTPD_SASL_USERS | tr , \\n > /tmp/passwd
		while IFS=':' read -r _user _pwd; do
			# Fix for issue https://github.com/bokysan/docker-postfix/issues/192
			if [[ "$_user" = *@* ]]; then
				echo $_pwd | saslpasswd2 -p -c $_user
			else
				if [[ -z "$bad_users" ]]; then
					bad_users="${emphasis}${_user}${reset}"
					first_bad_user="${_user}"
				else
					bad_users="${bad_users},${emphasis}${_user}${reset}"
				fi
				echo $_pwd | saslpasswd2 -p -c -u $mydomain $_user
			fi
		done < /tmp/passwd

		rm -f /tmp/passwd

		[[ -f /etc/sasldb2 ]] && chown postfix:postfix /etc/sasldb2
		[[ -f /etc/sasl2/sasldb2 ]] && chown postfix:postfix /etc/sasl2/sasldb2

		if [[ -n "$bad_users" ]]; then
			notice "$(printf '%s' \
				"Some SASL users (${bad_users}) were specified without the domain. Container domain (${emphasis}${mydomain}${reset}) was automatically applied. " \
				"If this was an intended behavour, you can safely ignore this message. To prevent the message in the future, specify your usernames with domain " \
				"name, e.g. ${emphasis}${first_bad_user}@${mydomain}:<pass>${reset}. For more info, see https://github.com/bokysan/docker-postfix/issues/192"			
			)"
		fi

		debug 'Sasldb configured'
	fi
}

postfix_setup_networks() {
	if [ ! -z "$MYNETWORKS" ]; then
		deprecated "${emphasis}MYNETWORKS${reset} variable is deprecated. Please use ${emphasis}POSTFIX_mynetworks${reset} instead."
		notice "Using custom allowed networks: ${emphasis}$MYNETWORKS${reset}"
		POSTFIX_mynetworks="$MYNETWORKS"
	elif [ ! -z "$POSTFIX_mynetworks" ]; then
		notice "Using custom allowed networks: ${emphasis}$POSTFIX_mynetworks${reset}"
	else
		info "Using default private network list for trusted networks."
		POSTFIX_mynetworks="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
	fi
}

postfix_setup_debugging() {
	if [ ! -z "$INBOUND_DEBUGGING" ]; then
		notice "Enabling additional debbuging for: ${emphasis}$POSTFIX_mynetworks${reset}, as INBOUND_DEBUGGING=''${INBOUND_DEBUGGING}''"
		do_postconf -e "debug_peer_list=$POSTFIX_mynetworks"

		sed -i -E 's/^[ \t]*#?[ \t]*LogWhy[ \t]*.+$/LogWhy                  yes/' /etc/opendkim/opendkim.conf
		if ! egrep -q '^LogWhy' /etc/opendkim/opendkim.conf; then
			echo >> /etc/opendkim/opendkim.conf
			echo "LogWhy                  yes" >> /etc/opendkim/opendkim.conf
		fi
	else
		info "Debugging is disabled.${reset}"
		sed -i -E 's/^[ \t]*#?[ \t]*LogWhy[ \t]*.+$/LogWhy                  no/' /etc/opendkim/opendkim.conf
		if ! egrep -q '^LogWhy' /etc/opendkim/opendkim.conf; then
			echo >> /etc/opendkim/opendkim.conf
			echo "LogWhy                  no" >> /etc/opendkim/opendkim.conf
		fi
	fi
}

postfix_setup_sender_domains() {
	if [ ! -z "$ALLOWED_SENDER_DOMAINS" ]; then
		infon "Setting up allowed SENDER domains:"
		allowed_senders=/etc/postfix/allowed_senders
		rm -f $allowed_senders $allowed_senders.db > /dev/null
		touch $allowed_senders
		for i in $ALLOWED_SENDER_DOMAINS; do
			echo -ne " ${emphasis}$i${reset}"
			echo -e "$i\tOK" >> $allowed_senders
		done
		echo
		postmap lmdb:$allowed_senders

		if [ ! -z "$SMTPD_SASL_USERS" ]; then
			smtpd_sasl="permit_sasl_authenticated,"
		fi

		do_postconf -e "smtpd_recipient_restrictions=reject_non_fqdn_recipient, reject_unknown_recipient_domain, check_sender_access lmdb:$allowed_senders, $smtpd_sasl reject"

		# Since we are behind closed doors, let's just permit all relays.
		do_postconf -e "smtpd_relay_restrictions=permit"
	elif [ -z "$ALLOW_EMPTY_SENDER_DOMAINS" ]; then
		error "You need to specify ${emphasis}ALLOWED_SENDER_DOMAINS${reset} or ${emphasis}ALLOW_EMPTY_SENDER_DOMAINS${reset}, otherwise Postfix will not run! See ${emphasis}README.md${reset} for more info."
		exit 1
	fi
}

postfix_setup_masquarading() {
	if [ ! -z "$MASQUERADED_DOMAINS" ]; then
		notice "Setting up address masquerading: ${emphasis}$MASQUERADED_DOMAINS${reset}"
		do_postconf -e "masquerade_domains = $MASQUERADED_DOMAINS"
		do_postconf -e "local_header_rewrite_clients = static:all"
	fi
}

postfix_setup_header_checks() {
	if [ ! -z "$SMTP_HEADER_CHECKS" ]; then
		if [ "$SMTP_HEADER_CHECKS" == "1" ]; then
			info "Using default file for SMTP header checks"
			SMTP_HEADER_CHECKS="regexp:/etc/postfix/smtp_header_checks"
		fi

		FORMAT=$(echo "$SMTP_HEADER_CHECKS" | cut -d: -f1)
		FILE=$(echo "$SMTP_HEADER_CHECKS" | cut -d: -f2-)

		if [ "$FORMAT" == "$FILE" ]; then
			warn "No Postfix format defined for file ${emphasis}SMTP_HEADER_CHECKS${reset}. Using default ${emphasis}regexp${reset}. To avoid this message, set format explicitly, e.g. ${emphasis}SMTP_HEADER_CHECKS=regexp:$SMTP_HEADER_CHECKS${reset}."
			FORMAT="regexp"
		fi

		if [ -f "$FILE" ]; then
			notice "Setting up ${emphasis}smtp_header_checks${reset} to ${emphasis}$FORMAT:$FILE${reset}"
			do_postconf -e "smtp_header_checks=$FORMAT:$FILE"
		else
			fatal "File ${emphasis}$FILE${reset} cannot be found. Please make sure your SMTP_HEADER_CHECKS variable points to the right file. Startup aborted."
			exit 2
		fi
	fi
}

postfix_setup_dkim() {
	local DKIM_ENABLED
	local domain_dkim_selector
	local private_key
	local dkim_socket
	local domain
	local any_generated
	local file

	if [[ -n "${DKIM_AUTOGENERATE}" ]]; then
		info "${emphasis}DKIM_AUTOGENERATE${reset} set -- will try to auto-generate keys for ${emphasis}${ALLOWED_SENDER_DOMAINS}${reset}."
		mkdir -p /etc/opendkim/keys
		if [[ -n "${ALLOWED_SENDER_DOMAINS}" ]]; then
			for domain in ${ALLOWED_SENDER_DOMAINS}; do
				private_key=/etc/opendkim/keys/${domain}.private
				if [[ -f "${private_key}" ]]; then
					info "Key for domain ${emphasis}${domain}${reset} already exists in ${emphasis}${private_key}${reset}. Will not overwrite."
				else
					notice "Auto-generating DKIM key for ${emphasis}${domain}${reset} into ${private_key}."
					(
						cd /tmp
						domain_dkim_selector="$(get_dkim_selector "${domain}")"
						opendkim-genkey -b 2048 -h rsa-sha256 -r -v --subdomains -s ${domain_dkim_selector} -d $domain
						# Fixes https://github.com/linode/docs/pull/620
						sed -i 's/h=rsa-sha256/h=sha256/' ${domain_dkim_selector}.txt
						mv -v ${domain_dkim_selector}.private /etc/opendkim/keys/${domain}.private
						mv -v ${domain_dkim_selector}.txt /etc/opendkim/keys/${domain}.txt

						# Fixes #39
						chown opendkim:opendkim /etc/opendkim/keys/${domain}.private
						chmod 400 /etc/opendkim/keys/${domain}.private

						chown opendkim:opendkim /etc/opendkim/keys/${domain}.txt
						chmod 644 /etc/opendkim/keys/${domain}.txt

					) | sed 's/^/       /'
					any_generated=1
				fi
			done
			if [[ -n "${any_generated}" ]]; then
				notice "New DKIM keys have been generated! Please make sure to update your DNS records! You need to add the following details:"
				for file in /etc/opendkim/keys/*.txt; do
					echo "====== $file ======"
					cat $file
				done
				echo
			fi
		else
			warn "DKIM auto-generate requested, but ${emphasis}ALLOWED_SENDER_DOMAINS${reset} not set. Nothing to generate!"
		fi
	else
		debug "${emphasis}DKIM_AUTOGENERATE${reset} not set -- you will need to provide your own keys."
	fi

	if [ -d /etc/opendkim/keys ] && [ ! -z "$(find /etc/opendkim/keys -type f ! -name .)" ]; then
		DKIM_ENABLED=", ${emphasis}opendkim${reset}"
		notice "Configuring OpenDKIM."
		mkdir -p /var/run/opendkim
		chown -R opendkim:opendkim /var/run/opendkim
		dkim_socket=$(cat /etc/opendkim/opendkim.conf | egrep ^Socket | awk '{ print $2 }')
		if [ $(echo "$dkim_socket" | cut -d: -f1) == "inet" ]; then
			dkim_socket=$(echo "$dkim_socket" | cut -d: -f2)
			dkim_socket="inet:$(echo "$dkim_socket" | cut -d@ -f2):$(echo "$dkim_socket" | cut -d@ -f1)"
		fi
		echo -e "        ...using socket $dkim_socket"

		do_postconf -e "milter_protocol=6"
		do_postconf -e "milter_default_action=accept"
		do_postconf -e "smtpd_milters=$dkim_socket"
		do_postconf -e "non_smtpd_milters=$dkim_socket"

		echo > /etc/opendkim/TrustedHosts
		echo > /etc/opendkim/KeyTable
		echo > /etc/opendkim/SigningTable

		# Since it's an internal service anyways, it's safe
		# to assume that *all* hosts are trusted.
		echo "0.0.0.0/0" > /etc/opendkim/TrustedHosts

		if [ ! -z "$ALLOWED_SENDER_DOMAINS" ]; then
			for domain in $ALLOWED_SENDER_DOMAINS; do
				private_key=/etc/opendkim/keys/${domain}.private
				if [ -f $private_key ]; then
					domain_dkim_selector="$(get_dkim_selector "${domain}")"
					echo -e "        ...for domain ${emphasis}${domain}${reset} (selector: ${emphasis}${domain_dkim_selector}${reset})"
					if ! su opendkim -s /bin/bash -c "cat /etc/opendkim/keys/${domain}.private" > /dev/null 2>&1; then
						echo -e "        ...trying to reown ${emphasis}${private_key}${reset} as it's not readable by OpenDKIM..."
						# Fixes #39
						chown opendkim:opendkim "${private_key}"
						chmod u+r "${private_key}"
					fi

					echo "${domain_dkim_selector}._domainkey.${domain} ${domain}:${domain_dkim_selector}:${private_key}" >> /etc/opendkim/KeyTable
					echo "*@${domain} ${domain_dkim_selector}._domainkey.${domain}" >> /etc/opendkim/SigningTable
				else
					error "Skipping DKIM for domain ${emphasis}${domain}${reset}. File ${private_key} not found!"
				fi
			done
		fi
	else
		info "No DKIM keys found, will not use DKIM."
		do_postconf -# smtpd_milters
		do_postconf -# non_smtpd_milters
	fi
}

opendkim_custom_commands() {
	local setting
	local key
	local padded_key
	local value
	for setting in ${!OPENDKIM_*}; do
		key="${setting:9}"
		value="${!setting}"
		if [ -n "${value}" ]; then
			if [ "${#key}" -gt 23 ]; then
				padded_key="${key} "
			else
				padded_key="$(printf %-24s "${key}")"
			fi
			if cat /etc/opendkim/opendkim.conf | egrep -q "^[[:space:]]*#?[[:space:]]*${key}"; then
				info "Updating custom OpenDKIM setting: ${emphasis}${key}=${value}${reset}"
				sed -i -E "s/^[ \t]*#?[ \t]*${key}[ \t]*.+$/${padded_key}${value}/" /etc/opendkim/opendkim.conf
			else
				info "Adding custom OpenDKIM setting: ${emphasis}${key}=${value}${reset}"
				echo "Adding ${padded_key}${value}"
				echo "${padded_key}${value}" >> /etc/opendkim/opendkim.conf
			fi
		else
			info "Deleting custom OpenDKIM setting: ${emphasis}${key}${reset}"
			sed -i -E "/^[ \t]*#?[ \t]*${key}[ \t]*.+$/d" /etc/opendkim/opendkim.conf
		fi
	done
}

postfix_custom_commands() {
	local setting
	local key
	local value
	for setting in ${!POSTFIX_*}; do
		key="${setting:8}"
		value="${!setting}"
		if [ -n "${value}" ]; then
			info "Applying custom postfix setting: ${emphasis}${key}=${value}${reset}"
			if [ "${key}" == "maillog_dir" ]; then
				warn "You're overriding ${emphasis}${key}${reset}. This image has a lot of assumptions about logs going to syslog."
				warn "Make sure you know what you're doing. Most likely you will want to add an additional file to ${emphasis}/etc/rsyslog.d/${reset}."
			fi

			do_postconf -e "${key}=${value}"
		else
			info "Deleting custom postfix setting: ${emphasis}${key}${reset}"
			do_postconf -# "${key}"
		fi
	done
}

postfix_open_submission_port() {
	# Use 587 (submission)
	sed -i -r -e 's/^#submission/submission/' /etc/postfix/master.cf
}

execute_post_init_scripts() {
	if [ -d /docker-init.db/ ]; then
		notice "Executing any found custom scripts..."
		for f in /docker-init.db/*; do
			case "$f" in
				*.sh)
					if [[ -x "$f" ]]; then
						echo -e "\tsourcing ${emphasis}$f${reset}"
						. "$f"
					else
						echo -e "\trunning ${emphasis}bash $f${reset}"
						bash "$f"
					fi
					;;
				*)
					echo "$0: ignoring $f" ;;
			esac
		done
	fi
}

unset_sensitive_variables() {
	unset RELAYHOST_PASSWORD
	unset XOAUTH2_CLIENT_ID
	unset XOAUTH2_SECRET
	unset XOAUTH2_INITIAL_ACCESS_TOKEN
	unset XOAUTH2_INITIAL_REFRESH_TOKEN
	unset SMTPD_SASL_USERS
}
