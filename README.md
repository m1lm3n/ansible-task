# Ansible-стенд: WAF, VPN и мониторинг логов

Два Ubuntu-хоста в Docker (`ubu1` и `ubu2`), которыми целиком управляет Ansible:
hardening SSH и файрвол, WireGuard VPN, Nginx + ModSecurity (OWASP CRS) на `ubu1`,
Loki + Grafana на `ubu2`, алерт в Telegram. Всё поднимается с нуля несколькими командами.

## Схема стенда

| Хост | Роль | IP в docker-сети `lab` | IP в VPN | Доступ с хоста |
|------|------|------------------------|----------|----------------|
| ubu1 | веб: nginx + ModSecurity + Alloy | 172.28.0.11 | 10.8.0.2 | SSH только через VPN; HTTP `127.0.0.1:8080` |
| ubu2 | мониторинг: Loki + Grafana, VPN-сервер | 172.28.0.12 | 10.8.0.1 | SSH `127.0.0.1:2222`; Grafana `http://10.8.0.1:3000` |
| хост (RDS) | админ, откуда запускается Ansible | - | 10.8.0.10 | - |

## Требования

- Ubuntu с Docker и Docker Compose, пользователь в группе `docker` (или `sudo docker ...`).
- Ansible (пакет `ansible` из Ubuntu); нужны коллекции `community.general` и `ansible.posix`
  (в пакете `ansible` они есть, проверка: `ansible-galaxy collection list`).
- На хосте sudo без пароля для пользователя, из-под которого запускается Ansible
  (см. «Проблемы и ограничения», пункт про sudo-rs).

## Секреты

Каталог `.secrets/` добавлен в `.gitignore`.

| Файл | Как создаётся |
|------|----------------|
| `.secrets/grafana_admin_password` | автоматически при первом запуске плейбука |
| `.secrets/telegram_bot_token` | вручную (токен от @BotFather), нужен для задачи 7* |
| `.secrets/telegram_chat_id` | вручную (chat id из `getUpdates`), нужен для задачи 7* |

```bash
mkdir -p .secrets
read -rs -p "Токен бота: " T; echo; printf '%s' "$T" > .secrets/telegram_bot_token; unset T
printf '%s' '<chat id>' > .secrets/telegram_chat_id
chmod 600 .secrets/telegram_*
```

Без файлов `telegram_*` плейбук упадёт на роли `grafana`. Приватный SSH-ключ
(`~/.ssh/ubu_lab`) в репозиторий не попадает, публичный лежит в `docker/ssh/authorized_keys`.

## Быстрый старт с нуля

```bash
cd ~/ansible-task

# 1. SSH-ключ (один раз)
ssh-keygen -t ed25519 -f ~/.ssh/ubu_lab -N "" -C ansible-lab
mkdir -p docker/ssh && cp ~/.ssh/ubu_lab.pub docker/ssh/authorized_keys

# 2. Контейнеры
sudo docker compose -f docker/docker-compose.yml up -d --build
sleep 10

# 3. Этап 1: bootstrap (SSH на ubu1 ещё открыт через docker-порт, поднимаем VPN)
ansible-playbook site.yml -e bootstrap=true

# 4. Этап 2: финал (Ansible ходит на ubu1 через VPN, SSH закрывается везде, кроме wg0)
ansible-playbook site.yml

# 5. Идемпотентность: в PLAY RECAP везде changed=0
ansible-playbook site.yml

# 6. Демонстрация
./scripts/demo.sh
```

Пересоздание контейнеров (`down` и `up`) стирает всё внутри них, поэтому после него
всегда нужны оба этапа, начиная с `-e bootstrap=true`.

## Структура репозитория

```
ansible.cfg
site.yml
inventory/hosts.ini
group_vars/        # порты файрвола по группам
host_vars/         # адреса WireGuard, пиры
docker/            # Dockerfile, docker-compose.yml, ssh/authorized_keys
roles/
  ssh_hardening/ firewall/ wireguard/
  nginx_waf/ grafana_apt_repo/ loki/ grafana/ alloy/
scripts/           # demo.sh, load.sh, alert_test.sh
docs/              # скриншоты и вывод проверок
```

---

## Задача 1: Docker ubu1 и ubu2

Два контейнера Ubuntu 24.04 (systemd + sshd) вместо ВМ: быстрее и воспроизводимо.
Ansible управляет ими по SSH-ключу (пользователь `ansible`, sudo без пароля, только внутри контейнеров).

