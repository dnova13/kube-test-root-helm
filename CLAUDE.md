# pr9-code 전체 개요

강의 "9개 프로젝트로 경험하는 대용량 트래픽 & 데이터 처리"의 **Project 09: Kubernetes를 이용한 MSA 기반 SNS 백엔드 개발** 실습 코드 모음.
하위 폴더는 각각 독립된 마이크로서비스/모듈이며, 이 파일은 모든 하위 폴더 세션에 공통 적용된다.

- **기준 문서**: `../Project 9/summary/01_Kubernetes를이용한MSA기반SNS백엔드개발.md` (다른 챕터 요약도 같은 폴더에 추가될 수 있음)
  - 설계/구현 판단은 이 문서를 기준으로 한다. 작업을 시작할 때 이 문서를 읽고, 문서와 충돌하는 구현은 먼저 사용자에게 확인한다.
  - 경로에 공백과 한글이 있어 `@` import 대신 직접 읽도록 지시한다. 하위 폴더 세션에서도 상대경로 기준은 `pr9-code/`이다.
- 학습 핵심은 비즈니스 로직이 아니라 **단순한 Java/Spring 서비스들을 Kubernetes + AWS 위에 배치하고 연동하는 것**이다. 기능 구현은 단순하게 유지한다.

## 기술 스택
- 백엔드: Java, Spring
- 인프라: Kubernetes (AWS 위에 구성), Redis, Kafka
- 외부 자원(클러스터 밖): MySQL, SMTP Server

## 하위 프로젝트 (폴더명 기준, 역할은 강의 아키텍처 기준)
| 폴더 | 역할 |
|---|---|
| `part3-user-server` | User Server: 로그인, 팔로우, 사용자 조회. MySQL에 사용자/팔로우 저장 |
| `part3-feed-server` | Feed Server: 게시물 저장/조회(MySQL), 새 피드를 Kafka로 발행, User/Image Server 호출 |
| `part3-image-server` | Image Server: 이미지 조회 |
| `part3-timeline-sersver` | Timeline Server: 타임라인 조회, Redis 저장, Kafka 구독 (폴더명 오타 `sersver`는 그대로 사용) |
| `part3-notification-batch` | Notification: MySQL에서 팔로워 취합 후 SMTP로 이메일 발송 (배치) |
| `part3-infra` | 인프라 셋업 가이드(`README.md`: EKS, EFS, RDS, ECR, 모니터링, k6, Ingress), `ddl.sql`, 공용 K8s manifest(`manifests/`: configmap/secret, frontend deploy 등) |
| `part3-frontend` | Frontend: 직접 만든 React(Vite) 앱 + 강의 제공 이미지 배포. 로컬 실행(`docker-compose.yml`, nginx 프록시), `scripts/`로 ECR push·K8s 배포. 문서는 `README.md` |
| `part3-testdatagen` | `TestDataGen.jar`로 임의 사용자/포스트 생성. `SNS_DATA_GENERATOR_BASEURL`로 대상 지정, Java 19+ 필요 |

- Frontend: 강사 제공 이미지(소스 없음)는 `part3-infra/manifests/sns-frontend-*.yaml`로 배포하고, 직접 만든 React(Vite) 소스는 `part3-frontend/`에 있다(로컬 실행·ECR push·배포 스크립트 포함).
- 각 서비스 폴더에는 자기 배포용 manifest(`*-deploy.yaml`, `*-service.yaml` 등)가 함께 있다. Notification은 Deployment 대신 `notification-cronjob.yaml`(CronJob)을 쓴다.
- **하위 폴더마다 독립된 `.git` 저장소**다. 커밋/푸시는 해당 서비스 폴더 안에서 한다. `pr9-code` 자체는 git 저장소가 아니다.
- 커밋 메시지는 `chX-Y. 작업 내용` 형식(강의 챕터 번호)을 따른다.

