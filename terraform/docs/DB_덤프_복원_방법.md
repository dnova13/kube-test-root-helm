# RDS 데이터 덤프와 복원 (AWS를 내렸다가 다시 올릴 때)

> 2026-10-06. AWS를 내리기 전에 `sns` DB를 덤프로 받아 두고, 다시 올린 뒤 그 덤프를 넣는 방법이다. RDS 스냅샷을 쓰지 않는 방식이다.
> 덤프 파일: `terraform/data/sns-dump.sql` (199KB). **`.gitignore`에 등록되어 git에 올라가지 않는다.** 이 PC에만 있으므로 폴더를 지우지 않도록 주의한다.

## 1. 덤프에 들어 있는 것 (2026-10-06 기준)

| 테이블 | 행 수 | 내용 |
|---|---|---|
| `user` | 340 | 테스트 데이터 생성기로 만든 사용자 339명 + **테스트 계정 `test`** |
| `social_feed` | 1,003 | 피드 |
| `follow` | 1 | 팔로우 |
| `BATCH_*` 6개 | 5 등 | Spring Batch 실행 이력 |

- 덤프에는 `CREATE DATABASE sns`, 테이블 정의(`CREATE TABLE`)와 데이터가 모두 들어 있어서 **`part3-infra/ddl.sql`을 따로 적용하지 않아도 된다.**
- 비밀번호는 BCrypt 해시로 저장되어 있다.
- 덤프에 들어 있는 DB는 MariaDB 11.8(`utf8mb4_uca1400_ai_ci`)이다. 11.5 이전 서버에는 복원되지 않는다. Terraform 기본값(11.8.8)과 같다.

## 2. 테스트 계정

| 항목 | 값 |
|---|---|
| 사용자 이름(아이디) | `test` |
| 이메일 | `test@test.com` |
| 비밀번호 | `1q2w3e4r` |
| user_id | 340 |

- 2026-10-06에 **회원가입 API**(`POST /api/users`)로 만들었다. 비밀번호가 BCrypt로 저장되어서 DB에 평문으로 `INSERT`하면 로그인이 안 되기 때문이다.
- 로그인 확인: `POST /api/users/signIn`이 사용자 정보를 반환하고, 틀린 비밀번호는 빈 응답이다.
- 이 계정은 덤프에 포함되어 있어 복원하면 함께 살아난다.
- 비밀번호가 단순하고 문서에 평문으로 적혀 있으니 **이 저장소는 비공개로 둔다.** 공개 환경에는 쓰지 않는다.

덤프 없이 계정만 새로 만들려면(예: 빈 DB에서 시작할 때):

```bash
ADDR=<ALB 주소 또는 user-service 주소>
curl -X POST http://$ADDR/api/users -H 'Content-Type: application/json' \
  -d '{"username":"test","email":"test@test.com","plainPassword":"1q2w3e4r"}'
```

## 3. 덤프 받는 방법 (AWS를 내리기 전에, 다시 받을 때)

RDS는 비공개라 PC에서 직접 접속할 수 없어서 클러스터 안에 임시 Pod를 띄운다. DB 접속 정보는 이미 있는 `mysql-config`, `mysql-secret`을 Pod 환경변수로 주입하므로 비밀번호를 직접 입력하거나 출력하지 않는다.

```bash
# 1) 임시 Pod (mariadb 클라이언트). 15분 뒤 자동으로 쉬는 sleep 프로세스
kubectl -n sns run dbdump --restart=Never --image=mariadb:11.8 --overrides='{"spec":{"containers":[{"name":"dbdump","image":"mariadb:11.8","command":["sleep","900"],"envFrom":[{"configMapRef":{"name":"mysql-config"}},{"secretRef":{"name":"mysql-secret"}}]}]}}'
kubectl -n sns wait --for=condition=Ready pod/dbdump --timeout=180s

# 2) 덤프 (Pod 안에서 만들고 PC로 꺼낸다)
kubectl -n sns exec dbdump -- sh -c 'mariadb-dump -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --skip-ssl-verify-server-cert --single-transaction --routines --triggers --databases sns > /tmp/sns-dump.sql'
kubectl -n sns exec dbdump -- cat /tmp/sns-dump.sql > terraform/data/sns-dump.sql

# 3) 정리
kubectl -n sns delete pod dbdump
```

