// Mismo origin que la API (CloudFront enruta /api/* al ALB): rutas relativas, sin CORS.
// Barra final obligatoria en /api/installments/: sin ella FastAPI responde 307 con
// un Location armado con el Host del ALB (AllViewerExceptHostHeader), inaccesible.
const API = "/api";

// Modo demo: abierto como archivo local o con ?demo. Solo para previsualizar la UI.
const DEMO = location.protocol === "file:" || new URLSearchParams(location.search).has("demo");
const DEMO_ROWS = [
  { installment_id: 1, loan_id: 1, installment_number: 1, due_date: "2026-08-15", amount_due: "350.00", status: "paid" },
  { installment_id: 2, loan_id: 1, installment_number: 2, due_date: "2026-09-15", amount_due: "350.00", status: "partially_paid" },
  { installment_id: 3, loan_id: 1, installment_number: 3, due_date: "2026-10-15", amount_due: "350.00", status: "pending" },
  { installment_id: 4, loan_id: 2, installment_number: 1, due_date: "2026-09-01", amount_due: "1200.00", status: "pending" },
  { installment_id: 5, loan_id: 2, installment_number: 2, due_date: "2026-10-01", amount_due: "1200.00", status: "pending" },
  { installment_id: 6, loan_id: 3, installment_number: 1, due_date: "2026-09-20", amount_due: "780.50", status: "partially_paid" },
];

const STATUS_LABEL = { pending: "Pendiente", partially_paid: "Pago parcial", paid: "Pagada" };
const money = new Intl.NumberFormat("es", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const $ = (id) => document.getElementById(id);

async function fetchInstallments(overdue) {
  if (DEMO) {
    const today = new Date().toISOString().slice(0, 10);
    const rows = overdue
      ? DEMO_ROWS.filter((r) => r.due_date < today && r.status !== "paid")
      : DEMO_ROWS;
    return { rows, cache: overdue ? "HIT" : null };
  }
  const res = await fetch(`${API}/installments/?overdue=${overdue}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return { rows: await res.json(), cache: res.headers.get("X-Cache") }; // X-Cache solo con overdue=true (ADR-0011)
}

async function loadInstallments() {
  const overdue = $("only-overdue").checked;
  $("list-status").textContent = "Cargando…";
  $("cache-badge").hidden = true;

  try {
    const { rows, cache } = await fetchInstallments(overdue);
    renderRows(rows);
    renderKpis(rows);
    if (cache) {
      const badge = $("cache-badge");
      badge.textContent = `Caché ${cache}`;
      badge.className = `pill ${cache === "HIT" ? "ok" : "warn"}`;
      badge.title = "Header X-Cache de la API (ElastiCache, cache-aside)";
      badge.hidden = false;
    }
    $("list-status").textContent = overdue ? "Cuotas vencidas sin pagar" : "Todas las cuotas";
  } catch (err) {
    renderRows([]);
    renderKpis([]);
    $("list-status").textContent = `No se pudo cargar: ${err.message}`;
  }
}

// textContent (nunca innerHTML) con datos de la API: evita XSS almacenado.
function cell(text, className) {
  const td = document.createElement("td");
  td.textContent = text;
  if (className) td.className = className;
  return td;
}

function renderRows(rows) {
  $("empty").hidden = rows.length > 0;
  $("installments").replaceChildren(
    ...rows.map((r) => {
      const tr = document.createElement("tr");
      tr.append(
        cell(`#${r.installment_id}`, "strong"),
        cell(`PR-${r.loan_id}`),
        cell(r.installment_number),
        cell(r.due_date),
        cell(money.format(Number(r.amount_due)), "num"),
      );

      const status = document.createElement("td");
      const pill = document.createElement("span");
      pill.className = `pill status-${r.status}`;
      pill.textContent = STATUS_LABEL[r.status] ?? r.status;
      status.append(pill);

      const action = document.createElement("td");
      if (r.status !== "paid") {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "btn link";
        btn.textContent = "Cobrar";
        btn.addEventListener("click", () => prefillPayment(r));
        action.append(btn);
      }

      tr.append(status, action);
      return tr;
    })
  );
}

function renderKpis(rows) {
  const total = rows.reduce((sum, r) => sum + Number(r.amount_due), 0);
  $("kpi-count").textContent = rows.length;
  $("kpi-amount").textContent = money.format(total);
  $("kpi-pending").textContent = rows.filter((r) => r.status === "pending").length;
  $("kpi-partial").textContent = rows.filter((r) => r.status === "partially_paid").length;
}

function prefillPayment(row) {
  const form = $("payment-form");
  form.installment_id.value = row.installment_id;
  form.amount_paid.value = Number(row.amount_due).toFixed(2);
  form.amount_paid.focus();
}

let toastTimer;
function toast(message, kind = "ok") {
  const el = $("toast");
  el.textContent = message;
  el.className = `toast ${kind}`;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 4000);
}

async function submitPayment(event) {
  event.preventDefault();
  const form = event.target;
  const data = new FormData(form);
  const id = data.get("installment_id");
  // amount_paid como string: el backend lo parsea a Decimal sin errores de float.
  const payload = { amount_paid: data.get("amount_paid"), payment_method: data.get("payment_method") };
  const button = form.querySelector("button[type=submit]");
  button.disabled = true;

  try {
    let body;
    if (DEMO) {
      body = { payment_id: Math.floor(Math.random() * 900) + 100, installment_id: Number(id) };
    } else {
      const res = await fetch(`${API}/installments/${encodeURIComponent(id)}/payments`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(typeof body.detail === "string" ? body.detail : `HTTP ${res.status}`);
    }
    toast(`Pago #${body.payment_id} registrado en la cuota #${body.installment_id}`);
    form.reset();
    loadInstallments(); // el POST invalida la clave de caché: la próxima lectura debe ser MISS
  } catch (err) {
    toast(`Error al registrar el pago: ${err.message}`, "error");
  } finally {
    button.disabled = false;
  }
}

$("demo-banner").hidden = !DEMO;
$("reload").addEventListener("click", loadInstallments);
$("only-overdue").addEventListener("change", loadInstallments);
$("payment-form").addEventListener("submit", submitPayment);
loadInstallments();
