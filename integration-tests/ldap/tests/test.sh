#!/bin/sh
set -e
set -x

if ! hash postmap; then
    echo "postmap not found!" >2
    exit 1
fi

postmap -q demo@example.org ldap:/etc/postfix/conf/restricted-senders.cf
