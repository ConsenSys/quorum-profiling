resource "local_file" "docker-compose" {
  count    = local.number_of_nodes
  filename = format("%s/%s%s/docker-compose.yml", quorum_bootstrap_network.this.network_dir_abs, local.node_dir_prefix, count.index)
  content  = <<-EOF
version: "3.6"
x-quorum-def:
  &quorum-def
  restart: "no"
  healthcheck:
    test: ["CMD", "wget", "--spider", "--proxy", "off", "--no-check-certificate", "http://localhost:${local.container_rpc_port}"]
    interval: 3s
    timeout: 3s
    retries: 10
    start_period: 5s
  logging:
    driver: "awslogs"
    options:
      awslogs-region: "${var.aws_region}"
      awslogs-group: "${aws_cloudwatch_log_group.quorum.name}"
      awslogs-stream: "${format("node-%d", count.index)}"
  entrypoint:
    - /bin/sh
    - -c
    - |
%{if var.enable_tessera == true~}
      UDS_WAIT=10
      for i in $$(seq 1 100)
      do
        set -e
        if [ -S $$PRIVATE_CONFIG ] && \
          [ "I'm up!" == "$$(wget --timeout $$UDS_WAIT -qO- --proxy off $$TXMANAGER_IP:${local.container_tm_p2p_port}/upcheck)" ];
        then break
        else
          echo "Sleep $$UDS_WAIT seconds. Waiting for TxManager."
          sleep $$UDS_WAIT
        fi
      done
%{endif~}
      geth $$ADDITIONAL_GETH_ARGS \
        --identity Node$$NODE_ID \
        --datadir $$DDIR \
        --nodiscover \
        --verbosity 3 \
        --networkid ${random_integer.network_id.result} \
        --nodekeyhex $$NODEKEY_HEX \
        --miner.gastarget ${var.gasLimit} \
        --miner.gaslimit ${var.gasLimit} \
        --rpc \
        --rpccorsdomain=* \
        --rpcvhosts=* \
        --rpcaddr 0.0.0.0 \
        --rpcport ${local.container_rpc_port} \
        --rpcapi admin,db,eth,debug,miner,net,shh,txpool,personal,web3,quorum,${var.consensus == "raft" ? "raft" : "istanbul"} \
        --ws \
        --wsorigins=* \
        --wsaddr 0.0.0.0 \
        --wsport ${local.container_ws_port} \
        --wsapi admin,db,eth,debug,miner,net,shh,txpool,personal,web3,quorum,${var.consensus == "raft" ? "raft" : "istanbul"} \
        --metrics --metrics.expensive --metrics.influxdb --metrics.influxdb.endpoint "http://${aws_instance.wrk.private_ip}:8086" --metrics.influxdb.username "telegraf" --metrics.influxdb.password "test123" --metrics.influxdb.database "telegraf" --metrics.influxdb.tags "node=${format("node-%d", count.index)}" \
        --port ${local.container_p2p_port} \
%{if var.consensus == "ibft"~}
        --istanbul.blockperiod ${var.blockPeriod > 10 ? 1 : var.blockPeriod} \
        --mine \
        --minerthreads 1 \
        --syncmode full \
%{endif~}
%{if var.consensus == "clique"~}
        --mine \
        --minerthreads 1 \
        --syncmode full \
%{endif~}
%{if var.consensus == "raft"~}
        --raft \
        --raftport ${local.container_raft_port} \
        --raftblocktime ${var.blockPeriod} \
%{endif~}
        --unlock 0 \
        --password ${local.qdata_dir_container_path}/${basename(local_file.passwords[0].filename)} \
        --txpool.accountqueue ${var.txpoolSize} \
        --txpool.globalslots ${var.txpoolSize} \
        --txpool.globalqueue ${var.txpoolSize}
%{if var.enable_tessera == true~}
x-tx-manager-def:
  &tx-manager-def
  image: "${local.tessera_docker_image}"
  restart: "no"
  healthcheck:
    test: ["CMD-SHELL", "[ -S ${local.tm_dir_container_path}/tm.ipc ] || exit 1"]
    interval: 3s
    timeout: 3s
    retries: 20
    start_period: 5s
  logging:
    driver: "awslogs"
    options:
      awslogs-region: "${var.aws_region}"
      awslogs-group: "${aws_cloudwatch_log_group.quorum.name}"
      awslogs-stream: "${format("tm-%d", count.index)}"
  entrypoint:
    - /bin/sh
    - -c
    - |
      rm -f ${local.tm_dir_container_path}/tm.ipc
      java -Xms1024M -Xmx2048M -jar /tessera/tessera-app.jar -configfile ${local.tm_dir_container_path}/config.json
%{endif~}
services:
  node:
    << : *quorum-def
    image: "${local.quorum_docker_image}"
    container_name: ${local.network_name}-node
    hostname: node
    ports:
      - ${format("%d:%d", local.host_rpc_port, local.container_rpc_port)}
      - ${format("%d:%d", local.host_ws_port, local.container_ws_port)}
      - ${format("%d:%d", local.host_p2p_port, local.container_p2p_port)}
      - ${format("%d:%d", local.host_raft_port, local.container_raft_port)}
    volumes:
      - vol:/data
      - ${local.qdata_dir_vm_path}:${local.qdata_dir_container_path}
      - ${local.tm_dir_vm_path}:${local.tm_dir_container_path}
%{if var.enable_tessera == true~}
    depends_on:
      - txmanager
%{endif~}
    networks:
      ${local.network_name}-net:
        ipv4_address: ${element(data.null_data_source.meta[*].inputs.nodeContainerIP, count.index)}
    environment:
      - ADDITIONAL_GETH_ARGS=${local.geth_addt_args}
      - PRIVATE_CONFIG=${var.enable_tessera == true ? format("%s/tm.ipc", local.tm_dir_container_path) : "ignore"}
      - TXMANAGER_IP=${element(data.null_data_source.meta[*].inputs.txManagerContainerIP, count.index)}
      - NODE_ID=${format("%d", count.index + 1)}
      - DDIR=${local.qdata_dir_container_path}
      - NODEKEY_HEX=${element(quorum_bootstrap_node_key.nodekeys-generator[*].node_key_hex, count.index)}
%{if var.enable_tessera == true~}
  txmanager:
    << : *tx-manager-def
    container_name: ${local.network_name}-tm
    hostname: txmanager
    ports:
      - ${format("%d:%d", local.host_tm_p2p_port, local.container_tm_p2p_port)}
      - ${format("%d:%d", local.host_tm_third_party_port, local.container_tm_third_party_port)}
    volumes:
      - vol:/data
      - ${local.tm_dir_vm_path}:${local.tm_dir_container_path}
    networks:
      ${local.network_name}-net:
        ipv4_address: ${element(data.null_data_source.meta[*].inputs.txManagerContainerIP, count.index)}
%{endif~}
networks:
  ${local.network_name}-net:
    name: ${local.network_name}-net
    driver: bridge
    ipam:
      driver: default
      config:
      - subnet: ${local.network_cidr}
volumes:
  "vol":
EOF
}
