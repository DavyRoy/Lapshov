#!/bin/bash
# skip crab_syntax
set -ue
# --cpuset-cpus 30,31,62,63
# --add-host eva.eva-hl.local:test.eva.ip.addr
# -d --entrypoint bash -c "while true; do sleep 1; done" -v /opt/eva_admin/load-testing/root:/root
# ./tank_run.sh yandex-tank -c simple-real-load.yaml --option=bfg.ammofile=simple-real-ammo.tsv
exec docker run \
    -ti --rm \
    -v /opt/eva_admin/load-testing:/var/loadtest --name tank \
    yandex/yandex-tank "$@"
