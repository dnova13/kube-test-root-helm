# Helm 패키징 세팅 과정 (kubectl 배포 → `sns-chart` 전환)

> `sns` 네임스페이스에 `kubectl`로 올려 둔 서비스 전체를 Helm 차트 `sns-chart/`로 바꾼 과정을 **실제로 한 순서대로** 정리한 문서다. (2026-10-06)
> 개념은 [Helm_패키징_개념정리.md](Helm_패키징_개념정리.md). 사용법 요약은 `sns-chart/README.md`.
> 강의 요약에는 이 주제의 정리 문서가 없어서, 강의 방식이 아니라 일반적인 실무 방식(템플릿 + 환경별 values)으로 만들었다. 강의 영상은 `helm create`까지만 확인했다(`part3-infra/docs/Helm_패키징_helm_create.md`).

## 0. 시작 상태와 목표

- **시작 상태**: `sns` 네임스페이스에 `kubectl apply`로 배포. Pod 10개(feed 4, user 2, image 2, timeline 1, frontend 1), Ingress(ALB), 알림 CronJob(멈춤). YAML이 `part3-*/` 폴더와 `part3-infra/manifests/`에 흩어져 있었다.
- **목표**: 서비스 전체를 **명령 한 번**으로 배포·변경·삭제하고, 개발/운영 환경을 값 파일로 구분한다.
- **전제**: Helm v4.3.0 설치됨, `kubectl`이 EKS에 연결됨.

## 1. 기존 YAML 파악

옮길 대상을 먼저 읽었다. 서비스 5개의 Deployment·Service, ConfigMap 4개, PVC 1개, CronJob 1개, Ingress 1개다.

| 종류 | 이름 | 원본 위치 |
|---|---|---|
| Deployment/Service | feed, user, image, timeline | 각 `part3-*/*-deploy.yaml`, `*-service.yaml` |
| Deployment/Service | sns-frontend | `part3-infra/manifests/sns-frontend-*.yaml` |
| ConfigMap | mysql-config, kafka-config, redis-config, email-config | 각 서비스 폴더 |
| PVC | image-volume-claim | `part3-image-server/image-pvc.yaml` |
| CronJob | notification-batch | `part3-notification-batch/notification-cronjob.yaml` |
| Ingress | sns-ingress | `part3-infra/manifests/sns-ingress.yaml` |

서비스마다 달라지는 것은 이름, 이미지, 환경변수, 참조하는 ConfigMap/Secret, 볼륨 정도이고 나머지(Probe, `preStop`, 자원 요청)는 거의 같았다. 이 구조가 "서비스 목록을 반복해서 찍어 내는" 설계의 근거가 됐다.

## 2. 설계 결정

| 결정 | 이유 |
|---|---|
| 차트 **하나**에 서비스 전체를 담는다 | 명령 한 번으로 전체 배포·롤백 |
| 서비스는 `values.yaml`의 `services` 목록을 **반복 렌더링** | 서비스를 추가해도 템플릿을 고치지 않는다 |
| 환경은 `values-dev.yaml`/`values-prod.yaml`로 구분, **네임스페이스로 분리** | 같은 서비스 이름을 환경마다 쓸 수 있다 |
| **Secret은 차트가 만들지 않는 것이 기본** | 비밀번호를 git에 올리지 않기 위해 |
| **클러스터 공용 리소스는 제외** (IngressClass, StorageClass, DB ExternalName Service, Redis, Kafka) | 서비스 차트의 소관이 아니고 지우면 다른 환경에 영향 |
| 차트 위치는 `pr9-code/sns-chart/` (루트 저장소) | 서비스 폴더는 각자 저장소라 전체를 묶는 것은 루트에 둔다 |

## 3. 차트 뼈대 만들기

`pr9-code` 루트에서 실행했다.

```bash
helm create sns-chart
```

`helm create`가 만든 `deployment.yaml`, `hpa.yaml`, `ingress.yaml`, `httproute.yaml`, `serviceaccount.yaml`, `tests/`는 nginx 샘플용이라 **전부 지우고**, `Chart.yaml`과 `.helmignore`만 남겼다.

```bash
rm -rf sns-chart/templates/* sns-chart/values.yaml
```

> Helm 4에서는 영상(`charts/` 폴더 생성)과 달리 `httproute.yaml`이 추가로 생긴다. 쓰지 않아 삭제했다.

## 4. 파일 작성

### 4-1. `Chart.yaml`

차트 이름 `sns-chart`, `type: application`, 차트 버전 `0.1.0`, 앱 버전 `1.0.0`. 서비스별 이미지 태그는 앱 버전이 아니라 values에서 따로 관리한다.

