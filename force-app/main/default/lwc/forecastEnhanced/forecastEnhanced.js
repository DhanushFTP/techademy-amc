import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getForecastData    from '@salesforce/apex/ForecastEnhancedController.getForecastData';
import getConversionRate  from '@salesforce/apex/ForecastEnhancedController.getConversionRate';
import saveConversionRate from '@salesforce/apex/ForecastEnhancedController.saveConversionRate';
import getUsers           from '@salesforce/apex/ForecastEnhancedController.getUsers';
import getDealsForCell    from '@salesforce/apex/ForecastEnhancedController.getDealsForCell';

const MONTH_NAMES_FULL = {
    '01': 'January',  '02': 'February', '03': 'March',    '04': 'April',
    '05': 'May',      '06': 'June',     '07': 'July',     '08': 'August',
    '09': 'September','10': 'October',  '11': 'November', '12': 'December'
};

const CATEGORY_LABELS = {
    Closed: 'Closed', Commit: 'Commit', BestCase: 'Best Case', Pipeline: 'Pipeline'
};

function fmt(amount) {
    if (amount == null || amount === '') return '₹0';
    return '₹' + Number(amount).toLocaleString('en-IN', { maximumFractionDigits: 0 });
}

/** April–March FY: April (month index 3) starts a new FY */
function buildFyOptions() {
    const today = new Date();
    const currentFyYear = today.getMonth() >= 3 ? today.getFullYear() + 1 : today.getFullYear();
    const options = [];
    for (let y = currentFyYear - 2; y <= currentFyYear + 1; y++) {
        options.push({
            label: `FY ${y}`, value: `FY ${y}`,
            startDate: `${y - 1}-04-01`,
            endDate:   `${y}-03-01`
        });
    }
    return { options, currentFyYear };
}

function monthLabelFor(startDate) {
    const mo     = startDate.substring(5, 7);
    const yr     = Number(startDate.substring(0, 4));
    const fyYear = (parseInt(mo, 10) >= 4) ? yr + 1 : yr;
    return `${MONTH_NAMES_FULL[mo] ?? mo} FY ${fyYear}`;
}

export default class ForecastEnhanced extends LightningElement {
    @track rows = [];
    @track totals = null;
    @track conversionRate = null;
    @track isLoading = true;
    @track savingConversion = false;
    @track error = null;
    @track isManager = false;

    // User selector
    @track users = [];
    @track selectedUserId = null;

    // Fiscal year
    @track fyOptions = [];
    @track selectedFyLabel = '';
    fyInfo = null;

    // Drill-down
    @track showDrill = false;
    @track drillLoading = false;
    @track drillRows = [];
    @track drillTitle = '';
    @track drillError = null;

    // Column resize (non-reactive)
    _resizing = false;
    _resizeCol = null;
    _resizeStartX = 0;
    _resizeStartWidth = 0;
    _boundMouseMove = null;
    _boundMouseUp = null;

    // ─── Getters ─────────────────────────────────────────────────────────────

    get conversionLabel() {
        if (this.conversionRate == null) return '-';
        return `${Number(this.conversionRate).toFixed(0)}%`;
    }

    get totalRowLabel() {
        return `Total: ${this.selectedFyLabel} (${this.rows.length} Months)`;
    }

    get noDrillRows() {
        return !this.drillLoading && this.drillRows.length === 0 && !this.drillError;
    }