## 강의 정리 문서 바로가기
| 챕터 | 문서 |
|---|---|
| Ch 1 | [Kubernetes를 이용한 MSA 기반 SNS 백엔드 개발](../Project%209/summary/01_Kubernetes%EB%A5%BC%EC%9D%B4%EC%9A%A9%ED%95%9CMSA%EA%B8%B0%EB%B0%98SNS%EB%B0%B1%EC%97%94%EB%93%9C%EA%B0%9C%EB%B0%9C.md) |
| Ch 1-03 AWS와 EKS 클러스터 설정 (17:27) | [part3-infra/docs/Ch1-03_AWS와EKS클러스터설정.md](part3-infra/docs/Ch1-03_AWS%EC%99%80EKS%ED%81%B4%EB%9F%AC%EC%8A%A4%ED%84%B0%EC%84%A4%EC%A0%95.md) |
| Ch 1-04 EFS StorageClass 정의 (10:38) | [part3-infra/docs/Ch1-04_EFS_StorageClass_정의.md](part3-infra/docs/Ch1-04_EFS_StorageClass_%EC%A0%95%EC%9D%98.md) |
| Ch 1-05 ECR, MySQL, Redis, Kafka 설치 (14:13) | [part3-infra/docs/Ch1-05_ECR_MySQL_Redis_Kafka_설치.md](part3-infra/docs/Ch1-05_ECR_MySQL_Redis_Kafka_%EC%84%A4%EC%B9%98.md) |
| 클러스터 배포 현황 (Feed·User·Image·Notification) | [part3-infra/docs/클러스터_배포_현황_Feed_User_Image_Notification.md](part3-infra/docs/%ED%81%B4%EB%9F%AC%EC%8A%A4%ED%84%B0_%EB%B0%B0%ED%8F%AC_%ED%98%84%ED%99%A9_Feed_User_Image_Notification.md) |
| Grafana·Prometheus 설치·세팅 (강의 방식, 경고 수정판 — 실설치 확인) | [part3-infra/docs/Grafana_설치_세팅_방법_강의용.md](part3-infra/docs/Grafana_%EC%84%A4%EC%B9%98_%EC%84%B8%ED%8C%85_%EB%B0%A9%EB%B2%95_%EA%B0%95%EC%9D%98%EC%9A%A9.md) |
| Grafana·Prometheus 설치·세팅 (많이 쓰는 방식 kube-prometheus-stack — 렌더링 검증만) | [part3-infra/docs/Grafana_설치_세팅_방법_많이쓰는방식.md](part3-infra/docs/Grafana_%EC%84%A4%EC%B9%98_%EC%84%B8%ED%8C%85_%EB%B0%A9%EB%B2%95_%EB%A7%8E%EC%9D%B4%EC%93%B0%EB%8A%94%EB%B0%A9%EC%8B%9D.md) |
| metrics-server 개념·특징과 `kubectl top` 트러블슈팅 | [part3-infra/docs/metrics-server_개념과_트러블슈팅.md](part3-infra/docs/metrics-server_%EA%B0%9C%EB%85%90%EA%B3%BC_%ED%8A%B8%EB%9F%AC%EB%B8%94%EC%8A%88%ED%8C%85.md) |
| 클러스터 재생성 체크리스트 (EKS 삭제 후 다시 만들기) | [part3-infra/docs/클러스터_재생성_체크리스트.md](part3-infra/docs/%ED%81%B4%EB%9F%AC%EC%8A%A4%ED%84%B0_%EC%9E%AC%EC%83%9D%EC%84%B1_%EC%B2%B4%ED%81%AC%EB%A6%AC%EC%8A%A4%ED%8A%B8.md) |
| 비용 절약: EKS 일시 중지·재개 가이드 | [part3-infra/docs/비용_절약_일시중지_가이드.md](part3-infra/docs/%EB%B9%84%EC%9A%A9_%EC%A0%88%EC%95%BD_%EC%9D%BC%EC%8B%9C%EC%A4%91%EC%A7%80_%EA%B0%80%EC%9D%B4%EB%93%9C.md) |
| Ch 1-04/05 본인 실습 이슈 기록 | [part3-infra/docs/실습_이슈_기록_Ch1-04_05.md](part3-infra/docs/%EC%8B%A4%EC%8A%B5_%EC%9D%B4%EC%8A%88_%EA%B8%B0%EB%A1%9D_Ch1-04_05.md) |
| Ch 2 Social Feed 서버 | [02_SocialFeed서버개발.md](../Project%209/summary/02_SocialFeed%EC%84%9C%EB%B2%84%EA%B0%9C%EB%B0%9C.md) |
| Ch 2 코드 분석 | [part3-feed-server/docs/Ch2_SocialFeed서버_코드분석.md](part3-feed-server/docs/Ch2_SocialFeed%EC%84%9C%EB%B2%84_%EC%BD%94%EB%93%9C%EB%B6%84%EC%84%9D.md) |
| Ch 2-03 Social Feed 기능 개발·배포 | [part3-feed-server/docs/Ch2-03_SocialFeed_기능개발_배포.md](part3-feed-server/docs/Ch2-03_SocialFeed_%EA%B8%B0%EB%8A%A5%EA%B0%9C%EB%B0%9C_%EB%B0%B0%ED%8F%AC.md) |
| Ch 2-04 Telepresence 개발환경 (설치·테스트) | [part3-feed-server/docs/Ch2-04_Telepresence_개발환경.md](part3-feed-server/docs/Ch2-04_Telepresence_%EA%B0%9C%EB%B0%9C%ED%99%98%EA%B2%BD.md) |
| Feed Server 실행·배포·확인 가이드 (트러블슈팅 포함) | [part3-feed-server/docs/Feed서버_실행_배포_확인_가이드.md](part3-feed-server/docs/Feed%EC%84%9C%EB%B2%84_%EC%8B%A4%ED%96%89_%EB%B0%B0%ED%8F%AC_%ED%99%95%EC%9D%B8_%EA%B0%80%EC%9D%B4%EB%93%9C.md) (`part3-infra/docs/`에 심볼릭 링크) |
| Ch 7-1 Feed Server Kafka 발행 코드·배포 상태 | [part3-feed-server/docs/Kafka_발행_코드와_배포_상태.md](part3-feed-server/docs/Kafka_%EB%B0%9C%ED%96%89_%EC%BD%94%EB%93%9C%EC%99%80_%EB%B0%B0%ED%8F%AC_%EC%83%81%ED%83%9C.md) |
| Ch 7-1 User Server Kafka 발행 코드·배포 상태 | [part3-user-server/docs/Kafka_발행_코드와_배포_상태.md](part3-user-server/docs/Kafka_%EB%B0%9C%ED%96%89_%EC%BD%94%EB%93%9C%EC%99%80_%EB%B0%B0%ED%8F%AC_%EC%83%81%ED%83%9C.md) |
| Ch 7 Timeline Server Kafka 구독 코드·배포 상태 | [part3-timeline-sersver/docs/Kafka_구독_코드와_배포_상태.md](part3-timeline-sersver/docs/Kafka_%EA%B5%AC%EB%8F%85_%EC%BD%94%EB%93%9C%EC%99%80_%EB%B0%B0%ED%8F%AC_%EC%83%81%ED%83%9C.md) |
| Ch 3 User 서버 | [part3-user-server/docs/Ch3_User서버개발.md](part3-user-server/docs/Ch3_User%EC%84%9C%EB%B2%84%EA%B0%9C%EB%B0%9C.md) |
| Ch 4 Image 서버 | [part3-image-server/docs/Ch4_Image서버개발.md](part3-image-server/docs/Ch4_Image%EC%84%9C%EB%B2%84%EA%B0%9C%EB%B0%9C.md) |
| Ch 5 Notification Batch | [part3-notification-batch/docs/Ch5_NotificationBatch개발.md](part3-notification-batch/docs/Ch5_NotificationBatch%EA%B0%9C%EB%B0%9C.md) |
| 무중단 업데이트 세팅 (RollingUpdate, Probe, preStop, graceful shutdown) | [part3-infra/docs/무중단_업데이트_세팅.md](part3-infra/docs/%EB%AC%B4%EC%A4%91%EB%8B%A8_%EC%97%85%EB%8D%B0%EC%9D%B4%ED%8A%B8_%EC%84%B8%ED%8C%85.md) |
| 인프라 세팅 트러블슈팅 (Grafana No data, EC2 종료 시 재생성 등) | [part3-infra/docs/인프라_세팅_트러블슈팅.md](part3-infra/docs/%EC%9D%B8%ED%94%84%EB%9D%BC_%EC%84%B8%ED%8C%85_%ED%8A%B8%EB%9F%AC%EB%B8%94%EC%8A%88%ED%8C%85.md) |
| Kubecost 설치 요약 — 최신 v3 (강의와 달라진 점·Helm 설치 결과·현재 상태) | [part3-infra/docs/Kubecost_설치_요약_최신.md](part3-infra/docs/Kubecost_%EC%84%A4%EC%B9%98_%EC%9A%94%EC%95%BD_%EC%B5%9C%EC%8B%A0.md) |
| Kubecost 설치 요약 — 강의용 v1 (README 방식, values URL만 수정 — 설치 성공) | [part3-infra/docs/Kubecost_설치_요약_강의용_v1.md](part3-infra/docs/Kubecost_%EC%84%A4%EC%B9%98_%EC%9A%94%EC%95%BD_%EA%B0%95%EC%9D%98%EC%9A%A9_v1.md) |
| Timeline Server 코드 분석 (목적, Redis 설계, 주석 코드) | [part3-timeline-sersver/docs/Timeline서버_코드분석.md](part3-timeline-sersver/docs/Timeline%EC%84%9C%EB%B2%84_%EC%BD%94%EB%93%9C%EB%B6%84%EC%84%9D.md) |
| Timeline Server 배포 치트시트 (내 AWS 기준) | [part3-timeline-sersver/배포_치트시트.md](part3-timeline-sersver/%EB%B0%B0%ED%8F%AC_%EC%B9%98%ED%8A%B8%EC%8B%9C%ED%8A%B8.md) |
| Ingress(ALB) 세팅과 이슈 — CLI/웹 콘솔 + 캡처 (Auto Mode, sts:TagSession 오류) | [part3-infra/docs/Ingress_ALB_세팅_이슈_가이드.md](part3-infra/docs/Ingress_ALB_%EC%84%B8%ED%8C%85_%EC%9D%B4%EC%8A%88_%EA%B0%80%EC%9D%B4%EB%93%9C.md) |
| Helm 패키징: 서비스 전체를 차트로 묶기, `helm create`로 뼈대 만들기 (도입부만 정리) | [part3-infra/docs/Helm_패키징_helm_create.md](part3-infra/docs/Helm_%ED%8C%A8%ED%82%A4%EC%A7%95_helm_create.md) |
| Frontend (React 소스, 로컬 실행, 배포) | [part3-frontend/README.md](part3-frontend/README.md) |
| 인프라 트러블슈팅: EKS kubectl 인증 오류 | [part3-infra/docs/EKS_kubectl_인증오류_트러블슈팅.md](part3-infra/docs/EKS_kubectl_%EC%9D%B8%EC%A6%9D%EC%98%A4%EB%A5%98_%ED%8A%B8%EB%9F%AC%EB%B8%94%EC%8A%88%ED%8C%85.md) |

