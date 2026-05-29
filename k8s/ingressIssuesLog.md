pp@DESKTOP-TEO1DA8:~/Epitech/KubeQuest/T-CLO-902-PAR_9$ kubectl get nodes 
NAME         STATUS   ROLES           AGE   VERSION
ingress      Ready    ingress         68d   v1.35.3
kube1        Ready    control-plane   68d   v1.35.3
kube2        Ready    worker          68d   v1.35.3
monitoring   Ready    monitoring      68d   v1.35.3
pp@DESKTOP-TEO1DA8:~/Epitech/KubeQuest/T-CLO-902-PAR_9$ kubectl get pods -A
NAMESPACE       NAME                                                     READY   STATUS                   RESTARTS         AGE
app             laravel-app-594b8b6b74-qz5h2                             1/1     Running                  5 (11m ago)      55d
app             leravel-app-8598d7c6d6-dbj4l                             1/1     Running                  4 (11m ago)      55d
app             mysql-6649b5f59f-wmffg                                   1/1     Running                  3 (4h16m ago)    55d
default         nginx-test-5887565d84-hp25c                              1/1     Running                  7 (4h16m ago)    63d
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-2xbvt        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-5th5c        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-628hr        0/1     Evicted                  0                83s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-62jtg        0/1     Evicted                  0                83s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-66mqb        0/1     Evicted                  0                4h6m
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-69stw        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-6cppt        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-6zsfg        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-879vp        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-8t2gs        0/1     Unknown                  0                50d
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-9bzc6        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-cdqxf        0/1     ContainerStatusUnknown   1                41d
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-dj68z        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-dmvrv        0/1     Pending                  0                79s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-dsrsc        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-fcz56        0/1     Evicted                  0                83s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-fgzkz        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-fpnd4        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-fpqtp        0/1     Evicted                  0                83s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-ftth9        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-g9kfk        0/1     Error                    0                4h6m
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-h4mkr        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-hb2gj        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-hbghc        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-hdv4n        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-hzx9h        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-jvrfp        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-k5kn4        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-kfjcs        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-lqxl8        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-ls8wd        0/1     Evicted                  0                4h6m
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-nr59q        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-pd68d        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-rswcn        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-sf9tn        0/1     Evicted                  0                83s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-sg5pn        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-v4xb2        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-vcxtw        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-vk8jm        0/1     Evicted                  0                4h6m
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-wf8qk        0/1     Evicted                  0                81s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-wlgrg        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-wlxp8        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-x6wnz        0/1     ContainerStatusUnknown   1                4h13m
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-xctj7        0/1     Evicted                  0                80s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-xrlzq        0/1     Evicted                  0                82s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-xvrt2        0/1     Evicted                  0                84s
ingress-nginx   ingress-ingress-nginx-controller-7b4957d686-zhxwz        0/1     Evicted                  0                83s
kube-system     calico-kube-controllers-984995b45-bffzg                  1/1     Running                  7 (4h16m ago)    63d
kube-system     calico-node-76jcx                                        1/1     Running                  9 (4h15m ago)    68d
kube-system     calico-node-jncj7                                        1/1     Running                  9 (4h15m ago)    68d
kube-system     calico-node-lpbck                                        1/1     Running                  9 (4h16m ago)    68d
kube-system     calico-node-rxh2q                                        1/1     Running                  9 (4h16m ago)    68d
kube-system     coredns-7d764666f9-9fg6p                                 1/1     Running                  7 (4h16m ago)    63d
kube-system     coredns-7d764666f9-plzvq                                 1/1     Running                  7 (4h15m ago)    63d
kube-system     etcd-kube1                                               1/1     Running                  9 (4h16m ago)    68d
kube-system     kube-apiserver-kube1                                     1/1     Running                  9 (4h16m ago)    68d
kube-system     kube-controller-manager-kube1                            1/1     Running                  9 (4h16m ago)    68d
kube-system     kube-proxy-6df2f                                         1/1     Running                  9 (4h16m ago)    68d
kube-system     kube-proxy-bjk75                                         1/1     Running                  9 (4h16m ago)    68d
kube-system     kube-proxy-bmxfs                                         1/1     Running                  9 (4h15m ago)    68d
kube-system     kube-proxy-mw6bb                                         1/1     Running                  9 (4h15m ago)    68d
kube-system     kube-scheduler-kube1                                     1/1     Running                  9 (4h16m ago)    68d
logs            loki-0                                                   1/1     Running                  6 (4h15m ago)    62d
logs            loki-promtail-m5mgk                                      1/1     Running                  5 (4h16m ago)    61d
logs            loki-promtail-m6x4b                                      1/1     Running                  5 (4h15m ago)    61d
logs            loki-promtail-zktxg                                      1/1     Running                  5 (4h16m ago)    61d
monitoring      alertmanager-monitoring-kube-prometheus-alertmanager-0   2/2     Running                  12 (4h15m ago)   62d
monitoring      monitoring-grafana-694fb4fb64-q8gsb                      3/3     Running                  18 (4h15m ago)   62d
monitoring      monitoring-kube-prometheus-operator-68fbbd6d4-cfdq9      1/1     Running                  8 (4h14m ago)    62d
monitoring      monitoring-kube-state-metrics-55d5c9988b-bwq2c           1/1     Running                  6 (4h15m ago)    62d
monitoring      monitoring-prometheus-node-exporter-bhtqn                1/1     Running                  5 (4h15m ago)    61d
monitoring      monitoring-prometheus-node-exporter-gtcrb                0/1     Evicted                  0                4h5m
monitoring      monitoring-prometheus-node-exporter-l6l44                1/1     Running                  5 (4h16m ago)    61d
monitoring      monitoring-prometheus-node-exporter-rzpfx                1/1     Running                  5 (4h16m ago)    61d
monitoring      prometheus-monitoring-kube-prometheus-prometheus-0       2/2     Running                  12 (4h15m ago)   62d
pp@DESKTOP-TEO1DA8:~/Epitech/KubeQuest/T-CLO-902-PAR_9$ ^C
pp@DESKTOP-TEO1DA8:~/Epitech/KubeQuest/T-CLO-902-PAR_9$ 
