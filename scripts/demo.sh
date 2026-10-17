#!/usr/bin/env bash
# QA-демо задачи 6: запросы к ubu1 -> проверка логов в Loki на ubu2 (через VPN)
set -u

WEB="${WEB:-http://127.0.0.1:8080}"
LOKI="${LOKI:-http://10.8.0.1:3100}"
RETRIES=12
DELAY=5
FAILED=0

G='\033[32m'; R='\033[31m'; Y='\033[33m'; N='\033[0m'
pass() { echo -e "  ${G}PASS${N}  $1"; }
fail() { echo -e "  ${R}FAIL${N}  $1"; FAILED=1; }
info() { echo -e "${Y}==>${N} $1"; }

# loki_has '<logql>' : ждёт, пока запрос вернёт хотя бы одну запись
loki_has() {
  local q="$1" i out
  for ((i = 1; i <= RETRIES; i++)); do
    out=$(curl -sG --max-time 10 "$LOKI/loki/api/v1/query_range" \
      --data-urlencode "query=$q" --data-urlencode "limit=5" 2>/dev/null)
    if echo "$out" | grep -q '"values":\[\['; then
      return 0
    fi
    sleep "$DELAY"
  done
  return 1
}

# loki_empty '<logql>' : одна проверка, что записей нет
loki_empty() {
  ! curl -sG --max-time 10 "$LOKI/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "limit=5" 2>/dev/null \
    | grep -q '"values":\[\['
}

info "0. Loki доступен через VPN ($LOKI)"
if [ "$(curl -s --max-time 5 "$LOKI/ready")" = "ready" ]; then
  pass "Loki отвечает ready"
else
  fail "Loki недоступен: поднят ли VPN (sudo wg show)?"
  exit 1
fi

# ---------- Тест 1: обычный запрос ----------
M1="demo-ok-$(date +%s)-$RANDOM"
info "1. Обычный запрос (маркер $M1)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$WEB/?demo=$M1")
[ "$code" = "200" ] && pass "HTTP $code" || fail "ожидали 200, получили $code"

echo "     жду появления в Loki (до $((RETRIES * DELAY)) c)..."
if loki_has "{job=\"nginx\", log_type=\"access\"} |= \"$M1\""; then
  pass "запрос виден в nginx access-логе в Loki"
else
  fail "запрос не найден в nginx access-логе"
fi
if loki_empty "{job=\"modsecurity\"} |= \"$M1\" |= \"Access denied\""; then
  pass "WAF его не блокировал (нет события Access denied)"
else
  fail "обычный запрос заблокирован WAF"
fi

# ---------- Тест 2: SQL-инъекция ----------
M2="demo-sqli-$(date +%s)-$RANDOM"
info "2. SQL-инъекция (маркер $M2)"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  "$WEB/?id=1%27%20OR%20%271%27=%271&demo=$M2")
[ "$code" = "403" ] && pass "HTTP $code (заблокирован WAF)" || fail "ожидали 403, получили $code"

echo "     жду появления в Loki (до $((RETRIES * DELAY)) c)..."
if loki_has "{job=\"modsecurity\"} |= \"$M2\" |= \"Access denied\""; then
  pass "блокировка записана в audit-логе ModSecurity (Access denied)"
else
  fail "события блокировки нет в логе ModSecurity"
fi
if loki_has "{job=\"modsecurity\"} |= \"$M2\" |= \"942100\""; then
  pass "сработало правило CRS 942100 (SQL injection)"
else
  echo -e "  ${Y}INFO${N}  правило 942100 не найдено, другие правила SQLi могли сработать вместо него"
fi
if loki_has "{job=\"nginx\", log_type=\"access\"} |= \"$M2\" |= \" 403 \""; then
  pass "в nginx access-логе есть статус 403"
else
  fail "403 не найден в nginx access-логе"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo -e "${G}ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ${N}"
else
  echo -e "${R}ЕСТЬ ПРОВАЛЕННЫЕ ПРОВЕРКИ${N}"
fi
exit "$FAILED"
