provider "aws" {
  region = var.region
}

data "aws_ami" "this" {
  most_recent = true

  filter {
    name = "name"

    values = [
      "amzn2-ami-hvm-*",
    ]
  }

  filter {
    name = "virtualization-type"

    values = [
      "hvm",
    ]
  }

  filter {
    name = "architecture"

    values = [
      "x86_64",
    ]
  }

  owners = [
    "137112412989",
  ]

  # amazon
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "local_file" "private_key" {
  filename = format("%s/%s.pem", quorum_bootstrap_network.this.network_dir_abs, local.network_name)
  content  = tls_private_key.ssh.private_key_pem

  provisioner "local-exec" {
    on_failure = continue
    command    = "chmod 600 ${self.filename}"
  }
}

resource "aws_key_pair" "ssh" {
  public_key      = tls_private_key.ssh.public_key_openssh
  key_name_prefix = "${local.network_name}-"
}

data "http" "myIpAddr" {
  url = "http://ifconfig.me"
}

resource "aws_security_group" "external" {
  name        = format("%s-external", local.network_name)
  description = "Allow external traffic"
  vpc_id      = var.vpc_id

  ingress {
    from_port = 22
    protocol  = "tcp"
    to_port   = 22

    cidr_blocks = [
      "${chomp(data.http.myIpAddr.body)}/32"
    ]
  }

  ingress {
    from_port = local.host_rpc_port
    protocol  = "tcp"
    to_port   = local.host_rpc_port

    cidr_blocks = [
      "${chomp(data.http.myIpAddr.body)}/32"
    ]
  }

  ingress {
    from_port = local.host_ws_port
    protocol  = "tcp"
    to_port   = local.host_ws_port

    cidr_blocks = [
      "${chomp(data.http.myIpAddr.body)}/32"
    ]
  }

  tags = {
    Name = local.network_name
    By   = "quorum"
  }
}

resource "aws_security_group" "quorum" {
  name        = format("%s-internal", local.network_name)
  description = "Allow Quorum Network traffic"
  vpc_id      = var.vpc_id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    Name = local.network_name
    By   = "quorum"
  }
}

data "aws_subnet_ids" "node" {
  vpc_id = var.vpc_id
}

resource "aws_instance" "node" {
  count = local.number_of_nodes

  ami                         = data.aws_ami.this.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ssh.key_name
  subnet_id                   = element(tolist(data.aws_subnet_ids.node.ids), 0)
  iam_instance_profile        = aws_iam_instance_profile.node.name

  vpc_security_group_ids = [
    aws_security_group.quorum.id,
    aws_security_group.external.id,
  ]

  root_block_device {
    volume_size = var.volume_size
  }

  user_data = <<EOF
#!/bin/bash

set -e

# START: added per suggestion from AWS support to mitigate an intermittent failures from yum update
sleep 20
yum clean all
yum repolist
# END

yum -y update
yum -y install jq
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker

curl -L https://github.com/docker/compose/releases/download/1.25.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

rpm -Uvh https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
cat <<JSON > /opt/aws/amazon-cloudwatch-agent/amazon-cloudwatch-agent.json
{
	"agent": {
		"metrics_collection_interval": 30,
		"run_as_user": "cwagent"
	},
	"metrics": {
        "namespace": "${local.network_name}",
        "aggregation_dimensions": [
          ["InstanceId"],
          ["AutoScalingGroupName"]
        ],
        "append_dimensions": {
          "AutoScalingGroupName": "\$${aws:AutoScalingGroupName}",
          "InstanceId": "\$${aws:InstanceId}"
        },
		"metrics_collected": {
			"cpu": {
				"measurement": [
					"usage_idle",
					"usage_iowait",
					"usage_user",
					"usage_system"
				],
				"metrics_collection_interval": 30
			},
            "net" : {
                "measurement" : ["bytes_recv", "bytes_sent"],
                "metrics_collection_interval": 30
            },
			"diskio": {
				"measurement": [
					"io_time"
				],
				"metrics_collection_interval": 30
			},
			"mem": {
				"measurement": [
					"mem_used_percent"
				],
				"metrics_collection_interval": 30
			}
		}
	}
}
JSON
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/amazon-cloudwatch-agent.json -s

touch /tmp/done

EOF

  tags = {
    By   = "quorum"
    Name = "${local.network_name}-node-${count.index}"
  }
}

