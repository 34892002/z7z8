#!/bin/bash
TARGET="${1:-google.com}"
TIMEOUT="${2:-3}"

echo "Testing all global IPv6 addresses against $TARGET (timeout: ${TIMEOUT}s)"
echo "==================================================================="
ip -6 addr show | grep 'inet6 ' | grep -v 'scope host' | grep -v 'scope link' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do
  printf "%-50s " "$ip"
  result=$(curl -6 --interface "$ip" "https://$TARGET" -I -m "$TIMEOUT" -s -o /dev/null -w "%{http_code}" 2>&1)
  if [ "$result" = "000" ]; then
    echo "FAIL (timeout)"
  else
    echo "OK (HTTP $result)"
  fi
done
