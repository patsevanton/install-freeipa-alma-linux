# Инструкция по настройке FreeIPA с внешним сертификатом

Цель: Развернуть сервер **FreeIPA** с использованием **внешнего TLS‑сертификата**, выпущенного собственной двухуровневой PKI (Root CA + Intermediate CA), созданной через OpenSSL.

В результате:
* FreeIPA работает с сертификатом, выпущенным **не встроенным CA**, а внешним;
* есть контролируемая цепочка доверия;
* корневой ключ не используется в продакшене;
* сертификаты можно обновлять и отзывать независимо от FreeIPA.

## Обзор архитектуры

```
Root CA (apatsev.corp)
 └── Intermediate CA (intermediate.apatsev.corp)
     └── TLS-сертификат FreeIPA (ipa.apatsev.corp)
```

FreeIPA:
* DNS: `apatsev.corp`
* Hostname: `ipa.apatsev.corp`
* Realm: `APATSEV.CORP`

## Комментарии для начинающих DevOps

* **FreeIPA** — это центр управления идентификацией (LDAP + Kerberos + DNS + CA).
* По умолчанию FreeIPA поднимает **собственный CA**, но чаще нужно использовать корпоративный CA.
* Поэтому мы используем **внешний сертификат**, выпущенный собственной PKI.

### Почему двухуровневая PKI

* Root CA хранится оффлайн.
* Intermediate CA используется для выпуска сертификатов.
* В случае компрометации Intermediate CA — Root остаётся безопасным.

## Предварительные требования

### На управляющей машине (Ansible host)

* `ansible >= 2.14`
* `openssl`
* `python3`
* SSH‑доступ к серверу FreeIPA

### На сервере FreeIPA

* Fedora / Rocky / Alma / RHEL
* Открыты порты:
  * 80, 443
  * 389, 636
  * 88, 464
  * 53 (TCP/UDP)

## Шаг 1. Подготовка сервера FreeIPA

На сервере:

```bash
sudo hostnamectl set-hostname ipa.apatsev.corp
```

Проверь:

```bash
hostname -f
```

Должно быть:

```
ipa.apatsev.corp
```

## Шаг 2. Создание корневого и промежуточного CA (OpenSSL)

> **Этот шаг выполняется НЕ на сервере FreeIPA**, а на отдельной защищённой машине.

### 2.1 Создание Root CA

#### Конфигурация Root CA

```bash
cat <<EOF > rootCA.cnf
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[ req_distinguished_name ]
C = RU
ST = Omsk Oblast
L = Omsk
O = MyCompany
OU = Apatsev
CN = apatsev.corp Root CA

[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
```

#### Генерация ключа

```bash
openssl genrsa -out rootCA.key 4096
```

#### Самоподписанный сертификат

```bash
openssl req -x509 -new -key rootCA.key \
  -sha256 -days 3650 \
  -out rootCA.crt \
  -config rootCA.cnf -extensions v3_ca
```

### 2.2 Создание Intermediate CA

#### Ключ

```bash
openssl genrsa -out intermediateCA.key 4096
```

#### Конфигурация

```bash
cat <<EOF > intermediateCA.cnf
[ req ]
distinguished_name = req_distinguished_name
prompt = no

[ req_distinguished_name ]
C = RU
ST = Omsk Oblast
L = Omsk
O = MyCompany
OU = Apatsev
CN = intermediate.apatsev.corp Intermediate CA

[ v3_intermediate_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
```

#### CSR

```bash
openssl req -new \
  -key intermediateCA.key \
  -out intermediateCA.csr \
  -config intermediateCA.cnf
```

#### Подписание Root CA

```bash
openssl x509 -req \
  -in intermediateCA.csr \
  -CA rootCA.crt \
  -CAkey rootCA.key \
  -CAcreateserial \
  -out intermediateCA.crt \
  -days 1825 \
  -sha256 \
  -extfile intermediateCA.cnf \
  -extensions v3_intermediate_ca
```

