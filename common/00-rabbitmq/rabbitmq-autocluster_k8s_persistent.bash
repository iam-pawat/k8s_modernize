#!/bin/bash

set -eo pipefail

export KUBE_NAMESPACE=payment
export REPLICA_COUNT=3

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1beta1
kind: StatefulSet
metadata:
  name: rabbitmq
  namespace: $KUBE_NAMESPACE
spec:
  serviceName: rabbitmq
  replicas: $REPLICA_COUNT
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      terminationGracePeriodSeconds: 10
      serviceAccountName: payment-sa
      containers:
      - name: rabbitmq-autocluster
        image: reghbpr01.dc1.true.th/bss-payments/pivotalrabbitmq/rabbitmq-autocluster
        ports:
          - name: http
            protocol: TCP
            containerPort: 15672
          - name: amqp
            protocol: TCP
            containerPort: 5672
        resources:
          requests:
            memory: '256Mi'
            cpu: '50m'
          limits:
            memory: '512Mi'
        livenessProbe:
          exec:
            command: ["rabbitmqctl", "status"]
          initialDelaySeconds: 30
          timeoutSeconds: 5
        readinessProbe:
          exec:
            command: ["rabbitmqctl", "status"]
          initialDelaySeconds: 10
          timeoutSeconds: 5
        imagePullPolicy: Always
        env:
          - name: MY_POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
          - name: NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: HOSTNAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: RABBITMQ_USE_LONGNAME
            value: "true"
          - name: RABBITMQ_NODENAME
            value: "rabbit@\$(HOSTNAME).rabbitmq.\$(NAMESPACE).svc.k8stdev"
          - name: AUTOCLUSTER_TYPE
            value: "k8s"
          - name: AUTOCLUSTER_DELAY
            value: "10"
          - name: K8S_ADDRESS_TYPE
            value: "hostname"
          - name: K8S_SERVICE_NAME
            value: rabbitmq
          - name: K8S_HOSTNAME_SUFFIX
            value: ".rabbitmq.\$(NAMESPACE).svc.k8stdev"
          - name: AUTOCLUSTER_CLEANUP
            value: "false"
          - name: CLEANUP_WARN_ONLY
            value: "true"
        volumeMounts:
        - name: rabbitmq-data
          #mountPath: /var/lib/rabbitmq/mnesia
          mountPath: /var/lib/rabbitmq/
      imagePullSecrets:
        - name: regcred
  volumeClaimTemplates:
  - metadata:
      name: rabbitmq-data
      annotations:
        volume.beta.kubernetes.io/storage-class: acs-abs
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 4Gi
EOF

# Headless service for Pod DNS

cat <<EOF | kubectl apply -f -
kind: Service
apiVersion: v1
metadata:
  namespace: $KUBE_NAMESPACE
  name: rabbitmq
  labels:
    app: rabbitmq
spec:
  clusterIP: None
  ports:
   - name: http
     protocol: TCP
     port: 15672
     targetPort: 15672
   - name: amqp
     protocol: TCP
     port: 5672
     targetPort: 5672
  selector:
    app: rabbitmq
EOF

# LoadBalancer service for public access

cat <<EOF | kubectl apply -f -
kind: Service
apiVersion: v1
metadata:
  namespace: $KUBE_NAMESPACE
  name: rabbitmq-lb
  labels:
    app: rabbitmq
spec:
  type: ClusterIP
  ports:
   - name: http
     protocol: TCP
     port: 15672
     targetPort: 15672
   - name: amqp
     protocol: TCP
     port: 5672
     targetPort: 5672
  selector:
    app: rabbitmq
EOF

echo "Waiting for StatefulSet to complete rolled out"
# kubectl rollout status statefulset/rabbitmq -n $KUBE_NAMESPACE # Not supported in k8s v1.6 and prior
for i in $(seq 1 120); do
  if kubectl exec rabbitmq-$(($REPLICA_COUNT - 1)) -n $KUBE_NAMESPACE -- rabbitmqctl status &> /dev/null; then
    break
  fi
  sleep 1s
done
if [[ "$i" == 120 ]]; then
  echo "StatefulSet taking too long to complete, you need to manual install..."
  exit 1
fi

echo "Setting up HA policy"
kubectl exec rabbitmq-0 -n $KUBE_NAMESPACE -- rabbitmqctl set_policy ha-all "" '{"ha-mode":"all","ha-sync-mode":"automatic"}'