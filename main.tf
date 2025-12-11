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
  family = "almalinux-10"
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
    ssh-keys = "almalinux:${file("~/.ssh/id_ed25519.pub")}"
  }

  scheduling_policy {
    preemptible = false
  }
}