#### Проверка

```bash
openssl verify -CAfile rootCA.crt intermediateCA.crt
```

## Шаг 3. Выпуск сертификата для FreeIPA

### 3.1 Ключ для FreeIPA

```bash
openssl genrsa -out ipa.apatsev.corp.key 4096
```

### 3.2 CSR для FreeIPA

```bash
cat <<EOF > ipa.cnf
[ req ]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[ dn ]
CN = ipa.apatsev.corp
O = MyCompany

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ipa.apatsev.corp
DNS.2 = ipa
EOF
```

```bash
openssl req -new \
  -key ipa.apatsev.corp.key \
  -out ipa.apatsev.corp.csr \
  -config ipa.cnf
```

### 3.3 Подписание Intermediate CA

```bash
openssl x509 -req \
  -in ipa.apatsev.corp.csr \
  -CA intermediateCA.crt \
  -CAkey intermediateCA.key \
  -CAcreateserial \
  -out ipa.apatsev.corp.crt \
  -days 825 \
  -sha256 \
  -extensions req_ext \
  -extfile ipa.cnf
```

### 3.4 Сборка цепочки

```bash
cat ipa.apatsev.corp.crt intermediateCA.crt rootCA.crt > ipa-fullchain.crt
```
## Шаг 4. Установка FreeIPA с внешним сертификатом (Ansible)

### 4.1 Установка ролей

```bash
ansible-galaxy collection install freeipa.ansible_freeipa
```

Развёртывание выполняется через **Ansible** с использованием inventory‑файла.

### 4.2 Подготовка файлов сертификата для Ansible

Перед установкой необходимо разместить файлы сертификата на управляющей машине в доступном для плейбука месте. Рекомендуемая структура:

```
files/
├── ipa.apatsev.corp.key
├── ipa-fullchain.crt
└── intermediateCA.crt
```

Убедитесь, что:
* `ipa.apatsev.corp.key` — приватный ключ сервера;
* `ipa-fullchain.crt` — полная цепочка (сертификат сервера + промежуточный CA + корневой CA);
* `intermediateCA.crt` — отдельный файл промежуточного CA (потребуется для настройки доверия).

### 4.3 Корректировка playbook.yaml

Ниже приведён исправленный вариант плейбука `install-ipa.yml` с поддержкой внешнего сертификата:

```yaml
---
- name: Install FreeIPA server with external CA
  hosts: ipaserver
  become: true
  vars:
    ipaserver_external_ca: true
    ipaserver_cert_file: "/tmp/ipa-fullchain.crt"
    ipaserver_key_file: "/tmp/ipa.apatsev.corp.key"
    ipaserver_ca_cert_file: "/tmp/intermediateCA.crt"

  pre_tasks:
    - name: Copy certificate files to target host
      copy:
        src: "files/{{ item }}"
        dest: "/tmp/{{ item }}"
      loop:
        - ipa.apatsev.corp.key
        - ipa-fullchain.crt
        - intermediateCA.crt
      mode: '0600'

  roles:
    - role: freeipa.ansible_freeipa.ipaserver
      vars:
        ipaserver_setup_adtrust: false
        ipaserver_setup_kra: true
        ipaserver_setup_dns: true
        ipaserver_domain: "{{ ipaserver_domain }}"
        ipaserver_realm: "{{ ipaserver_realm }}"
        ipaserver_hostname: "{{ ipaserver_hostname }}"
        ipaserver_ip_addresses: "{{ ipaserver_ip_addresses }}"
        ipaadmin_password: "{{ ipaadmin_password }}"
        ipadm_password: "{{ ipadm_password }}"
        ipaserver_no_host_dns: "{{ ipaserver_no_host_dns | default(false) }}"
        ipaserver_forwarders: "{{ ipaserver_forwarders | default([]) }}"
        # Параметры внешнего CA
        ipaserver_external_ca: "{{ ipaserver_external_ca }}"
        ipaserver_cert_file: "{{ ipaserver_cert_file }}"
        ipaserver_key_file: "{{ ipaserver_key_file }}"
        ipaserver_ca_cert_file: "{{ ipaserver_ca_cert_file }}"

  post_tasks:
    - name: Remove temporary certificate files
      file:
        path: "/tmp/{{ item }}"
        state: absent
      loop:
        - ipa.apatsev.corp.key
        - ipa-fullchain.crt
        - intermediateCA.crt
```

