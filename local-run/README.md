# 로컬 실행 가이드 (Ch 2~5 서비스)

기존 로컬 MySQL(3306), 다른 프로젝트의 DB/Kafka와 겹치지 않도록 이 프로젝트 전용 MySQL/Kafka를 **다른 포트**로 띄운다.
각 서비스의 `application-local.yaml`이 이 포트(MySQL 23307, Kafka 19092)를 가리키고 프로파일 기본값이 `local`이라서, 별도 실행 인자 없이 실행하면 된다.

| 구성 | 주소 | 비고 |
|---|---|---|
| MySQL 8.2 | `localhost:23307` | DB `sns`, 계정 `sns-server` / `password!`, 테이블은 `init.sql`로 생성 |
| Kafka 3.7 | `localhost:19092` | 컨테이너 안에서 CLI를 쓸 때는 `localhost:29092` |

## 1. 인프라 기동 / 종료
```sh
cd local-run
docker compose up -d      # 최초 기동 시 init.sql이 실행된다
docker compose stop       # 데이터는 유지한 채 중지
docker compose down -v    # 컨테이너와 데이터 삭제 (스키마를 다시 만들 때)
```

## 2. 서비스 빌드
```sh
cd part3-user-server && ./gradlew build -x test   # feed-server, image-server, notification-batch도 동일
```

## 3. 서비스 실행
프로파일을 지정하지 않으면 `local`이 적용된다(클러스터는 `SPRING_PROFILES_ACTIVE=dev`로 덮어씀). IntelliJ에서 실행해도 같다.
```sh
java -jar part3-user-server/build/libs/*SNAPSHOT.jar    # :9080  MySQL 23307, Kafka 19092
java -jar part3-feed-server/build/libs/*SNAPSHOT.jar    # :8080  MySQL 23307, Kafka 19092
java -jar part3-image-server/build/libs/*SNAPSHOT.jar   # :6080  DB 없음
```
- Image Server는 실행 디렉터리 아래 `images/` 폴더에 저장하므로 그 폴더가 미리 있어야 한다(`mkdir -p images`). 경로를 바꾸려면 `--images.upload-root=<경로>`를 준다.
- Feed Server는 User Server(9080)가 떠 있어야 피드 조회/생성이 된다.
- 각 서비스의 Swagger UI는 `http://localhost:<포트>/swagger-ui.html`이다.

## 4. Notification Batch 실행
`local` 프로파일은 포트 7080, MySQL 23307로 뜨고 **기동할 때 Job을 자동 실행하지 않는다**. Swagger에서 `POST /api/batch/notification/run`을 호출해 한 번씩 실행한다. 메일은 `localhost:1025`로 보내므로 그 포트에서 받는 SMTP 서버가 필요하다.
```sh
java -jar part3-notification-batch/build/libs/*SNAPSHOT.jar   # :7080, http://localhost:7080/swagger-ui.html
```
클러스터(CronJob)에서는 `dev` 프로파일로 Job을 한 번 실행하고 종료한다.

## 5. 동작 확인 예시
```sh
H='Content-Type: application/json'
curl -X POST localhost:9080/api/users -H "$H" -d '{"username":"alice","email":"alice@example.com","plainPassword":"pw1"}'
curl -X POST localhost:9080/api/follows/follow -H "$H" -d '{"userId":1,"followerId":2}'
curl -X POST localhost:6080/api/images/upload -F "image=@part3-image-server/testimage.png"
curl -X POST localhost:8080/api/feeds -H "$H" -d '{"imageId":"<업로드 응답 ID>","uploaderId":1,"contents":"hello"}'
curl localhost:8080/api/feeds
docker exec pr9-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:29092 --topic feed.created --from-beginning --timeout-ms 5000
```

## 범위 밖
- Timeline Server는 Redis가 필요해서 이 가이드에 포함하지 않았다(Ch 7 범위).
- 클러스터(EKS) 배포는 `part3-infra/README.md`를 따른다.
