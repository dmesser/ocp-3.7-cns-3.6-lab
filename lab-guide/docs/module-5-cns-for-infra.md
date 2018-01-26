!!! Summary "Overview"
    In this module you will learn how to use Container-Native Storage to serve storage for OpenShift internal infrastructure.
    This module does not have any pre-requisites.

OpenShift Registry on CNS
-------------------------

The Registry in OpenShift is used to store all images that result of Source-to-Image deployments as well as custom container images.
It runs as one or more containers in specific Infrastructure Nodes or Master Nodes in OpenShift.

As explored in Module 1, by default the registry uses a hosts local storage (`emptyDir`) which makes it prone to outages. To avoid such outages the storage needs to be **persistent** and **shared** in order to survive Registry pod restarts and scale-out.

What we want to achieve is a setup like depicted in the following diagram:

[![OpenShift Registry on CNS](img/scaleout_registry_on_cns.png)](img/scaleout_registry_on_cns.png)

This can be achieved with CNS simply by making the registry pods refer to a PVC in access mode *RWX* based on CNS.
Before OpenShift Container Platform 3.6 this had to be done manually on an existing CNS cluster.

With `openshift-ansible` you now have this setup task automated. The playbooks that implement this will deploy a **separate CNS cluster**, preferably on the *Infrastructure Nodes*, create a `PVC` and update the Registry `DeploymentConfig` to mount the associated `PV` which is where container images will then be stored. This new cluster will be independent from the first one you created in Module 2, including it's own dedicated `heketi` instance.

In this step we will also enable the `gluster-block` capability. We do this because we want this separate CNS cluster to serve other infrastructure workloads like OpenShift Logging and Metrics as well. You will learn more about the nature of that feature in a few minutes.

First, let's deploy this CNS cluster with infrastructure focus. Currently `openshift-ansible` is missing some automation in regards to setting up requirements for `gluster-block`. We will compensate for that with a small Ansible playbook that you can copy & paste from below.

&#8680; Create the following file called `prepare-gluster-block.yml`:

<kbd>prepare-gluster-block.yml:</kbd>
~~~~yaml
---

- hosts: glusterfs_registry

  tasks:

    - name: install dependencies
      yum: name={{ item }} state=present
      with_items:
        - iscsi-initiator-utils
        - device-mapper-multipath

    - name: enable multipathing
      shell: mpathconf --enable
      args:
        creates: /etc/multipath.conf

    - name: configure iscsi multipathing
      blockinfile:
        path: /etc/multipath.conf
        block: |
         devices {
                  device {
                          vendor "LIO-ORG"
                          user_friendly_names "yes"
                          path_grouping_policy "failover"
                          path_selector "round-robin 0"
                          failback immediate
                          path_checker "tur"
                          prio "const"
                          no_path_retry 120
                          rr_weight "uniform"
                  }
          }

    - name: load required kernel modules
      modprobe: name={{ item }} state=present
      with_items:
        - dm_thin_pool
        - dm_multipath
        - target_core_user

    - name: ensure kernel modules load a boot
      lineinfile:
        path: /etc/modules-load.d/{{ item }}.conf
        line: "{{ item }}"
        create: yes
      with_items:
        - dm_thin_pool
        - dm_multipath
        - target_core_user

    - name: configure firewall
      shell: "iptables {{ item }}"
      with_items:
        - "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 24010 -j ACCEPT"
        - "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 3260 -j ACCEPT"
        - "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 111 -j ACCEPT"

    - name: persist firewall confg
      lineinfile:
        path: /etc/sysconfig/iptables
        line: "{{ item }}"
        insertafter: "^:OS_FIREWALL_ALLOW"
      with_items:
        - "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 24010 -j ACCEPT"
        - "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 3260 -j ACCEPT"
        - "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 111 -j ACCEPT"

    - name: start and enable rpcbind service
      service: name=rpcbind state=started enabled=yes

...
~~~~

&#8680; Save the file in your current directory and execute it like this:

    ansible-playbook -i /etc/ansible/ocp-with-glusterfs-registry prepare-gluster-block.yml

The playbook should finish without any errors. In the next release of `openshift-ansible` this manual preparation will not be necessary anymore.

Next, we will deploy the second CNS cluster and the update the OpenShift Registry configuration to store it's images on a `PersistentVolume` provided by that cluster.

