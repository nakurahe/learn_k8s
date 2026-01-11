# learn_k8s
This is a structured learning path to get you up to speed with Kubernetes, tailored for a data engineering context. The goal is to build practical skills that you can apply directly to your work, rather than just theoretical knowledge.

Phase 1: Solidify the Foundations
Goal: Make sure your mental model of containers and orchestration is rock-solid.

- Quick Docker refresh — Can you confidently build an image, run containers, manage volumes, and understand networking between containers? If any of that feels shaky, spend a day or two here first.
- Why Kubernetes exists — Understand the problems it solves (scaling, self-healing, service discovery, rolling updates). This makes everything else click.

Hands-on: Deploy a simple multi-container app with Docker Compose, then ask yourself: "What would break if I needed to run this across 10 machines?"

Phase 2: Core Kubernetes Concepts
Goal: Understand the building blocks and how they relate.
Learn these in order, as each builds on the previous:

1. Cluster architecture — Control plane vs. worker nodes, what each component does (API server, etcd, kubelet, etc.)
2. Pods — The smallest deployable unit. Why pods and not just containers?
3. Workloads — Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs
4. Services & Networking — ClusterIP, NodePort, LoadBalancer, Ingress. How do pods find each other?
5. Configuration & Storage — ConfigMaps, Secrets, Persistent Volumes, Persistent Volume Claims
6. Namespaces & RBAC — Multi-tenancy and access control basics

Resources recommend:

- Video: Kubernetes Course by Nana Janashia (TechWorld with Nana on YouTube) — practical and clear
- Interactive labs: Killer.sh, KodeKloud, or Play with Kubernetes
- Docs: The official Kubernetes docs are actually quite good once you have context

Hands-on: Set up a local cluster with minikube or kind, then deploy progressively more complex apps.

Phase 3: Real-World Skills for DevOps/Platform Work
Goal: Bridge the gap between tutorials and production.

- Helm — Templating and packaging Kubernetes apps (you'll see this constantly at work)
- kubectl mastery — Get fast at debugging: logs, describe, exec, port-forward
- Observability basics — How to see what's happening (Prometheus, Grafana, or whatever your team uses)
- CI/CD integration — How code gets from a repo to a running pod (ArgoCD, Flux, or Jenkins pipelines)

Hands-on project idea: Deploy a simple data pipeline (maybe a Go app that reads from a queue and writes to a database) on Kubernetes, with Helm charts and a basic CI/CD flow.

Phase 4: Connect to Your Data Engineering Stack (ongoing)
Goal: See how Kubernetes fits into your actual work.

- Airflow on Kubernetes — KubernetesExecutor, KubernetesPodOperator. How does Airflow spin up pods for tasks?
- Spark on Kubernetes — Spark-submit to K8s, understanding driver/executor pods
- Ask your team — What patterns do they use? What does your cluster setup look like? Shadowing a senior engineer for an hour is worth days of tutorials.
