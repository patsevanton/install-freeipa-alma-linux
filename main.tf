resource "yandex_vpc_network" "main" {
  name = "freeipa-network"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "freeipa-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = ["10.0.0.0/24"]
}

data "yandex_compute_image" "ubuntu" {
  family = "fedora-37"
}

resource "yandex_compute_instance" "vm" {
  name        = "freeipa-instance"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 20
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "fedora:${file("~/.ssh/id_ed25519.pub")}"
  }

  scheduling_policy {
    preemptible = false
  }
}

resource "null_resource" "vm" {
  provisioner "local-exec" {
    command = <<EOF
      ansible-galaxy collection install freeipa.ansible_freeipa
      ansible-playbook -i ${yandex_compute_instance.vm[*].network_interface[0].nat_ip_address}, ${path.module}/provision/playbook.yml'
    EOF
    environment = {
      ANSIBLE_HOST_KEY_CHECKING  = "False"
      ANSIBLE_CONFIG             = "${path.module}/ansible.cfg"
    }
  }
  depends_on = [yandex_compute_instance.vm]
}

