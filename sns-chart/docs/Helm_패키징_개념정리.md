# Helm 패키징이란

> 이 프로젝트에서 서비스 전체를 Helm 차트(`sns-chart/`)로 묶어 배포하면서 정리한 개념 문서다. (2026-10-06)
> 실제로 세팅한 순서는 [Helm_패키징_세팅_과정.md](Helm_패키징_세팅_과정.md), Helm 자체(Redis·Kafka 설치에 쓴 `helm install`)는 `part3-infra/docs/Helm_개념정리.md`를 본다.

## 1. 한 줄 요약

**쿠버네티스에 올릴 YAML 여러 개를 하나의 묶음(차트)으로 만들고, 달라지는 값만 따로 넣어서 한 번에 설치·변경·삭제하는 방법**이다.

## 2. 왜 필요한가

마이크로서비스를 `kubectl`로 배포하면 서비스마다 YAML이 필요하다. 이 프로젝트는 서비스 5개에 Deployment, Service, ConfigMap, CronJob, Ingress, PVC까지 합쳐 **YAML 20여 개**였다. 문제는 다음과 같다.

| 문제 | 예 |
|---|---|
| 같은 내용이 반복된다 | Probe, `preStop`, 자원 요청, 롤링 업데이트 설정이 서비스마다 거의 같다 |
| 배포가 번거롭다 | 파일마다 `kubectl apply -f`를 실행하고, 지울 때도 하나씩 지운다 |
| 환경별로 복사해서 고친다 | 개발과 운영의 Pod 수·자원이 다르면 YAML을 통째로 복사해 수정한다 |
| 한꺼번에 되돌리기 어렵다 | 서비스 5개를 이전 상태로 돌리려면 Deployment마다 `rollout undo`를 한다 |
| 어떤 YAML이 최신인지 헷갈린다 | `kubectl edit`으로 고친 값이 파일에는 없다 |

Helm 패키징은 "반복되는 틀은 한 번만 쓰고, 다른 값만 바꿔 끼운다"로 이 문제를 줄인다.

## 3. 핵심 용어

비유하면 **붕어빵 틀(템플릿)에 반죽(값)을 넣어 붕어빵(YAML)을 찍어 내는 것**이다.

| 용어 | 뜻 | 이 프로젝트에서 |
|---|---|---|
| **Chart** | 템플릿과 기본값을 모아 둔 폴더(패키지) | `sns-chart/` |
| **Template** | 값이 들어갈 자리가 비어 있는 YAML | `templates/workloads.yaml` 등 |
| **Values** | 템플릿에 끼워 넣는 값 | `values.yaml`, `values-dev.yaml`, `values-prod.yaml` |
| **Release** | 차트를 클러스터에 설치한 결과. 이름이 붙는다 | `sns` (네임스페이스 `sns`) |
| **Revision** | 릴리스의 변경 이력 번호. 롤백의 기준 | 설치 직후 1 |

```
 템플릿(틀) + 값(반죽)  --helm-->  완성된 YAML  --적용-->  클러스터의 리소스
 templates/    values.yaml        (helm template로 미리 볼 수 있음)
```

템플릿의 `{{ .Values.xxx }}` 자리에 값이 들어간다. 예를 들어 같은 Deployment 틀로 feed는 이미지 `feed-server`·Pod 4개, user는 `user-server`·Pod 2개를 찍어 낸다.

## 4. "패키징"이라는 말

- 폴더 상태의 차트를 `helm package sns-chart`로 압축하면 `sns-chart-0.1.0.tgz` 파일 하나가 된다. 버전이 붙어 저장소(OCI 레지스트리 등)에 올려 공유할 수 있다.
- 이 프로젝트에서 Redis·Kafka를 설치한 `oci://registry-1.docker.io/bitnamicharts/...`도 누군가 이렇게 패키징해서 올려 둔 차트다. 이번에는 **우리가 직접 만든 차트를 `./sns-chart` 폴더 그대로** 설치한다.
- 폴더 그대로 쓰든 `.tgz`로 만들든 설치 방식은 같다. `.tgz`는 다른 사람·다른 환경에 배포할 때 필요하다.

## 5. 일하는 방식: 명령 한 번

```bash
helm upgrade --install sns ./sns-chart -n sns        # 없으면 설치, 있으면 변경
helm -n sns history sns                              # 변경 이력
helm -n sns rollback sns                             # 직전 버전으로 되돌리기 (전체)
helm uninstall sns -n sns                            # 전체 삭제
helm template sns ./sns-chart                        # 설치하지 않고 YAML만 미리 보기
helm lint ./sns-chart                                # 문법 검사
```

