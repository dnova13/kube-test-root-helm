# 진행 현황

## 현황 (2026-10-01 기준, 각 저장소 git log로 확인)
| 폴더 | 마지막 커밋 단계 | 구현된 것 |
|---|---|---|
| `part3-user-server` | ch7-1 | 회원가입/로그인, 팔로우/언팔로우, 팔로우 메시지 Kafka 발행 |
| `part3-feed-server` | ch7-1 | 소셜 피드 API, User Server 연동, 타임라인용 메시지 Kafka 발행 |
| `part3-image-server` | ch4-2 | 이미지 볼륨(PVC) 설정, 업로드/다운로드 (EKS 배포 완료, 2026-10-04) |
| `part3-notification-batch` | ch5-2 | 알림 배치(CronJob) 설정 |
| `part3-timeline-sersver` | ch7-2 | 타임라인 API, Feed/Follow Kafka 리스너, Redis 저장 |
| `part3-infra` | (가이드) | EKS/EFS/RDS/ECR/모니터링/k6/Ingress 가이드, manifest |
| `part3-testdatagen` | (도구) | 제공된 테스트 데이터 생성기 |

- 위 폴더들은 강의 제공 저장소 상태로 보이며, 본인 구현 진행도와 같은지는 미확인.
- 현재 학습 중인 강의: Ch 2. Social Feed 서버 개발 → 정리 문서 `../Project 9/summary/02_SocialFeed서버개발.md`

## 강의 정리 문서 (2026-10-01 작성)
- Ch 2, 3, 4, 5 정리 완료. 문서 위치는 `CLAUDE.md`의 「강의 정리 문서 바로가기」 표 참고.
- Ch 6 이후(모니터링, 성능 테스트 등)와 Ch 7(Kafka, Timeline)은 미정리.

