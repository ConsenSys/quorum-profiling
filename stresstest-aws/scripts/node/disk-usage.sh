#!/bin/bash
while read -a LIST; \
do timestamp=$(date +%s%N); \
        printf '%s\n' 'disk-usage,folder="'${LIST[1]}'" bytes='${LIST[0]}' '$timestamp; \
done < <(du -b /data/tm/db.mv.db /data/tm/db.trace.db /data/qdata/geth/chaindata /data/qdata/geth/lightchaindata /data/qdata/geth/nodes /data/qdata/geth/transactions.rlp )