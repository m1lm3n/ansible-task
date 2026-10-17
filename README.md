## Задача 1: Docker ubu1 и ubu2

cd ~/ansible-task
sudo docker compose -f docker/docker-compose.yml up -d --build

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
