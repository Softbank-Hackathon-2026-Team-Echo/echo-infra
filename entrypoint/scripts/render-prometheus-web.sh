#!/usr/bin/env bash
# Prometheus web 설정 파일(basic auth)을 만든다 (인프라 9 remote write 수신).
# 비밀번호는 표준 입력으로만 받고(명령줄·환경 변수에 안 남김), 파일에는 bcrypt 해시만 쓴다.
#
#   printf '%s' "$PW" | bash entrypoint/scripts/render-prometheus-web.sh <출력 파일> [사용자, 기본 echo-otel]
#
# VM: startup 스크립트가 Secret Manager 값으로 부른다(htpasswd = apache2-utils). 로컬: htpasswd 가 없으면 httpd 이미지로 만든다.
# 같은 비밀번호라도 소금(salt)이 달라 해시는 매번 다르다 — 정상이다.
set -euo pipefail

out=${1:?출력 파일 경로}
user=${2:-echo-otel}
pw=$(cat)
[ -n "$pw" ] || { echo "render-prometheus-web: 비밀번호가 비었다" >&2; exit 1; }

if command -v htpasswd >/dev/null 2>&1; then
  line=$(printf '%s' "$pw" | htpasswd -niBC 10 "$user")
else
  line=$(printf '%s' "$pw" | docker run --rm -i httpd:2.4-alpine htpasswd -niBC 10 "$user")
fi
hash=$(printf '%s' "$line" | head -n1 | cut -d: -f2- | tr -d '[:space:]')
case "$hash" in
  '$2'?'$'*) ;;
  *) echo "render-prometheus-web: bcrypt 해시를 만들지 못했다" >&2; exit 1 ;;
esac

tmp="$out.tmp.$$"
{
  echo "# 만든 곳: entrypoint/scripts/render-prometheus-web.sh (bcrypt 해시만, 원문 없음)"
  echo "basic_auth_users:"
  echo "  $user: '$hash'"
} > "$tmp"
chmod 0644 "$tmp" # Prometheus 컨테이너(nobody)가 읽는다. 해시만 있어 읽혀도 원문은 안 나온다
mv -f "$tmp" "$out"