!!! Caution "Important"
    This method is potentially disruptive. The registry will be re-deployed in this process and may temporarily be unavailable.
    Migration of the data will in the future be taken care of by `openshift-ansible`.

&#8680; Review the `openshift-ansible` inventory file in `/etc/ansible/ocp-with-glusterfs-registry` that has been prepared in your environment:

<kbd>/etc/ansible/ocp-with-glusterfs-registry:</kbd>
~~~~ini hl_lines="4 15 16 17 18 19 32 33 34 35 36 37 73 74 75 76"
[OSEv3:children]
masters
nodes
glusterfs_registry

[OSEv3:vars]
deployment_type=openshift-enterprise
containerized=true
openshift_image_tag=v3.6.173.0.21
openshift_master_identity_providers=[{'name': 'htpasswd', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]
openshift_master_htpasswd_users={'developer': '$apr1$bKWroIXS$/xjq07zVg9XtH6/VKuh6r/','operator': '$apr1$bKWroIXS$/xjq07zVg9XtH6/VKuh6r/'}
openshift_master_default_subdomain='cloudapps.52.59.170.248.xip.io'
openshift_router_selector='role=master'
openshift_hosted_router_wait=false
openshift_registry_selector='role=infra'
openshift_hosted_registry_wait=false
openshift_hosted_registry_storage_volume_size=10Gi
#openshift_hosted_registry_storage_glusterfs_swap=true
#openshift_hosted_registry_storage_glusterfs_swapcopy=true
openshift_metrics_install_metrics=false
openshift_metrics_hawkular_hostname="hawkular-metrics.{{ openshift_master_default_subdomain }}"
openshift_metrics_cassandra_storage_type=pv
openshift_metrics_cassandra_pvc_size=10Gi
openshift_logging_install_logging=false
openshift_logging_es_pvc_size=10Gi
openshift_logging_es_pvc_dynamic=true
openshift_logging_es_memory_limit=2G
openshift_storage_glusterfs_image=rhgs3/rhgs-server-rhel7
openshift_storage_glusterfs_version=3.3.0-362
openshift_storage_glusterfs_heketi_image=rhgs3/rhgs-volmanager-rhel7
openshift_storage_glusterfs_heketi_version=3.3.0-364
openshift_storage_glusterfs_registry_namespace=infra-storage
openshift_storage_glusterfs_registry_storageclass=false
openshift_storage_glusterfs_registry_block_deploy=true
openshift_storage_glusterfs_registry_block_version=3.3.0-362
openshift_storage_glusterfs_registry_block_host_vol_create=true
openshift_storage_glusterfs_registry_block_host_vol_size=30
openshift_docker_additional_registries=mirror.lab:5555
openshift_docker_insecure_registries=mirror.lab:5555
oreg_url=mirror.lab:5555/openshift3/ose-${component}:${version}
osm_etcd_image=mirror.lab:5555/rhel7/etcd
openshift_service_catalog_image_prefix=mirror.lab:5555/openshift3/ose-
openshift_cli_image=mirror.lab:5555/openshift3/ose
osm_image=mirror.lab:5555/openshift3/ose
openshift_examples_modify_imagestreams=false
openshift_disable_check=disk_availability,memory_availability,docker_image_availability
openshift_enable_service_catalog=true
openshift_template_service_broker_namespaces=['openshift']
template_service_broker_install=true
ansible_service_broker_install=false

[masters]
master.lab openshift_public_hostname=52.59.170.248.xip.io openshift_hostname=master.lab openshift_ip=10.0.1.100 openshift_public_ip=52.59.170.248

[masters:vars]
openshift_schedulable=true
openshift_node_labels="{'role': 'master'}"

[etcd:children]
masters

[nodes]
master.lab openshift_public_hostname=52.59.170.248.xip.io openshift_hostname=master.lab openshift_ip=10.0.1.100 openshift_public_ip=52.59.170.248
infra-1.lab openshift_hostname=infra-1.lab openshift_ip=10.0.2.101 openshift_node_labels="{'role': 'infra'}"
infra-2.lab openshift_hostname=infra-2.lab openshift_ip=10.0.3.102 openshift_node_labels="{'role': 'infra'}"
infra-3.lab openshift_hostname=infra-3.lab openshift_ip=10.0.4.103 openshift_node_labels="{'role': 'infra'}"
node-1.lab openshift_hostname=node-1.lab openshift_ip=10.0.2.201 openshift_node_labels="{'role': 'app'}"
node-2.lab openshift_hostname=node-2.lab openshift_ip=10.0.3.202 openshift_node_labels="{'role': 'app'}"
node-3.lab openshift_hostname=node-3.lab openshift_ip=10.0.4.203 openshift_node_labels="{'role': 'app'}"
node-4.lab openshift_hostname=node-4.lab openshift_ip=10.0.2.204 openshift_node_labels="{'role': 'app'}"
node-5.lab openshift_hostname=node-5.lab openshift_ip=10.0.3.205 openshift_node_labels="{'role': 'app'}"
node-6.lab openshift_hostname=node-6.lab openshift_ip=10.0.4.206 openshift_node_labels="{'role': 'app'}"

[glusterfs_registry]
infra-1.lab glusterfs_ip=10.0.2.101 glusterfs_zone=1 glusterfs_devices='[ "/dev/xvdc" ]'
infra-2.lab glusterfs_ip=10.0.3.102 glusterfs_zone=2 glusterfs_devices='[ "/dev/xvdc" ]'
infra-3.lab glusterfs_ip=10.0.4.103 glusterfs_zone=3 glusterfs_devices='[ "/dev/xvdc" ]'
~~~~

The highlighted lines indicate the vital options in the inventory file to instruct `openshift-ansible` to deploy this setup.

- a hostgroup called `[glusterfs_registry]` is created with all those OpenShift nodes that are designed to run CNS for Registry and other infrastructure
- an instruction to trigger deployment of CNS for the registry (`openshift_hosted_registry_storage_kind=glusterfs`)
- a custom name for the namespace is provided in which the CNS pods will live (`openshift_storage_glusterfs_registry_namespace`, optional)
- any existing registry backend will be swapped out for a CNS volume (`openshift_hosted_registry_storage_glusterfs_swap`, default `false`)
- any existing data on the old backend will be copied over to the CNS volume (`openshift_hosted_registry_storage_glusterfs_swapcopy`, default `false`)
- the `gluster-block` provisioner is enabled (`openshift_storage_glusterfs_registry_block_deploy`) and a version is selected (`openshift_storage_glusterfs_registry_block_version`)
- a 30GiB volume that `gluster-block` will use to back iSCSI LUNs will be created (`openshift_storage_glusterfs_registry_block_host_vol_create`, `openshift_storage_glusterfs_registry_block_host_vol_size`)

!!! Tip "Why are some entries commented out?"
    At this time of writing `openshift-ansible` has not fully implemented the new way of swapping the registry.
    These two settings

      - `openshift_hosted_registry_storage_glusterfs_swap: true`
      - `openshift_hosted_registry_storage_glusterfs_swapcopy: true`

    are required for the next version of `openshift-ansible`.
    In this lab we rely on a fall back behaviour with these settings disabled.

Hosts in the `[glusterfs_registry]` group will run the CNS cluster specifically created for OpenShift Infrastructure. Just like in Module 2, each host gets specific information about the free block device to use for CNS and the failure zone it resides in (the infrastructure nodes are also hosted in 3 different Availability Zones)
The option `openshift_hosted_registry_storage_kind=glusterfs` will cause the registry to re-deployed with a `PVC` served by this cluster.

&#8680; First ensure that from an Ansible-perspective the required nodes are reachable

    ansible -i /etc/ansible/ocp-with-glusterfs-registry glusterfs_registry -m ping


All 3 OpenShift infrastructure nodes should respond:

~~~~
infra-3.lab | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
infra-1.lab | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
infra-2.lab | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
~~~~

&#8680; Enable the Master to be schedulable:

    oadm manage-node master.lab --schedulable=true

!!! Important "Why does the master need to be schedulable?"
    This is a very simple lab environment :)
    There is no sophisticated external load-balancing across the infrastructure nodes in place.
    That's why the OpenShift router will run on the master node. The router will get re-deployed when executing the following playbook.
    So making the master accept pods again we ensure the re-deployed router finds it's place again. In a production environment this is not required.

