import { GxDialog } from "./dialog.js"
import { GxState } from "./state.js"
import { GxNotice } from "./notice.js"
import { PollTimer, connectionError } from "./polling.js"
import { requestJson } from "./startup.js"

const text = (value, limit = 240) => typeof value === "string" && value.length <= limit
const count = value => value === null || Number.isSafeInteger(value) && value >= 0
const detailValue = (value, depth = 0) => value === null || typeof value === "boolean" ||
  typeof value === "number" && Number.isFinite(value) || text(value, 500) ||
  depth < 2 && (Array.isArray(value) ? value.length <= 16 && value.every(item => detailValue(item, depth + 1)) :
    value && typeof value === "object" && Object.keys(value).length <= 64 &&
    Object.entries(value).every(([key, item]) => text(key, 80) && detailValue(item, depth + 1)))
export function validTrainingResults(value) {
  if (!value || value.version !== 1 || !Array.isArray(value.history) || value.history.length > 20) return false
  if (!value.history.every(row => row && text(row.time, 80) && text(row.status, 64) && text(row.reason) && typeof row.applied === "boolean")) return false
  const row = value.current
  if (row === null) return true
  if (!row || typeof row.fresh !== "boolean" || !Number.isFinite(row.ageSeconds) || row.ageSeconds < 0 ||
      ![true, false, null].includes(row.enabled) || !text(row.status, 64) || !text(row.reason) || !row.progress ||
      ![row.progress.samples, row.progress.blocks, row.progress.requiredBlocks].every(count)) return false
  if (row.fit !== null && (!row.fit || !text(row.fit.status, 64) || !text(row.fit.reason) ||
      ![row.fit.trainWindows, row.fit.heldoutWindows].every(count))) return false
  if (row.application !== null && (!row.application || typeof row.application.applied !== "boolean" || !text(row.application.reason))) return false
  return row.details === undefined || row.details && typeof row.details === "object" && !Array.isArray(row.details) &&
    Object.keys(row.details).length <= 64 && Object.entries(row.details).every(([key, item]) => text(key, 80) && detailValue(item))
}
const labels = { collecting: "Gathering driving examples", unavailable: "Waiting for usable driving data",
  qualifiedFit: "Fit passed validation", qualified: "Fit passed validation", rejected: "Fit did not pass validation",
  fitting: "Evaluating a possible adjustment", applied: "Adjustment applied",
  independent_evidence: "Gathering independently measured driving examples",
  settings_receipt_expired: "Learning paused because its settings confirmation expired",
  no_current_controller_evidence: "Waiting for current steering measurements",
  capturing_steering_evidence: "Recording eligible steering measurements",
  awaiting_different_maneuver: "Current maneuver captured; waiting for a different driving example",
  evaluating_collected_maneuvers: "Checking the collected driving examples",
  report_stale: "Current results are unavailable; this is an earlier report" }
export const readable = value => labels[value] || String(value ?? "Not reported").replaceAll("_", " ")
export const detailText = value => value === null ? "Not reported" : Array.isArray(value) ? value.map(detailText).join(", ") :
  typeof value === "boolean" ? value ? "Yes" : "No" : typeof value === "object" ?
    Object.entries(value).map(([key, item]) => `${readable(key)}: ${detailText(item)}`).join("; ") : String(value)
export const trainingSummary = (report, error = "") => error ? "Live update unavailable. Previous results may be out of date." :
  !report?.current ? "No training results have been reported yet." : !report.current.fresh ?
    "Saved report only. Current learning and application are unknown." : readable(report.current.status)