- (2026-10-02) 강의 Ch 1-03 「AWS와 EKS를 이용한 쿠버네티스 클러스터 설정」(17:27) 정리 완료: `part3-infra/docs/Ch1-03_AWS와EKS클러스터설정.md` (캡처 `part3-infra/docs/images/ch01-03/`). 영상 캡처 기반이라 초반 IAM 생성 구간은 일부 미확인. Auto Mode 기준 가이드는 `part3-infra/AWS_SETUP.md`.
- (2026-10-02) 강의 Ch 1-04(EFS StorageClass), Ch 1-05(ECR·MySQL·Redis·Kafka) 정리 완료: `part3-infra/docs/Ch1-04_*.md`, `Ch1-05_*.md`. 본인 실습에서 확인된 문제(IAM 오타 의심, YAML 탭, kubectl 권한, Pod Pending, RDS 접속 불가)는 `part3-infra/docs/실습_이슈_기록_Ch1-04_05.md`에 따로 기록.
- (2026-10-03) 강의 Ch 2-03(Social Feed 기능 개발·배포), Ch 2-04(Telepresence 개발환경) 정리 문서 작성: `part3-feed-server/docs/Ch2-03_*.md`, `Ch2-04_*.md`. 사용자가 읽고 피드백 예정.
- (2026-10-03) Feed Server를 EKS에 배포해 `healthcheck/live`·`GET /api/feeds` 정상 확인. `POST /api/feeds`는 User Server 미배포로 500. 배포하며 바뀐 것: RDS(MariaDB 11.8)용으로 `dev` 프로파일 DB 드라이버를 `mariadb-java-client`로 교체(`jdbc:mariadb://…?sslMode=trust`), 이미지 베이스 `eclipse-temurin:21-jre`, 이미지 태그 0.0.7, Kafka 이미지 `bitnamilegacy/kafka`로 `helm upgrade`, 노드 그룹 3대로 증설. 정리: `part3-feed-server/docs/Feed서버_실행_배포_확인_가이드.md`(트러블슈팅 포함), Ch2-03·Ch2-04 문서에 보충. 다음: User Server 배포.
- (2026-10-04) Ch3-04(무중단 업데이트)를 영상 캡처 65장으로 보충: `part3-user-server/docs/Ch3_User서버개발.md` 04 절. 실제 강의는 Feed Server(replicas 2)를 0.0.3으로 롤링 업데이트하며 구버전/신버전 응답이 교차하는 것을 관찰하고, API 하위 호환·경로 버전 분기를 강조하는 내용. User Server 배포 명령은 `part3-user-server/배포명령어.md`.
- (2026-10-04) image-server를 EKS에 배포해 PVC `Bound`(EFS `efs-sc`, RWX 5Gi), Pod 1/1 Running, `/healthcheck/live`·`ready` 200 확인(업로드/다운로드 API는 미호출). 바뀐 것: `build.gradle` ECR 계정 `076899627941`·베이스 `eclipse-temurin:21-jre`·태그 0.0.4, `image-deploy.yaml` 이미지 태그 0.0.4·`IMAGE_PATH=/images`. 배포 중 PVC가 Pending이었던 원인은 EFS CSI 역할 `AmazoneEKS-EFS-CSI-DriverRole`의 IAM 설정 오류 3건(OIDC ClientID `sts.amazonews.com` 오타, 신뢰 정책 `aud`/`sub` 오타, `AmazonEFSCSIDriverPolicy` 미연결). 앞의 둘은 aws CLI로 수정, 정책은 사용자가 직접 연결. 상세는 `part3-infra/docs/실습_이슈_기록_Ch1-04_05.md` 6번. 치트시트: `part3-image-server/배포_치트시트.md`, `part3-image-server/볼륨_치트시트.md`. 역할 이름의 케밥 케이스(`AmazoneEKS-...`)는 사용자가 의도한 것이라 오타로 보지 않는다.
- (2026-10-04) Feed(2), User(1), Image(1) Deployment와 Notification CronJob(suspend) 배포 완료, Pod 모두 Running, healthcheck ok. 현황·설정·자원 사용은 `part3-infra/docs/클러스터_배포_현황_Feed_User_Image_Notification.md`. 남은 것: Timeline Server, Frontend, Ingress, Notification 메일 검증.
- (2026-10-05) Grafana `rate(container_cpu_usage_seconds_total{namespace="sns"}[5m])`가 `No data`였던 원인은 당시 `sns` Pod가 Pending(노드 NotReady)이라 컨테이너가 없었던 것으로 확인(첫 샘플 11:10 KST). EC2를 콘솔에서 종료하면 노드 그룹 ASG(`desiredSize=3`)가 다시 만든다는 것도 확인. 정리: `part3-infra/docs/인프라_세팅_트러블슈팅.md`.
- (2026-10-05) 강의 README의 Kubecost 설치(차트 1.108.1, `develop` values)는 values URL 404 등으로 그대로 불가. 최신 v3 차트(`oci://public.ecr.aws/kubecost/kubecost` 3.3.0)·EKS 애드온 기준으로 애드온은 Marketplace 구독 필요로 `CREATE_FAILED`, Helm 설치는 `deployed`지만 PVC `Pending`·`finopsagent` `ImagePullBackOff` 등 미해결(2026-10-05 확인). Helm에 볼륨 끄기·이미지 수정 옵션을 넣어 대부분 `Running`, `aggregator`·`mcp`는 자원 부족 `Pending`. 정리는 최신 v3 `part3-infra/docs/Kubecost_설치_요약_최신.md`, 강의 v1 `Kubecost_설치_요약_강의용_v1.md`(v1.108.1은 `-f` URL을 `develop`→`v1.108.1` 태그로 바꿔 `monitoring`에 설치 성공, cost-analyzer·kubecost-prometheus-server `Running`, 접속 HTTP 200).
- (2026-10-06) k6 부하 테스트 실행 확인. `part3-testdatagen/k6-test.md`(`telepresence connect` → `k6 run k6-script.js`)와 `k6-script.js`(10 VU, 30초, `GET /api/feeds`). Telepresence는 로컬 맥을 EKS 클러스터 네트워크(터널+DNS)에 붙여 `*.svc.cluster.local` 주소를 직접 호출하게 해 준다. 스크립트 호스트가 `feed-server`로 잘못 적혀 있어(실제 Service 이름은 `feed-service`) 100% `no such host`였고, `feed-service.sns.svc.cluster.local:8080`으로 수정. 수정 후 결과: 13,151건(약 438 req/s), 실패 0%, 응답시간 평균 22.7ms / p95 32.8ms / 최대 348ms (Feed Pod 2개). 강의 의도(Grafana로 CPU/메모리 관찰, 확장 필요성 체감)는 추정이며 강의 자료로 확인하지 않음.
- (2026-10-06) Timeline Server 코드 분석·주석 추가: `part3-timeline-sersver/docs/Timeline서버_코드분석.md`, 배포 치트시트 `배포_치트시트.md`. 내 AWS 세팅으로 변경: jib/Deployment ECR 계정 `638597541124`→`076899627941`, 베이스 `openjdk:21`→`eclipse-temurin:21-jre`, replicas 2→1(클러스터 Pending Pod 있음). 아직 배포 전(이미지 push·`redis-config` apply 필요). `sns-frontend-deploy.yaml`은 아직 강의 계정 이미지.
- (2026-10-06) Ch 7-1 Kafka 발행 반영 여부 확인: Feed(`feed-server:0.0.7`)·User(`user-server:0.0.7`)는 코드와 배포 모두 반영, 토픽 `feed.created`(메시지 1,003개)·`user.follower`(0개) 존재. 받는 쪽 Timeline Server는 이 시점에는 미배포였고 이후 배포되어 `feed.created` 1,003개를 모두 소비(LAG 0). 정리: 각 서비스 `docs/Kafka_*_코드와_배포_상태.md`. 관련 코드에 한국어 주석 보강(동작 변경 없음).
- (2026-10-06) TestDataGen 1000건 실행(사용자 334명·피드 998개 추가, 전체 피드 1,003개)과 스케일아웃 k6 비교: feed 2·user 1 → feed 4·user 2에서 처리량 0.46 → 0.85 req/s, 평균 응답 19.2초 → 10.4초(Hikari 풀 3 기준). `GET /api/feeds`는 전체 조회 후 피드마다 User Server를 호출하는 N+1 구조라 데이터가 늘면 급격히 느려진다. 정리: `part3-testdatagen/k6-test.md`, `TestDataGen_설명.md`. 클러스터를 바꾼 것(Deployment YAML에는 미반영): 노드 그룹 `sns-node` 3 → 6대(`maxSize=6`, EC2 비용 증가), feed/user에 `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=3` 추가(RDS `db.t4g.micro`의 `max_connections`가 28~30 정도로 추정되어 `Too many connections`로 CrashLoopBackOff 발생), image-server replicas 2. 측정 후 노드 3대·feed 2·user 1·image 1로 되돌리는 것을 권장하며 아직 되돌리지 않았다.
- (2026-10-06) Timeline Server를 EKS에 배포(`timeline-server:0.0.1`, 1/1 Running, Kafka 구독·Redis 적재 확인). Ingress(ALB) 공개: 서브넷 4개 ALB 태그, IngressClass `alb`, `EKS-Cluster-role` 신뢰 정책 `sts:TagSession` 추가·Auto Mode 정책 4종 연결(IAM 변경은 사용자가 직접 실행), `part3-infra/manifests/sns-ingress.yaml` 적용으로 ALB 생성, 외부 주소로 timeline/users/feeds 200 확인. 프런트는 이미지 문제로 보류(`/`는 404). **ALB 켜 둔 동안 과금** — 쓰지 않으면 Ingress 삭제. 주소와 사용법은 `part3-timeline-sersver/배포_치트시트.md` 6절. 세팅·이슈 정리(CLI/웹 콘솔, 캡처 7장)는 `part3-infra/docs/Ingress_ALB_세팅_이슈_가이드.md`.
- (2026-10-06) Timeline Server(코드 최적화: Kafka로 받아 Redis 저장, REST는 Redis만 읽음) k6 비교: ① 기본 feed 2·user 1의 Feed API 0.46 req/s·평균 19.2초, ② 늘림 feed 4·user 2의 Feed API 약 0.85 req/s·평균 약 10.5초(4회 평균), ③ Timeline `GET /api/timeline`(Pod 1개) 약 36 req/s·평균 0.27초(3회 평균), `GET /api/timeline/339` 약 370 req/s·평균 27ms. 개선 이유: User Server N+1 호출 제거(작성자 이름이 Kafka 메시지에 포함), DB 대신 Redis ZSet 조회, 쓸 때 미리 계산(CQRS), DB 연결 한도 무관. 첫 측정(9.27 req/s)은 원인 불명의 이상치. 비교용 스크립트 `part3-testdatagen/k6-compare.js`(`-e URL=`), 분석·3가지 조건 비교표는 `part3-testdatagen/k6-test.md`의 「코드 최적화 비교」. 클러스터는 아직 노드 6대, feed 4·user 2·image 2·timeline 1 상태.
- (2026-10-06) 강의 제공 프런트 이미지(`jheo/sns-frontend:1.0.0`, Docker Hub 공개)를 내 ECR `sns-frontend:1.0.0`으로 옮겨 EKS 배포(1/1 Running). Ingress에 `/`(frontend)와 `/api/images`(image-service) 추가 — 프런트가 `/api/images/*`도 호출하는데 처음 Ingress에 빠져 있었음. ALB 주소로 `/`·`/sign-in`·`/mypage`·API 200 확인. 직접 만든 React(Vite) 프런트와 로컬 실행·배포 스크립트를 `part3-frontend/`에 작성(`README.md`). React 이미지(`sns-frontend:react-1.0.0`)를 amd64로 빌드해 ECR push 후 `k8s-deploy.sh react`로 EKS에 롤링 교체 배포(1/1 Running), ALB 주소로 `/`·`/sign-in`·`/mypage`·`/timeline/339`·API 200 확인. 처음 amd64 pull이 멈춘 것은 내가 띄웠다 남긴 docker 프로세스 탓으로 추정(Docker Desktop 재시작 불필요했음). 되돌리기: `kubectl -n sns rollout undo deploy/sns-frontend`.
- (2026-10-06) 강의 Helm 패키징 영상(48:18) 앞 00:13~01:28 구간을 캡처 25장으로 정리: `part3-infra/docs/Helm_패키징_helm_create.md`(캡처 8장 `images/helm-packaging/`). `helm create sns-chart`로 차트 뼈대(`Chart.yaml`, `values.yaml`, `templates/`)를 만드는 데까지만 확인. 템플릿 수정·`helm install`·서비스 분리 방식은 캡처가 없어 미정리. 챕터 번호도 미확인.

