#!/bin/bash

export url=$1

function help {
  echo "Command Usage: $0 CFN_SIGNAL_URL"
  exit 1
}

if [ -z $url ]; then
  help
fi

ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml

export installer_result = $?

if [ $installer_result -eq 0 ]; then
  oc --config=/home/ec2-user/.kube/config adm policy add-cluster-role-to-user cluster-admin operator
  oadm --config=/home/ec2-user/.kube/config manage-node master.lab --schedulable=false
fi

/usr/local/sbin/cfn-signal.sh $installer_result '${url}'"
