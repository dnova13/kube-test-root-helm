# Helm 배포 치트시트 (`sns-chart`)

`pr9-code/` 루트에서 실행한다. 차트 설명은 `sns-chart/README.md`, 개념과 세팅 과정은 `sns-chart/docs/`.
현재 `sns` 네임스페이스에 릴리스 `sns`가 이 차트로 배포되어 있다.

## 목차

| 절 | 내용 |
|---|---|
| 0. 시작 전 확인 | Helm 버전, kubectl 컨텍스트, 노드 상태 |
| 1. 전체 배포 | `helm upgrade --install sns ./sns-chart -n sns` 한 줄, 환경별(dev/prod) 명령 |
| 2. 설치 전 미리 보기 | lint, template, 배포된 것과 차이 비교 |
| 3. 상태 확인 | Pod, 헬스체크, ALB 주소와 외부 접속 |
| 4. 서비스 하나만 바꿔 배포 | 이미지 빌드부터 태그만 바꿔 올리는 순서, 서비스별 키 표 |
| 5. 자주 하는 변경 | Pod 수, 서비스 빼기, 프런트 이미지 교체, 배치 켜기·끄기, ALB 끄기 |
| 6. 되돌리기 / 삭제 | history, rollback, uninstall |
| 7. 문제가 생겼을 때 | 증상별 원인과 조치 |
| 8. 주의 | 아래 「먼저 알아 둘 주의할 점」 상세 |

## 먼저 알아 둘 주의할 점

1. **`helm uninstall`을 하면 이미지 PVC도 함께 지워져 업로드한 이미지 파일이 사라질 수 있다.** PVC 보존 설정(`keepOnUninstall`)은 `values-prod.yaml`에만 있다. 삭제 전에 6절의 보존 방법을 먼저 적용한다.
2. **Helm으로 올린 뒤에는 `kubectl edit`·`kubectl set image`·`kubectl scale`로 고치지 않는다.** 다음 `helm upgrade`에서 원래 값으로 조용히 되돌아간다. 남길 값은 `values.yaml`에 적는다.
3. **`--set`은 그 명령에만 적용된다.** 값을 계속 쓰려면 `values.yaml`을 고치거나 `--reuse-values`를 붙인다.
4. **Secret(`mysql-secret`, `kafka-secret`, `email-secret`)은 차트가 만들지 않는다.** 새 네임스페이스에 설치할 때는 먼저 만들어야 하고, `uninstall`을 해도 남는다.
5. **Ingress를 지우고 다시 만들면 ALB 주소가 바뀐다.** 켜 둔 시간만큼 과금되므로 쓰지 않으면 `ingress.enabled=false`나 `helm uninstall`.
6. **같은 클러스터에 환경을 두 벌 올리면** 노드 자원 부족(Pod Pending)과 ALB 요금 2배가 생긴다.

## 0. 시작 전 확인

```bash
helm version --short                  # v4.x
kubectl config current-context        # EKS 클러스터인지 확인
kubectl get nodes                     # 노드 Ready (클러스터를 일시 중지했다면 먼저 재개)
```

## 1. 전체 배포 (명령 한 번)

```bash
# 처음 설치 = 변경 반영, 같은 명령 (없으면 설치, 있으면 업데이트)
helm upgrade --install sns ./sns-chart -n sns --wait --timeout 8m
```

- `values.yaml` 기본값이 **현재 클러스터와 같다**: feed 4, user 2, image 2, timeline 1, frontend 1(`react-1.0.0`).
- 환경별로 하려면 `-f`를 붙이고 네임스페이스를 나눈다.

```bash
helm upgrade --install sns-dev  ./sns-chart -n sns-dev  --create-namespace -f sns-chart/values-dev.yaml    # Pod 1개씩
helm upgrade --install sns-prod ./sns-chart -n sns-prod --create-namespace -f sns-chart/values-prod.yaml   # 이중화
```