&#8680; Run the CNS registry playbook that ships with `openshift-ansible`:

    ansible-playbook -i /etc/ansible/ocp-with-glusterfs-registry \
    /usr/share/ansible/openshift-ansible/playbooks/byo/openshift-glusterfs/registry.yml


This creates a new CNS deployment just for infrastructure workloads on the infrastructure nodes. This will take 5-6 minutes to complete and also create `PersistentVolume` and `PersistentVolumeClaim` objects for CNS volume that will serve the registry as a backend.

&#8680; Now, run the following playbook to update the registry's configuration:

    ansible-playbook -i /etc/ansible/ocp-with-glusterfs-registry \
    /usr/share/ansible/openshift-ansible/playbooks/byo/openshift-cluster/openshift-hosted.yml

This will take another 2-3 minutes. The playbook should complete without any errors.

&#8680; Disable scheduling on the Master again:

    oadm manage-node master.lab --schedulable=false

Now you have a Registry that uses CNS to store container images. It has been re-deployed and automatically scaled to 3 pods for high availability too.

&#8680; Log in as `operator` in the `default` namespace

    oc login -u operator -n default

&#8680; Verify a new version of the registry's `DeploymentConfig` is running:

    oc get deploymentconfig/docker-registry

It should say:

~~~
NAME              REVISION   DESIRED   CURRENT   TRIGGERED BY
docker-registry   2          1         1         config
~~~