### 4-2. `values.yaml` (공통 기본값)

기존 YAML 값을 그대로 옮겼다.

| 블록 | 내용 |
|---|---|
| `global` | `environment`, ECR 주소(`imageRegistry`), `springProfile` |
| `configMaps` | mysql/kafka/redis/email 접속 정보. 항목마다 ConfigMap 하나 |
| `secrets` | `create: false`가 기본. 켜면 값 파일로 Secret 생성 |
| `serviceDefaults` | 서비스 공통: 포트 8080, RollingUpdate, `preStop` 10초, 자원 요청/제한, Probe |
| `services` | feed, user, image, timeline, frontend. 서비스별 이름·이미지·Pod 수·환경변수·참조할 ConfigMap/Secret |
| `cronJobs` | notification (스케줄, `suspend: true`) |
| `ingress` | ALB 어노테이션과 경로(`/api/timeline`, `/api/feeds`, `/api/users`, `/api/follows`, `/api/images`, `/`) |

핵심 장치는 두 가지다.
- **`serviceDefaults` 병합**: 공통값은 한 번만 쓰고, 서비스는 다른 값만 적는다.
- **`{{ .Release.Namespace }}`**: Feed가 User를 호출하는 주소(`USER_SERVICE`)에 넣어서, 어느 네임스페이스에 설치해도 맞는 주소가 된다.

### 4-3. `templates/`

| 파일 | 하는 일 |
|---|---|
| `_helpers.tpl` | 공통 라벨, 이미지 주소(`<ECR>/<repository>:<tag>`), `envFrom` 블록 |
| `workloads.yaml` | `services` 목록을 돌며 **Deployment + Service (+ PVC)** 생성 |
| `configmaps.yaml` | `configMaps` 항목마다 ConfigMap 생성 |
| `secrets.yaml` | `secrets.create=true`일 때만 Secret 생성 |
| `cronjobs.yaml` | 알림 배치 CronJob |
| `ingress.yaml` | ALB Ingress |
| `NOTES.txt` | 설치 후 확인·롤백 안내 |

기존 Deployment의 `selector`(`app: <이름>`)는 **바꾸지 않았다.** Deployment의 selector는 한 번 만들면 바꿀 수 없기 때문이다.

### 4-4. 환경·보조 파일

| 파일 | 내용 |
|---|---|
| `values-dev.yaml` | 자원 아끼기: Pod 1개씩, 요청 CPU 250m |
| `values-prod.yaml` | 이중화: feed 4, user/timeline/image/frontend 2, 알림 배치 켜짐, 이미지 PVC 보존. 운영 인프라 주소는 미정이라 주석으로 남김 |
| `values-secret.example.yaml` | Secret을 차트로 만들 때 쓰는 예시(자리표시자만). 실제 값은 `values-secret.yaml`에 쓰고 git 제외 |
| 루트 `.gitignore` | `values-secret.yaml` 추가 |

## 5. 검증 (클러스터에 올리기 전)

```bash
helm lint ./sns-chart -f sns-chart/values-dev.yaml     # dev, prod 모두 통과
helm template sns-dev ./sns-chart -n sns-dev -f sns-chart/values-dev.yaml
```

- dev와 prod 모두 렌더링 결과 **리소스 17개**(ConfigMap 4, CronJob 1, Deployment 5, Ingress 1, PVC 1, Service 5)가 나왔다.
- **기존 YAML과의 비교**: 환경 파일 없이 기본값으로 렌더링한 결과를 기존 `kubectl`용 YAML 20여 개와 자원별로 비교했다(Python으로 YAML을 읽어 라벨·namespace 제외 후 비교).
  - 동일: ConfigMap 4, Service 5, Ingress, PVC, timeline Deployment
  - 의미상 동일한 차이: `envFrom` 나열 순서, `imagePullPolicy: IfNotPresent` 명시(태그 있는 이미지의 기본값), 프런트 `strategy: RollingUpdate` 명시(기본값)
  - 비교 대상에서 제외: `mysql` ExternalName Service(`infra` 네임스페이스, 차트 범위 밖)

## 6. 클러스터에만 있던 설정 발견

전환 전에 현재 클러스터의 Deployment 환경변수를 읽어 YAML과 비교하니, feed와 user에 `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=3`이 **클러스터에만** 있었다(DB 연결 한도 때문에 이전에 `kubectl`로 추가했던 값). 그대로 지우고 재설치하면 사라져, Pod를 늘릴 때 `Too many connections`로 CrashLoopBackOff가 난다. `values.yaml`의 feed·user에 옮겨 적고 렌더링으로 확인했다.