- **새 네임스페이스에는 Secret 3개를 먼저 만들어야 한다** (`mysql-secret`, `kafka-secret`, `email-secret`). 없으면 Pod가 `CreateContainerConfigError`. 차트로 만들려면 `sns-chart/values-secret.example.yaml`을 복사해 `values-secret.yaml`로 값을 채우고 `-f sns-chart/values-secret.yaml`을 추가한다(git 제외 파일).
- 같은 클러스터에 두 벌을 올리면 노드 자원이 모자라 Pod가 Pending이 될 수 있고, 환경마다 ALB 요금이 따로 나온다.

## 2. 설치 전 미리 보기

```bash
helm lint ./sns-chart                                   # 문법 검사
helm template sns ./sns-chart -n sns | less             # 만들어질 YAML 보기 (클러스터 변경 없음)
helm template sns ./sns-chart -n sns | grep -E '^kind:' | sort | uniq -c   # 종류별 개수 (17개)
helm -n sns get manifest sns | diff - <(helm template sns ./sns-chart -n sns)   # 배포된 것과 차이
```

## 3. 상태 확인

```bash
helm -n sns list                                        # 릴리스 (STATUS deployed)
helm -n sns status sns
kubectl -n sns get pods                                 # 10개 모두 Running 1/1
kubectl -n sns get deploy,svc,ingress,pvc
kubectl -n sns get cronjob                              # notification-batch (suspend)

# 서비스 헬스체크 (port-forward 없이)
for s in feed-service user-service image-service timeline-service; do
  echo "$s: $(kubectl get --raw /api/v1/namespaces/sns/services/$s:8080/proxy/healthcheck/ready)"
done

# ALB 주소와 외부 접속 확인 (생성까지 1~4분)
ADDR=$(kubectl -n sns get ingress sns-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); echo $ADDR
curl -s -o /dev/null -w '%{http_code}\n' http://$ADDR/api/timeline
```

현재 ALB 주소: `k8s-sns-snsingre-b1f3243e9d-1778477687.ap-northeast-2.elb.amazonaws.com` (Ingress를 지우고 다시 만들면 바뀐다)

## 4. 서비스 하나만 바꿔 배포

```bash
# (1) 이미지 새 태그로 빌드·push (build.gradle의 태그를 올린 뒤). 각 서비스 폴더의 배포_치트시트.md 참고
cd part3-feed-server && ./gradlew jib && cd ..

# (2) 태그만 바꿔서 배포 -> feed만 롤링 업데이트, 나머지 서비스는 재시작하지 않는다
helm upgrade sns ./sns-chart -n sns --set services.feed.image.tag=0.0.8

# (3) 계속 유지할 값이면 values.yaml의 태그를 직접 고친 뒤 (--set은 다음 upgrade에서 사라진다)
helm upgrade --install sns ./sns-chart -n sns
```

| 서비스 | 키 | 이미지 저장소 |
|---|---|---|
| Feed | `services.feed` | `feed-server` |
| User | `services.user` | `user-server` |
| Image | `services.image` | `image-server` |
| Timeline | `services.timeline` | `timeline-server` |
| Frontend | `services.frontend` | `sns-frontend` (React: `react-1.0.0`, 강의 이미지: `1.0.0`) |
| 알림 배치 | `cronJobs.notification` | `notification-batch` |

## 5. 자주 하는 변경

```bash
# Pod 수 조정
helm upgrade sns ./sns-chart -n sns --set services.feed.replicas=2

# 한 서비스만 빼기 / 프런트를 강의 제공 이미지로
helm upgrade sns ./sns-chart -n sns --set services.timeline.enabled=false
helm upgrade sns ./sns-chart -n sns --set services.frontend.image.tag=1.0.0

# 알림 배치 켜기(스케줄 시작) / 다시 멈추기 (메일 검증이 끝난 뒤에만)
helm upgrade sns ./sns-chart -n sns --set cronJobs.notification.suspend=false
helm upgrade sns ./sns-chart -n sns --set cronJobs.notification.suspend=true

# Ingress(ALB) 끄기 = ALB 요금 중단 / 켜기
helm upgrade sns ./sns-chart -n sns --set ingress.enabled=false
helm upgrade sns ./sns-chart -n sns --set ingress.enabled=true
```

