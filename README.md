## Задача 1: Docker ubu1 и ubu2

Два контейнера Ubuntu 24.04 (systemd + sshd) вместо ВМ. Ansible управляет ими по SSH-ключу.

| Хост | Роль | IP | SSH |
|------|------|----|-----|
| ubu1 | веб | 172.28.0.11 | 127.0.0.1:2221 |
| ubu2 | мониторинг | 172.28.0.12 | 127.0.0.1:2222 |

### Запуск

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ubu_lab -N "" -C ansible-lab
cp ~/.ssh/ubu_lab.pub docker/ssh/authorized_keys
sudo docker compose -f docker/docker-compose.yml up -d --build
ansible all -m ping
sleep 10
ansible-playbook site.yml -e bootstrap=true
ansible-playbook site.yml
ansible-playbook site.yml          # в RECAP везде changed=0
./scripts/demo.sh
./scripts/load.sh
```

### Проблемы

- `permission denied ... docker.sock`: пользователя нужно добавить в группу `docker` и перелогиниться.
- Контейнеры `privileged`, так как systemd, ufw и WireGuard требуют доступа к ядру (только для лаборатории).

## Задача 2: Firewall и SSH hardening

- Роль `ssh_hardening`: drop-in `/etc/ssh/sshd_config.d/00-hardening.conf`
  (root запрещён, пароли запрещены, только publickey, MaxAuthTries 3).
- Роль `firewall`: ufw, default deny incoming, allow outgoing.
  Порты задаются через `firewall_allowed_ports` в `group_vars`.
  - ubu1 (web): 22, 80, 443
  - ubu2 (monitoring): 22, 9090, 3000
- Проверка: `ansible all -b -m command -a "sshd -T"` и `ufw status verbose`.

## Задача 3: WireGuard

- Топология hub-and-spoke, подсеть 10.8.0.0/24:
  ubu2 = сервер (10.8.0.1), ubu1 = клиент (10.8.0.2), хост-админ = клиент (10.8.0.10).
- Ключи генерируются на хостах (`/etc/wireguard/*.key`, 0600), в репозитории их нет.
- ubu2 пересылает трафик между пирами (ip_forward + ufw route wg0->wg0).
- SSH на ubu1 разрешён только на интерфейсе wg0 (правило ufw), остальное закрыто.
- Запуск в два этапа: `-e bootstrap=true` (SSH ещё открыт, поднимаем VPN),
  затем без флага (Ansible ходит на ubu1 через VPN).
- Проверка: `wg show`, ssh на 10.8.0.2 работает, прямой ssh на ubu1 не работает.

interface: wglab
  public key: jWhIt1B3Zje8cKRKfh6gUnqHC9B2dpb5VybNeyIPqgg=
  private key: (hidden)
  listening port: 57404

peer: 3CHGkqdW51Qd3PHHgyrSEo40Yhy+wFjCF0uecgIbIhU=
  endpoint: 172.28.0.12:51820
  allowed ips: 10.8.0.0/24
  latest handshake: 1 second ago
  transfer: 92 B received, 180 B sent
  persistent keepalive: every 25 seconds

## Задача 4: Nginx + ModSecurity (OWASP CRS)

- Роль `nginx_waf` на ubu1: nginx, libnginx-mod-http-modsecurity, modsecurity-crs (пакеты Ubuntu 24.04).
- Пакеты вместо Docker-образа: ubu1 сам является контейнером.
- `modsecurity.conf-recommended` в пакетах Ubuntu нет, поэтому базовый конфиг
  ModSecurity лежит в шаблоне роли (`modsec-main.conf.j2`).
- SecRuleEngine On, CRS 3.3.5, paranoia level 1, порог блокировки 5.
- Проверка: `/` = 200; XSS, SQLi, path traversal = 403;
  события в `/var/log/modsec_audit.log` (правило 949110).

## Задача 5: Loki + Grafana

- Роли `loki`, `grafana` (ubu2) и `alloy` (ubu1), пакеты из apt-репозитория Grafana (`grafana_apt_repo`).
- Вместо Promtail используется Grafana Alloy.
- Alloy читает nginx access/error и ModSecurity audit-лог (многострочные события
  склеиваются по секциям) и шлёт в Loki на 10.8.0.1:3100 через VPN.
- Loki (3100) и Grafana (3000) доступны только через wg0 (ufw), наружу не проброшены.
- Пароль админа Grafana генерируется на контроллере в `.secrets/` (не в Git).
- Хранение логов: 7 дней (`loki_retention`).

### Проблемы по ходу
- Loki не стартовал: пакет создаёт пользователя `loki`, но не каталог `/var/lib/loki`.
  Исправлено задачей `file` в роли.
- Ограничение: `/var/log/modsec_audit.log` не ротируется, в проде нужен logrotate.

## Задача 6: Демонстрация

`./scripts/demo.sh` (на хосте при поднятом VPN):
1. Обычный запрос -> 200, виден в nginx access-логе в Loki, события Access denied нет.
2. SQLi -> 403, `Access denied` + правило CRS 942100 в логе ModSecurity,
   403 в nginx access-логе.

Каждый запрос несёт уникальный маркер, по нему скрипт ищет записи в Loki.

Дашборд: http://10.8.0.1:3000 -> Lab -> "nginx + ModSecurity (ubu1)".
Скриншот: docs/dashboard.png, вывод скрипта: docs/demo-output.txt.

### Замечание
Обычные запросы тоже попадают в audit-лог ModSecurity: правило 920350
(Host header is a numeric IP address) срабатывает как предупреждение,
потому что мы ходим по IP, а не по имени. Запрос при этом не блокируется,
поэтому скрипт проверяет отсутствие `Access denied`, а не отсутствие записи.

## Задача 7*: Алерт в Telegram

- Grafana Alerting, всё провижинится Ansible (роль `grafana`, каталог provisioning/alerting).
- Правило: больше 5 блокировок WAF (`Access denied` в audit-логе) с одного IP за 1 минуту,
  проверка каждые 30 с. IP извлекается из audit-записи регулярным выражением в LogQL.
- Уведомление в Telegram: IP и число запросов; при завершении атаки приходит отбой.
- Токен бота и chat id лежат в `.secrets/` (не в Git):
  `telegram_bot_token`, `telegram_chat_id`.
- Тест: `./scripts/alert_test.sh`.
- Ограничение: запросы с хоста приходят через docker-порт, поэтому WAF видит
  адрес шлюза docker-сети 172.28.0.1, а не внешний IP.