#!/usr/bin/env bash
# Задача 7*: 8 SQLi-запросов за несколько секунд -> алерт в Telegram
WEB="${WEB:-http://127.0.0.1:8080}"
echo "Шлю 8 SQLi-запросов..."
for i in $(seq 1 8); do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "$WEB/?id=1%27%20OR%20%271%27=%271&alert=test-$i")
  echo "  запрос $i: HTTP $code"
done
echo "Жди сообщение в Telegram: правило проверяется каждые 30 с."
