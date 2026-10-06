{{/* 모든 리소스에 붙는 공통 라벨 */}}
{{- define "sns.labels" -}}
app.kubernetes.io/part-of: sns
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
environment: {{ .Values.global.environment | quote }}
{{- end }}

{{/* 이미지 주소: <imageRegistry>/<repository>:<tag>. 인자: dict "root" $ "image" <image 설정> */}}
{{- define "sns.image" -}}
{{- printf "%s/%s:%s" .root.Values.global.imageRegistry .image.repository (toString .image.tag) -}}
{{- end }}

{{/* envFrom 블록. 인자: dict "configMaps" <목록> "secrets" <목록> (들여쓰기는 호출하는 쪽에서 맞춘다) */}}
{{- define "sns.envFrom" -}}
{{- range .configMaps }}
- configMapRef:
    name: {{ . }}
{{- end }}
{{- range .secrets }}
- secretRef:
    name: {{ . }}
{{- end }}
{{- end }}
