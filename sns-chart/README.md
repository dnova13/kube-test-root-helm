# sns-chart: SNS 전체를 한 번에 배포하는 Helm 차트

Feed, User, Image, Timeline, Frontend(Deployment + Service), Image 볼륨(PVC), 설정(ConfigMap), 알림 배치(CronJob), Ingress(ALB)를 **명령 한 번**으로 배포한다.
환경(dev/prod)은 values 파일로 구분한다. 서비스마다 YAML을 따로 쓰지 않고 `values.yaml`의 `services` 목록을 템플릿이 반복해서 만든다.

## 구조

```
sns-chart/
├── Chart.yaml
├── values.yaml                 # 공통 기본값 (기존 kubectl용 YAML과 같은 값)
├── values-dev.yaml             # 개발: Pod 1개, 요청 자원 축소
├── values-prod.yaml            # 운영: 이중화(feed 4, user/timeline/image/frontend 2), 배치 켜짐
├── values-secret.example.yaml  # Secret을 차트로 만들 때 쓰는 예시 (실제 값은 values-secret.yaml, git 제외)
└── templates/
    ├── workloads.yaml          # services 목록 -> Deployment + Service (+ PVC)
    ├── configmaps.yaml         # mysql/kafka/redis/email 접속 정보
    ├── secrets.yaml            # secrets.create=true일 때만
    ├── cronjobs.yaml           # 알림 배치
    ├── ingress.yaml            # ALB
    ├── _helpers.tpl
    └── NOTES.txt
```

## 배포

```bash
# 개발 환경 (처음 설치 = 업데이트 모두 같은 명령)
helm upgrade --install sns-dev ./sns-chart -n sns-dev --create-namespace -f sns-chart/values-dev.yaml

# 운영 환경
helm upgrade --install sns-prod ./sns-chart -n sns-prod --create-namespace -f sns-chart/values-prod.yaml
```

- 환경은 **네임스페이스로 분리**한다. 서비스 이름(`feed-service` 등)은 환경이 같아 네임스페이스만 다르다.
- 서비스 간 주소(`USER_SERVICE`)는 설치한 네임스페이스에 맞게 자동으로 바뀐다.

## 자주 하는 작업

```bash
# 설치 전 확인: 어떤 YAML이 만들어지는지 / 문법 검사
helm template sns-dev ./sns-chart -n sns-dev -f sns-chart/values-dev.yaml
helm lint ./sns-chart -f sns-chart/values-dev.yaml

# 이미지 태그만 바꿔 배포 (feed를 0.0.8로)
helm upgrade sns-dev ./sns-chart -n sns-dev -f sns-chart/values-dev.yaml --set services.feed.image.tag=0.0.8

# 한 서비스만 빼기 / 직접 만든 React 프런트로 교체
--set services.timeline.enabled=false
--set services.frontend.image.tag=react-1.0.0

# 롤백 / 전체 삭제
helm -n sns-dev history sns-dev
helm -n sns-dev rollback sns-dev        # 직전 버전으로
helm -n sns-dev uninstall sns-dev       # 전체 삭제 (Ingress 삭제로 ALB 과금도 중단)
```

## 환경 구분 방식

`values.yaml`(공통) 위에 `-f values-<환경>.yaml`이 **다른 값만 덮어쓴다**. 파일을 여러 개 넘기면 뒤쪽이 우선한다.

| 항목 | dev | prod |
|---|---|---|
| feed / user / image / timeline / frontend 개수 | 1 / 1 / 1 / 1 / 1 | 4 / 2 / 2 / 2 / 2 |
| 요청 CPU | 250m | 500m |
| 알림 배치(CronJob) | 멈춤 | 켜짐 |
| Image PVC | uninstall 시 삭제 | 보존 |

운영용 DB/Kafka/Redis를 따로 만들면 `values-prod.yaml`의 `configMaps`에서 주소만 바꾸면 된다(지금은 개발과 같은 infra를 가리킨다).

## 주의

- **이미 `kubectl apply`로 배포한 `sns` 네임스페이스에 같은 이름으로 설치하면 실패한다** (`exists and cannot be imported`). 새 네임스페이스(`sns-dev`)에 설치하거나, 기존 리소스를 지운 뒤 설치한다. 같은 클러스터에 두 벌이 뜨면 노드 자원이 부족해 Pod가 Pending이 될 수 있다.
- **ALB는 켜 두는 시간만큼 과금**된다. 환경마다 Ingress가 하나씩 생긴다.
- **Secret(`mysql-secret`, `kafka-secret`, `email-secret`)은 기본적으로 차트가 만들지 않는다.** 설치할 네임스페이스에 미리 만들어 두거나(`kubectl -n <ns> apply -f ...`), `values-secret.yaml`로 `secrets.create=true`를 쓴다. 없으면 Pod가 `CreateContainerConfigError`가 된다.
- 클러스터 공용 리소스는 차트에 넣지 않았다: IngressClass `alb`, StorageClass `efs-sc`, infra 네임스페이스의 MySQL ExternalName Service, Redis, Kafka.
- 이미지는 ECR에 해당 태그가 push되어 있어야 한다.
- 현재 코드에는 `application-dev.yaml`만 있어서 prod에서도 Spring 프로파일은 `dev`다. 운영 프로파일이 생기면 `global.springProfile`을 바꾼다.
