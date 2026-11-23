# SmartLaundryIoT 🧺

> **Smart Dorm Laundry Management & IoT Platform for Zewail City of Science and Technology (ZC)**

A modern, full-stack IoT and web platform designed to streamline student laundry bookings, door-access control, machine monitoring, supervisor room management, and automated payment/wallet handling.

---

## 🌟 Key Features

* **🎓 Student Portal (`student.html`):**
  * Time-slot discovery and laundry machine booking.
  * Real-time wallet balance, manual top-ups, and Paymob payment integration.
  * Dynamic, cryptographically verifiable QR tickets for IoT door access.
  * Push notifications for laundry cycle updates.

* **🛡️ Supervisor Workspace (`supervisor.html`):**
  * Dorm-scoped machine controls and slot scheduling.
  * Student profile review and approval queue.
  * Real-time IoT door lock access logs and washer sensor health.

* **⚙️ Main Administrator Portal (`admin.html`):**
  * People & access management: Manual student enrollment and supervisor assignments.
  * Student wallet management: Balance crediting and append-only ledger transaction history.
  * Global ticket pricing controls and system audit logs.

* **🔒 Air-Tight Security & Strict Role Isolation:**
  * Enforced single active role per account (`role_assignments` unique partial index).
  * Page-level security guards preventing cross-portal unauthorized access.
  * Auditable ledger entries for every financial and access transaction.

---

## 🏗️ Architecture

* **Frontend:** Responsive vanilla HTML5, CSS3, and JavaScript (No bulky runtime dependencies, mobile & desktop optimized).
* **Backend:** [Supabase](https://supabase.com) (PostgreSQL 15+, GoTrue Auth, Row-Level Security, Edge Functions).
* **Payment Integration:** Paymob Accept hosted checkout & Sandbox simulator.
* **Notifications:** Firebase Cloud Messaging (FCM) Web Push.
* **IoT Hardware Layer:** ESP32 QR Scanner (Door relay) + STM32 vibration & current sensor nodes.

---

## 🚀 Quick Start

### 1. Prerequisites
* Modern web browser (Chrome, Edge, Firefox, Safari).
* Local HTTP server (e.g. VS Code Live Server, Python `python -m http.server 8000`, or Node `npx serve`).

### 2. Configuration
* Copy `.env.example` to `.env` (or configure `supabase-config.js` and `firebase-config.js` with your project credentials).
* All remote database migrations are located in `supabase/migrations/`.

### 3. Running Locally
```bash
# Using python
python -m http.server 8000

# Using Node.js
npx serve .
```
Navigate to `http://localhost:8000/login.html` to sign in.

---

## 👥 Default Test Accounts

| Role | University Email | Password | Dorm Scope |
| :--- | :--- | :--- | :---: |
| **Main Administrator** | `admin@zewailcity.edu.eg` | `AdminPass2026!#` | All Dorms |
| **Dorm C Supervisor** | `supervisor.dormc@zewailcity.edu.eg` | `Supervisor2026!#` | Dorm C |
| **Dorm A Supervisor** | `supervisor.dorma@zewailcity.edu.eg` | `SupPass2026!#` | Dorm A |
| **Approved Student (Youssef)** | `s-youssef.ali@zewailcity.edu.eg` | `StudentPass2026!#` | Dorm C |
| **Approved Student (Tarek)** | `s-tarek.nour@zewailcity.edu.eg` | `StudentPass2026!#` | Dorm B |

---

## 📄 License
Zewail City Dorm Laundry IoT Project · All Rights Reserved.
