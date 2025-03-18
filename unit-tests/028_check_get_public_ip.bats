#!/usr/bin/env bats

load /code/scripts/common.sh

assert_equals() {
	local expected="$1"
	local actual="$2"
	if [[ "${expected}" != "${actual}" ]]; then
		echo "Expected: \"${expected}\". Got: \"${actual}\"." >&2
		exit 1
	fi
}

@test "check if get_public_ip works" {
	local ip1
	local ip2
	ip1=get_public_ip
	AUTOSET_HOSTNAME_SERVICES=(https://ifconfig.co) ip2=get_public_ip
	assert_equals "${ip1}" "${ip2}"
}