- `--skip-ssl-verify-server-cert`: RDS는 보안 전송을 요구하고, 클라이언트(11.x)가 기본으로 인증서를 검증해 `unable to get local issuer certificate`로 실패하기 때문이다(Feed 서버의 `sslMode=trust`와 같은 이유).
- 덤프 끝에 `-- Dump completed on ...` 줄이 있으면 정상으로 끝난 것이다. `tail -1 terraform/data/sns-dump.sql`로 확인한다.

## 4. 다시 올린 뒤 복원하는 방법

순서: `terraform apply` → kubeconfig → 네임스페이스·`mariadb` ExternalName·Secret 적용 → **그다음 복원** → 서비스 배포.

**복원은 마스터 계정(`admin`)으로 한다.** 서비스가 쓰는 `sns-server` 계정(`mysql-secret`)은 새 RDS에 없고, 덤프에도 계정 정보는 들어 있지 않다(덤프는 `sns` DB만 담는다). 그래서 마스터로 접속해 `sns-server`를 만들어 주고(`part3-infra/ddl.sql` 4~5행과 같은 내용), 덤프를 복원한다. 마스터 비밀번호는 `terraform apply` 때 넣은 `TF_VAR_db_password` 값이다(`mysql-secret`의 값과 별개).

```bash
# 1) 임시 Pod. 마스터 비밀번호를 환경변수 DBADMIN_PW로 넘긴다 (파일에 쓰지 않는다)
#    mysql-secret의 sns-server 비밀번호는 MYSQL_PASSWORD로 주입된다
read -rs DBADMIN_PW   # 입력은 화면에 보이지 않는다
kubectl -n sns create secret generic dbadmin --from-literal=DBADMIN_PW="$DBADMIN_PW" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sns run dbrestore --restart=Never --image=mariadb:11.8 --overrides='{"spec":{"containers":[{"name":"dbrestore","image":"mariadb:11.8","command":["sleep","1200"],"env":[{"name":"MYSQL_HOST","value":"mariadb.infra.svc.cluster.local"},{"name":"MYSQL_PORT","value":"3306"}],"envFrom":[{"secretRef":{"name":"mysql-secret"}},{"secretRef":{"name":"dbadmin"}}]}]}}'
kubectl -n sns wait --for=condition=Ready pod/dbrestore --timeout=180s

# 2) 복원 대상이 새(빈) RDS인지 마스터로 확인한다 (아래 주의 참고)
kubectl -n sns exec dbrestore -- sh -c 'echo "대상: $MYSQL_HOST"; mariadb -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u admin -p"$DBADMIN_PW" --skip-ssl-verify-server-cert -e "SHOW DATABASES"'
#    기대: sns가 없다 (information_schema, mysql, performance_schema, sys)

# 3) 서비스 계정 sns-server 생성 + 덤프 복원 (둘 다 마스터로)
kubectl -n sns exec dbrestore -- sh -c 'mariadb -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u admin -p"$DBADMIN_PW" --skip-ssl-verify-server-cert -e "CREATE USER IF NOT EXISTS \"sns-server\"@\"%\" IDENTIFIED BY \"$MYSQL_PASSWORD\"; GRANT ALL PRIVILEGES ON sns.* TO \"sns-server\"@\"%\"; FLUSH PRIVILEGES;"'
kubectl -n sns exec -i dbrestore -- sh -c 'mariadb -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u admin -p"$DBADMIN_PW" --skip-ssl-verify-server-cert' < terraform/data/sns-dump.sql

# 4) 확인: 서비스 계정(sns-server)으로 접속되고 데이터가 있는지
kubectl -n sns exec dbrestore -- sh -c 'mariadb -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --skip-ssl-verify-server-cert sns -N -e "SELECT COUNT(*) FROM user; SELECT COUNT(*) FROM social_feed"'
#   기대값: 340, 1003

# 5) 정리 (마스터 비밀번호를 담은 임시 Secret도 지운다)
kubectl -n sns delete pod dbrestore
kubectl -n sns delete secret dbadmin
```