```bash
sudo docker compose -f docker/docker-compose.yml up -d --build
sudo docker ps    # ubu1 и ubu2 в статусе Up
```

Проверка связи `ansible all -m ping` работает на этом этапе, пока SSH на ubu1 ещё не закрыт
(после задачи 3 для ubu1 нужен `-e bootstrap=true` или VPN).

Контейнеры запущены с `privileged: true`, потому что systemd, ufw и WireGuard внутри контейнера
требуют доступа к cgroups, iptables и модулям ядра.

## Задача 2: Firewall и SSH hardening

- Роль `ssh_hardening`: drop-in `/etc/ssh/sshd_config.d/00-hardening.conf`
  (root запрещён, пароли запрещены, только publickey, `MaxAuthTries 3`).
- Роль `firewall`: ufw, default deny incoming, allow outgoing. Порты задаются в `group_vars`:
  `firewall_allowed_ports` (открыты для всех) и `firewall_vpn_only_ports` (только на `wg0`).

| Хост | Открыто для всех | Только через wg0 |
|------|------------------|------------------|
| ubu1 | 80/tcp, 443/tcp | 22/tcp (SSH) |
| ubu2 | 22/tcp, 51820/udp (WireGuard) | 3000/tcp (Grafana), 3100/tcp (Loki) |

Проверка:

```bash
ansible all -b -m command -a "sshd -T" | grep -Ei 'permitrootlogin|passwordauthentication|authenticationmethods'
ansible all -b -m command -a "ufw status verbose"
```

Ожидается: `permitrootlogin no`, `passwordauthentication no`, `authenticationmethods publickey`,
`Default: deny (incoming), allow (outgoing)`.

## Задача 3: WireGuard

- Топология hub-and-spoke, подсеть `10.8.0.0/24`: ubu2 = сервер (10.8.0.1),
  ubu1 = клиент (10.8.0.2), хост-админ = клиент (10.8.0.10, интерфейс `wglab`).
- Ключи генерируются на самих хостах (`/etc/wireguard/*.key`, права 0600), в репозитории их нет.
- ubu2 пересылает трафик между пирами (`ip_forward` и правило ufw route wg0 -> wg0).
- SSH на ubu1 разрешён только на интерфейсе `wg0`; запуск в два этапа (см. «Быстрый старт»).

Проверка:

```bash
sudo wg show                                              # у пира есть latest handshake
ssh -i ~/.ssh/ubu_lab ansible@10.8.0.2 hostname           # через VPN работает
ssh -i ~/.ssh/ubu_lab -p 2221 -o ConnectTimeout=5 ansible@127.0.0.1   # напрямую: не работает
ssh -i ~/.ssh/ubu_lab -o ConnectTimeout=5 ansible@172.28.0.11         # напрямую: не работает
```

Пример вывода `sudo wg show` (ключи сокращены):

```text
interface: wglab
  listening port: 57404

peer: 3CHGkq...
  endpoint: 172.28.0.12:51820
  allowed ips: 10.8.0.0/24
  latest handshake: 1 second ago
  persistent keepalive: every 25 seconds
```

## Задача 4: Nginx + ModSecurity (OWASP CRS)

- Роль `nginx_waf` на ubu1: пакеты `nginx`, `libnginx-mod-http-modsecurity`, `modsecurity-crs` (Ubuntu 24.04).
- Пакеты вместо Docker-образа: ubu1 сам является контейнером, Docker внутри него хрупок.
- В пакетах Ubuntu нет `modsecurity.conf-recommended`, поэтому базовый конфиг ModSecurity
  лежит в шаблоне роли (`modsec-main.conf.j2`).
- `SecRuleEngine On`, CRS 3.3.5, paranoia level 1, блокировка при Inbound Anomaly Score ≥ 5
  (правило 949110). Audit-лог: `/var/log/modsec_audit.log`.

Проверка (порт 8080 хоста проброшен на 80 ubu1):

```bash
curl -i http://127.0.0.1:8080/                                        # 200
curl -i "http://127.0.0.1:8080/?q=<script>alert(1)</script>"          # 403 (XSS)
curl -i "http://127.0.0.1:8080/?id=1%27%20OR%20%271%27=%271"          # 403 (SQLi)
curl -i "http://127.0.0.1:8080/?file=../../etc/passwd"                # 403 (path traversal)
ansible ubu1 -b -m command -a "tail -n 20 /var/log/modsec_audit.log"
```

