locals {
  k3s_server_token = base64encode("coscup-workshop-master${uuid()}")
  k3s_agent_token  = base64encode("coscup-workshop-agent-${uuid()}")
}

provider "openstack" {
  auth_url = "https://openstack.cloudnative.tw:5000/v3"
}

resource "openstack_compute_keypair_v2" "key" {
  name       = "workshop_key"
  public_key = file("~/.ssh/id_ed25519.pub")
}

resource "openstack_networking_router_v2" "router" {
  name                = "workshop_router"
  admin_state_up      = true
  external_network_id = "a13bc653-bc5d-4274-9de6-32a40df0d881"
}

resource "openstack_networking_network_v2" "network" {
  name = "workshop"
}

resource "openstack_networking_subnet_v2" "subnet" {
  network_id = openstack_networking_network_v2.network.id
  cidr       = "192.168.10.0/24"
  ip_version = 4
  name       = "workshop_subnet"

  allocation_pool {
    start = "192.168.10.10"
    end   = "192.168.10.100"
  }

  dns_nameservers = ["1.1.1.1"]
  enable_dhcp     = true
}

resource "openstack_networking_router_interface_v2" "router_interface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.subnet.id
}

#######################
#         HTTP        #
#######################
resource "openstack_networking_secgroup_v2" "http" {
  name        = "http"
  description = "Allow HTTP/HTTPS from anywhere"
}

//SSH PORT
resource "openstack_networking_secgroup_rule_v2" "default" {
  direction = "ingress"
  ethertype = "IPv4"
  protocol  = "tcp"

  port_range_min   = 22
  port_range_max   = 22
  remote_ip_prefix = "0.0.0.0/0"

  security_group_id = var.default_secgroup_id
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  direction = "ingress"
  ethertype = "IPv4"
  protocol  = "tcp"

  port_range_min   = 80
  port_range_max   = 80
  remote_ip_prefix = "0.0.0.0/0"

  security_group_id = openstack_networking_secgroup_v2.http.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction = "ingress"
  ethertype = "IPv4"
  protocol  = "tcp"

  port_range_min   = 443
  port_range_max   = 443
  remote_ip_prefix = "0.0.0.0/0"

  security_group_id = openstack_networking_secgroup_v2.http.id
}

#######################
#  Control Plane API  #
#######################
resource "openstack_networking_secgroup_v2" "control_plane_api" {
  name        = "control-plane-api"
  description = "Allow API traffic to control plane api"
}

resource "openstack_networking_secgroup_rule_v2" "control_plane_api" {
  direction = "ingress"
  ethertype = "IPv4"
  protocol  = "tcp"

  port_range_min   = 6443
  port_range_max   = 6443
  remote_ip_prefix = "0.0.0.0/0"

  security_group_id = openstack_networking_secgroup_v2.control_plane_api.id
}

resource "openstack_identity_application_credential_v3" "credential" {
  name  = "k0s-cloud-credentials"
  roles = ["reader", "member", "load-balancer_member"]
}

resource "openstack_networking_port_v2" "master_port" {
  depends_on = [openstack_networking_subnet_v2.subnet]
  count      = var.master_count
  network_id = openstack_networking_network_v2.network.id
  name       = "master_port_${count.index}"
  security_group_ids = [
    var.default_secgroup_id,
    openstack_networking_secgroup_v2.http.id,
    openstack_networking_secgroup_v2.control_plane_api.id,
  ]

}

resource "openstack_compute_instance_v2" "master" {
  name            = "k3s_master"
  image_id        = "8a39b990-5fac-41bb-8abe-b864dff0aa60"
  flavor_id       = "m1.medium"
  key_pair        = "workshop_key"
  count           = var.master_count
  
  network {
    port = openstack_networking_port_v2.master_port[count.index].id
  }

}

resource "openstack_networking_floatingip_v2" "master_fip" {
  depends_on = [openstack_compute_instance_v2.master]
  count = var.master_count
  pool = "public-jp"
  port_id = openstack_networking_port_v2.master_port[count.index].id
}

resource "null_resource" "provision_master" {
  depends_on = [openstack_networking_floatingip_v2.master_fip]
  count = length(openstack_compute_instance_v2.master)

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = element(openstack_networking_floatingip_v2.master_fip.*.address, count.index)
      timeout     = "500s"
      private_key = file("~/.ssh/id_ed25519")
    }

    inline = [
      <<EOF
        curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=latest K3S_KUBECONFIG_MODE=644 \
          sh -s - \
          server \
          --token "${local.k3s_server_token}" \
          --agent-token "${local.k3s_agent_token}" \
          --advertise-address "${element(openstack_compute_instance_v2.master.*.network.0.fixed_ip_v4, count.index)}" \
          --tls-san "${element(openstack_compute_instance_v2.master.*.network.0.fixed_ip_v4, count.index)}" \
          --tls-san "${element(openstack_networking_floatingip_v2.master_fip.*.address, count.index)}" \
          --disable=local-storage \
          ${count.index == 0 ? "--cluster-init" : ""}
        EOF
    ]
  }
}

resource "openstack_networking_port_v2" "worker_port" {
  depends_on = [openstack_networking_subnet_v2.subnet]
  count      = var.worker_count
  network_id = openstack_networking_network_v2.network.id
  name       = "worker_port_${count.index}"
}

resource "openstack_compute_instance_v2" "worker" {
  depends_on = [null_resource.provision_master]

  name            = "k3s_worker"
  image_id        = "8a39b990-5fac-41bb-8abe-b864dff0aa60"
  flavor_id       = "m1.medium"
  key_pair        = "workshop_key"
  count           = var.worker_count

  network {
    port = openstack_networking_port_v2.worker_port[count.index].id
  }
}

resource "openstack_networking_floatingip_v2" "worker_fip" {
  depends_on = [openstack_compute_instance_v2.worker]
  count = var.worker_count
  pool = "public-jp"
#  fixed_ip = element(openstack_compute_instance_v2.worker.*.network.0.fixed_ip_v4, count.index)
  port_id = openstack_networking_port_v2.worker_port[count.index].id
}

resource "null_resource" "provision_worker" {
  depends_on = [openstack_networking_floatingip_v2.worker_fip]
  count = length(openstack_compute_instance_v2.worker)

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = element(openstack_networking_floatingip_v2.worker_fip.*.address, count.index)
      timeout     = "500s"
      private_key = file("~/.ssh/id_ed25519")
    }

    inline = [
      <<EOF
        curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=latest \
          sh -s - \
          agent \
          --token "${local.k3s_agent_token}" \
          --server "https://${openstack_networking_floatingip_v2.master_fip[0].address}:6443" \
          --node-ip "${element(openstack_networking_floatingip_v2.worker_fip.*.address, count.index)}" \
          --node-label=purpose=worker
        EOF
    ]
  }
}