resource "aws_instance" "wrk" {
  ami                         = data.aws_ami.this.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ssh.key_name
  subnet_id                   = element(tolist(data.aws_subnet_ids.node.ids), 0)
  iam_instance_profile        = aws_iam_instance_profile.node.name

  vpc_security_group_ids = [
    aws_security_group.quorum.id,
    aws_security_group.external.id,
  ]


  root_block_device {
    volume_size = 100
  }

  user_data = <<EOF
#!/bin/bash

set -e

# START: added per suggestion from AWS support to mitigate an intermittent failures from yum update
sleep 20
yum clean all
yum repolist
# END

yum -y update
yum -y install openssl-devel git
yum -y groupinstall 'Development Tools'
yum -y install jq
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker

curl -L https://github.com/docker/compose/releases/download/1.25.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

rpm -Uvh https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
cat <<JSON > /opt/aws/amazon-cloudwatch-agent/amazon-cloudwatch-agent.json
{
	"agent": {
		"metrics_collection_interval": 30,
		"run_as_user": "cwagent"
	},
	"metrics": {
        "namespace": "${local.network_name}",
        "aggregation_dimensions": [
          ["InstanceId"],
          ["AutoScalingGroupName"]
        ],
        "append_dimensions": {
          "AutoScalingGroupName": "\$${aws:AutoScalingGroupName}",
          "InstanceId": "\$${aws:InstanceId}"
        },
		"metrics_collected": {
			"cpu": {
				"measurement": [
					"usage_idle",
					"usage_iowait",
					"usage_user",
					"usage_system"
				],
				"metrics_collection_interval": 30
			},
            "net" : {
                "measurement" : ["bytes_recv", "bytes_sent"],
                "metrics_collection_interval": 30
            },
			"diskio": {
				"measurement": [
					"io_time"
				],
				"metrics_collection_interval": 30
			},
			"mem": {
				"measurement": [
					"mem_used_percent"
				],
				"metrics_collection_interval": 30
			}
		}
	}
}
JSON
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/amazon-cloudwatch-agent.json -s

touch /tmp/done

EOF

  tags = {
    By   = "quorum"
    Name = "${local.network_name}-test"
  }
}

resource "aws_cloudwatch_log_group" "quorum" {
  name              = "/quorum/${local.network_name}"
  retention_in_days = "7"

  tags = {
    By   = "quorum"
    Name = local.network_name
  }
}

resource "local_file" "node_monitor_sh" {
  filename = format("%s/start-monitor.sh", local.generated_dir)
  content  = <<-EOF
#!/bin/bash
region="${var.region}"
nprefix="${var.network_name}"
ts=`date +"%d%m%Y%H%M%S"`
lf="node_monitor_$ts.log"
while true
do
timeStamp=`date +'%d/%m/%Y %H:%M:%S'`
GETH_CPU=$( sudo docker stats --no-stream | grep "$nprefix-node" | awk '{printf "%.2f", $3}' )
GETH_MEM=$( sudo docker stats --no-stream | grep "$nprefix-node" | awk '{printf "%.2f", $7}' )
TM_CPU=$( sudo docker stats --no-stream | grep "$nprefix-tm" | awk '{printf "%.2f", $3}' )
TM_MEM=$( sudo docker stats --no-stream | grep "$nprefix-tm" | awk '{printf "%.2f", $7}' )
INSTANCEID="CpuMemMonitor"
NSID=$(ec2-metadata -v|awk '{printf $2}')
echo $timeStamp,$INSTANCEID,$GETH_CPU,$GETH_MEM,$TM_CPU,$TM_MEM >> $lf
aws cloudwatch put-metric-data --region $region --metric-name "geth-CPU%" --dimensions System=$INSTANCEID  --namespace "$nprefix-$NSID" --value $GETH_CPU
aws cloudwatch put-metric-data --region $region --metric-name "geth-MEM%" --dimensions System=$INSTANCEID  --namespace "$nprefix-$NSID" --value $GETH_MEM
aws cloudwatch put-metric-data --region $region --metric-name "tm-CPU%" --dimensions System=$INSTANCEID  --namespace "$nprefix-$NSID" --value $TM_CPU
aws cloudwatch put-metric-data --region $region --metric-name "tm-MEM%" --dimensions System=$INSTANCEID  --namespace "$nprefix-$NSID" --value $TM_MEM
sleep $1
done
EOF
}