export const FLMTrainingResults = {
  name: "FLMTrainingResults",
  components: { GxDialog, GxState, GxNotice },
  props: { mode: { type: String, required: true }, unauthorized: { type: Function, required: true } },
  data: () => ({ open: false, report: null, error: "", loading: false, request: null }),
  mounted() { this.activePage = true; this.poller = new PollTimer({ read: () => this.load(), interval: 3000 }) },
  beforeUnmount() { this.close(); this.activePage = false },
  computed: {
    summary() { return trainingSummary(this.report, this.error) },
    current() { return this.report?.current },
    details() { return Object.entries(this.current?.details || {}) },
    currentApplied() { return !this.error && this.current?.fresh && this.current.application?.applied === true },
  },
  methods: {
    readable, detailText,
    amount(value) { return value === null || value === undefined ? "Not reported" : value.toLocaleString() },
    show() { if (this.mode !== "local") return; this.open = true; this.poller.start(); this.load() },
    close() { this.open = false; this.poller?.stop(); this.request?.abort(); this.request = null; this.loading = false },
    async load() {
      if (!this.open || !this.activePage || this.mode !== "local" || this.request) return
      const controller = new AbortController()
      this.request = controller
      this.loading = true
      try {
        const value = await requestJson("./api/flm/training-results", { request: { signal: controller.signal } })
        if (this.request !== controller || !this.activePage || !this.open) return
        if (!validTrainingResults(value)) throw new Error("The device returned an unsupported training report.")
        this.report = value
        this.error = ""
      } catch (error) {
        if (this.request !== controller || !this.activePage || !this.open) return
        if (error.status === 401 || ["access_unavailable", "setup_required"].includes(error.code)) this.unauthorized()
        else this.error = connectionError(error, "Training results could not be refreshed. Reconnecting automatically…")
      } finally {
        if (this.request === controller) { this.request = null; this.loading = false }
      }
    },
  },
  template: `<div class="gx-card">
    <button type="button" class="gx-btn gx-btn--tonal" @click="show" :disabled="mode !== 'local'">View FLM training results</button>
    <GxDialog v-if="open" class="gx-flm__panel" labelledby="gx-flm-results-title" describedby="gx-flm-results-summary" @close="close">
      <h2 id="gx-flm-results-title">FLM training results</h2>
      <p id="gx-flm-results-summary" role="status">{{ summary }}</p>
      <GxNotice v-if="error" tone="danger">{{ error }}</GxNotice>
      <GxState v-if="loading && !report" loading>Reading training results…</GxState>
      <template v-if="current">
        <p>Last controller report: {{ current.ageSeconds.toFixed(1) }} seconds old when read.</p>
        <p>{{ readable(current.reason) }}</p>
        <p>Auto Learn: {{ current.enabled === null ? 'Not reported' : current.enabled ? 'Enabled' : 'Off' }}.</p>
        <dl><dt>Collected samples</dt><dd>{{ amount(current.progress.samples) }}</dd>
          <dt>Completed driving blocks</dt><dd>{{ amount(current.progress.blocks) }}<template v-if="current.progress.requiredBlocks !== null"> / {{ amount(current.progress.requiredBlocks) }} minimum for evaluation</template></dd>
          <dt>Last controller report</dt><dd>{{ currentApplied ? 'Correction reported applied' : current.fresh && !error && current.application ? 'No correction reported applied' : current.fresh && !error ? 'Not reported' : 'Application unknown — report is out of date' }}</dd>
        </dl>
        <p>Only eligible driving data counts. Reaching the minimum starts evaluation; a correction still has to pass validation.</p>
        <p v-if="current.application">{{ readable(current.application.reason) }}</p>
        <section v-if="current.fit"><h3>Latest evaluation</h3><p>{{ readable(current.fit.status) }}: {{ readable(current.fit.reason) }}</p>
          <p>Training windows: {{ amount(current.fit.trainWindows) }} · Validation windows: {{ amount(current.fit.heldoutWindows) }}</p></section>
        <details v-if="details.length"><summary>More training details</summary><dl>
          <template v-for="[key, value] in details" :key="key"><dt>{{ readable(key) }}</dt><dd>{{ detailText(value) }}</dd></template>
        </dl></details>
      </template>
      <section><h3>Recent history</h3><p v-if="!report?.history.length">No training history has been reported yet.</p>
        <ol v-else><li v-for="(row, index) in report.history" :key="index">{{ row.time }} — {{ readable(row.status) }}: {{ readable(row.reason) }}<template v-if="row.applied"> · Adjustment applied at that time</template></li></ol></section>
      <button type="button" class="gx-btn gx-btn--tonal" @click="load" :disabled="loading">Refresh</button>
      <button type="button" class="gx-btn gx-btn--tonal" @click="close">Close</button>
    </GxDialog>
  </div>`,
}