    /**
     * Flattened row list for the table.
     * Each month row is followed by its (optionally visible) member sub-rows.
     */
    get flatRows() {
        const result = [];
        const today  = new Date();
        const currentMonthKey = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}`;

        for (const row of this.rows) {
            result.push({
                ...row,
                _key:        row.startDate,
                _isMonthRow: true,
                _rowClass:   'month-row' + (row.isCurrent ? ' current-month-row' : '')
            });

            if (this.isManager && row.isExpanded && row.members) {
                for (const m of row.members) {
                    result.push({
                        ...m,
                        _key:        `${row.startDate}_${m.userId}`,
                        _isMonthRow: false,
                        _rowClass:   'member-row',
                        isCurrent:   false
                    });
                }
            }
        }
        return result;
    }

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        const { options, currentFyYear } = buildFyOptions();
        this.fyOptions      = options;
        this.selectedFyLabel = `FY ${currentFyYear}`;
        this.fyInfo         = this.fyOptions.find(o => o.value === this.selectedFyLabel);
        this._loadUsers();
        this.loadData();
    }

    async _loadUsers() {
        try { this.users = await getUsers(); }
        catch (e) { console.error('Could not load users:', e); }
    }

    // ─── Data loading ─────────────────────────────────────────────────────────

    async loadData() {
        this.isLoading = true;
        this.error     = null;
        this.showDrill = false;
        try {
            const [rate, data] = await Promise.all([
                getConversionRate({ fiscalYear: this.selectedFyLabel, userId: this.selectedUserId }),
                getForecastData({ startDate: this.fyInfo.startDate, endDate: this.fyInfo.endDate, userId: this.selectedUserId })
            ]);
            this.conversionRate = rate ?? null;
            this.isManager      = data.isManager === true;
            this.buildRows(data.rows, {});
        } catch (e) {
            this.error = e.body?.message ?? e.message ?? 'Failed to load forecast data.';
        } finally {
            this.isLoading = false;
        }
    }

    buildRows(rawRows, expandedStates = {}) {
        const today           = new Date();
        const currentMonthKey = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}`;
        const conversion      = this.conversionRate ? Number(this.conversionRate) / 100 : null;

        let tQuota = 0, tClosed = 0, tCommit = 0, tBestCase = 0, tPipeline = 0;

        this.rows = rawRows.map(r => {
            const mo         = r.startDate.substring(5, 7);
            const yr         = Number(r.startDate.substring(0, 4));
            const fyYear     = (parseInt(mo, 10) >= 4) ? yr + 1 : yr;
            const monthLabel = `${MONTH_NAMES_FULL[mo] ?? mo} FY ${fyYear}`;
            const rowKey     = `${r.startDate.substring(0, 4)}-${mo}`;
            const isCurrent  = rowKey === currentMonthKey;

            const quota    = Number(r.quota    ?? 0);
            const closed   = Number(r.closed   ?? 0);
            const commit   = Number(r.commit   ?? 0);
            const bestCase = Number(r.bestCase ?? 0);
            const pipeline = Number(r.pipeline ?? 0);

            tQuota    += quota;
            tClosed   += closed;
            tCommit   += commit;
            tBestCase += bestCase;
            tPipeline += pipeline;

            const reqPipe      = conversion ? quota / conversion : null;
            const currPipe     = closed + commit + bestCase + pipeline;
            const gap          = reqPipe != null ? reqPipe - currPipe : null;
            const isExpanded   = expandedStates[r.startDate] === true;

            // Process member sub-rows (for manager view)
            let members = [];
            if (r.members && r.members.length > 0) {
                members = r.members.map(m => {
                    const mQ  = Number(m.quota    ?? 0);
                    const mCl = Number(m.closed   ?? 0);
                    const mCo = Number(m.commit   ?? 0);
                    const mBC = Number(m.bestCase ?? 0);
                    const mPi = Number(m.pipeline ?? 0);
                    const mCP = mCl + mCo + mBC + mPi;
                    const mRP = conversion ? mQ / conversion : null;
                    const mG  = mRP != null ? mRP - mCP : null;
                    return {
                        userId:                    m.userId,
                        userName:                  m.userName,
                        startDate:                 r.startDate,
                        conversionLabel:           this.conversionLabel,
                        quotaFormatted:            fmt(mQ),
                        closedFormatted:           fmt(mCl),
                        commitFormatted:           fmt(mCo),
                        bestCaseFormatted:         fmt(mBC),
                        pipelineFormatted:         fmt(mPi),
                        currentPipelineFormatted:  fmt(mCP),
                        requiredPipelineFormatted: mRP != null ? fmt(mRP) : '-',
                        gapFormatted:              mG  != null ? fmt(mG)  : '-',
                        gapClass:                  (mG != null && mG > 0) ? 'gap-negative' : '',
                        _quota: mQ, _closed: mCl, _commit: mCo, _bestCase: mBC, _pipeline: mPi
                    };
                });
            }

            return {
                startDate: r.startDate,
                monthLabel,
                isCurrent,
                isExpanded,
                members,
                conversionLabel:           this.conversionLabel,
                quotaFormatted:            fmt(quota),
                closedFormatted:           fmt(closed),
                commitFormatted:           fmt(commit),
                bestCaseFormatted:         fmt(bestCase),
                pipelineFormatted:         fmt(pipeline),
                requiredPipelineFormatted: reqPipe  != null ? fmt(reqPipe)  : '-',
                currentPipelineFormatted:  fmt(currPipe),
                gapFormatted:              gap != null ? fmt(gap) : '-',
                gapClass:                  (gap != null && gap > 0) ? 'gap-negative' : '',
                _quota: quota, _closed: closed, _commit: commit, _bestCase: bestCase, _pipeline: pipeline
            };
        });

