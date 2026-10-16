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
