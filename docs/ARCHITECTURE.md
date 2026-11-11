# Architecture Specification & Network Port Registry

This document outlines the system architecture, component topology, network segmentation, and the exposed port registry for the **Linux Server Administration & Deployment Automation Platform**.

---

## 1. System Topology & Component Model

```mermaid
flowchart TD
    subgraph Public Internet / Clients
        Admin[DevOps Engineer / Workstation]
        Client[End User Browser / HTTP Traffic]
    end

    subgraph Host Perimeter [Ubuntu Linux Host]
        subgraph Firewall [UFW (Uncomplicated Firewall)]
            P22[Port 22/TCP: SSH - Rate Limited]
            P80[Port 80/TCP: HTTP Ingress]
            P443[Port 443/TCP: HTTPS Ingress]
            P8080[Port 8080/TCP: Web Admin Dashboard]
        end

        subgraph Docker Bridge [Isolated Container Network]
            subgraph Frontend Net [frontend_net: 172.20.0.0/16]
                Nginx[Nginx Reverse Proxy Container\n:80 & :443]
            end

            subgraph Backend Net [backend_net: 172.21.0.0/16]
                App[Node.js Web App\n:3000 non-root]
                Redis[Redis Cache\n:6379 password-protected]
            end
        end

        subgraph Host Management Layer
            CLI[serveradmin CLI Engine]
            Cron[Cron Automation: /etc/cron.d]
            Scripts[Bash Automation Suite: /opt/serveradmin/scripts]
            Logs[Rotated Logs & Backups: /var/log & /var/backups]
        end
    end

    Admin -->|SSH Key Auth| P22
    Admin -->|Web UI| P8080
    Client -->|HTTP/HTTPS| P80
    Client -->|HTTP/HTTPS| P443

    P80 --> Nginx
    P443 --> Nginx
    Nginx -->|Reverse Proxy| App
    App -->|Internal Network Call| Redis

    Cron --> Scripts
    CLI --> Scripts
    Scripts --> Logs
```

---

## 2. Port Registry & Exposed Services Matrix

The following table documents every port, service, listening scope, and security posture on the server:

| Port | Protocol | Binding Address | Associated Service | Exposure Scope | Security Controls Applied |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **22** | TCP | `0.0.0.0` / `[::]` | `OpenSSH` (`sshd`) | **Public** | Ed25519 Keys Only, Passwords Disabled, Root Login Disabled, UFW Rate-Limited (`ufw limit 22/tcp`), MaxAuthTries 4 |
| **80** | TCP | `0.0.0.0` / `[::]` | `Nginx Reverse Proxy` | **Public** | UFW Allowed, Ingress Gateway, Rate Limiting (10r/s burst=20), Security Headers injected |
| **443** | TCP | `0.0.0.0` / `[::]` | `Nginx Reverse Proxy` | **Public** | TLS 1.3/1.2 only, HSTS ready, Security Headers |
| **8080** | TCP | `0.0.0.0` / `127.0.0.1` | `ServerAdmin Web Console` | **Restricted / Admin** | Localhost binding by default or restricted to admin IP via UFW |
| **3000** | TCP | Container Internal | `Node.js Web App` | **Isolated (Docker)** | NOT bound to host network. Accessible ONLY from `serveradmin_nginx` through `frontend_net` |
| **6379** | TCP | Container Internal | `Redis 7 Cache` | **Isolated (Docker)** | NOT bound to host network. Accessible ONLY through `backend_net`. Password authentication enforced |

---

## 3. Defense-in-Depth Security Strategy

### 3.1 Network Isolation (Least Privilege Networking)
- **Zero Public DB Exposure**: Redis runs in an isolated Docker bridge network (`backend_net`). No host port is published (`-p 6379:6379` is strictly prohibited).
- **Ingress Funneling**: The Web Application is reachable exclusively through Nginx. Direct access to port 3000 from outside the Docker virtual network is blocked.

### 3.2 Operating System Hardening
- **Least-Privilege User RBAC**: Operations are executed under dedicated non-root accounts (e.g. `deploy`, `auditor`). Administrative sudo rights are scoped in `/etc/sudoers.d/`.
- **SSH Protocol Hardening**: Direct root login and password-based authentication are disabled via `/etc/ssh/sshd_config.d/99-hardened.conf`.

### 3.3 Container Security Posture
- Container processes run as non-root user `node` (UID 1000).
- Docker containers run with security options `no-new-privileges:true`.
- Healthchecks are built into each container for automated watchdog intervention.