> **주의: 덤프에는 `DROP TABLE IF EXISTS`가 들어 있다.** 이미 데이터가 있는 DB에 복원하면 그 테이블을 지우고 덮어쓴다. 복원 전에 2)로 접속 대상이 새(빈) RDS가 맞는지 확인한다.
> **환경변수 함정:** `mariadb` 클라이언트는 `MYSQL_HOST` 환경변수를 읽는다. 임시 Pod에는 RDS용 `MYSQL_HOST`가 들어 있어서, 로컬 소켓(`-S`)으로 시험하려고 해도 **RDS로 접속을 시도한다.** 2026-10-06 검증 때 실제로 이 때문에 두 번 RDS로 접속을 시도했고, RDS의 보안 전송 설정 덕분에 접속 단계에서 거부되어 데이터는 바뀌지 않았다. 로컬 시험은 `env -u MYSQL_HOST mariadb --protocol=socket -S ...`처럼 하고, 대상을 확인(`select @@socket`)한 뒤 실행한다.

## 5. 복원이 되는지 검증한 결과 (2026-10-06)

RDS는 건드리지 않고, 임시 Pod 안에 별도 MariaDB 11.8 서버를 띄워 덤프를 복원해 비교했다.

| 테이블 | 복원본 | 원본(RDS) |
|---|---|---|
| user | 340 | 340 |
| social_feed | 1,003 | 1,003 |
| follow | 1 | 1 |
| BATCH_JOB_EXECUTION | 5 | 5 |

- `test` 계정도 복원본에서 확인했다(`user_id` 340, 이메일 `test@test.com`, 비밀번호는 `$2a$` BCrypt 해시 60자).
- **새 RDS(Terraform으로 만든 것)에 실제로 복원해 확인했다 (2026-10-07).** 마스터(`admin`)로 `sns-server` 계정을 만들고 덤프를 복원한 뒤, 서비스 계정으로 접속해 행 수가 원본과 같음을 확인했다(user 340, social_feed 1,003, follow 1, BATCH_JOB_EXECUTION 5). 배포한 서비스에서도 `GET /api/feeds`가 1,003개를 반환했다.
- 처음 시도에서 `sns-server`로 접속이 거부됐다. 새 RDS에는 마스터 계정만 있고 서비스 계정은 없기 때문이며(덤프는 `sns` DB만 담는다), 4절의 순서(마스터로 계정 생성 → 복원)가 이 경험을 반영한 것이다.

## 6. 복원해도 돌아오지 않는 것 (알아 둘 점)

| 항목 | 이유 | 대응 |
|---|---|---|
| **이미지 파일** | EFS에 있고 EFS는 AWS 삭제와 함께 사라진다. 피드 데이터는 `imageId`만 가진다 | 이미지가 깨져 보인다. 테스트 데이터 생성기로 새 피드를 만들면 된다 |
| **Timeline 화면의 기존 피드** | Timeline 서버는 Kafka로 받아 Redis에 쌓은 것만 읽는다(문서 `Timeline서버_코드분석.md`). 새 클러스터는 Redis·Kafka가 비어 있어 DB의 기존 피드가 타임라인에 나오지 않는다(**2026-10-07 재생성 후 확인**: `GET /api/timeline`이 `[]`, 같은 시점에 `GET /api/feeds`는 1,003개) | 피드를 새로 작성하면 반영된다. 기존 피드를 보려면 `GET /api/feeds`(DB 조회)를 쓴다 |
| ECR 이미지 | 저장소와 함께 삭제 | `./gradlew jib`로 다시 push |
| Secret 값 | 클러스터와 함께 삭제 | 비밀번호 관리자에서 다시 입력 |