&#8680; Verify you now have 3 registry pods running:

    oc get pods -l docker-registry

It should say:

~~~
NAME                      READY     STATUS    RESTARTS   AGE
docker-registry-2-5d4n7   1/1       Running   0          1m
docker-registry-2-89c28   1/1       Running   0          1m
docker-registry-2-mvgw9   1/1       Running   0          1m
~~~

&#8680; You can review the details and see how the `PVC` backs the registry by executing this command

    oc describe deploymentconfig/docker-registry

~~~~ hl_lines="36 37"
Name:		docker-registry
Namespace:	default
Created:	40 minutes ago
Labels:		docker-registry=default
Annotations:	<none>
Latest Version:	2
Selector:	docker-registry=default
Replicas:	3
Triggers:	Config
Strategy:	Rolling
Template:
Pod Template:
  Labels:		docker-registry=default
  Service Account:	registry
  Containers:
   registry:
    Image:	mirror.lab:5555/openshift3/ose-docker-registry:v3.7.14
    Port:	5000/TCP
    Requests:
      cpu:	100m
      memory:	256Mi
    Liveness:	http-get https://:5000/healthz delay=10s timeout=5s period=10s #success=1 #failure=3
    Readiness:	http-get https://:5000/healthz delay=0s timeout=5s period=10s #success=1 #failure=3
    Environment:
      REGISTRY_HTTP_ADDR:					:5000
      REGISTRY_HTTP_NET:					tcp
      REGISTRY_HTTP_SECRET:					xeEy14G8IIpgkmQ5mA4UMC+XMhZgEfCy8JRvTN003oQ=
      REGISTRY_MIDDLEWARE_REPOSITORY_OPENSHIFT_ENFORCEQUOTA:	false
      REGISTRY_HTTP_TLS_KEY:					/etc/secrets/registry.key
      REGISTRY_HTTP_TLS_CERTIFICATE:				/etc/secrets/registry.crt
    Mounts:
      /etc/secrets from registry-certificates (rw)
      /registry from registry-storage (rw)
  Volumes:
   registry-storage:
    Type:	PersistentVolumeClaim (a reference to a PersistentVolumeClaim in the same namespace)
    ClaimName:	registry-claim
    ReadOnly:	false
   registry-certificates:
    Type:	Secret (a volume populated by a Secret)
    SecretName:	registry-certificates
    Optional:	false

Deployment #2 (latest):
	Name:		docker-registry-2
	Created:	15 minutes ago
	Status:		Complete
	Replicas:	3 current / 3 desired
	Selector:	deployment=docker-registry-2,deploymentconfig=docker-registry,docker-registry=default
	Labels:		docker-registry=default,openshift.io/deployment-config.name=docker-registry
	Pods Status:	3 Running / 0 Waiting / 0 Succeeded / 0 Failed
Deployment #1:
	Created:	40 minutes ago
	Status:		Complete
	Replicas:	0 current / 0 desired

Events:
  FirstSeen	LastSeen	Count	From				SubObjectPath	Type		Reason			Message
  ---------	--------	-----	----				-------------	--------	------			-------
  40m		40m		1	deploymentconfig-controller			Normal		DeploymentCreated	Created new replication controller "docker-registry-1" for version 1
  15m		15m		1	deploymentconfig-controller			Normal		DeploymentCreated	Created new replication controller "docker-registry-2" for version 2
~~~~

