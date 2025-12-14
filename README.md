# Инструкция по настройке FreeIPA с внешним сертификатом

## Цель

Развернуть сервер **FreeIPA** с использованием **внешнего TLS-сертификата**, выпущенного собственной двухуровневой PKI (Root CA + Intermediate CA), созданной через OpenSSL.

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

* **FreeIPA** — это центр управления идентификацией (LDAP + Kerberos + DNS + CA).
* По умолчанию FreeIPA поднимает **собственный CA**, но чаще нужно использовать корпоравный CA.
* Поэтому мы используем **внешний сертификат**, выпущенный собственной PKI.

### Почему двухуровневая PKI

* Root CA хранится оффлайн
* Intermediate CA используется для выпуска сертификатов
* В случае компрометации Intermediate CA — Root остаётся безопасным

## Предварительные требования

### На управляющей машине (Ansible host)

* `ansible >= 2.14`
* `openssl`
* `python3`
* SSH-доступ к серверу FreeIPA

### На сервере FreeIPA

* Fedora / Rocky / Alma / RHEL
* Открыты порты:

  * 80, 443
  * 389, 636
  * 88, 464
  * 53 (TCP/UDP)

## Шаг 1. Подготовка сервера FreeIPA

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

## Шаг 2. Создание корневого и промежуточного CA (OpenSSL)

> **Этот шаг выполняется НЕ на сервере FreeIPA**, а на отдельной защищённой машине.

### 2.1 Создание Root CA

#### Конфигурация Root CA

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

### 2.2 Создание Intermediate CA

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

#### Подписание Root CA

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

## Шаг 3. Выпуск сертификата для FreeIPA

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

### 3.3 Подписание Intermediate CA

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

## Шаг 4. Установка FreeIPA с внешним сертификатом (Ansible)

### 4.1 Установка ролей

```bash
ansible-galaxy collection install freeipa.ansible_freeipa
```

Развёртывание выполняется через **Ansible** с использованием inventory-файла.

## Используемый inventory.yml

```yaml
all:
  children:
    ipaserver:
      hosts:
        freeipa-instance:
          ansible_host: ip

  vars:
    ansible_user: fedora

    # Пароли FreeIPA
    ipaadmin_password: ADMPassword1
    ipadm_password: ADMPassword1

    # Сетевые настройки
    ipaserver_no_host_dns: true
    ipaserver_ip_addresses:
      - "{{ ansible_default_ipv4.address | default(ansible_all_ipv4_addresses[0]) }}"

    # Доменные параметры FreeIPA
    ipaserver_domain: apatsev.corp
    ipaserver_realm: APATSEV.CORP
    ipaserver_hostname: ipa.apatsev.corp

    # DNS
    ipaserver_setup_dns: true
    ipaserver_forwarders:
      - 8.8.8.8
```

### 4.3 Установка FreeIPA без встроенного CA

```bash
ansible-playbook install-ipa.yml \
  --extra-vars "ipaserver_external_ca=true"
```

## Проверка

```bash
openssl s_client -connect ipa.apatsev.corp:443 -showcerts
```

```bash
ipa healthcheck
```

## Результат

FreeIPA развернут
Используется внешний TLS-сертификат
Собственная PKI с Root + Intermediate
Готово к продакшену