## Задача 5: Loki + Grafana

- Роли `loki`, `grafana` (ubu2) и `alloy` (ubu1); пакеты из apt-репозитория Grafana (`grafana_apt_repo`).
- Вместо Promtail используется Grafana Alloy (Promtail снят с поддержки).
- Alloy читает nginx access/error и ModSecurity audit-лог (многострочные события склеиваются
  по секциям A..Z) и шлёт в Loki на `10.8.0.1:3100` через VPN.
- Loki (3100) и Grafana (3000) доступны только через `wg0`, наружу не проброшены.
- Пароль админа Grafana генерируется на контроллере в `.secrets/`. Хранение логов: 7 дней (`loki_retention`).

Проверка:

```bash
ansible ubu2 -b -m command -a "systemctl is-active loki grafana-server"
ansible ubu1 -b -m command -a "systemctl is-active alloy"
curl -s http://10.8.0.1:3100/ready
curl -s http://10.8.0.1:3100/loki/api/v1/labels
curl --max-time 5 http://172.28.0.12:3000/api/health    # напрямую: таймаут
```

Grafana: `http://10.8.0.1:3000`, логин `admin`, пароль в `.secrets/grafana_admin_password`.

## Задача 6: Демонстрация

```bash
./scripts/demo.sh
```

Скрипт (запускается на хосте при поднятом VPN) проверяет:

1. Обычный запрос: 200, виден в nginx access-логе в Loki, события `Access denied` нет.
2. SQLi: 403, `Access denied` и правило CRS 942100 в логе ModSecurity, 403 в nginx access-логе.

Каждый запрос несёт уникальный маркер, по нему скрипт ищет записи в Loki. Код выхода 0/1.
Для наглядности есть дашборд: Grafana -> Dashboards -> Lab -> «nginx + ModSecurity (ubu1)»;
`./scripts/load.sh` создаёт нагрузку для графиков.

Материалы: `docs/dashboard.png` (дашборд), `docs/demo-output.txt` (вывод скрипта).

## Задача 7*: Алерт в Telegram

- Grafana Alerting, всё провижинится Ansible (роль `grafana`, `provisioning/alerting`).
- Правило: больше 5 блокировок WAF (`Access denied`) с одного IP за 1 минуту, проверка каждые 30 с.
  IP извлекается из audit-записи регулярным выражением в LogQL.
- Telegram получает IP и число запросов; при завершении атаки приходит сообщение об отбое.

Проверка:

```bash
./scripts/alert_test.sh    # 8 SQLi-запросов подряд
```

Сообщение приходит через 30-60 с; статус правила: Grafana -> Alerting -> Alert rules.
Скриншот сообщения: `docs/telegram-alert.png`.

---

## Проблемы и ограничения

- **sudo-rs на хосте (Ubuntu 26.04).** Ansible не распознаёт приглашение пароля sudo-rs
  (become timeout). Решение для лаборатории: `NOPASSWD` в `/etc/sudoers.d/ansible-lab`.
  В продакшене так делать не стоит.
- **`modsecurity.conf-recommended` отсутствует** в пакетах Ubuntu; базовый конфиг ModSecurity написан в роли.
- **Loki не стартовал:** пакет создаёт пользователя `loki`, но не каталог `/var/lib/loki`.
  Исправлено отдельной задачей `file` (без группы: группы `loki` в пакете нет).
- **Promtail заменён на Grafana Alloy**, так как Promtail снят с поддержки.
- **Контейнеры `privileged`** (systemd, ufw, WireGuard); подходит только для лаборатории.
- **Двухэтапный запуск** из-за закрытого SSH на ubu1: сначала `-e bootstrap=true`, затем финальный прогон.
  Пересоздание контейнеров стирает их состояние, поэтому оба этапа нужны заново.
- **Ротация `/var/log/modsec_audit.log` не настроена**, в продакшене нужен logrotate.
- **Источник запросов в логах.** Запросы с хоста идут через docker-порт, поэтому WAF видит
  адрес шлюза сети `172.28.0.1`, а не внешний IP (важно для алерта задачи 7*).
- **Предупреждение 920350** (Host header is a numeric IP address) появляется у обычных запросов,
  потому что мы ходим по IP, а не по имени. Запрос не блокируется, поэтому `demo.sh`
  проверяет отсутствие `Access denied`, а не отсутствие записи.