While the exact output will be different for you it is easy to tell the registry pods are configured to mount a `PersistentVolume` associated with the `PersistentVolumeClaim` named `registry-claim`.

&#8680; Verify this `PVC` exists:

    oc get pvc/registry-claim

The `PVC` was automatically generated by `openshift-ansible`:

~~~~
NAME             STATUS    VOLUME            CAPACITY   ACCESSMODES   STORAGECLASS   AGE
registry-claim   Bound     registry-volume   10Gi       RWX                          23m
~~~~

In the OpenShift UI you will see the new Registry configuration when you log on as `operator` and check the **Overview** page in the `default` namespace:

[![Registry Deployment Scaled](img/registry_3way_dc.png)](img/registry_3way_dc.png)

`openshift-ansible` generated an independent set of GlusterFS pods and even separate instance of `heketi`. These components were configured to use the `infra-storage` namespace. It has consciously **not configured** a `StorageClass` and statically provioned the `PV` and `PVC` for `registry-claim`. This is in order to prevent accidental deletion of the Registry storage.
Refer to Module 2 to get an understanding of those components if you just skipped to here.

&#8680; Verify there are at least 3 GlusterFS pods and one `heketi` pod:

    oc get pods -n infra-storage

There is now dedicated a CNS stack including the `gluster-block` provisioner for OpenShift Infrastructure:

~~~~
NAME                                           READY     STATUS    RESTARTS   AGE
glusterblock-registry-provisioner-dc-1-6wlcw   1/1       Running   0          24m
glusterfs-registry-2f2vk                       1/1       Running   0          27m
glusterfs-registry-kxghm                       1/1       Running   0          27m
glusterfs-registry-pjrfl                       1/1       Running   0          27m
heketi-registry-1-6rjth                        1/1       Running   0          25m
~~~~

With this you have successfully remediated a single point of failure from your OpenShift installation. Since this setup is entirely automated by `openshift-ansible` you can deploy out of the box an OpenShift environment capable of hosting stateful applications and operate a fault-tolerant registry. All this with no external dependencies or complicated integration of external storage :)

---

OpenShift Logging/Metrics on CNS block storage
----------------------------------------------

OpenShift Logging (Kibana) and Metrics (Cassandra) are also components that require persistent storage. Typically so far external block storage providers had to be used in order to get these services to work reliably.
Since the introduction of `gluster-block` this is now possible with CNS as well.

#### A `gluster-block` crash course

`gluster-block` is a block-storage provisioner based on CNS. It is implemented using a large GlusterFS volume that hosts sparse files which in turn are the backing files of iSCSI LUNs served by `gluster-block`. The orchestration of this taken care of by the `gluster-block-provisioner` which runs in a pod just like `heketi`.
Even though the result of this are iSCSI LUNs, i.e. block devices, this kind of storage, when claimed, still ends up being mounted by OpenShift nodes and then formatted with XFS (like for any other block storage in OpenShift). As a consequence `gluster-block` only supports `RWO` volumes.

!!! Tip "Will this not make things slower?"
    So you may ask: is this, an XFS-formatted iSCSI LUN backed by a sparse file on top of GlusterFS, still faster than a plain GlusterFS volume? The answer is yes for applications like OpenShift Metrics and Logging. Such applications regularly do file-system operations like locking or byte-range locking which are very expensive on any distributed filesystem, and GlusterFS is no exception. On local filesystems like XFS this is not a problem. The resulting XFS meta-data operations are not distributed in `gluster-block` but are perceived as plain I/O to a file on top of GlusterFS through the iSCSI target which is fast.

It might seem counter-intuitive at first to consider CNS to serve these systems, mainly because:

  - Kibana and Cassandra are shared-nothing scale-out services
  - CNS provides shared filesystem storage whereas for Kibana/Cassandra a block storage device formatted with a local filesystem like XFS would be enough

Here are a couple of reasons why it is still a good idea to run those on CNS:

  - the total amount of storage available infra nodes is typically limited in capacity (CNS can scale beyond that)
  - the storage type available in infra nodes is most likely not suitable for performant long-term operations of these services (CNS uses aggregate performance of multiple devices and hosts)
  - without CNS some sort external storage system is required that requires additional manual configuration steps, in any case you should not use `emptyDir`

#### Completing `gluster-block` setup