resource "local_file" "node_monitor_start_sh" {
  filename = format("%s/start.sh", local.generated_dir)
  content  = <<-EOF
#!/bin/bash
nohup ./node_monitor.sh 30 &
EOF
}

resource "null_resource" "publish" {
  count = local.number_of_nodes

  triggers = {
    ec2 = aws_instance.node[count.index].id
  }

  connection {
    type        = "ssh"
    agent       = false
    timeout     = "60s"
    host        = aws_instance.node[count.index].public_ip
    user        = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${local.qdata_dir_vm_path}",
      "sudo mkdir -p ${local.tm_dir_vm_path}",
      "sudo chown -R ec2-user:ec2-user ${local.qdata_dir_vm_path}",
      "sudo chown -R ec2-user:ec2-user ${local.tm_dir_vm_path}",
      "sudo mkdir -p ${local.node_monitor_home_path}",
      "sudo chown -R ec2-user:ec2-user ${local.node_monitor_home_path}",
    ]
  }


  provisioner "file" {
    source      = format("%s/", quorum_bootstrap_data_dir.datadirs-generator[count.index].data_dir_abs)
    destination = local.qdata_dir_vm_path
  }

  provisioner "file" {
    source      = format("%s/", dirname(local_file.tmconfigs-generator[count.index].filename))
    destination = local.tm_dir_vm_path
  }

  provisioner "file" {
    content = local_file.node_monitor_sh.content
    destination = "~/monitor/node_monitor.sh"
  }

  provisioner "file" {
    content = local_file.node_monitor_start_sh.content
    destination = format("%s/start.sh", local.node_monitor_home_path)
  }

  provisioner "remote-exec" {
    inline = [
      "while [ ! -f /tmp/done ]; do echo 'Wait for node ${count.index} being fully ready'; sleep 3; done",
      "cd ${local.qdata_dir_vm_path} && sudo /usr/local/bin/docker-compose up -d",
      "sleep 5", // avoid connection shutting down before processes start up
      "sudo chmod 755 ${local.node_monitor_home_path}/*",
      "if [ ${count.index} -eq 0 ]; then echo 'start monitor script node ${count.index}';cd ${local.node_monitor_home_path};./start.sh; sleep 5; fi",
    ]
  }
}

# this file is read by jmeter test targetting this network
resource "local_file" "host_acct_csv" {
  filename = format("%s/host_acct.csv", local.wrk_stresstest_gen_dir)
  content  = <<-EOF
url,port,from,privateFor
%{for i in data.null_data_source.meta[*].inputs.idx~}
${aws_instance.node[i].private_ip},8545,${quorum_bootstrap_keystore.accountkeys-generator[i].account[0].address},"${quorum_transaction_manager_keypair.tm[(i+1 == length(data.null_data_source.meta) ? 0 : i + 1)].public_key_b64}"
%{endfor~}
EOF
}


