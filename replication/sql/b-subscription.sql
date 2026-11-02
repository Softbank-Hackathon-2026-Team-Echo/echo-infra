-- 대상 B: A 에 붙어 초기 복사 + 지속 반영.
-- CONNECTION 의 host=pg_a 는 compose 네트워크에서 B 컨테이너가 A 를 찾는 이름이다.
CREATE SUBSCRIPTION sub_demo
  CONNECTION 'host=pg_a port=5432 dbname=app user=postgres'
  PUBLICATION pub_demo
  WITH (copy_data = true);