        const tReq  = conversion ? tQuota / conversion : null;
        const tCurr = tClosed + tCommit + tBestCase + tPipeline;
        const tGap  = tReq != null ? tReq - tCurr : null;

        this.totals = {
            quotaFormatted:            fmt(tQuota),
            closedFormatted:           fmt(tClosed),
            commitFormatted:           fmt(tCommit),
            bestCaseFormatted:         fmt(tBestCase),
            pipelineFormatted:         fmt(tPipeline),
            requiredPipelineFormatted: tReq  != null ? fmt(tReq)  : '-',
            currentPipelineFormatted:  fmt(tCurr),
            gapFormatted:              tGap  != null ? fmt(tGap)  : '-',
            gapClass:                  (tGap != null && tGap > 0) ? 'gap-negative' : ''
        };
    }

    // ─── Month expand / collapse ──────────────────────────────────────────────

    handleMonthToggle(event) {
        const startDate = event.currentTarget.dataset.month;
        this.rows = this.rows.map(r =>
            r.startDate === startDate
                ? { ...r, isExpanded: !r.isExpanded }
                : r
        );
    }

    // ─── User & FY selection ──────────────────────────────────────────────────

    handleUserChange(event) {
        const val = event.detail.value;
        this.selectedUserId = (val === '_me_' || !val) ? null : val;
        this.loadData();
    }

    handleFyChange(event) {
        this.selectedFyLabel = event.detail.value;
        this.fyInfo          = this.fyOptions.find(o => o.value === this.selectedFyLabel);
        this.loadData();
    }

    // ─── Conversion rate ──────────────────────────────────────────────────────

    handleConversionInput(event)   { this.conversionRate = event.target.value; }
    handleConversionBlur(event)    { this.conversionRate = event.target.value; this._rebuildRows(); }
    handleConversionKeydown(event) {
        if (event.key === 'Enter') { this.conversionRate = event.target.value; this._rebuildRows(); }
    }

    _rebuildRows() {
        if (!this.rows.length) return;
        const expandedStates = {};
        this.rows.forEach(r => { expandedStates[r.startDate] = r.isExpanded; });

        const rawRows = this.rows.map(r => ({
            startDate: r.startDate,
            quota: r._quota, closed: r._closed, commit: r._commit,
            bestCase: r._bestCase, pipeline: r._pipeline,
            members: r.members ? r.members.map(m => ({
                userId: m.userId, userName: m.userName,
                quota: m._quota, closed: m._closed, commit: m._commit,
                bestCase: m._bestCase, pipeline: m._pipeline
            })) : []
        }));
        this.buildRows(rawRows, expandedStates);
    }

    async saveConversion() {
        if (this.conversionRate == null || this.conversionRate === '') return;
        this.savingConversion = true;
        try {
            await saveConversionRate({
                rate: Number(this.conversionRate),
                fiscalYear: this.selectedFyLabel,
                userId: this.selectedUserId
            });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Saved',
                message: `Conversion rate saved as ${Number(this.conversionRate).toFixed(2)}%`,
                variant: 'success'
            }));
            this._rebuildRows();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error saving',
                message: e.body?.message ?? 'Could not save conversion rate.',
                variant: 'error'
            }));
        } finally {
            this.savingConversion = false;
        }
    }

    // ─── Deal drill-down ──────────────────────────────────────────────────────

    async handleCategoryClick(event) {
        const startDate = event.currentTarget.dataset.month;
        const category  = event.currentTarget.dataset.category;

        this.drillTitle   = `${monthLabelFor(startDate)} — ${CATEGORY_LABELS[category] ?? category}`;
        this.showDrill    = true;
        this.drillLoading = true;
        this.drillRows    = [];
        this.drillError   = null;

        try {
            const deals = await getDealsForCell({
                userId: this.selectedUserId, startDate, forecastCategory: category
            });
            this.drillRows = deals.map((d, i) => ({
                ...d, rowNum: i + 1, amountFormatted: fmt(d.amount)
            }));
        } catch (e) {
            this.drillError = e.body?.message ?? e.message ?? 'Failed to load deals.';
        } finally {
            this.drillLoading = false;
        }

        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const panel = this.template.querySelector('.drill-panel');
            if (panel) panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }, 100);
    }

    closeDrill() {
        this.showDrill = false;
        this.drillRows = [];
    }

    // ─── Column resize ────────────────────────────────────────────────────────

    handleResizeMousedown(event) {
        event.preventDefault();
        const th = event.currentTarget.parentElement;
        this._resizing       = true;
        this._resizeCol      = th;
        this._resizeStartX   = event.clientX;
        this._resizeStartWidth = th.offsetWidth;
        this._boundMouseMove = this._handleResizeMousemove.bind(this);
        this._boundMouseUp   = this._handleResizeMouseup.bind(this);
        // eslint-disable-next-line @lwc/lwc/no-document-query
        document.addEventListener('mousemove', this._boundMouseMove);
        // eslint-disable-next-line @lwc/lwc/no-document-query
        document.addEventListener('mouseup',   this._boundMouseUp);
        const table = this.template.querySelector('.forecast-table');
        if (table) table.classList.add('no-select');
    }

    _handleResizeMousemove(event) {
        if (!this._resizing || !this._resizeCol) return;
        const newWidth = Math.max(60, this._resizeStartWidth + event.clientX - this._resizeStartX);
        this._resizeCol.style.width    = `${newWidth}px`;
        this._resizeCol.style.minWidth = `${newWidth}px`;
    }

    _handleResizeMouseup() {
        this._resizing   = false;
        this._resizeCol  = null;
        // eslint-disable-next-line @lwc/lwc/no-document-query
        document.removeEventListener('mousemove', this._boundMouseMove);
        // eslint-disable-next-line @lwc/lwc/no-document-query
        document.removeEventListener('mouseup',   this._boundMouseUp);
        const table = this.template.querySelector('.forecast-table');
        if (table) table.classList.remove('no-select');
    }

    disconnectedCallback() {
        if (this._boundMouseMove) {
            // eslint-disable-next-line @lwc/lwc/no-document-query
            document.removeEventListener('mousemove', this._boundMouseMove);
        }
        if (this._boundMouseUp) {
            // eslint-disable-next-line @lwc/lwc/no-document-query
            document.removeEventListener('mouseup', this._boundMouseUp);
        }
    }
}