- User Server kubectl 배포 명령: [part3-user-server/배포명령어.md](part3-user-server/%EB%B0%B0%ED%8F%AC%EB%AA%85%EB%A0%B9%EC%96%B4.md)
- 로컬 실행 방법: [local-run/README.md](local-run/README.md) (전용 MySQL/Kafka를 docker compose로 띄우고 서비스를 실행)
- 각 챕터 문서는 해당 코드 폴더의 `docs/`에 있다(Ch 1, 2는 `Project 9/summary/`). 새 챕터를 정리하면 이 표에 추가한다.

## 아키텍처 (데이터 흐름)
- User → Frontend → Timeline Server(타임라인 조회) / User Server(로그인, 팔로우)
- Timeline Server ↔ Redis(타임라인 저장), Timeline Server ↔ Kafka(타임라인 정보 수신)
- Feed Server → Kafka(새 피드 발행), Feed Server → User Server(사용자 조회), Feed Server → Image Server(이미지 조회)
- Feed Server / User Server ↔ MySQL, Notification ↔ MySQL(팔로워 취합), Notification → SMTP(이메일 발송)
- 클러스터 내부: Frontend, Timeline, User, Feed, Notification, Image, Redis, Kafka / 클러스터 외부: MySQL, SMTP

## Kubernetes 설계 원칙 (강의 제시)
1. 내부 자원과 외부 자원을 분리해서 설계한다.
2. 스토리지 구성은 저장 공간 활용 방식에 따라 결정한다.
3. 배치 프로그램(CronJob 등) 구성에 따라 개발 방향이 달라질 수 있다.
4. 기존 시스템을 Kubernetes로 옮길 때 일부 기능이 그대로 동작하지 않을 수 있다.

## 세션 공유 규칙
- 전체에 영향을 주는 결정(서비스 간 계약, 공통 설정, 포트, 토픽명 등)이 생기면 `docs/PROGRESS.md`에 기록한다.
- 작업 시작 전 아래 진행 현황을 확인한다.
- 하위 프로젝트 전용 규칙은 해당 폴더의 CLAUDE.md에 적는다.

@docs/PROGRESS.md