## 질의 메모
- Ch2 04강을 보다가 "ECR과 Telepresence가 무엇인지" 궁금해서 질문함 (스크린샷은 그 질문용이라 문서에는 첨부하지 않음).
  - 개념 정리는 `../Project 9/summary/02_SocialFeed서버개발.md`의 「개념 정리: ECR과 Telepresence」 절에 있음.
  - 04강의 Telepresence 설치/실행 명령어는 저장소에 없음. 사용자 기억으로는 telepresence.io에서 설치 명령어를 실행하고 테스트 데이터 생성기를 실행하는 흐름. 정확한 명령어는 미확인.
- (2026-10-02) `part3-infra/README.md`의 Redis/Kafka `helm install` 명령을 보고 "Helm이 무엇인지, 이미 Docker 이미지가 있는데 이 주소는 무슨 용도인지, Docker로 하는 게 아닌지"를 질문함.
  - 결론: `oci://registry-1.docker.io/bitnamicharts/...`는 Docker 이미지가 아니라 Helm Chart(Kubernetes에 올리는 YAML 템플릿 묶음)이고, `helm install`은 Docker 실행이 아니라 Kubernetes 클러스터에 설치하는 것. 정리는 `part3-infra/docs/Helm_개념정리.md`.
  - **추후 Helm, Chart, Redis/Kafka 설치 방식을 다시 물어볼 수 있으니 이 문서를 먼저 참고해 답한다.**