resource "local_file" "network_props" {
  filename = format("%s/network.properties", local.wrk_stresstest_gen_dir)
  content  = <<-EOF
#common params
threads=${var.no_of_threads}
seconds=${var.duration_of_run}
delay=5
varsFile=/stresstest/host_acct.csv
%{if var.throughput > 0~}
throughput=${var.throughput}
%{endif~}
%{if var.public_throughput > 0~}
public.throughput=${var.public_throughput}
%{endif~}
%{if var.private_throughput > 0~}
private.throughput=${var.private_throughput}
%{endif~}

#for single node test
url=${aws_instance.node[0].private_ip}
port=8545
from=${quorum_bootstrap_keystore.accountkeys-generator[0].account[0].address}
privateFor="${quorum_transaction_manager_keypair.tm[1].public_key_b64}"

#for multiple nodes
%{for i in data.null_data_source.meta[*].inputs.idx~}
#node${i}
url${i}=${aws_instance.node[i].private_ip}
port${i}=8545
from${i}=${quorum_bootstrap_keystore.accountkeys-generator[i].account[0].address}
privateFor${i}="${quorum_transaction_manager_keypair.tm[(i+1 == length(data.null_data_source.meta) ? 0 : i + 1)].public_key_b64}"

%{endfor~}



EOF
}

resource "local_file" "start_tps_sh" {
  filename = format("%s/start-tps.sh", local.wrk_stresstest_gen_dir)
  content  = <<-EOF
#!/bin/bash
echo "start tps monitor..."
sudo docker run -d -v ${local.wrk_stresstest_home_path}:/stresstest -p 7575:7575 --name tps-monitor --log-driver=awslogs --log-opt awslogs-region=${var.region} --log-opt awslogs-group=${aws_cloudwatch_log_group.quorum.name} --log-opt awslogs-stream=tpsmonitor ${var.tps_docker_image} --awsmetrics --awsregion ${var.region} --awsnetwork ${var.network_name} --awsinst ${aws_instance.node[0].public_ip} --wsendpoint ws://${aws_instance.node[0].private_ip}:8546 --consensus=${var.consensus} --report /stresstest/tps-report.csv
echo "tps monitor started"
EOF
}

resource "local_file" "start_jmeter_sh" {
  filename = format("%s/start-jmeter-test.sh", local.wrk_stresstest_gen_dir)
  content  = <<-EOF
#!/bin/bash
echo "start jmeter profile ${var.test_profile}.."
sudo docker run -d -v ${local.wrk_stresstest_home_path}:/stresstest --name jmeter --log-driver=awslogs --log-opt awslogs-region=${var.region} --log-opt awslogs-group=${aws_cloudwatch_log_group.quorum.name} --log-opt awslogs-stream=jmeter    ${var.jmeter_docker_image} -n -t /stresstest/${var.test_profile}.jmx -q /stresstest/network.properties -l /stresstest/result.log -j /stresstest/j.log -e -o /stresstest/tmp/
echo "jmeter test profile ${var.test_profile} started"
EOF
}

resource "null_resource" "wrk_publish" {
  count = 1

  triggers = {
    ec2 = aws_instance.wrk.id
    file1 = local_file.network_props.content
    file2 = local_file.host_acct_csv.content
    file3 = local_file.start_jmeter_sh.content
    file4 = local_file.start_tps_sh.content

  }

  connection {
    type = "ssh"
    agent = false
    timeout = "60s"
    host = aws_instance.wrk.public_ip
    user = "ec2-user"
    private_key = tls_private_key.ssh.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${local.wrk_stresstest_home_path}",
      "sudo chown -R ec2-user:ec2-user ${local.wrk_stresstest_home_path}"
    ]
  }

  provisioner "file" {
    source = format("%s/", local.wrk_stresstest_gen_dir)
    destination = local.wrk_stresstest_home_path
  }

  provisioner "file" {
    source = format("%s/", local.stresstest_src_path)
    destination = format("%s", local.wrk_stresstest_home_path)
  }

  provisioner "remote-exec" {
    inline = [
      "while [ ! -f /tmp/done ]; do echo 'Wait for test node being fully ready'; sleep 3; done",
      "sleep 3", // avoid connection shutting down before processes start up
      "sudo chmod 755 ${local.wrk_stresstest_home_path}/*",
      "cd ${local.wrk_stresstest_home_path};./bootstrap.sh",
      "sleep 5", // avoid connection shutting down before processes start up
    ]
  }

}