## 7. 전환 방식 결정

| 방식 | 설명 | 선택 |
|---|---|---|
| **이어받기** | 기존 리소스에 Helm 소유 표시(라벨·어노테이션)를 붙이고 `helm upgrade` | 무중단이지만 17개를 손으로 다뤄야 하고 실수하면 중간에 멈춘다 |
| **삭제 후 재설치** | 기존 것을 지우고 Helm으로 새로 설치 | 몇 분 중단되지만 단순하고, 차트가 처음부터 도는지도 검증된다 → **채택** |
| 새 네임스페이스에 설치 | `sns-dev`에 먼저 설치 | 노드 자원·ALB 요금이 두 배 |

학습용 클러스터라 중단이 문제되지 않아 **삭제 후 재설치**로 했다. Helm은 자기가 만들지 않은 리소스를 건드리지 않기 때문에(개념 문서 8번) 그냥 `helm install`은 실패한다.

## 8. 전환 실행

### 8-1. 지우지 않을 것과 지울 것 정하기

| 구분 | 리소스 | 이유 |
|---|---|---|
| 유지 | Secret 3개(`mysql-secret`, `kafka-secret`, `email-secret`) | 차트가 만들지 않는다. 비밀번호를 다시 넣기 번거롭다 |
| 유지 | PVC `image-volume-claim` | 지우면 업로드한 이미지 파일을 잃을 수 있다 |
| 유지 | `kube-root-ca.crt` | 쿠버네티스가 자동 생성 |
| 삭제 | Deployment 5, Service 5, ConfigMap 4, CronJob 1, Ingress 1 (16개) | 차트가 같은 이름으로 다시 만든다 |

`--all` 대신 **이름을 하나씩 지정**해서 지웠다(`kube-root-ca.crt` 보호).

### 8-2. 명령

```bash
NS=sns
# 1) PVC에만 Helm 소유 표시를 붙여 이어받기 (삭제하지 않음)
kubectl -n $NS label    pvc/image-volume-claim app.kubernetes.io/managed-by=Helm --overwrite
kubectl -n $NS annotate pvc/image-volume-claim meta.helm.sh/release-name=sns meta.helm.sh/release-namespace=$NS --overwrite

# 2) 기존 리소스 16개 삭제
kubectl -n $NS delete deploy/feed-server deploy/user-server deploy/image-server deploy/timeline-server deploy/sns-frontend
kubectl -n $NS delete svc/feed-service svc/user-service svc/image-service svc/timeline-service svc/sns-frontend-service
kubectl -n $NS delete cm/mysql-config cm/kafka-config cm/redis-config cm/email-config
kubectl -n $NS delete cronjob/notification-batch ingress/sns-ingress

# 3) Helm으로 한 번에 설치 (당시 상태를 유지하도록 값을 넘김)
helm upgrade --install sns ./sns-chart -n sns \
  --set services.feed.replicas=4 --set services.user.replicas=2 --set services.image.replicas=2 \
  --set services.frontend.image.tag=react-1.0.0 \
  --wait --timeout 8m
```

> 삭제는 되돌릴 수 없는 작업이라 지울 목록을 먼저 확인하고 진행했다. 이전 YAML은 그대로 남아 있어, 실패하면 `kubectl apply`로 원래 상태로 되돌릴 수 있었다.

## 9. 전환 후 확인

| 항목 | 결과 |
|---|---|
| `helm list` | `sns`, revision 1, `deployed`, 차트 `sns-chart-0.1.0` |
| Pod | 10개 모두 `Running` 1/1, 재시작 0 (feed 4, user 2, image 2, timeline 1, frontend 1) |
| 서비스 헬스체크 | feed, user, image, timeline `/healthcheck/ready` 모두 `ready` |
| 기존 데이터 | Timeline API가 이전 피드를 그대로 반환 (RDS·Redis·Kafka는 영향 없음) |
| PVC·Secret | 유지, PVC `Bound` |
| 알림 배치 | `suspend=true` 유지 |
| **ALB** | **주소가 바뀜** `k8s-sns-snsingre-b1f3243e9d-1778477687.ap-northeast-2.elb.amazonaws.com`. 설치 직후에는 `000`(ALB 생성 중)이었고 약 4분 뒤 `/`·`/api/timeline`·`/api/feeds` 모두 **200** |

헬스체크는 처음 `port-forward`로 시도했을 때 연결 전에 요청이 나가 `000`이 나왔다. 클러스터 API 프록시(`kubectl get --raw /api/v1/namespaces/sns/services/<이름>:8080/proxy/healthcheck/ready`)로 바꾸니 정상이었다.