## 결정 사항
- (2026-10-02) feed-server 로컬 실행: `application.yaml`에 `spring.profiles.default: local`, `local` 프로파일은 `local-run/` docker compose 포트(MySQL 23307, Kafka 19092)를 사용. 클러스터는 `SPRING_PROFILES_ACTIVE=dev`로 덮어씀.
- (2026-10-02) feed-server에 Swagger(springdoc-openapi 2.3.0) 추가: `/swagger-ui.html`. image-server에도 추가됨. timeline 서버에는 아직 없음.
- (2026-10-02) image-server에도 같은 방식 적용: `spring.profiles.default: local`(포트 6080, 저장 경로 `images`)과 Swagger(springdoc-openapi 2.3.0, `/swagger-ui.html`). 상세는 `part3-image-server/docs/Ch4_Image서버개발.md` 하단, 트러블슈팅은 `part3-image-server/docs/트러블슈팅.md`.
- (2026-10-02) user-server에도 같은 방식 적용: `spring.profiles.default: local`(포트 9080, `application-local.yaml`을 MySQL 23307/Kafka 19092로 수정)과 Swagger(springdoc-openapi 2.3.0, `/swagger-ui.html`). 상세는 `part3-user-server/docs/Ch3_User서버개발.md` 하단, 트러블슈팅은 `part3-user-server/docs/트러블슈팅.md`. 이제 feed/image/user 서버에 Swagger가 있고 timeline 서버에는 아직 없음.
- (2026-10-02) notification-batch 로컬 실행: `spring.profiles.default: local`(포트 7080, MySQL 23307)과 Swagger(springdoc 2.3.0, `/swagger-ui.html`)로 Job 수동 실행 API(`POST /api/batch/notification/run`) 추가. `dev`는 `web-application-type: none`으로 기존 CronJob 동작 유지. 상세는 `part3-notification-batch/docs/Ch5_NotificationBatch개발.md` 하단, API 정리/Swagger 링크는 `part3-notification-batch/docs/API.md`, 트러블슈팅은 `part3-notification-batch/docs/트러블슈팅.md`.
- (2026-10-02) 로컬 MySQL 포트를 13306에서 **23307**로 변경(13306을 다른 곳에서 사용 중). `local-run/docker-compose.yml`, 각 서비스의 `application-local.yaml`, 관련 문서를 모두 23307로 수정. Kafka는 19092 그대로. 앞의 결정 사항에 적힌 13306은 이 변경 이전 값이다.
- feed-server 문서: `part3-feed-server/docs/Ch2_SocialFeed서버_코드분석.md`, 트러블슈팅은 같은 폴더 `TROUBLESHOOTING.md`.

## 다음 할 일
- 본인 작업 폴더의 실제 구현 진행도 확인 후 위 표 갱신
