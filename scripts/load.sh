for i in $(seq 1 15); do
  curl -s -o /dev/null "http://127.0.0.1:8080/?demo=load-$i"
  curl -s -o /dev/null "http://127.0.0.1:8080/?id=1%27%20OR%20%271%27=%271&demo=load-$i"
  sleep 2
done