- `--set`은 그 명령에만 적용된다. 값을 유지하려면 `values.yaml`을 고치거나, 직전 값을 이어 쓰는 `--reuse-values`를 붙인다.
- 값은 `values.yaml`(공통) → `-f values-<환경>.yaml` → `--set` 순으로 뒤쪽이 우선한다.

## 6. 되돌리기 / 삭제

```bash
helm -n sns history sns                 # 변경 이력 (revision 번호)
helm -n sns rollback sns                # 직전 버전으로 (전체)
helm -n sns rollback sns 1              # 특정 revision으로
helm uninstall sns -n sns               # 전체 삭제 (Ingress 삭제로 ALB 과금도 중단)
```

- `uninstall`을 해도 **Secret 3개는 남는다**(차트가 만들지 않았다). 이미지 PVC는 `values-prod.yaml`에서만 보존 설정이라, `sns`에서는 `uninstall` 시 PVC도 함께 지워져 업로드한 이미지가 사라질 수 있다. 보존하려면 `--set services.image.persistence.keepOnUninstall=true`로 한 번 `upgrade`해 둔 뒤 삭제한다.
- 삭제 후 다시 설치하면 ALB 주소가 바뀐다.

## 7. 문제가 생겼을 때

| 증상 | 확인·조치 |
|---|---|
| `exists and cannot be imported into the current release` | 같은 이름의 리소스를 `kubectl`로 만든 상태. 지우고 설치하거나 `app.kubernetes.io/managed-by=Helm` 라벨과 `meta.helm.sh/release-name`·`release-namespace` 어노테이션을 붙여 이어받는다 |
| Pod `CreateContainerConfigError` | Secret/ConfigMap이 없다. `kubectl -n sns get secret,cm`로 `mysql-secret`, `kafka-secret`, `email-secret` 확인 |
| Pod `Pending` | 노드 자원 부족. `kubectl -n sns describe pod <이름>`의 Events 확인, Pod 수를 줄이거나 노드 증설 |
| Pod `CrashLoopBackOff` + `Too many connections` | RDS 연결 한도. feed·user의 `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE`(현재 3)와 Pod 수 확인 |
| `ImagePullBackOff` | ECR에 그 태그가 push되어 있는지, 노드의 ECR 읽기 권한 확인 |
| ALB 접속이 안 됨 (`000`) | 생성 직후 1~4분은 정상. `kubectl -n sns get ingress`의 ADDRESS 확인, 계속 안 되면 `describe ingress` |
| 값을 바꿨는데 되돌아감 | `kubectl edit`으로 고친 값이 `helm upgrade`에서 사라진 것. 값은 `values.yaml`에 적는다 |

## 8. 주의

- Helm으로 올린 뒤에는 **`kubectl edit`·`kubectl set image`·`kubectl scale`로 고치지 않는다**(다음 `helm upgrade`에서 원래 값으로 돌아간다).
- **ALB는 켜 둔 시간만큼 과금**된다. 쓰지 않으면 `ingress.enabled=false`나 `helm uninstall`.
- 클러스터 공용 리소스(IngressClass `alb`, StorageClass `efs-sc`, DB ExternalName Service, Redis, Kafka)는 차트가 관리하지 않는다. 클러스터를 새로 만들면 `part3-infra/docs/클러스터_재생성_체크리스트.md`를 먼저 따른다.
- 비밀번호는 차트나 git에 넣지 않는다 (`values-secret.yaml`은 `.gitignore` 대상).