## 10. 현재 상태를 `values.yaml`에 옮기기

`--set`으로 넘긴 값은 다음 `helm upgrade`에서 기본값으로 돌아간다. 그래서 `values.yaml`에 직접 옮겼다.

| 항목 | 이전 기본값 | 반영 값 |
|---|---|---|
| feed Pod | 2 | 4 |
| user Pod | 1 | 2 |
| image Pod | 1 | 2 |
| 프런트 이미지 태그 | `1.0.0` | `react-1.0.0` |

- 배포된 릴리스(`helm get manifest`)와 `--set` 없이 렌더링한 결과를 비교해 빈 줄 2개 외에 **차이가 없음**을 확인했다. 이제 `helm upgrade --install sns ./sns-chart -n sns`만 해도 현재 상태가 유지된다.
- 기본값이 올라가면서 `values-dev.yaml`이 의도(Pod 1개씩)와 달라져, user·image도 1로 지정했다.

| 환경 | feed | user | image | timeline | frontend |
|---|---|---|---|---|---|
| 기본값(현재 클러스터) | 4 | 2 | 2 | 1 | 1 |
| dev | 1 | 1 | 1 | 1 | 1 |
| prod | 4 | 2 | 2 | 2 | 2 |

## 11. 앞으로 변경하는 방법

```bash
# 이미지 새 태그로 배포 (예: feed 0.0.8)
cd part3-feed-server && ./gradlew jib            # build.gradle 태그를 올린 뒤 ECR push
helm upgrade sns ./sns-chart -n sns --set services.feed.image.tag=0.0.8

# 값을 오래 유지하려면 values.yaml의 태그를 직접 고친 뒤
helm upgrade --install sns ./sns-chart -n sns

# 롤백 / 전체 삭제
helm -n sns rollback sns
helm uninstall sns -n sns
```

- `--set`만 쓰고 `values.yaml`을 안 고치면, 다음 `helm upgrade`에서 이전 값으로 돌아갈 수 있다. 계속 유지할 값은 `values.yaml`에 적는다.
- Helm으로 올린 뒤에는 `kubectl edit`·`kubectl set image`로 고치지 않는다.

## 12. 겪은 문제와 조치

| 문제 | 원인 | 조치 |
|---|---|---|
| `helm create` 결과가 영상과 다름 | Helm 4는 `httproute.yaml` 추가, `charts/` 폴더 생성 방식이 다름 | 쓰지 않는 템플릿 삭제 |
| 그냥 `helm install`은 실패 예상 | 기존 리소스에 Helm 소유 표시가 없음 | 삭제 후 재설치, PVC만 표시를 붙여 이어받기 |
| 클러스터에만 있던 DB 연결 풀 설정 | 이전에 `kubectl`로만 추가했고 YAML에 미반영 | `values.yaml` feed·user에 반영 |
| 설치 직후 ALB 접속 불가(`000`) | ALB·DNS 생성에 1~4분 소요 | 기다린 뒤 재확인, 200 |
| 첫 헬스체크 `000` | `port-forward` 연결 전에 요청 | API 프록시 방식으로 재확인 |
| `--set` 값이 기본값으로 돌아갈 위험 | `values.yaml`에 없는 값 | 현재 Pod 수·프런트 태그를 `values.yaml`로 이동 |
| dev의 Pod 수가 의도와 달라짐 | 기본값을 올린 영향 | `values-dev.yaml`에 user·image 1 명시 |

## 13. 현재 상태와 남은 것

- 클러스터: `sns` 네임스페이스가 Helm 릴리스 `sns`로 관리된다. Pod 10개 정상, ALB 접속 확인.
- 차트 파일은 `pr9-code/sns-chart/`(루트 저장소 `kube-test-root-helm`)에 있다.
- **prod 환경은 틀만 있다.** 운영용 DB·Kafka 주소, 도메인, Spring 운영 프로파일(코드에는 `dev`만 있음)이 정해지지 않았다.
- **`sns-dev`/`sns-prod` 네임스페이스에는 아직 설치해 보지 않았다.** 환경 파일 렌더링만 검증했다.
- 기존 서비스 폴더의 `*-deploy.yaml` 등은 남아 있다. 이제 배포는 차트로 하므로 중복 관리를 줄이려면 어떻게 정리할지 정해야 한다(그대로 두면 값이 어긋날 수 있다).
- **ALB는 켜 둔 시간만큼 과금**된다. 쓰지 않을 때는 `helm uninstall sns -n sns`.
