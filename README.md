 
# Инструкция по настройке 

## Цель:

## Обзор

Эта инструкция представляет собой полное руководство по развертыванию одвухуровневой Public Key Infrastructure (PKI). Корневой сертификат и промежуточный CA создаются через OpenSSL.

**План:**

2.  **Создание корневого и промежуточного сертификатов через OpenSSL:** Генерация корневого сертификата `apatsev.corp` и промежуточного CA `intermediate.apatsev.corp` с помощью OpenSSL.
3.  **Импорт промежуточного сертификата в Vault:** Настройка PKI-движка в Vault для промежуточного CA.
## Комментарии для начинающих DevOps

Перед началом, несколько ключевых концепций, которые помогут понять происходящее:

*   **PKI (Public Key Infrastructure)** — это набор технологий, позволяющих выпускать и управлять цифровыми сертификатами. Вместо одного сертификата используется цепочка доверия: **Корневой CA -Промежуточный CA -Сертификат услуги**. Это повышает безопасность: корневой ключ хранится в сейфе и используется редко, а промежуточный — для повседневных задач.


## Предварительные требования

*   Установленные утилиты командной строки: ``, ``, `openssl`, ``, ``.

### **Шаг 2: Создание корневого и промежуточного сертификатов через OpenSSL**

**Пояснение:** Мы создаём двухуровневую PKI. Корневой сертификат (Root CA) — это корень доверия. Его приватный ключ должен храниться максимально защищённо (оффлайн). Промежуточный сертификат (Intermediate CA) подписан корневым и используется для ежедневной выдачи сертификатов. Если он скомпрометирован, мы отзываем его, не трогая корневой.

**2.1. Создание корневого сертификата через OpenSSL:**
*Корневой сертификат является корнем доверия всей инфраструктуры. Его закрытый ключ должен храниться в безопасном месте, в идеале — оффлайн.*

**Создание конфигурационного файла для корневого CA:**
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

**Генерация приватного ключа для корневого CA:**
```bash
openssl genrsa -out rootCA.key 4096
```

**Создание самоподписанного корневого сертификата:**
```bash
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 -out rootCA.crt -config rootCA.cnf -extensions v3_ca
```

**Проверка:**
```bash
openssl x509 -in rootCA.crt -text -noout | grep "Subject:"
```

**2.2. Создание промежуточного сертификата через OpenSSL:**
*Промежуточный сертификат будет использоваться Vault для ежедневного выпуска сертификатов, что ограничивает риск компрометации корневого ключа.*

**Генерация приватного ключа для промежуточного CA:**
```bash
openssl genrsa -out intermediateCA.key 4096
```

**Создание конфигурационного файла для промежуточного CA:**
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
authorityInfoAccess = @issuer_info
crlDistributionPoints = @crl_info

[ issuer_info ]
caIssuers;URI.0 = http://vault.apatsev.corp/v1/pki/ca

[ crl_info ]
URI.0 = http://vault.apatsev.corp/v1/pki/crl
EOF
```

**Примечание:** Расширения `authorityInfoAccess` и `crlDistributionPoints` критически важны. Они указывают клиентам (браузерам, ОС) где искать цепочку сертификатов (CA Issuers) и списки отозванных сертификатов (CRL). Мы указываем будущий внешний URL Vault.

**Создание CSR (Certificate Signing Request) для промежуточного CA:**
```bash
openssl req -new -key intermediateCA.key -out intermediateCA.csr -config intermediateCA.cnf
```

**Подписание промежуточного CA корневым сертификатом:**
```bash
openssl x509 -req -in intermediateCA.csr \
  -CA rootCA.crt -CAkey rootCA.key -CAcreateserial \
  -out intermediateCA.crt -days 1825 -sha256 \
  -extfile intermediateCA.cnf -extensions v3_intermediate_ca
```

**Проверка цепочки сертификатов:**
```bash
openssl verify -CAfile rootCA.crt intermediateCA.crt
```