With the execution of previous playbook we have also deployed and configured `gluster-block`. The required settings were all in the Ansible inventory file. Note that while the registry will consume a normal CNS volume based on `gluster-fuse`, GlusterFS' native file protocol, the only supported form of CNS backing both OpenShift Logging and/or Metrics is `gluster-block`.


Now, the only configuration step left is to create a `StorageClass` for `gluster-block` and temporarily make it the default so the playbooks which provision OpenShift Logging and Metrics get their PVCs fulfilled by `gluster-block`.  For more details on the `gluster-block`, consult the [documentation](https://access.redhat.com/documentation/en-us/red_hat_gluster_storage/3.3/html-single/container-native_storage_for_openshift_container_platform/#Block_Storage).

First, make sure you are logged in as `operator` in the `infra-storage` namespace:

    oc login -u operator -n infra-storage

Then, programmatically determine the auto-generated credentials for the `heketi` pod and the cluster ID for the CNS cluster serving the registry:

~~~~
HEKETI_POD=$(oc get pods -l glusterfs=heketi-registry-pod -n infra-storage -o jsonpath="{.items[0].metadata.name}")
export HEKETI_CLI_SERVER=http://$(oc get route/heketi-registry -o jsonpath='{.spec.host}')
export HEKETI_CLI_USER=admin
export HEKETI_CLI_KEY=$(oc get pod/$HEKETI_POD -o jsonpath='{.spec.containers[0].env[?(@.name=="HEKETI_ADMIN_KEY")].value}')
export CNS_INFRA_CLUSTER=$(heketi-cli cluster list --json | jq -r '.clusters[0]')
export HEKETI_ADMIN_KEY_SECRET=$(echo -n ${HEKETI_CLI_KEY} | base64)
~~~~

The, create YAML representation of the `secret` to store the credentials for the `heketi` pod by copy&pasting the following command (inserts the credentials from the environment variable for you convenience):

~~~~
cat > gluster-block-secret.yml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: heketi-secret
  namespace: infra-storage
data:
  # base64 encoded password. E.g.: echo -n "mypassword" | base64
  key: ${HEKETI_ADMIN_KEY_SECRET}
type: gluster.org/glusterblock
EOF
~~~~

Create the `secret`:

    oc create -f gluster-block-secret.yml

Now create the actual `StorageClass` for `gluster-block`, again by running this command that creates the file with the right content and saves you from typing:

~~~~
cat > gluster-block-storageclass.yml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
 name: glusterfs-block
provisioner: gluster.org/glusterblock
parameters:
 resturl: "${HEKETI_CLI_SERVER}"
 restuser: "${HEKETI_CLI_USER}"
 restsecretnamespace: "infra-storage"
 restsecretname: "heketi-secret"
 hacount: "3"
 clusterids: "${CNS_INFRA_CLUSTER}"
 chapauthenabled: "true"
EOF
~~~~

Now create the `StorageClass`:

    oc create -f gluster-block-storageclass.yml

To review the required configuration sections in the `openshift-ansible` inventory file, open the standard inventory file `/etc/ansible/ocp-with-glusterfs-registry` that was used to deploy this OCP cluster initially:

<kbd>/etc/ansible/ocp-with-glusterfs-registry:</kbd>
~~~~ini hl_lines="21 22 24 25"
[OSEv3:children]
masters
nodes

[OSEv3:vars]
deployment_type=openshift-enterprise
containerized=true
openshift_image_tag=v3.7.14
openshift_master_identity_providers=[{'name': 'htpasswd', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]
openshift_master_htpasswd_users={'developer': '$apr1$bKWroIXS$/xjq07zVg9XtH6/VKuh6r/','operator': '$apr1$bKWroIXS$/xjq07zVg9XtH6/VKuh6r/'}
openshift_master_default_subdomain='cloudapps.52.59.170.248.xip.ioopenshift_router_selector='role=master'
openshift_hosted_router_wait=false
openshift_registry_selector='role=infra'
openshift_hosted_registry_wait=false
openshift_hosted_registry_storage_volume_size=10Gi
openshift_hosted_registry_storage_kind=glusterfs
#openshift_hosted_registry_storage_glusterfs_swap=true
#openshift_hosted_registry_storage_glusterfs_swapcopy=true
openshift_metrics_install_metrics=false
openshift_metrics_hawkular_hostname="hawkular-metrics.{{ openshift_master_default_subdomain }}"
openshift_metrics_cassandra_storage_type=pv
openshift_metrics_cassandra_pvc_size=10Gi
openshift_logging_install_logging=false
openshift_logging_es_pvc_size=10Gi
openshift_logging_es_pvc_dynamic=true
openshift_logging_es_memory_limit=2G

[... output omitted... ]
~~~~

The highlighted lines indicate the settings that are required in order to put the Cassandra database of the OpenShift Metrics service on a `PersistentVolume` (`openshift_metrics_cassandra_storage_type=pv`) and how large this volume should be (`openshift_metrics_cassandra_pvc_size=10Gi`).
Similarly the backend for the ElasticSearch component of OpenShift Logging is set to `PersistentVolume` (`openshift_logging_es_pvc_dynamic=true`) and the size is specifed (`openshift_logging_es_pvc_size=10Gi`).
With these settings in place `openshift-ansible` will request `PVC` object for these services.

Unfortunately `openshift-ansible` today is lacking the ability to specify a certain `StorageClass` with those `PVCs`, so we have to make the CNS cluster that was created above temporarily the system-wide default.

&#8680; Login as `operator` to the `openshift-infra` namespace:

    oc login -u operator -n openshift-infra

&#8680; First, if you deployed the general-purpose CNS cluster in [Module 2](../module-2-deploy-cns/), you need to disable the other `StorageClass` `glusterfs-storage` from the other CNS stack as being the default:

    oc patch storageclass glusterfs-storage \
    -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'

This is because the playbooks for Metrics and Logging don't allow to specify a `StorageClass` name for the `PVC` they will generate. Hence it will take the default and we make that temporarily be `gluster-block`.

&#8680; Again, use the `oc patch` command again to change the definition of the `StorageClass` `glusterfs-block` on the fly:

    oc patch storageclass glusterfs-block \
    -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'

&#8680; Verify that now the `StorageClass` `glusterfs-block` is the default:

    oc get storageclass

~~~~ hl_lines="2"
NAME                           TYPE
glusterfs-block (default)      gluster.org/glusterblock
glusterfs-storage              kubernetes.io/glusterfs
~~~~

#### Deploying OpenShift Metrics with Persistent Storage from CNS

The inventory file `/etc/ansible/ocp-with-glusterfs-registry` as explained has all the required options set to run Logging/Metrics on dynamic provisioned storage supplied via a `PVC`. The only variable that we need to override is (`openshift_metrics_install_metrics`) to actually invoke the required playbooks the installation.

&#8680; Execute the Metrics deployment playbook like this:

    ansible-playbook -i /etc/ansible/ocp-with-glusterfs-registry \
        -e openshift_metrics_install_metrics=True \
        /usr/share/ansible/openshift-ansible/playbooks/byo/openshift-cluster/openshift-metrics.yml

This takes about 3-4 minutes to complete. However the deployment is not quite finished yet.

&#8680; Use the `watch` command to wait for the `hawkular-metrics` pod to be in `READY` state.

    watch oc get pods -l name=hawkular-metrics

Exit out of the watch mode with: <kbd>Ctrl</kbd> + <kbd>c</kbd>

It will be ready when the database (Cassandra) finished initializing. Alternatively in the UI observe the deployment in the **Overview** pane, focussing on the `hawkular-metrics` deployment:

[![Waiting on OpenShift Metrics to be deployed](img/waiting_for_metrics_on_cns.png)](img/waiting_for_metrics_on_cns.png)

After 2-3 minutes all 3 pods, that make up the OpenShift Metrics service, should be ready:

&#8680; Verify all pods in the namespace have a `1/1` in the `READY` column:

    oc get pods

~~~~
NAME                         READY     STATUS    RESTARTS   AGE
hawkular-cassandra-1-sxctx   1/1       Running   0          5m
hawkular-metrics-895xz       1/1       Running   0          5m
heapster-pjxpp               1/1       Running   0          5m
~~~~

To use the Metrics service you need to logon / reload the OpenShift UI in your browser. You will then see a warning message like this one:

[![OpenShift Metrics Warning](img/metrics_warning.png)](img/metrics_warning.png)

Don't worry - this is due to self-signed SSL certificates in this environment.

&#8680; Click the **Open Metrics URL** link and accept the self-signed certificate in your new browser tab. You will see the status page of the OpenShift Hawkular Metrics component:

[![OpenShift Metrics Hawkular](img/metrics_hawkular.png)](img/metrics_hawkular.png)

&#8680; Then go back to the overview page and **reload your browser again**. Next to the pods monitoring graphs for CPU, memory and network consumption will now appear:

[![OpenShift Metrics Graphs](img/metrics_graphs.png)](img/metrics_graphs.png)

If you change to the **Storage** menu in the OpenShift UI you will also see the `PVC` that `openshift-ansible` has set up for the Cassandra pod.

[![OpenShift Metrics PVC](img/metrics_pvc.png)](img/metrics_pvc.png)

Congratulations. You have successfully deploy OpenShift Metrics using scalable, fault-tolerant and persistent storage. The data that you see visualized in the UI is stored on a `PersistentVolume` served by CNS using `gluster-block`.

#### Deploying OpenShift Logging with Persistent Storage from CNS

In a very similar fashion you can install OpenShift Logging Services, run by Kibana and ElasticSearch.

&#8680; As `operator`, login in to the `logging` namespace:

    oc login -u operator -n logging

The settings for Logging are already in place in the inventory file (see the previous listing before you deployed Metrics).

&#8680; Execute the Logging deployment playbook like this:

    ansible-playbook -i /etc/ansible/ocp-with-glusterfs-registry \
      -e openshift_logging_install_logging=true \
      /usr/share/ansible/openshift-ansible/playbooks/byo/openshift-cluster/openshift-logging.yml

After 5 minutes the playbook finishes and you have a number of new pods in the `logging` namespace:

&#8680; List all the ElasticSearch pods that aggregate and store the logs:

    oc get pods -l component=es

This pod runs a single ElasticSearch instance.

~~~~
NAME                                      READY     STATUS    RESTARTS   AGE
logging-es-data-master-kcbtgll3-1-vb34h   1/1       Running   0          11m
~~~~

&#8680; List the Kibana pod:

    oc get pods -l component=kibana

This pod runs the Kibana front-end to query and search through logs:

~~~~
NAME                     READY     STATUS    RESTARTS   AGE
logging-kibana-1-1c2dj   2/2       Running   0          11m
~~~~

&#8680; List all Fluentd pods:

    oc get pods -l component=fluentd

These pods run as part of a `DaemonSet` and are responsible for collecting and shipping the various logs from all nodes to the ElasticSearch instance.

~~~~
NAME                    READY     STATUS    RESTARTS   AGE
logging-fluentd-3k7nh   1/1       Running   0          5m
logging-fluentd-473cf   1/1       Running   0          4m
logging-fluentd-9kgsv   1/1       Running   0          5m
logging-fluentd-h8fhb   1/1       Running   0          4m
logging-fluentd-pb6h8   1/1       Running   0          4m
logging-fluentd-q6lv4   1/1       Running   0          4m
logging-fluentd-r455n   1/1       Running   0          4m
logging-fluentd-v34ll   1/1       Running   0          5m
logging-fluentd-vxnd3   1/1       Running   0          5m
logging-fluentd-wf3lr   1/1       Running   0          5m
~~~~

Switch to the OpenShift UI and as `operator` select the `logging` project. In the **Overview** section you'll a `Route` for the Kibana deployment created. **Click** the link on the `Route` to open the Kibana UI in a new browser tab and verify the Kibana deployment is healthy.

[![OpenShift Logging Pods](img/kibana_pod_ready.png)](img/kibana_pod_ready.png)

The public URL for the Kibana UI will be visible in the **ROUTES** section of the `logging-kibana` deployment.

[![OpenShift Logging UI](img/kibana_ui_loading.png)](img/kibana_ui_loading.png)

When you are logging on for the first time Kibana will ask for credentials.
Use your OpenShift `operator` account with the password `r3dh4t`.

After logging in you will see the Kibana dashboard whichs displays log data from it's index, which is hosted on CNS by ElasticSearch.

[![OpenShift Logging Indexing](img/kibana_es_dashboard.png)](img/kibana_es_dashboard.png)

This shows that ElasticSearch search running of CNS-provided `PersistentVolume` successfully.

Now let's put back things in order and make the `StorageClass` for the first CNS cluster the default again.

&#8680; Again, use the `oc patch` command again to change the definition of the `StorageClass` `glusterfs-block` on the fly:

    oc patch storageclass glusterfs-block \
    -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'

&#8680;  Patch the `StorageClass` `glusterfs-storage` from the first CNS stack to be the default:

    oc patch storageclass glusterfs-storage \
    -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