Helm은 **이전 릴리스와 새 결과를 비교해서 바뀐 리소스만 갱신**한다. feed 이미지 태그만 바꾸면 feed Deployment만 롤링 업데이트되고 나머지 서비스는 재시작하지 않는다.

## 6. 환경 구분

`values.yaml`(공통) 위에 환경별 파일이 **다른 값만 덮어쓴다**. 파일을 여러 개 주면 뒤쪽이 우선한다.

```bash
helm upgrade --install sns-dev  ./sns-chart -n sns-dev  --create-namespace -f sns-chart/values-dev.yaml
helm upgrade --install sns-prod ./sns-chart -n sns-prod --create-namespace -f sns-chart/values-prod.yaml
```

- 개발과 운영은 **네임스페이스로 분리**한다. 서비스 이름(`feed-service` 등)은 같아도 네임스페이스가 다르면 충돌하지 않는다.
- 같은 템플릿을 쓰므로 "개발에서는 되는데 운영에서는 YAML이 달라서 안 된다"는 사고가 줄어든다.

## 7. kubectl 방식과의 차이

| | kubectl | Helm 패키징 |
|---|---|---|
| 정의 | 서비스마다 YAML 작성 | 템플릿 한 번 + 값 |
| 서비스 추가 | YAML 복사 후 수정 | `values.yaml`에 항목 추가 |
| 이미지 태그 변경 | YAML 수정 후 `apply` | `--set ...image.tag=` 후 `upgrade` |
| 배포·삭제 | 파일마다 반복 | 한 번에 |
| 롤백 | 리소스별 | `helm rollback` 한 번 (릴리스 전체) |
| 환경 구분 | YAML 복사 | values 파일 |
| 변경 이력 | 없음 (git에만) | 클러스터에도 revision으로 남음 |

## 8. 알아 둘 점 (이 프로젝트에서 실제로 부딪힌 것)

1. **Helm은 자기가 만들지 않은 리소스를 건드리지 않는다.** 이미 `kubectl apply`로 올린 리소스와 같은 이름으로 설치하면 `exists and cannot be imported` 오류로 멈춘다. 리소스에 "이 릴리스 소속"이라는 라벨·어노테이션이 있어야 이어받는다. 그래서 기존 것을 지우고 새로 설치했다(PVC만 표시를 붙여 이어받음).
2. **Helm으로 올린 뒤에는 `kubectl edit`으로 고치지 않는다.** 다음 `helm upgrade`에서 값이 조용히 원래대로 돌아간다. 남길 값은 반드시 `values.yaml`에 적는다. 이번에도 클러스터에만 있던 DB 연결 풀 값(`SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=3`)을 차트에 옮겨 적어야 했다.
3. **비밀번호는 차트에 넣지 않는다.** Secret은 기본적으로 차트가 만들지 않고, 필요하면 git에 올리지 않는 values 파일로 넘긴다.
4. **값이 `0`이나 `false`일 때 기본값 병합이 의도와 다르게 동작할 수 있다.** 템플릿에서 기본값과 서비스별 값을 합칠 때 `false`/`0`을 "빈 값"으로 보고 기본값으로 덮어쓰는 함정이 있어, 이 차트는 "끄는 항목"을 `noProbes: true`처럼 **true로 켜는 플래그**로 만들었다.
5. **클러스터 공용 리소스는 차트에 넣지 않는다.** IngressClass, StorageClass, DB 연결용 ExternalName Service, Redis, Kafka는 서비스 차트의 소관이 아니다. 지우면 다른 환경까지 영향을 받는다.
6. **Ingress를 켜면 ALB 요금이 나온다.** 환경마다 Ingress가 하나씩 생긴다.

## 9. 언제 쓰면 좋은가

- 서비스가 여러 개이고 설정이 비슷할 때 (이 프로젝트)
- 개발·운영 등 환경이 둘 이상일 때
- 전체를 한 번에 올리고 내리고 되돌려야 할 때

반대로 서비스 하나를 한 번 올리고 끝나는 작은 실험에는 `kubectl apply`가 더 단순하다. 학습 초반(Ch 1~7)에 `kubectl`로 배포한 것도 구조를 이해하기에는 그쪽이 낫기 때문이다.