**Пояснения к ключевым параметрам:**
* `ipaserver_external_ca: true` — указывает на использование внешнего CA;
* `ipaserver_cert_file` — путь к полной цепочке сертификатов на целевом хосте;
* `ipaserver_key_file` — путь к приватному ключу на целевом хосте;
* `ipaserver_ca_cert_file` — путь к сертификату промежуточного CA (нужен для настройки доверия в системе).

### 4.4 Запуск установки

Выполните плейбук с указанием inventory:

```bash
ansible-playbook -i inventory.yml install-ipa.yml
```

### 4.5 Проверка корректности установки

После завершения установки выполните следующие проверки:

1. **Проверка TLS‑соединения:**
```bash
openssl s_client -connect ipa.apatsev.corp:443 -showcerts
```
В выводе должны присутствовать:
* сертификат сервера (`ipa.apatsev.corp`);
* промежуточный CA (`intermediate.apatsev.corp Intermediate CA`);
* корневой CA (`apatsev.corp Root CA`).

2. **Проверка состояния FreeIPA:**
```bash
ipa healthcheck
```
Ожидаемый результат — отсутствие критических ошибок.

3. **Проверка цепочки доверия:**
```bash
certutil -L -d /etc/dirsrv/slapd-APATSEV-CORP/
```
Убедитесь, что в списке есть все необходимые сертификаты.

## Шаг 5. Дополнительные настройки (опционально)

### 5.1 Настройка доверия к корневому CA

Чтобы клиенты системы доверяли сертификатам из вашей PKI, установите корневой CA на все машины домена:

```bash
sudo cp rootCA.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### 5.2 Автоматизация обновления сертификатов

Для планового обновления сертификатов:
1. Повторите шаги **3.1–3.4** для генерации нового сертификата.
2. Замените файлы в директории `files/`.
3. Выполните плейбук повторно (Ansible обновит сертификаты без пересоздания сервера).

## Шаг 6. Устранение типичных проблем

### Проблема 1: Ошибка «Certificate signature verification failed»

**Причина:** Некорректная цепочка сертификатов или отсутствие промежуточного CA.

**Решение:**
1. Проверьте содержимое `ipa-fullchain.crt`:
```bash
openssl crl2pkcs7 -certfile ipa-fullchain.crt -out chain.p7b -nocrl
openssl pkcs7 -in chain.p7b -print_certs -text -noout
```
2. Убедитесь, что все сертификаты присутствуют и валидны.

### Проблема 2: Ошибка «Private key does not match certificate»

**Причина:** Несоответствие приватного ключа и сертификата.

**Решение:**
1. Проверьте соответствие:
```bash
openssl x509 -noout -modulus -in ipa.apatsev.corp.crt | openssl md5
openssl rsa -noout -modulus -in ipa.apatsev.corp.key | openssl md5
```
2. Если хеши не совпадают — пересоздайте пару ключ/сертификат.

### Проблема 3: Ошибка «CA certificate not found»

**Причина:** Отсутствует сертификат промежуточного CA в настройках.

**Решение:** Убедитесь, что параметр `ipaserver_ca_cert_file` указывает на корректный файл промежуточного CA.

## Результат

После выполнения всех шагов:
* FreeIPA развёрнут с использованием внешнего TLS‑сертификата;
* цепочка доверия контролируется вашей PKI (Root CA + Intermediate CA);
* сервер готов к работе в продакшен‑среде;
* сертификаты можно обновлять без остановки сервиса.
